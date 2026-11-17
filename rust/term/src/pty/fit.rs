//! Which console's size the host window follows (spec §4.3).
//!
//! A pure, clock-injected state machine: no I/O. Viewers report what they want
//! and when they act; `take` says whether a resize request is due.

use std::collections::HashMap;
use std::time::{Duration, Instant};

pub type Conn = u64;

pub const MIN_COLS: u16 = 20;
pub const MIN_ROWS: u16 = 5;
/// How long the actor must be idle before another console may take over.
pub const HANDOVER: Duration = Duration::from_secs(2);

#[derive(Clone, Copy, PartialEq, Eq)]
struct Want {
    fit: bool,
    cols: u16,
    rows: u16,
}

#[derive(Default)]
pub struct Fit {
    next: Conn,
    wants: HashMap<Conn, Want>,
    actor: Option<Conn>,
    last_op: Option<Instant>,
    pending: Option<(u16, u16)>,
}

impl Fit {
    pub fn join(&mut self) -> Conn {
        self.next += 1;
        self.next
    }

    pub fn view(&mut self, c: Conn, fit: bool, cols: u16, rows: u16, now: Instant) {
        let new = Want { fit, cols, rows };
        let old = self.wants.insert(c, new);
        if old.is_some_and(|o| !o.fit) && fit {
            self.op(c, now);
            if self.actor == Some(c) {
                self.request();
            }
        } else if self.actor.is_none() && fit {
            self.actor = Some(c);
            self.last_op = None;
            self.request();
        } else if self.actor == Some(c) && fit && old != Some(new) {
            self.request();
        }
    }

    pub fn input(&mut self, c: Conn, now: Instant) {
        self.op(c, now);
    }

    pub fn leave(&mut self, c: Conn) {
        self.wants.remove(&c);
        if self.actor == Some(c) {
            self.actor = None;
            self.last_op = None;
        }
    }

    /// The size to ask the window for, `(cols, rows)`, already floored.
    pub fn take(&mut self) -> Option<(u16, u16)> {
        self.pending.take()
    }

    fn op(&mut self, c: Conn, now: Instant) {
        if self.actor == Some(c) {
            self.last_op = Some(now);
            return;
        }
        let free = match (self.actor, self.last_op) {
            (None, _) | (Some(_), None) => true,
            (Some(_), Some(t)) => now.saturating_duration_since(t) >= HANDOVER,
        };
        if free {
            self.actor = Some(c);
            self.last_op = Some(now);
            self.request();
        }
    }

    fn request(&mut self) {
        let want = self.actor.and_then(|a| self.wants.get(&a));
        if let Some(w) = want.filter(|w| w.fit) {
            self.pending = Some((w.cols.max(MIN_COLS), w.rows.max(MIN_ROWS)));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ms(t0: Instant, n: u64) -> Instant {
        t0 + Duration::from_millis(n)
    }

    #[test]
    fn the_first_fit_view_takes_over() {
        let mut f = Fit::default();
        let a = f.join();
        f.view(a, true, 100, 30, Instant::now());
        assert_eq!(f.take(), Some((100, 30)));
        assert_eq!(f.take(), None);
    }

    #[test]
    fn a_fit_false_view_never_requests() {
        let t0 = Instant::now();
        let mut f = Fit::default();
        let a = f.join();
        f.view(a, false, 100, 30, t0);
        f.input(a, t0);
        assert_eq!(f.take(), None);
    }

    #[test]
    fn a_second_viewer_opening_does_not_take_over() {
        let t0 = Instant::now();
        let mut f = Fit::default();
        let (a, b) = (f.join(), f.join());
        f.view(a, true, 100, 30, t0);
        f.take();
        f.view(b, true, 80, 20, t0);
        assert_eq!(f.take(), None);
    }

    #[test]
    fn handover_waits_for_two_idle_seconds() {
        let t0 = Instant::now();
        let mut f = Fit::default();
        let (a, b) = (f.join(), f.join());
        f.view(a, true, 100, 30, t0);
        f.take();
        f.view(b, true, 80, 20, t0);
        f.input(a, t0);
        f.input(b, ms(t0, 500));
        assert_eq!(f.take(), None);
        f.input(b, ms(t0, 2000));
        assert_eq!(f.take(), Some((80, 20)));
        f.input(b, ms(t0, 2100));
        assert_eq!(f.take(), None);
    }

    #[test]
    fn typing_by_the_actor_does_not_rewrite() {
        let t0 = Instant::now();
        let mut f = Fit::default();
        let a = f.join();
        f.view(a, true, 100, 30, t0);
        f.take();
        for n in 1..=3 {
            f.input(a, ms(t0, n * 100));
            assert_eq!(f.take(), None);
        }
    }

    #[test]
    fn the_actor_s_new_size_applies_but_a_bystander_s_does_not() {
        let t0 = Instant::now();
        let mut f = Fit::default();
        let (a, b) = (f.join(), f.join());
        f.view(a, true, 100, 30, t0);
        f.take();
        f.view(b, true, 90, 25, ms(t0, 10));
        assert_eq!(f.take(), None);
        f.view(a, true, 110, 35, ms(t0, 20));
        assert_eq!(f.take(), Some((110, 35)));
    }

    #[test]
    fn turning_fit_on_is_an_operation() {
        let t0 = Instant::now();
        let mut f = Fit::default();
        let (a, b) = (f.join(), f.join());
        f.view(a, true, 100, 30, t0);
        f.take();
        f.view(b, false, 80, 20, ms(t0, 10));
        f.view(b, true, 80, 20, ms(t0, 3000));
        assert_eq!(f.take(), Some((80, 20)));
    }

    #[test]
    fn the_actor_leaving_frees_the_seat() {
        let t0 = Instant::now();
        let mut f = Fit::default();
        let (a, b) = (f.join(), f.join());
        f.view(a, true, 100, 30, t0);
        f.view(b, true, 70, 20, t0);
        f.take();
        f.leave(a);
        assert_eq!(f.take(), None);
        f.view(b, true, 70, 20, ms(t0, 10));
        assert_eq!(f.take(), Some((70, 20)));
    }

    #[test]
    fn sizes_are_floored() {
        let mut f = Fit::default();
        let a = f.join();
        f.view(a, true, 10, 3, Instant::now());
        assert_eq!(f.take(), Some((20, 5)));
    }
}
