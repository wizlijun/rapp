//! Forward pacing (spec §5.3): a delay-based rate controller. Pure logic, no clocks or I/O;
//! time comes in as the `now` argument.
// Task 2/3 build the pacer and wire it into the relay link; until then only tests use this.
#![cfg_attr(not(test), allow(dead_code))]

use std::collections::VecDeque;
use std::time::{Duration, Instant};

/// How often the relay link steps the controller.
pub(crate) const TICK: Duration = Duration::from_millis(100);
/// Queueing (rtt - base) above this means the forward is in the way of sessions.
pub(crate) const TARGET: Duration = Duration::from_millis(10);
/// The rate never goes below this (bit/s).
pub(crate) const FLOOR_BPS: u64 = 256_000;
/// Stuck at the floor with queueing this long: the queue is not ours, rebase.
const REBASE_AFTER: Duration = Duration::from_secs(10);

pub(crate) struct Control {
    /// Minimum rtt seen since the connection began (rebased when stuck at the floor).
    base: Option<Duration>,
    /// Current allowed rate in bit/s; `None` when not pacing.
    rate: Option<u64>,
    /// When the rate last grew or was cut.
    last_change: Option<Instant>,
    /// Since when the rate has sat at the floor with queueing above target.
    stuck_since: Option<Instant>,
    /// Recent rtt samples, for the rebase minimum.
    recent: VecDeque<(Instant, Duration)>,
}

impl Control {
    pub(crate) fn new() -> Control {
        Control { base: None, rate: None, last_change: None, stuck_since: None, recent: VecDeque::new() }
    }

    pub(crate) fn base(&self) -> Option<Duration> {
        self.base
    }

    /// One control step. Returns the allowed rate (bit/s) while `pacing`, else `None`.
    pub(crate) fn step(&mut self, now: Instant, rtt: Duration, sent_bps: u64, pacing: bool) -> Option<u64> {
        self.base = Some(self.base.map_or(rtt, |b| b.min(rtt)));
        self.recent.push_back((now, rtt));
        while self.recent.front().is_some_and(|(t, _)| now.duration_since(*t) > REBASE_AFTER) {
            self.recent.pop_front();
        }
        if !pacing {
            self.rate = None;
            self.last_change = None;
            self.stuck_since = None;
            return None;
        }
        let Some(rate) = self.rate else {
            let start = sent_bps.max(FLOOR_BPS);
            self.rate = Some(start);
            self.last_change = Some(now);
            self.stuck_since = None;
            return Some(start);
        };
        let base = self.base.unwrap_or(rtt);
        let queue = rtt.saturating_sub(base);
        let due = self.last_change.is_none_or(|t| now.duration_since(t) >= rtt);
        let mut rate = rate;
        if queue > TARGET {
            if due {
                rate = (rate / 2).max(FLOOR_BPS);
                self.last_change = Some(now);
            }
        } else if due {
            let cap = (sent_bps / 4 * 5 + sent_bps % 4 * 5 / 4).max(FLOOR_BPS);
            rate = (rate + rate / 20).min(cap).max(FLOOR_BPS);
            self.last_change = Some(now);
        }
        if rate == FLOOR_BPS && queue > TARGET {
            let since = *self.stuck_since.get_or_insert(now);
            if now.duration_since(since) >= REBASE_AFTER {
                self.base = self.recent.iter().map(|(_, r)| *r).min();
                self.stuck_since = None;
            }
        } else {
            self.stuck_since = None;
        }
        self.rate = Some(rate);
        Some(rate)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ms(n: u64) -> Duration {
        Duration::from_millis(n)
    }

    /// A control with the base fixed at 30 ms and pacing started at `sent`.
    fn started(t0: Instant, sent: u64) -> Control {
        let mut c = Control::new();
        assert_eq!(c.step(t0, ms(30), sent, true), Some(sent.max(FLOOR_BPS)));
        c
    }

    #[test]
    fn starts_at_the_sent_rate_with_a_floor() {
        let t0 = Instant::now();
        assert_eq!(Control::new().step(t0, ms(30), 10_000_000, true), Some(10_000_000));
        assert_eq!(Control::new().step(t0, ms(30), 0, true), Some(FLOOR_BPS));
    }

    #[test]
    fn halves_when_the_queue_passes_the_target_once_per_rtt() {
        let t0 = Instant::now();
        let mut c = started(t0, 10_000_000);
        assert_eq!(c.step(t0 + ms(100), ms(60), 10_000_000, true), Some(5_000_000));
        assert_eq!(c.step(t0 + ms(110), ms(60), 10_000_000, true), Some(5_000_000));
        assert_eq!(c.step(t0 + ms(170), ms(60), 10_000_000, true), Some(2_500_000));
    }

    #[test]
    fn grows_five_percent_per_rtt_up_to_a_cap() {
        let t0 = Instant::now();
        let mut c = started(t0, 4_000_000);
        assert_eq!(c.step(t0 + ms(32), ms(32), 4_000_000, true), Some(4_200_000));
        assert_eq!(c.step(t0 + ms(40), ms(32), 4_000_000, true), Some(4_200_000));
        assert_eq!(c.step(t0 + ms(64), ms(32), 4_000_000, true), Some(4_410_000));
        let mut last = 0;
        for i in 3..200u64 {
            last = c.step(t0 + ms(32 * i), ms(32), 4_000_000, true).unwrap();
            assert!(last <= 5_000_000);
        }
        assert_eq!(last, 5_000_000);
    }

    #[test]
    fn never_below_the_floor() {
        let t0 = Instant::now();
        let mut c = started(t0, 10_000_000);
        for i in 1..=200u64 {
            let r = c.step(t0 + TICK * i as u32, ms(130), 1_000_000, true).unwrap();
            assert!(r >= FLOOR_BPS);
        }
    }

    #[test]
    fn rebases_after_ten_seconds_stuck_at_the_floor() {
        let t0 = Instant::now();
        let mut c = started(t0, 10_000_000);
        let mut floor_at = None;
        let mut i = 1u64;
        while c.base() == Some(ms(30)) && i < 1000 {
            let now = t0 + TICK * i as u32;
            let r = c.step(now, ms(80), 1_000_000, true).unwrap();
            if r == FLOOR_BPS && floor_at.is_none() {
                floor_at = Some(now);
            }
            i += 1;
        }
        assert_eq!(c.base(), Some(ms(80)));
        let held = t0 + TICK * (i - 1) as u32 - floor_at.unwrap();
        assert!(held >= Duration::from_secs(10) && held < Duration::from_secs(11), "{held:?}");
        let now = t0 + TICK * i as u32;
        let r = c.step(now, ms(80), 1_000_000, true).unwrap();
        assert!(r > FLOOR_BPS, "grows after rebase: {r}");
    }

    #[test]
    fn base_is_the_minimum_since_new() {
        let t0 = Instant::now();
        let mut c = Control::new();
        c.step(t0, ms(40), 0, false);
        c.step(t0 + ms(100), ms(30), 0, false);
        c.step(t0 + ms(200), ms(35), 0, true);
        assert_eq!(c.base(), Some(ms(30)));
    }

    #[test]
    fn not_pacing_clears_the_rate() {
        let t0 = Instant::now();
        let mut c = started(t0, 10_000_000);
        c.step(t0 + ms(100), ms(60), 10_000_000, true);
        assert_eq!(c.step(t0 + ms(200), ms(30), 10_000_000, false), None);
        assert_eq!(c.step(t0 + ms(300), ms(30), 3_000_000, true), Some(3_000_000));
    }
}
