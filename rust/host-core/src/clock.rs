//! Every timestamp and every wait in host-core goes through `Clock`, so tests
//! can run the host faster than real time and the boundary test can prove no
//! other file reads the system clock.

use std::sync::OnceLock;
use std::time::{Duration, Instant};

pub trait Clock: Send + Sync {
    /// Seconds, monotonic, the same scale as Swift's `now` (only differences matter).
    fn now(&self) -> f64;
    /// Waits `seconds` of this clock's time.
    fn sleep(&self, seconds: f64);
    /// `seconds` of this clock's time as a real duration, for socket and channel timeouts.
    fn real(&self, seconds: f64) -> Duration;
}

/// A duration from seconds; negative, NaN and huge values are clamped
/// (`Duration::from_secs_f64` would panic on them).
fn duration(seconds: f64) -> Duration {
    if seconds.is_nan() || seconds <= 0.0 {
        return Duration::ZERO;
    }
    // About 31 years: longer than any wait the host makes.
    Duration::from_secs_f64(seconds.min(1.0e9))
}

/// The real monotonic clock. `now()` counts from the first use in this process.
#[derive(Debug, Clone, Copy, Default)]
pub struct SystemClock;

fn process_start() -> Instant {
    static START: OnceLock<Instant> = OnceLock::new();
    *START.get_or_init(Instant::now)
}

impl Clock for SystemClock {
    fn now(&self) -> f64 {
        process_start().elapsed().as_secs_f64()
    }

    fn sleep(&self, seconds: f64) {
        std::thread::sleep(duration(seconds));
    }

    fn real(&self, seconds: f64) -> Duration {
        duration(seconds)
    }
}

/// For tests: time runs `speed` times faster than real time.
/// `ScaledClock::new(20.0)` makes a 3 s wait take 150 ms.
#[derive(Debug, Clone, Copy)]
pub struct ScaledClock {
    start: Instant,
    speed: f64,
}

impl ScaledClock {
    pub fn new(speed: f64) -> Self {
        assert!(speed.is_finite() && speed > 0.0, "clock speed must be positive");
        ScaledClock { start: Instant::now(), speed }
    }

    pub fn speed(&self) -> f64 {
        self.speed
    }
}

impl Clock for ScaledClock {
    fn now(&self) -> f64 {
        self.start.elapsed().as_secs_f64() * self.speed
    }

    fn sleep(&self, seconds: f64) {
        std::thread::sleep(self.real(seconds));
    }

    fn real(&self, seconds: f64) -> Duration {
        duration(seconds / self.speed)
    }
}
