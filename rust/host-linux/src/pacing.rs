//! Protocol-compatible network saving and frame acknowledgement pacing.
//! Times are supplied by the caller so slow networks can be tested without sleeps.
use crate::wire::Settings;
use std::collections::VecDeque;

#[derive(Default)]
pub struct Pacing {
    pending: VecDeque<f64>,
    samples: VecDeque<(f64, f64)>,
    last_rtt: f64,
    first: bool,
    pub level: u8,
    queueing_since: Option<f64>,
    last_queueing: Option<f64>,
    paused_at: Option<f64>,
}
impl Pacing {
    pub fn effective(&self, mut s: Settings) -> Settings {
        if self.level >= 1 {
            s.fps = s.fps.min(5);
        }
        if self.level >= 2 {
            s.mode = 3;
            s.density = s.density.min(1.);
        }
        s
    }
    fn steps(s: Settings) -> Vec<u8> {
        let mut result = vec![];
        if s.fps > 5 {
            result.push(1);
        }
        if s.mode != 3 || s.density > 1. {
            result.push(2);
        }
        result
    }
    pub fn configure(&mut self, s: Settings) {
        let steps = Self::steps(s);
        if s.pinned {
            self.level = 0;
        } else if self.level > 0 && !steps.contains(&self.level) {
            self.level = steps.into_iter().rfind(|n| *n < self.level).unwrap_or(0);
        }
    }
    /// Keep in-flight ACK ordering, but exclude time spent deliberately paused from
    /// network samples, the ACK deadline and saving-level decisions.
    pub fn set_paused(&mut self, paused: bool, now: f64) {
        if paused {
            self.paused_at.get_or_insert(now);
            return;
        }
        let Some(start) = self.paused_at.take() else {
            return;
        };
        let duration = (now - start).max(0.);
        for sent in &mut self.pending {
            *sent += duration;
        }
        for (sent, _) in &mut self.samples {
            *sent += duration;
        }
        if let Some(last) = &mut self.last_queueing {
            *last += duration;
        }
        self.queueing_since = None;
    }
    pub fn sent(&mut self, now: f64) {
        self.pending.push_back(self.paused_at.unwrap_or(now));
    }
    pub fn oldest_age(&self, now: f64) -> f64 {
        if self.paused_at.is_some() {
            return 0.;
        }
        self.pending.front().map_or(0., |sent| now - sent)
    }
    fn base(&self, now: f64) -> Option<f64> {
        let minimum = |v: Vec<f64>| v.into_iter().reduce(f64::min);
        minimum(
            self.samples
                .iter()
                .filter(|(sent, _)| *sent >= now - 10.)
                .map(|(_, rtt)| *rtt)
                .collect(),
        )
        .or_else(|| {
            minimum(
                self.samples
                    .iter()
                    .rev()
                    .take(8)
                    .map(|(_, rtt)| *rtt)
                    .collect(),
            )
        })
    }
    fn queueing(&self, now: f64) -> bool {
        self.base(now)
            .is_some_and(|base| self.last_rtt.max(self.oldest_age(now)) > base + 0.1)
    }
    pub fn ready(&self, now: f64, fps: u8) -> bool {
        let cap = if self.queueing(now) {
            1
        } else {
            self.base(now).map_or(1, |base| {
                (1 + (fps as f64 * base - 1e-9).ceil().max(0.) as usize).min(fps.max(2) as usize)
            })
        };
        self.pending.len() < cap
    }
    pub fn ack(&mut self, now: f64, processing_ms: u16, s: Settings) {
        let Some(sent) = self.pending.pop_front() else {
            return;
        };
        if self.paused_at.is_some() {
            return;
        }
        self.last_rtt = (now - sent - processing_ms as f64 / 1000.).max(0.);
        self.samples.push_back((sent, self.last_rtt));
        if self.samples.len() > 4096 {
            self.samples.pop_front();
        }
        if !self.first {
            self.first = true;
            if now - sent > 1. && !s.pinned && self.level == 0 {
                self.level = Self::steps(s).last().copied().unwrap_or(0);
            }
        }
        self.observe(now, true, s);
    }
    pub fn observe(&mut self, now: f64, ack: bool, s: Settings) {
        if self.paused_at.is_some() {
            return;
        }
        self.configure(s);
        if self.queueing(now) {
            let since = *self.queueing_since.get_or_insert(now);
            self.last_queueing = Some(now);
            if !s.pinned && now - since >= 3. {
                if let Some(next) = Self::steps(s).into_iter().find(|n| *n > self.level) {
                    self.level = next;
                    self.queueing_since = Some(now);
                }
            }
        } else {
            self.queueing_since = None;
            if self.level > 0 {
                let last = *self.last_queueing.get_or_insert(now);
                if ack && now - last >= 30. {
                    self.level = Self::steps(s)
                        .into_iter()
                        .rfind(|n| *n < self.level)
                        .unwrap_or(0);
                    self.last_queueing = Some(now);
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn settings() -> Settings {
        Settings {
            mode: 0,
            fps: 30,
            density: 2.,
            focus: false,
            pinned: false,
        }
    }
    #[test]
    fn latency_processing_and_queueing_control_inflight_and_recovery() {
        let mut p = Pacing::default();
        let s = settings();
        p.sent(0.);
        assert!(!p.ready(0.01, 30));
        p.ack(0.3, 100, s);
        assert!((p.base(0.3).unwrap() - 0.2).abs() < 1e-9);
        for _ in 0..7 {
            p.sent(0.3);
        }
        assert!(!p.ready(0.3, 30));
        p.observe(0.7, false, s);
        p.observe(3.8, false, s);
        assert_eq!(p.level, 1);
        p.observe(6.9, false, s);
        assert_eq!(p.level, 2);
        for _ in 0..7 {
            p.ack(7., 0, s);
        }
        p.sent(8.);
        p.ack(8.2, 0, s);
        p.sent(39.);
        p.ack(39.2, 0, s);
        assert_eq!(p.level, 1);
        p.sent(70.);
        p.ack(70.2, 0, s);
        assert_eq!(p.level, 0);
    }
    #[test]
    fn a_pause_is_not_counted_as_a_slow_network() {
        let mut p = Pacing::default();
        let s = settings();
        p.sent(0.);
        p.ack(0.1, 0, s);
        p.sent(1.);
        p.ack(1.5, 0, s); // slow: queueing from here
        p.observe(1.6, false, s);
        // Paused 5 s: the server does not observe meanwhile.
        p.set_paused(true, 1.6);
        p.set_paused(false, 6.6);
        p.observe(6.6, false, s);
        assert_eq!(p.level, 0);
    }
    #[test]
    fn paused_inflight_frames_keep_ack_order_without_timeouts_or_saving() {
        let mut p = Pacing::default();
        let s = settings();
        p.sent(0.);
        p.ack(0.1, 0, s);
        p.sent(1.);
        p.set_paused(true, 1.1);
        p.set_paused(true, 10.); // repeated pause commands do not restart the clock
        p.sent(20.); // an encode already in flight still has to reach the decoder
        assert_eq!(p.oldest_age(60.), 0.);
        p.observe(60., false, s);
        p.ack(60., 0, s);
        assert_eq!(p.pending.len(), 1);
        assert_eq!(p.level, 0);
        p.set_paused(false, 61.1);
        assert!(p.oldest_age(61.1).abs() < 1e-8);
        p.ack(61.2, 0, s);
        assert_eq!(p.level, 0);
        assert!(p.pending.is_empty());
        assert!((p.last_rtt - 0.1).abs() < 1e-8);
        p.sent(62.);
        assert!(p.oldest_age(78.) >= 15., "real stalls still expire");
    }
    #[test]
    fn slow_first_ack_pinning_and_noop_steps_match_mac() {
        let mut p = Pacing::default();
        let mut s = settings();
        p.sent(0.);
        p.ack(1.1, 0, s);
        assert_eq!(p.level, 2);
        let effective = p.effective(s);
        assert_eq!(
            (effective.mode, effective.fps, effective.density),
            (3, 5, 1.)
        );
        s.pinned = true;
        p.configure(s);
        assert_eq!(p.level, 0);
        s.pinned = false;
        s.fps = 1;
        s.mode = 3;
        s.density = 1.;
        assert!(Pacing::steps(s).is_empty());
        p.level = 2;
        p.configure(s);
        assert_eq!(p.level, 0);
    }
}
