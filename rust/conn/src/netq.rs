//! Network quality of a link to the relay: four levels from round trips and losses
//! (spec 2026-11-14-rapp-network-status §3.4), and the stall test that starts fast probing (§3.2).

use std::collections::VecDeque;
use std::time::{Duration, Instant};

/// Best first: a later variant is a worse network.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum Level {
    Strong,
    Ok,
    Weak,
    Down,
}

impl Level {
    pub fn as_str(self) -> &'static str {
        match self {
            Level::Strong => "strong",
            Level::Ok => "ok",
            Level::Weak => "weak",
            Level::Down => "down",
        }
    }
}

/// How far back the median and the loss look.
pub const WINDOW: Duration = Duration::from_secs(10);
/// A better level must hold this long before it shows (worse shows at once).
pub const RISE_AFTER: Duration = Duration::from_secs(10);
/// Fast probes missed in a row that mean down.
pub const MISSES_DOWN: u32 = 3;
/// Losses are counted only over at least this many packets sent.
const MIN_SENT: u64 = 10;

/// Strong: rtt < 100 ms and loss < 2 %; Ok: rtt < 300 ms and loss < 5 %.
const LIMITS: [(Level, u32, f64); 2] = [(Level::Strong, 100, 0.02), (Level::Ok, 300, 0.05)];
/// Rising into a level needs this share of its limits, so a value sitting on a limit does not
/// make the level flap (spec §8: 95–105 ms changes it at most twice a minute).
const RISE_MARGIN: f64 = 0.9;

fn classify(rtt_ms: u32, loss: f64, margin: f64) -> Level {
    for (level, rtt, lost) in LIMITS {
        if f64::from(rtt_ms) < f64::from(rtt) * margin && loss < lost * margin {
            return level;
        }
    }
    Level::Weak
}

/// The level of one link, fed with samples; no clock of its own.
#[derive(Debug, Default)]
pub struct Meter {
    rtts: VecDeque<(Instant, Duration)>,
    counts: VecDeque<(Instant, u64, u64)>,
    misses: u32,
    level: Option<Level>,
    rising: Option<(Level, Instant)>,
}

impl Meter {
    pub fn new() -> Meter {
        Meter::default()
    }

    /// A round trip seen at `now`, with the link's running lost and sent packet counts.
    pub fn sample(&mut self, now: Instant, rtt: Duration, lost: u64, sent: u64) {
        self.misses = 0;
        self.rtts.push_back((now, rtt));
        self.counts.push_back((now, lost, sent));
        while self.rtts.front().is_some_and(|(t, _)| now.duration_since(*t) > WINDOW) {
            self.rtts.pop_front();
        }
        while self.counts.len() > 2 && self.counts.front().is_some_and(|(t, _, _)| now.duration_since(*t) > WINDOW) {
            self.counts.pop_front();
        }
        let (rtt_ms, loss) = (self.rtt_ms().unwrap_or(0), self.loss());
        let now_level = self.level;
        let measured = classify(rtt_ms, loss, 1.0);
        match now_level {
            // First sample, or back from down: what is measured shows at once (§8: leave down within 5 s).
            None | Some(Level::Down) => self.set(measured),
            Some(cur) if measured > cur => self.set(measured),
            Some(cur) => {
                let better = classify(rtt_ms, loss, RISE_MARGIN);
                if better >= cur {
                    self.rising = None;
                    return;
                }
                match self.rising {
                    Some((l, since)) if l == better => {
                        if now.duration_since(since) >= RISE_AFTER {
                            self.set(better);
                        }
                    }
                    _ => self.rising = Some((better, now)),
                }
            }
        }
    }

    /// A fast probe got no answer. True when that makes the link down.
    pub fn miss(&mut self) -> bool {
        self.misses += 1;
        if self.misses >= MISSES_DOWN {
            self.down();
            return true;
        }
        false
    }

    /// The link is gone (closed, or not dialed): down, and what was measured before is dropped.
    pub fn down(&mut self) {
        self.rtts.clear();
        self.counts.clear();
        self.misses = 0;
        self.set(Level::Down);
    }

    /// Nothing known (no relay): no level.
    pub fn clear(&mut self) {
        *self = Meter::default();
    }

    fn set(&mut self, level: Level) {
        self.level = Some(level);
        self.rising = None;
    }

    pub fn level(&self) -> Option<Level> {
        self.level
    }

    /// The median round trip of the window, in ms.
    pub fn rtt_ms(&self) -> Option<u32> {
        let mut v: Vec<Duration> = self.rtts.iter().map(|(_, d)| *d).collect();
        if v.is_empty() {
            return None;
        }
        v.sort();
        Some(u32::try_from(v[v.len() / 2].as_millis()).unwrap_or(u32::MAX))
    }

    /// Lost / sent over the window; 0 while fewer than 10 packets were sent.
    pub fn loss(&self) -> f64 {
        let (Some(a), Some(b)) = (self.counts.front(), self.counts.back()) else { return 0.0 };
        let sent = b.2.saturating_sub(a.2);
        if sent < MIN_SENT {
            return 0.0;
        }
        (b.1.saturating_sub(a.1) as f64 / sent as f64).min(1.0)
    }
}

/// Packets received stopped: no datagram for 12 s although keep-alives go every 10 s.
#[derive(Debug)]
pub struct Stall {
    last: Option<(u64, Instant)>,
}

/// No datagram for this long is a stall.
pub const STALL_AFTER: Duration = Duration::from_secs(12);

impl Stall {
    pub fn new() -> Stall {
        Stall { last: None }
    }

    /// `rx` is the link's running count of datagrams received. True while it has not moved for 12 s.
    pub fn observe(&mut self, now: Instant, rx: u64) -> bool {
        match self.last {
            Some((n, since)) if n == rx => now.duration_since(since) >= STALL_AFTER,
            _ => {
                self.last = Some((rx, now));
                false
            }
        }
    }

    /// A new link: counting starts again.
    pub fn reset(&mut self) {
        self.last = None;
    }
}

impl Default for Stall {
    fn default() -> Stall {
        Stall::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ms(n: u64) -> Duration {
        Duration::from_millis(n)
    }

    /// One sample a second for `secs` seconds from `t`; returns the time after.
    fn feed(m: &mut Meter, t: Instant, secs: u64, rtt: u64) -> Instant {
        for i in 0..secs {
            m.sample(t + Duration::from_secs(i), ms(rtt), 0, 100 * i);
        }
        t + Duration::from_secs(secs)
    }

    #[test]
    fn levels_by_rtt() {
        for (rtt, want) in [(30, Level::Strong), (200, Level::Ok), (600, Level::Weak)] {
            let mut m = Meter::new();
            feed(&mut m, Instant::now(), 3, rtt);
            assert_eq!(m.level(), Some(want), "{rtt} ms");
            assert_eq!(m.rtt_ms(), Some(rtt as u32));
        }
    }

    #[test]
    fn three_misses_are_down() {
        let mut m = Meter::new();
        feed(&mut m, Instant::now(), 2, 30);
        assert!(!m.miss());
        assert!(!m.miss());
        assert!(m.miss());
        assert_eq!(m.level(), Some(Level::Down));
        assert_eq!(m.rtt_ms(), None);
    }

    #[test]
    fn a_sample_between_misses_starts_the_count_again() {
        let mut m = Meter::new();
        let t = feed(&mut m, Instant::now(), 1, 30);
        m.miss();
        m.miss();
        m.sample(t, ms(30), 0, 0);
        assert!(!m.miss());
        assert_eq!(m.level(), Some(Level::Strong));
    }

    #[test]
    fn drops_at_once_rises_after_ten_seconds() {
        let mut m = Meter::new();
        let t = feed(&mut m, Instant::now(), 3, 200);
        assert_eq!(m.level(), Some(Level::Ok));
        // The window still holds the 200 ms samples: the median turns strong after a few.
        let mut t2 = t;
        let mut strong_at = None;
        for i in 0..30 {
            t2 = t + Duration::from_secs(i);
            m.sample(t2, ms(30), 0, 0);
            if m.level() == Some(Level::Strong) && strong_at.is_none() {
                strong_at = Some(i);
            }
        }
        let at = strong_at.expect("rose");
        assert!(at >= 10, "rose after {at} s");
        m.sample(t2 + Duration::from_secs(1), ms(900), 0, 0);
        m.sample(t2 + Duration::from_secs(2), ms(900), 0, 0);
        m.sample(t2 + Duration::from_secs(3), ms(900), 0, 0);
        m.sample(t2 + Duration::from_secs(4), ms(900), 0, 0);
        m.sample(t2 + Duration::from_secs(5), ms(900), 0, 0);
        m.sample(t2 + Duration::from_secs(6), ms(900), 0, 0);
        assert_eq!(m.level(), Some(Level::Weak));
    }

    #[test]
    fn leaves_down_at_once() {
        let mut m = Meter::new();
        m.down();
        m.sample(Instant::now(), ms(200), 0, 0);
        assert_eq!(m.level(), Some(Level::Ok));
    }

    #[test]
    fn loss_counts_only_over_ten_packets() {
        let mut m = Meter::new();
        let t = Instant::now();
        m.sample(t, ms(30), 0, 0);
        m.sample(t + Duration::from_secs(1), ms(30), 1, 5);
        assert_eq!(m.loss(), 0.0);
        m.sample(t + Duration::from_secs(2), ms(30), 3, 100);
        assert!((m.loss() - 0.03).abs() < 1e-9);
        assert_eq!(m.level(), Some(Level::Ok)); // 3 % loss is not strong
    }

    #[test]
    fn jitter_on_the_strong_limit_barely_flaps() {
        let mut m = Meter::new();
        let t = Instant::now();
        let mut changes = 0;
        let mut last = None;
        for i in 0..60u64 {
            let rtt = if i % 2 == 0 { 95 } else { 105 };
            m.sample(t + Duration::from_secs(i), ms(rtt), 0, 0);
            if m.level() != last {
                if last.is_some() {
                    changes += 1;
                }
                last = m.level();
            }
        }
        assert!(changes <= 2, "{changes} changes");
    }

    #[test]
    fn stall_after_twelve_seconds_without_datagrams() {
        let mut s = Stall::new();
        let t = Instant::now();
        assert!(!s.observe(t, 5));
        assert!(!s.observe(t + Duration::from_secs(11), 5));
        assert!(s.observe(t + Duration::from_secs(12), 5));
        assert!(!s.observe(t + Duration::from_secs(13), 6));
        assert!(!s.observe(t + Duration::from_secs(24), 6));
        assert!(s.observe(t + Duration::from_secs(25), 6));
    }
}
