//! One direction of a simulated weak link: a serial bottleneck with a bounded queue, delay, jitter,
//! random and burst loss, scheduled outages. Schedules (rate, delay, bursts) are derived from the seed
//! and the period index, so they do not depend on call order; only random loss and jitter use the
//! link's own RNG stream.

use super::profile::Profile;
use rand::rngs::StdRng;
use rand::{Rng, SeedableRng};
use std::time::Duration;

pub struct Link {
    p: Profile,
    seed: u64,
    rng: StdRng,
    busy_until: Duration,
    last_delivery: Duration,
}

/// Cheap seed mixer (splitmix64 finaliser) so sub-seeds for neighbouring indexes are unrelated.
fn mix(a: u64, b: u64, c: u64) -> u64 {
    let mut z = a ^ b.wrapping_mul(0x9E37_79B9_7F4A_7C15) ^ c.wrapping_mul(0xD1B5_4A32_D192_ED03);
    z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
    z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
    z ^ (z >> 31)
}

/// Log-uniform value in [lo, hi] for `u` in [0,1).
fn log_uniform(lo: u32, hi: u32, u: f64) -> f64 {
    let (lo, hi) = (lo.max(1) as f64, hi.max(1) as f64);
    if hi <= lo {
        return lo;
    }
    (lo.ln() + u * (hi.ln() - lo.ln())).exp()
}

impl Link {
    pub fn new(p: &Profile, dir_seed: u64) -> Link {
        let seed = p.seed ^ dir_seed;
        Link {
            p: p.clone(),
            seed,
            rng: StdRng::seed_from_u64(seed),
            busy_until: Duration::ZERO,
            last_delivery: Duration::ZERO,
        }
    }

    fn period_index(&self, now: Duration) -> u64 {
        if self.p.rate_every_s > 0.0 {
            (now.as_secs_f64() / self.p.rate_every_s) as u64
        } else {
            0
        }
    }

    /// Rate in kbit/s at `now`; 0 = unlimited.
    fn rate_kbps(&self, now: Duration) -> f64 {
        let (lo, hi) = self.p.rate_kbps;
        if lo == 0 && hi == 0 {
            return 0.0;
        }
        if self.p.rate_every_s <= 0.0 {
            return lo.max(1) as f64;
        }
        let u = StdRng::seed_from_u64(mix(self.seed, self.period_index(now), 1)).random::<f64>();
        log_uniform(lo, hi, u)
    }

    fn delay(&self, now: Duration) -> Duration {
        let (lo, hi) = self.p.delay_ms;
        let ms = if self.p.rate_every_s <= 0.0 {
            lo as f64
        } else {
            let u = StdRng::seed_from_u64(mix(self.seed, self.period_index(now), 2)).random::<f64>();
            log_uniform(lo, hi, u)
        };
        Duration::from_secs_f64(ms / 1000.0)
    }

    /// The loss-burst window (start, end) of period `k`: one burst per `60 / bursts_per_min` seconds.
    pub(crate) fn burst_window(&self, k: u64) -> Option<(Duration, Duration)> {
        if self.p.bursts_per_min <= 0.0 || self.p.burst_ms == 0 {
            return None;
        }
        let period = 60.0 / self.p.bursts_per_min;
        let burst = self.p.burst_ms as f64 / 1000.0;
        let slack = (period - burst).max(0.0);
        let off = StdRng::seed_from_u64(mix(self.seed, k, 3)).random::<f64>() * slack;
        let start = k as f64 * period + off;
        Some((Duration::from_secs_f64(start), Duration::from_secs_f64(start + burst)))
    }

    pub(crate) fn in_burst(&self, now: Duration) -> bool {
        if self.p.bursts_per_min <= 0.0 {
            return false;
        }
        let k = (now.as_secs_f64() * self.p.bursts_per_min / 60.0) as u64;
        matches!(self.burst_window(k), Some((s, e)) if now >= s && now < e)
    }

    pub fn down(&self, now: Duration) -> bool {
        let t = now.as_secs_f64();
        self.p.outages.iter().any(|o| o.every_s > 0.0 && t >= o.offset_s && (t - o.offset_s) % o.every_s < o.for_s)
    }

    pub fn rebind_epoch(&self, now: Duration) -> u64 {
        match self.p.rebind_every_s {
            Some(e) if e > 0.0 => (now.as_secs_f64() / e) as u64,
            _ => 0,
        }
    }

    /// Offer a packet of `len` bytes at `now` (time since start). Returns its delivery time, or `None` if dropped.
    pub fn admit(&mut self, now: Duration, len: usize) -> Option<Duration> {
        // Always draw, so the random stream does not depend on which other rules fired.
        let lost = self.rng.random::<f64>() < self.p.loss;
        let jitter = if self.p.jitter_ms > 0 { self.rng.random_range(0..=self.p.jitter_ms) } else { 0 };
        if self.down(now) || self.in_burst(now) || lost {
            return None;
        }
        let rate = self.rate_kbps(now);
        let start = now.max(self.busy_until);
        let tx = if rate > 0.0 { Duration::from_secs_f64(len as f64 * 8.0 / (rate * 1000.0)) } else { Duration::ZERO };
        let out = start + tx;
        if self.p.queue_ms > 0 && out - now > Duration::from_millis(self.p.queue_ms as u64) {
            return None;
        }
        self.busy_until = out;
        let at = (out + self.delay(now) + Duration::from_millis(jitter as u64)).max(self.last_delivery);
        self.last_delivery = at;
        Some(at)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ms(n: u64) -> Duration {
        Duration::from_millis(n)
    }

    fn quiet(name: &str) -> Profile {
        let mut p = Profile::named(name).unwrap();
        p.loss = 0.0;
        p.outages.clear();
        p
    }

    #[test]
    fn same_seed_same_fate() {
        let p = Profile::named("n1").unwrap();
        let (mut a, mut b) = (Link::new(&p, 0), Link::new(&p, 0));
        for i in 0..2000u64 {
            let now = ms(i * 7);
            assert_eq!(a.admit(now, 100 + (i as usize % 900)), b.admit(now, 100 + (i as usize % 900)));
        }
        // The other direction differs.
        let (mut a, mut c) = (Link::new(&p, 0), Link::new(&p, 1));
        let diff = (0..2000u64).any(|i| a.admit(ms(i * 7), 500) != c.admit(ms(i * 7), 500));
        assert!(diff);
    }

    #[test]
    fn rate_limit_spaces_packets() {
        let mut l = Link::new(&quiet("s0"), 0);
        for k in 0..25u64 {
            let at = l.admit(Duration::ZERO, 1000).unwrap();
            let want = 150.0 + (k + 1) as f64 * 40.0;
            assert!((at.as_secs_f64() * 1000.0 - want).abs() <= 1.0, "k={k} at={at:?} want={want}");
        }
    }

    #[test]
    fn queue_tail_drop() {
        let mut l = Link::new(&quiet("s0"), 0);
        let mut ok = 0;
        for _ in 0..60 {
            if let Some(at) = l.admit(Duration::ZERO, 1000) {
                assert!(at <= ms(1000 + 150));
                ok += 1;
            }
        }
        assert!(ok > 0 && ok < 60, "ok={ok}");
    }

    #[test]
    fn loss_rate_close_to_profile() {
        let mut l = Link::new(&Profile::named("n3").unwrap(), 0);
        let lost = (0..10000u64).filter(|i| l.admit(ms(i * 10), 100).is_none()).count();
        let r = lost as f64 / 10000.0;
        assert!((0.27..0.33).contains(&r), "r={r}");
    }

    #[test]
    fn bursts_drop_everything_inside() {
        let mut l = Link::new(&quiet("n1"), 0);
        let mut inside = 0;
        for i in 0..24000u64 {
            let now = ms(i * 5); // 120 s
            let r = l.admit(now, 1);
            if l.in_burst(now) {
                inside += 1;
                assert!(r.is_none(), "now={now:?}");
            } else {
                assert!(r.is_some(), "now={now:?}");
            }
        }
        assert!(inside > 0);
        // 6 bursts per minute, 200 ms each.
        let (s, e) = l.burst_window(3).unwrap();
        assert_eq!(e - s, ms(200));
    }

    #[test]
    fn outage_schedule() {
        let mut l = Link::new(&Profile::named("s0").unwrap(), 0);
        let s = Duration::from_secs_f64;
        assert!(l.down(s(30.0)) && l.down(s(39.9)) && !l.down(s(40.0)) && l.down(s(90.5)));
        assert!(!l.down(s(29.9)) && !l.down(s(100.0)));
        assert!(l.admit(s(35.0), 100).is_none());
    }

    #[test]
    fn jitter_never_reorders() {
        let mut l = Link::new(&quiet("n1"), 0);
        let mut last = Duration::ZERO;
        for i in 0..5000u64 {
            if let Some(at) = l.admit(ms(i * 3), 200) {
                assert!(at >= last);
                last = at;
            }
        }
    }

    #[test]
    fn rebind_epoch_counts() {
        let l = Link::new(&Profile::named("n4").unwrap(), 0);
        let s = Duration::from_secs;
        assert_eq!((l.rebind_epoch(s(119)), l.rebind_epoch(s(120)), l.rebind_epoch(s(250))), (0, 1, 2));
    }

    #[test]
    fn all_profiles_load() {
        for n in ["lan", "s0", "n1", "n2", "n3", "n4"] {
            Profile::named(n).unwrap();
        }
    }
}
