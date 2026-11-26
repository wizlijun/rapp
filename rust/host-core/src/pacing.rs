//! Frame pacing and the traffic-saving ladder, ported from `SendPacer.swift`,
//! `WeakTier.swift`, `SaveLadder.swift` and `PacedSender.swift`.
//!
//! No clock of its own: every call takes `now` in seconds (the Task 1 clock's
//! scale). Swift's `PacedSender` reads a `now` closure and reports through
//! `transmit`, `onLevelChange` and `onEncoded` callbacks; the Rust one takes `now`
//! as an argument and returns what Swift would have called back, in call order
//! (`SenderOutput`). Swift's re-entrancy guard (`pumping`) has nothing to guard
//! here: nothing calls back into the sender while it pumps.

use std::collections::VecDeque;
use std::sync::Arc;

use crate::clock::Clock;
use crate::protocol::{CanvasRect, FramePayload, Mode};
use crate::tile::{EncodeReport, FrameEncoder};

/// Swift `Swift.max(a, b)`: `b >= a ? b : a`.
fn swift_max(a: f64, b: f64) -> f64 {
    if b >= a {
        b
    } else {
        a
    }
}

/// Swift `Sequence.min()` over doubles: the first element no later one is below.
fn swift_min_of(values: impl Iterator<Item = f64>) -> Option<f64> {
    let mut out: Option<f64> = None;
    for v in values {
        out = match out {
            Some(m) if !(v < m) => Some(m),
            _ => Some(v),
        };
    }
    out
}

/// Swift `Int((x * 1000).rounded())` for a time in seconds. `as` saturates where
/// Swift would trap; times here are far inside the range.
fn millis(seconds: f64) -> i64 {
    (seconds * 1000.0).round() as i64
}

// MARK: - SendPacer

/// Tracks frames in flight and ack round trips; decides how many frames may be
/// outstanding (SendPacer.swift). Callers pass time in seconds.
#[derive(Debug, Clone)]
pub struct SendPacer {
    pub fps: i64,
    /// (sent at, rtt) per acked frame, oldest first, at most `MAX_SAMPLES`.
    samples: VecDeque<(f64, f64)>,
    /// (sent at, captured) per frame in flight, oldest first.
    pending: VecDeque<(f64, f64)>,
    last_rtt: Option<f64>,
}

impl SendPacer {
    const WINDOW: f64 = 10.0;
    const FALLBACK_COUNT: usize = 8;
    const QUEUEING_MARGIN: f64 = 0.1;
    const MAX_SAMPLES: usize = 4096;

    pub fn new(fps: i64) -> Self {
        SendPacer { fps, samples: VecDeque::new(), pending: VecDeque::new(), last_rtt: None }
    }

    pub fn in_flight(&self) -> i64 {
        self.pending.len() as i64
    }

    pub fn last_rtt(&self) -> Option<f64> {
        self.last_rtt
    }

    pub fn sent(&mut self, at: f64, captured: f64) {
        self.pending.push_back((at, captured));
    }

    /// Matches the oldest in-flight frame: `(rtt, latency)`. None (and no change)
    /// when nothing is in flight.
    pub fn acked(&mut self, at: f64, processing_ms: u16) -> Option<(f64, f64)> {
        let (sent_at, captured) = self.pending.pop_front()?;
        // Swift: `max(0, at - f.sentAt - Double(processingMs) / 1000)`.
        let rtt = swift_max(0.0, at - sent_at - processing_ms as f64 / 1000.0);
        self.samples.push_back((sent_at, rtt));
        while self.samples.len() > Self::MAX_SAMPLES {
            self.samples.pop_front();
        }
        self.last_rtt = Some(rtt);
        Some((rtt, at - captured))
    }

    /// Min RTT among samples sent within the last 10 s; else min of the last 8
    /// samples; else None.
    pub fn base_rtt(&self, now: f64) -> Option<f64> {
        let in_window = swift_min_of(self.samples.iter().filter(|s| s.0 >= now - Self::WINDOW).map(|s| s.1));
        if in_window.is_some() {
            return in_window;
        }
        let skip = self.samples.len().saturating_sub(Self::FALLBACK_COUNT);
        swift_min_of(self.samples.iter().skip(skip).map(|s| s.1))
    }

    pub fn queueing(&self, now: f64) -> bool {
        let Some(base) = self.base_rtt(now) else {
            return false;
        };
        let oldest_age = self.pending.front().map(|p| now - p.0).unwrap_or(0.0);
        swift_max(self.last_rtt.unwrap_or(0.0), oldest_age) > base + Self::QUEUEING_MARGIN
    }

    pub fn cap(&self, now: f64) -> i64 {
        let Some(base) = self.base_rtt(now) else {
            return 1;
        };
        if self.queueing(now) {
            return 1;
        }
        // The epsilon keeps float noise (e.g. 9.000000000000002) from rounding a whole frame up.
        // Swift: `Int((Double(fps) * base - 1e-9).rounded(.up))`; `ceil(-1e-9)` is -0.0, i.e. 0.
        let want = 1 + (self.fps as f64 * base - 1e-9).ceil() as i64;
        want.min(2.max(self.fps))
    }

    pub fn reset(&mut self) {
        self.samples.clear();
        self.pending.clear();
        self.last_rtt = None;
    }
}

// MARK: - WeakTier

/// The traffic-saving level state machine (WeakTier.swift; spec
/// 2026-11-14-rapp-network-status §6.2). Queueing for 3 s goes one step down,
/// 3 s more another; 30 s without queueing (seen on an ack) goes one step up.
/// `steps` are the levels below 0 that save something (`save_ladder_steps`).
#[derive(Debug, Clone)]
pub struct WeakTier {
    level: i64,
    pub steps: Vec<i64>,
    /// Swift `pinned` is a property whose `didSet` drops the level to 0; here it is
    /// set through `set_pinned`.
    pinned: bool,
    queueing_since: Option<f64>,
    last_queueing: Option<f64>,
}

impl Default for WeakTier {
    fn default() -> Self {
        WeakTier { level: 0, steps: vec![1, 2], pinned: false, queueing_since: None, last_queueing: None }
    }
}

impl WeakTier {
    const DOWN_AFTER: f64 = 3.0;
    const UP_AFTER: f64 = 30.0;
    const SLOW_FIRST_ACK: f64 = 1.0;

    pub fn new() -> Self {
        Self::default()
    }

    pub fn level(&self) -> i64 {
        self.level
    }

    pub fn weak(&self) -> bool {
        self.level > 0
    }

    pub fn pinned(&self) -> bool {
        self.pinned
    }

    /// Automatic saving off (true): level 0 at once, and it stays there.
    pub fn set_pinned(&mut self, pinned: bool) {
        self.pinned = pinned;
        if pinned {
            self.level = 0;
        }
    }

    /// Returns the new level when it changed, otherwise None.
    pub fn observe(&mut self, now: f64, queueing: bool, on_ack: bool) -> Option<i64> {
        if queueing {
            let since = *self.queueing_since.get_or_insert(now);
            self.last_queueing = Some(now);
            if !self.pinned {
                if let Some(next) = self.steps.iter().copied().find(|&s| s > self.level) {
                    if now - since >= Self::DOWN_AFTER {
                        self.level = next;
                        self.queueing_since = Some(now);
                        return Some(self.level);
                    }
                }
            }
            return None;
        }
        self.queueing_since = None;
        // Entered via probe: no queueing seen yet, so the 30 s count starts at the first observation.
        if self.weak() && self.last_queueing.is_none() {
            self.last_queueing = Some(now);
        }
        if self.weak() && on_ack {
            if let Some(last) = self.last_queueing {
                if now - last >= Self::UP_AFTER {
                    self.level = self.steps.iter().copied().rfind(|&s| s < self.level).unwrap_or(0);
                    self.last_queueing = Some(now);
                    return Some(self.level);
                }
            }
        }
        None
    }

    /// First ack arrived later than 1 s: start at the last step (unless pinned).
    pub fn probe(&mut self, first_ack_delay: f64) -> Option<i64> {
        if !(first_ack_delay > Self::SLOW_FIRST_ACK) || self.pinned || self.level != 0 {
            return None;
        }
        let last = *self.steps.last()?;
        self.level = last;
        Some(self.level)
    }

    /// A new ceiling. The level stays; one that is no longer a step (it would save
    /// nothing) becomes the step above it. Returns the new level when it changed.
    pub fn set_steps(&mut self, new: Vec<i64>) -> Option<i64> {
        self.steps = new;
        if !(self.level > 0) || self.steps.contains(&self.level) {
            return None;
        }
        self.level = self.steps.iter().copied().rfind(|&s| s < self.level).unwrap_or(0);
        Some(self.level)
    }
}

// MARK: - SaveLadder

/// What A streams: mode, frame rate and capture density (SaveLadder.swift:4).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct StreamSpec {
    pub mode: Mode,
    pub fps: i64,
    pub density: f32,
}

const SAVING_FPS: i64 = 5;
const FLOOR_MODE: Mode = Mode::Duogray;
const FLOOR_DENSITY: f32 = 1.0;

/// The automatic traffic-saving ladder (spec 2026-11-14-rapp-network-status §6.2).
/// B's choice is the ceiling (level 0); level 1 caps the frame rate at 5 fps;
/// level 2 and above is the weak floor (duogray, density at most 1.0), also capped.
pub fn save_ladder_stream(level: i64, ceiling: StreamSpec) -> StreamSpec {
    match level {
        i64::MIN..=0 => ceiling,
        1 => StreamSpec { mode: ceiling.mode, fps: ceiling.fps.min(SAVING_FPS), density: ceiling.density },
        _ => StreamSpec {
            mode: FLOOR_MODE,
            fps: ceiling.fps.min(SAVING_FPS),
            // Swift `min(ceiling.density, floorDensity)`: `y < x ? y : x`.
            density: if FLOOR_DENSITY < ceiling.density { FLOOR_DENSITY } else { ceiling.density },
        },
    }
}

/// The levels below the ceiling that save something over the one above them.
pub fn save_ladder_steps(ceiling: StreamSpec) -> Vec<i64> {
    let mut out = Vec::new();
    let mut above = ceiling;
    for level in 1..=2 {
        let s = save_ladder_stream(level, ceiling);
        if s != above {
            out.push(level);
        }
        above = s;
    }
    out
}

// MARK: - PacedSender

/// Stats for the last second (PacedSender.swift:10).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Stats {
    pub rtt_ms: Option<i64>,
    pub base_rtt_ms: Option<i64>,
    pub latency_ms: Option<i64>,
    pub in_flight: i64,
    pub cap: i64,
    pub weak: bool,
    pub level: i64,
    /// Full frames encoded since the previous call.
    pub full_frames: i64,
    /// The slowest encode since the previous call, in ms (None when none ran).
    pub encode_ms_max: Option<i64>,
}

/// What a `PacedSender` call would have reported through Swift's callbacks.
#[derive(Debug, Clone, PartialEq)]
pub enum SenderOutput {
    /// Swift `transmit(region, payload)`: send `Message::Frame { region, payload }`.
    Frame { region: CanvasRect, payload: FramePayload },
    /// Swift `onLevelChange`: the saving level changed (0 = the ceiling).
    LevelChanged(i64),
    /// Swift `onEncoded`: what an encode sent, right after it.
    Encoded(EncodeReport),
}

struct Offer {
    samples: Vec<u8>,
    raw: Option<Vec<u8>>,
    width: usize,
    height: usize,
    region: CanvasRect,
    captured: f64,
}

struct Slice {
    region: CanvasRect,
    payload: FramePayload,
    captured: f64,
}

/// Sends encoded frames under the in-flight cap and drives the traffic-saving
/// level (`WeakTier`).
///
/// At most `cap` frames are outstanding; a changed frame is cut into slices, one
/// per free slot, and only the newest offered frame is kept while the slices go out.
pub struct PacedSender {
    encoder: FrameEncoder,
    pacer: SendPacer,
    tier: WeakTier,
    latest: Option<Offer>,
    queue: VecDeque<Slice>,
    /// B paused the pictures (v15 fps 0): nothing new is encoded; the newest offer waits for resume.
    paused: bool,
    session_first_frame: bool,
    first_sent_at: Option<f64>,
    first_ack_seen: bool,
    latency_ms: Option<i64>,
    full_frames: i64,
    encode_ms_max: Option<i64>,
    /// The last time the canvas became more approximate (or first inexact); settle waits 0.3 s from here.
    diverged_at: Option<f64>,
    last_region: CanvasRect,
    /// Times encodes (Swift reads its `now` closure before and after each). Without
    /// one, an encode takes no time, as with Swift's test clocks.
    timer: Option<Arc<dyn Clock>>,
    /// Swift `now()` during the current call: the call's `now` plus the encode time so far.
    t: f64,
    out: Vec<SenderOutput>,
}

impl PacedSender {
    const SLICE_LIMIT: usize = 32768;
    const FIRST_SLICE_LIMIT: usize = 8192;
    /// Each settle frame is one slice of at most this many bytes, so a frame
    /// captured meanwhile waits for at most one such slice.
    const SETTLE_LIMIT: usize = 8192;
    const SETTLE_DELAY: f64 = 0.3;

    pub fn new(mode: Mode, fps: i64) -> Self {
        PacedSender {
            encoder: FrameEncoder::new(mode),
            pacer: SendPacer::new(fps),
            tier: WeakTier::new(),
            latest: None,
            queue: VecDeque::new(),
            paused: false,
            session_first_frame: true,
            first_sent_at: None,
            first_ack_seen: false,
            latency_ms: None,
            full_frames: 0,
            encode_ms_max: None,
            diverged_at: None,
            last_region: CanvasRect::new(0.0, 0.0, 0.0, 0.0),
            timer: None,
            t: 0.0,
            out: Vec::new(),
        }
    }

    /// Times encodes with `clock` (same scale as the `now` arguments). The time an
    /// encode takes moves this call's `now` on, as Swift's closure would.
    pub fn set_timer(&mut self, clock: Arc<dyn Clock>) {
        self.timer = Some(clock);
    }

    pub fn weak(&self) -> bool {
        self.tier.weak()
    }

    pub fn level(&self) -> i64 {
        self.tier.level()
    }

    /// Bytes of the held offer (samples and raw pixels): at most one frame's worth.
    #[doc(hidden)]
    pub fn pending_bytes(&self) -> usize {
        self.latest.as_ref().map_or(0, |o| o.samples.len() + o.raw.as_ref().map_or(0, |r| r.len()))
    }

    fn begin(&mut self, now: f64) {
        self.t = now;
        self.out.clear();
    }

    fn finish(&mut self) -> Vec<SenderOutput> {
        std::mem::take(&mut self.out)
    }

    fn report(&mut self, change: Option<i64>) {
        if let Some(c) = change {
            self.out.push(SenderOutput::LevelChanged(c));
        }
    }

    /// Runs `f` and moves `self.t` on by the time it took (when there is a timer).
    fn timed<R>(&mut self, f: impl FnOnce(&mut FrameEncoder) -> R) -> R {
        let mark = self.timer.as_ref().map(|c| c.now());
        let r = f(&mut self.encoder);
        if let (Some(c), Some(m)) = (self.timer.as_ref(), mark) {
            let d = c.now() - m;
            if d > 0.0 {
                self.t += d;
            }
        }
        r
    }

    /// `raw` is the frame's tightly packed BGRA, only for two-tone modes (None otherwise).
    /// Swift's `captured` argument is kept: it is the capture time, `now` the call time.
    #[allow(clippy::too_many_arguments)]
    pub fn offer(
        &mut self,
        samples: Vec<u8>,
        raw: Option<Vec<u8>>,
        width: usize,
        height: usize,
        region: CanvasRect,
        captured: f64,
        now: f64,
    ) -> Vec<SenderOutput> {
        self.begin(now);
        self.latest = Some(Offer { samples, raw, width, height, region, captured });
        self.pump();
        self.finish()
    }

    pub fn ack(&mut self, processing_ms: u16, now: f64) -> Vec<SenderOutput> {
        self.begin(now);
        let t = self.t;
        let Some((_, latency)) = self.pacer.acked(t, processing_ms) else {
            return self.finish();
        };
        self.latency_ms = Some(millis(latency));
        if !self.first_ack_seen {
            self.first_ack_seen = true;
            if let Some(sent_at) = self.first_sent_at {
                let c = self.tier.probe(t - sent_at);
                self.report(c);
            }
        }
        let queueing = self.pacer.queueing(t);
        let c = self.tier.observe(t, queueing, true);
        self.report(c);
        self.pump();
        self.finish()
    }

    /// New encoder: queued slices and the held offer (quantized for the old mode)
    /// are dropped, the next frame is full. Frames already in flight stay tracked
    /// and their acks still count.
    pub fn set_mode(&mut self, mode: Mode) {
        self.encoder = FrameEncoder::new(mode);
        self.queue.clear();
        self.latest = None;
        self.diverged_at = None;
    }

    /// Call every 100 ms: once the canvas has differed from the exact quantization
    /// for 300 ms, nothing is queued or held and a send slot is free, sends the next
    /// correcting frame (one slice of at most 8 KB). Later calls go on with the next
    /// part without another wait, as long as nothing is queued or held; a captured
    /// frame goes out before the next part, and one that adds approximation restarts
    /// the 300 ms.
    pub fn settle_if_idle(&mut self, now: f64) -> Vec<SenderOutput> {
        self.begin(now);
        // A free send slot too: a settle frame left waiting in the queue would hold up a
        // keystroke captured after it.
        if self.paused
            || !self.encoder.needs_settle()
            || !self.queue.is_empty()
            || self.latest.is_some()
            || !(self.pacer.in_flight() < self.pacer.cap(self.t))
        {
            return self.finish();
        }
        let Some(at) = self.diverged_at else {
            return self.finish();
        };
        if !(self.t - at >= Self::SETTLE_DELAY) {
            return self.finish();
        }
        let started = self.t;
        let slices = self.timed(|e| e.encode_settle(Self::SETTLE_LIMIT));
        let t = self.t;
        self.encode_ms_max = Some(self.encode_ms_max.unwrap_or(0).max(millis(t - started)));
        if !self.encoder.needs_settle() {
            self.diverged_at = None;
        }
        // Stamped now: the capture is old, but the correction was made just now.
        let region = self.last_region;
        self.queue = slices.into_iter().map(|payload| Slice { region, payload, captured: t }).collect();
        self.pump();
        self.finish()
    }

    pub fn set_fps(&mut self, fps: i64) {
        self.pacer.fps = fps;
    }

    /// Paused: offers only replace the held one and no settle runs, so the encoder's
    /// reference stays the last frame B got; slices already queued still go out (B must
    /// see a frame it was sent a part of). Resuming encodes the held offer, if any,
    /// against that reference. Swift's `setPaused` reads the clock when it resumes,
    /// hence `now`.
    pub fn set_paused(&mut self, on: bool, now: f64) -> Vec<SenderOutput> {
        self.begin(now);
        if on == self.paused {
            return self.finish();
        }
        self.paused = on;
        if !on {
            self.pump();
        }
        self.finish()
    }

    /// Automatic saving off (true): back to level 0 at once, and it stays there.
    pub fn set_pinned(&mut self, pinned: bool) -> Vec<SenderOutput> {
        self.out.clear();
        let was = self.tier.level();
        self.tier.set_pinned(pinned);
        if was != self.tier.level() {
            self.out.push(SenderOutput::LevelChanged(self.tier.level()));
        }
        self.finish()
    }

    /// The levels that save something under the current ceiling (`save_ladder_steps`).
    pub fn set_steps(&mut self, steps: Vec<i64>) -> Vec<SenderOutput> {
        self.out.clear();
        let c = self.tier.set_steps(steps);
        self.report(c);
        self.finish()
    }

    /// Call once a second: finds an outage (no acks arriving) that no ack can report.
    pub fn tick(&mut self, now: f64) -> Vec<SenderOutput> {
        self.begin(now);
        let t = self.t;
        // An idle link is not queueing: a stale slow RTT must not keep the weak timer running.
        let queueing = self.pacer.in_flight() > 0 && self.pacer.queueing(t);
        let c = self.tier.observe(t, queueing, false);
        self.report(c);
        self.finish()
    }

    /// Stats for the last second. `latency_ms` is the most recent capture-to-ack
    /// latency since the previous call (None when no ack arrived); this call clears
    /// it, the full-frame count and the encode maximum.
    pub fn take_stats(&mut self, now: f64) -> Stats {
        let t = now;
        let stats = Stats {
            rtt_ms: self.pacer.last_rtt().map(millis),
            base_rtt_ms: self.pacer.base_rtt(t).map(millis),
            latency_ms: self.latency_ms,
            in_flight: self.pacer.in_flight(),
            cap: self.pacer.cap(t),
            weak: self.tier.weak(),
            level: self.tier.level(),
            full_frames: self.full_frames,
            encode_ms_max: self.encode_ms_max,
        };
        self.latency_ms = None;
        self.full_frames = 0;
        self.encode_ms_max = None;
        stats
    }

    fn pump(&mut self) {
        while self.pacer.in_flight() < self.pacer.cap(self.t) {
            let Some(s) = self.queue.pop_front() else {
                if self.paused {
                    return;
                }
                let Some(o) = self.latest.take() else {
                    return;
                };
                let first = if self.session_first_frame { Some(Self::FIRST_SLICE_LIMIT) } else { None };
                self.session_first_frame = false;
                let started = self.t;
                let slices = self.timed(|e| {
                    e.encode_slices(
                        &o.samples,
                        o.raw.as_deref(),
                        o.width,
                        o.height,
                        Some(o.region),
                        Self::SLICE_LIMIT,
                        first,
                    )
                });
                if let Some(r) = self.encoder.last_report() {
                    self.out.push(SenderOutput::Encoded(r.clone()));
                }
                let ms = millis(self.t - started);
                self.encode_ms_max = Some(self.encode_ms_max.unwrap_or(0).max(ms));
                if slices.first().is_some_and(|s| s.is_full()) {
                    self.full_frames += 1;
                }
                self.last_region = o.region;
                if !self.encoder.needs_settle() {
                    self.diverged_at = None;
                } else if self.encoder.last_encode_added_approximation() || self.diverged_at.is_none() {
                    self.diverged_at = Some(self.t);
                }
                let (region, captured) = (o.region, o.captured);
                self.queue = slices.into_iter().map(|payload| Slice { region, payload, captured }).collect();
                continue;
            };
            let t = self.t;
            if self.first_sent_at.is_none() {
                self.first_sent_at = Some(t);
            }
            self.pacer.sent(t, s.captured);
            self.out.push(SenderOutput::Frame { region: s.region, payload: s.payload });
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cap_follows_base_rtt() {
        let mut p = SendPacer::new(30);
        assert_eq!(p.cap(0.0), 1);
        for i in 0..5 {
            let at = i as f64 * 0.1;
            p.sent(at, at);
            p.acked(at + 0.08, 0);
        }
        assert_eq!(p.cap(0.6), 4);
    }

    #[test]
    fn ladder_steps() {
        let best = StreamSpec { mode: Mode::Color16, fps: 30, density: 2.0 };
        assert_eq!(save_ladder_steps(best), vec![1, 2]);
        let floor = StreamSpec { mode: Mode::Duogray, fps: 1, density: 0.5 };
        assert_eq!(save_ladder_steps(floor), Vec::<i64>::new());
        assert_eq!(save_ladder_stream(2, floor), floor);
    }

    #[test]
    fn pinned_drops_the_level() {
        let mut t = WeakTier::new();
        t.observe(0.0, true, true);
        assert_eq!(t.observe(3.0, true, true), Some(1));
        t.set_pinned(true);
        assert_eq!(t.level(), 0);
        assert_eq!(t.probe(2.0), None);
    }
}
