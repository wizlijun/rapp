//! Abuse limits: failure backoff, per-minute rates, connection caps and byte pacing.

use std::collections::{HashMap, VecDeque};
use std::net::IpAddr;
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::{Duration, Instant};

const MAX_KEYS: usize = 100_000;
const WINDOW: Duration = Duration::from_secs(60);

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

/// `::ffff:a.b.c.d` is the same source as `a.b.c.d`; everything else is unchanged.
pub fn source_key(ip: IpAddr) -> IpAddr {
    match ip {
        IpAddr::V6(v6) => v6.to_ipv4_mapped().map(IpAddr::V4).unwrap_or(ip),
        _ => ip,
    }
}

struct Entry {
    fails: u32,
    locked_until: Option<Instant>,
}

/// Locks out a key after repeated consecutive failures.
pub struct Backoff {
    lock_after: u32,
    max_secs: u64,
    cap: usize,
    map: Mutex<HashMap<String, Entry>>,
}

impl Backoff {
    pub fn new(lock_after: u32, max_secs: u64) -> Backoff {
        Backoff { lock_after, max_secs, cap: MAX_KEYS, map: Mutex::new(HashMap::new()) }
    }

    #[cfg(test)]
    fn with_cap(lock_after: u32, max_secs: u64, cap: usize) -> Backoff {
        Backoff { cap, ..Backoff::new(lock_after, max_secs) }
    }

    /// Remaining lock in whole seconds (rounded up, at least 1), or None.
    pub fn locked(&self, key: &str, now: Instant) -> Option<u64> {
        let until = lock(&self.map).get(key)?.locked_until?;
        let left = until.checked_duration_since(now)?;
        if left.is_zero() {
            return None;
        }
        Some(left.as_secs() + u64::from(left.subsec_nanos() > 0))
    }

    /// Record a failure; returns how long this failure locks the key, if at all.
    pub fn fail(&self, key: &str, now: Instant) -> Option<u64> {
        let mut map = lock(&self.map);
        if !map.contains_key(key) && map.len() >= self.cap {
            map.retain(|_, e| e.locked_until.is_some_and(|u| u > now));
            if map.len() >= self.cap {
                return None;
            }
        }
        let e = map.entry(key.to_string()).or_insert(Entry { fails: 0, locked_until: None });
        e.fails = e.fails.saturating_add(1);
        if e.fails < self.lock_after {
            return None;
        }
        let exp = (e.fails - self.lock_after).min(32);
        let secs = (1u64 << exp).min(self.max_secs);
        e.locked_until = Some(now + Duration::from_secs(secs));
        Some(secs)
    }

    pub fn reset(&self, key: &str) {
        lock(&self.map).remove(key);
    }
}

/// Sliding 60 s window, at most N events per key.
pub struct Rate {
    per_min: u32,
    cap: usize,
    map: Mutex<HashMap<String, VecDeque<Instant>>>,
}

fn expire(q: &mut VecDeque<Instant>, now: Instant) {
    while q.front().is_some_and(|t| now.saturating_duration_since(*t) >= WINDOW) {
        q.pop_front();
    }
}

impl Rate {
    pub fn new(per_min: u32) -> Rate {
        Rate { per_min, cap: MAX_KEYS, map: Mutex::new(HashMap::new()) }
    }

    #[cfg(test)]
    fn with_cap(per_min: u32, cap: usize) -> Rate {
        Rate { cap, ..Rate::new(per_min) }
    }

    pub fn allow(&self, key: &str, now: Instant) -> bool {
        let mut map = lock(&self.map);
        if !map.contains_key(key) && map.len() >= self.cap {
            map.retain(|_, q| {
                expire(q, now);
                !q.is_empty()
            });
            if map.len() >= self.cap {
                return false;
            }
        }
        let q = map.entry(key.to_string()).or_default();
        expire(q, now);
        if q.len() >= self.per_min as usize {
            return false;
        }
        q.push_back(now);
        true
    }
}

#[derive(Default)]
struct Counts {
    total: usize,
    per_ip: HashMap<IpAddr, usize>,
}

/// Caps connections in total and per source address.
pub struct Conns {
    total: usize,
    per_ip: usize,
    counts: Arc<Mutex<Counts>>,
}

/// Releases its connection slot on drop.
pub struct ConnGuard {
    ip: IpAddr,
    counts: Arc<Mutex<Counts>>,
}

impl Conns {
    pub fn new(total: usize, per_ip: usize) -> Conns {
        Conns { total, per_ip, counts: Arc::new(Mutex::new(Counts::default())) }
    }

    /// A slot for one more connection from `ip`, or the name of the limit that refused it
    /// (`"max_conns"` or `"max_conns_per_ip"`, the config items).
    pub fn admit(&self, ip: IpAddr) -> Result<ConnGuard, &'static str> {
        let ip = source_key(ip);
        let mut c = lock(&self.counts);
        if c.total >= self.total {
            return Err("max_conns");
        }
        if c.per_ip.get(&ip).copied().unwrap_or(0) >= self.per_ip {
            return Err("max_conns_per_ip");
        }
        c.total += 1;
        *c.per_ip.entry(ip).or_insert(0) += 1;
        Ok(ConnGuard { ip, counts: self.counts.clone() })
    }
}

impl Drop for ConnGuard {
    fn drop(&mut self) {
        let mut c = lock(&self.counts);
        c.total = c.total.saturating_sub(1);
        if let Some(n) = c.per_ip.get_mut(&self.ip) {
            *n = n.saturating_sub(1);
            if *n == 0 {
                c.per_ip.remove(&self.ip);
            }
        }
    }
}

struct BucketState {
    tokens: f64,
    last: tokio::time::Instant,
}

/// Token bucket in bytes per second; capacity is one second's worth. 0 means unlimited.
pub struct Bucket {
    bps: u64,
    state: Mutex<BucketState>,
}

impl Bucket {
    pub fn new(bps: u64) -> Bucket {
        Bucket { bps, state: Mutex::new(BucketState { tokens: bps as f64, last: tokio::time::Instant::now() }) }
    }

    pub fn unlimited(&self) -> bool {
        self.bps == 0
    }

    /// Wait until `n` bytes may pass. `n` above the capacity goes into debt and is slept off.
    pub async fn take(&self, n: usize) {
        if self.bps == 0 || n == 0 {
            return;
        }
        let wait = {
            let mut s = lock(&self.state);
            let now = tokio::time::Instant::now();
            let rate = self.bps as f64;
            let elapsed = now.saturating_duration_since(s.last).as_secs_f64();
            s.tokens = (s.tokens + elapsed * rate).min(rate);
            s.last = now;
            s.tokens -= n as f64;
            if s.tokens >= 0.0 {
                return;
            }
            Duration::from_secs_f64(-s.tokens / rate)
        };
        tokio::time::sleep(wait).await;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ip(s: &str) -> IpAddr {
        s.parse().unwrap()
    }

    #[test]
    fn v4_mapped_v6_is_the_same_source() {
        assert_eq!(source_key(ip("::ffff:1.2.3.4")), ip("1.2.3.4"));
        assert_eq!(source_key(ip("2001:db8::1")), ip("2001:db8::1"));
    }

    #[test]
    fn backoff_follows_the_formula() {
        let b = Backoff::new(5, 300);
        let t = Instant::now();
        for _ in 0..4 {
            assert_eq!(b.fail("k", t), None);
        }
        assert_eq!(b.locked("k", t), None);
        assert_eq!(b.fail("k", t), Some(1));
        assert_eq!(b.locked("k", t), Some(1));
        assert_eq!(b.locked("k", t + Duration::from_millis(1500)), None);
        assert_eq!(b.fail("k", t), Some(2));
        for n in 7..=12 {
            assert_eq!(b.fail("k", t), Some(1 << (n - 5)));
        }
        assert_eq!(b.fail("k", t), Some(256));
        assert_eq!(b.fail("k", t), Some(300));
        assert_eq!(b.fail("k", t), Some(300));
        assert_eq!(b.locked("k", t + Duration::from_millis(299_500)), Some(1));
        b.reset("k");
        assert_eq!(b.locked("k", t), None);
        assert_eq!(b.fail("k", t), None);
    }

    #[test]
    fn backoff_does_not_overflow_on_huge_counts() {
        let b = Backoff::new(1, 300);
        let t = Instant::now();
        for _ in 0..200 {
            b.fail("k", t);
        }
        assert_eq!(b.fail("k", t), Some(300));
    }

    #[test]
    fn backoff_table_is_bounded() {
        let b = Backoff::with_cap(2, 300, 3);
        let t = Instant::now();
        b.fail("a", t);
        b.fail("b", t);
        b.fail("c", t);
        // full of unlocked entries: they are dropped, the new key is tracked
        assert_eq!(b.fail("d", t), None);
        assert_eq!(b.fail("d", t), Some(1));
        // fill with locked entries: a new key is refused
        assert_eq!(b.fail("e", t), None);
        assert_eq!(b.fail("e", t), Some(1));
        assert_eq!(b.fail("f", t), None);
        assert_eq!(b.fail("f", t), Some(1));
        assert_eq!(b.fail("g", t), None);
        assert_eq!(b.fail("g", t), None);
        assert_eq!(b.locked("g", t), None);
        // once locks expire, room is made again
        let later = t + Duration::from_secs(5);
        assert_eq!(b.fail("g", later), None);
        assert_eq!(b.fail("g", later), Some(1));
    }

    #[test]
    fn rate_allows_n_per_minute_per_key() {
        let r = Rate::new(10);
        let t = Instant::now();
        for _ in 0..10 {
            assert!(r.allow("a", t));
        }
        assert!(!r.allow("a", t));
        assert!(r.allow("b", t));
        assert!(r.allow("a", t + Duration::from_secs(61)));
    }

    #[test]
    fn rate_table_is_bounded() {
        let r = Rate::with_cap(1, 2);
        let t = Instant::now();
        assert!(r.allow("a", t));
        assert!(r.allow("b", t));
        assert!(!r.allow("c", t));
        assert!(r.allow("c", t + Duration::from_secs(61)));
    }

    #[test]
    fn conns_enforces_per_ip_and_total_and_releases_on_drop() {
        let c = Conns::new(3, 2);
        let g1 = c.admit(ip("1.2.3.4")).unwrap();
        let _g2 = c.admit(ip("::ffff:1.2.3.4")).unwrap();
        assert_eq!(c.admit(ip("1.2.3.4")).err(), Some("max_conns_per_ip"));
        drop(g1);
        let _g3 = c.admit(ip("1.2.3.4")).unwrap();
        let _g4 = c.admit(ip("9.9.9.9")).unwrap();
        // total is now 3; the total cap is named even for an address also at its own cap
        assert_eq!(c.admit(ip("5.6.7.8")).err(), Some("max_conns"));
        assert_eq!(c.admit(ip("1.2.3.4")).err(), Some("max_conns"));
    }

    #[test]
    fn conns_removes_zeroed_ip_entries() {
        let c = Conns::new(3, 2);
        drop(c.admit(ip("1.2.3.4")).unwrap());
        let counts = lock(&c.counts);
        assert_eq!(counts.total, 0);
        assert!(counts.per_ip.is_empty());
    }

    #[test]
    fn types_are_shareable() {
        fn ok<T: Send + Sync>() {}
        ok::<Backoff>();
        ok::<Rate>();
        ok::<Conns>();
        ok::<ConnGuard>();
        ok::<Bucket>();
    }

    #[tokio::test(start_paused = true)]
    async fn bucket_zero_is_unlimited_and_nonzero_paces() {
        let b = Bucket::new(0);
        assert!(b.unlimited());
        b.take(1 << 30).await;

        let b = Bucket::new(1000);
        assert!(!b.unlimited());
        let start = tokio::time::Instant::now();
        b.take(3000).await;
        assert!(start.elapsed() >= Duration::from_millis(1500));
        // a burst within one second's worth is immediate when full
        let b = Bucket::new(1000);
        let start = tokio::time::Instant::now();
        b.take(1000).await;
        assert!(start.elapsed() < Duration::from_millis(10));
    }
}
