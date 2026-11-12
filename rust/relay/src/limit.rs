//! Failure rate limiting (spec §2.2): after 5 consecutive failures, the n-th failure
//! locks the key for `min(2^(n-5), 300)` seconds. A success clears the key. Memory only.
//! Also `Seldom`, which thins out a repeated log line per key.

use std::collections::HashMap;
use std::time::{Duration, Instant};

const FREE_FAILURES: u32 = 5;
const MAX_LOCK_SECS: u64 = 300;
const MAX_KEYS: usize = 100_000;

#[derive(Default)]
pub struct Limiter {
    keys: HashMap<String, (u32, Option<Instant>)>,
}

impl Limiter {
    /// Seconds left (rounded up) if `key` is locked.
    pub fn locked(&self, key: &str, now: Instant) -> Option<u64> {
        let until = self.keys.get(key)?.1?;
        let left = until.checked_duration_since(now).filter(|d| !d.is_zero())?;
        Some(left.as_millis().div_ceil(1000) as u64)
    }

    /// Counts a failure; returns the lock length when this failure (re)locks the key.
    pub fn fail(&mut self, key: &str, now: Instant) -> Option<u64> {
        if self.keys.len() >= MAX_KEYS {
            self.keys.retain(|_, (_, until)| until.is_some_and(|u| u > now));
        }
        let e = self.keys.entry(key.to_string()).or_default();
        e.0 += 1;
        if e.0 >= FREE_FAILURES {
            let secs = 1u64.checked_shl(e.0 - FREE_FAILURES).unwrap_or(u64::MAX).min(MAX_LOCK_SECS);
            e.1 = Some(now + Duration::from_secs(secs));
            return Some(secs);
        }
        None
    }

    pub fn reset(&mut self, key: &str) {
        self.keys.remove(key);
    }
}

/// Lets one event per key through per `every`: a presence probe that finds its host offline
/// every 30 s leaves one Warn line per 10 minutes, not twenty. Memory only, bounded.
pub struct Seldom {
    every: Duration,
    last: HashMap<String, Instant>,
}

impl Seldom {
    pub fn new(every: Duration) -> Seldom {
        Seldom { every, last: HashMap::new() }
    }

    /// True when `key` was not let through within `every` (it is let through now).
    pub fn first(&mut self, key: &str, now: Instant) -> bool {
        let fresh = |t: &Instant| now.saturating_duration_since(*t) < self.every;
        if self.last.get(key).is_some_and(fresh) {
            return false;
        }
        if self.last.len() >= MAX_KEYS {
            self.last.retain(|_, t| fresh(t));
            if self.last.len() >= MAX_KEYS {
                self.last.clear();
            }
        }
        self.last.insert(key.to_string(), now);
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn seldom_lets_one_through_per_key_per_window() {
        let mut s = Seldom::new(Duration::from_secs(600));
        let t = Instant::now();
        assert!(s.first("1.2.3.4|111", t));
        assert!(!s.first("1.2.3.4|111", t + Duration::from_secs(30)));
        assert!(!s.first("1.2.3.4|111", t + Duration::from_secs(599)));
        assert!(s.first("1.2.3.4|222", t + Duration::from_secs(30)), "another id is its own pair");
        assert!(s.first("5.6.7.8|111", t + Duration::from_secs(30)), "another source is its own pair");
        assert!(s.first("1.2.3.4|111", t + Duration::from_secs(600)), "after 10 minutes, once more");
        assert!(!s.first("1.2.3.4|111", t + Duration::from_secs(630)));
    }

    #[test]
    fn seldom_stays_bounded() {
        let mut s = Seldom::new(Duration::from_secs(600));
        let t = Instant::now();
        for i in 0..MAX_KEYS + 10 {
            assert!(s.first(&format!("k{i}"), t));
        }
        assert!(s.last.len() <= MAX_KEYS);
    }

    #[test]
    fn locks_after_five_failures_with_doubling_capped_at_300() {
        let mut l = Limiter::default();
        let t = Instant::now();
        for _ in 0..4 {
            l.fail("k", t);
            assert_eq!(l.locked("k", t), None);
        }
        l.fail("k", t); // 5th
        assert_eq!(l.locked("k", t), Some(1));
        assert_eq!(l.locked("k", t + Duration::from_millis(1000)), None);
        l.fail("k", t); // 6th
        assert_eq!(l.locked("k", t), Some(2));
        l.fail("k", t); // 7th
        assert_eq!(l.locked("k", t + Duration::from_millis(500)), Some(4));
        for _ in 0..100 {
            l.fail("k", t);
        }
        assert_eq!(l.locked("k", t), Some(300));
        assert_eq!(l.locked("other", t), None);
        l.reset("k");
        assert_eq!(l.locked("k", t), None);
    }
}
