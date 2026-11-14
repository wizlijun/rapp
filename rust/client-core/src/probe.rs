//! B's measure of the whole path to A (spec 2026-11-14-rapp-network-status §3.3), the same rules
//! as RappCore's `PathProbe`: a `ping` at once, then every 10 s; every 2 s while the user is
//! operating (input in the last 5 s) or a ping went unanswered. A ping with nothing at all from A
//! within 2 s is a miss (a pong may wait behind frames, but then the frames arrive); two misses in
//! a row are stalled, and anything from A ends that. Callers pass time in seconds and tick once a
//! second.

const IDLE_EVERY: f64 = 10.;
const FAST_EVERY: f64 = 2.;
const WAIT: f64 = 2.;
const ACTIVE_FOR: f64 = 5.;
const MISSES_STALLED: u32 = 2;

#[derive(Default)]
struct Pending {
    seq: u32,
    at: f64,
    missed: bool,
}

#[derive(Default)]
pub struct PathProbe {
    seq: u32,
    pending: Option<Pending>,
    last_ping: Option<f64>,
    last_received: Option<f64>,
    last_input: Option<f64>,
    misses: u32,
    stalled: bool,
}

impl PathProbe {
    pub fn stalled(&self) -> bool {
        self.stalled
    }

    /// The user sent input.
    pub fn input(&mut self, now: f64) {
        self.last_input = Some(now);
    }

    /// Once a second: the ping to send, if one is due, and the new stalled state when it changed.
    pub fn tick(&mut self, now: f64) -> (Option<u32>, Option<bool>) {
        let mut change = None;
        let heard = self.last_received.unwrap_or(f64::NEG_INFINITY);
        if let Some(p) = self.pending.as_mut().filter(|p| !p.missed && now - p.at >= WAIT && heard < p.at) {
            p.missed = true;
            self.misses += 1;
            if self.misses >= MISSES_STALLED && !self.stalled {
                self.stalled = true;
                change = Some(true);
            }
        }
        let active = self.last_input.is_some_and(|t| now - t < ACTIVE_FOR);
        let every = if active || self.misses > 0 { FAST_EVERY } else { IDLE_EVERY };
        if self.last_ping.is_some_and(|t| now - t < every) {
            return (None, change);
        }
        self.seq = self.seq.wrapping_add(1);
        self.pending = Some(Pending { seq: self.seq, at: now, missed: false });
        self.last_ping = Some(now);
        (Some(self.seq), change)
    }

    /// Something arrived from A. Some(false) when that ends a stall.
    pub fn received(&mut self, now: f64) -> Option<bool> {
        self.last_received = Some(now);
        self.misses = 0;
        if !self.stalled {
            return None;
        }
        self.stalled = false;
        Some(false)
    }

    /// The round trip in ms when `seq` is the newest ping (call `received` too).
    pub fn pong(&mut self, seq: u32, now: f64) -> Option<u32> {
        let p = self.pending.take_if(|p| p.seq == seq)?;
        Some(((now - p.at) * 1000.).round().max(0.) as u32)
    }
}
