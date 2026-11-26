//! The picture loop (`Server.swift:699-791`, `:977-1052`, `:1156-1218`): a capture thread
//! that owns the platform's `Capture`, quantizes each new picture off the session thread and
//! hands the newest one over (latest wins); the session offers it to the `PacedSender`, which
//! sends `frame` messages under the in-flight cap. Pause (fps 0), mode, frame rate, density and
//! the region all reach the capture thread through `CaptureParams`.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::Sender;
use std::sync::{Arc, Mutex, MutexGuard};

use crate::clock::Clock;
use crate::platform::{Capture, Frame};
use crate::protocol::{CanvasRect, Mode};
use crate::quantize::quantize;
use crate::tile::TILE_SIZE;

use super::session::Session;
use super::Event;

/// What the capture thread works with; the session writes it, the thread reads it before each call.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct CaptureParams {
    /// The canvas region to capture, in display points.
    pub region: CanvasRect,
    /// Pixels per point asked of the platform: `min(requested density, display scale)`.
    pub density: f32,
    /// Captures per second: the stream's rate, or 1 while paused (enough to see a change).
    pub fps: i64,
    /// The mode samples are quantized for (Swift `sampleMode`).
    pub mode: Mode,
    /// Bumped by a mode switch: the thread quantizes its last picture again for the new mode.
    pub redraw: u64,
}

/// One quantized picture on its way to the session.
pub struct Quantized {
    pub samples: Vec<u8>,
    /// Tightly packed BGRA, two-tone modes only.
    pub raw: Option<Vec<u8>>,
    pub width: usize,
    pub height: usize,
    pub region: CanvasRect,
    pub mode: Mode,
    /// Capture sequence number: samples older than ones already submitted are dropped.
    pub seq: u64,
    /// Session-clock time of the capture.
    pub captured: f64,
    /// The platform delivered it (the picture changed); a mode switch's redraw is not fresh.
    pub fresh: bool,
}

/// The session's side of the capture thread.
pub struct CaptureHandle {
    params: Arc<Mutex<CaptureParams>>,
    /// The newest picture not yet taken by the session (capacity 1, latest wins).
    slot: Arc<Mutex<Option<Quantized>>>,
    /// The newest picture as captured (Swift `latest`), for the state rules' sampler.
    pub latest: Arc<Mutex<Option<Frame>>>,
    stop: Arc<AtomicBool>,
}

fn locked<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

impl CaptureHandle {
    pub fn params(&self) -> CaptureParams {
        *locked(&self.params)
    }

    fn set(&self, f: impl FnOnce(&mut CaptureParams)) {
        f(&mut locked(&self.params));
    }

    /// The picture waiting for the session, if any.
    pub fn take(&self) -> Option<Quantized> {
        locked(&self.slot).take()
    }

    /// The thread makes no further `frame` call once it sees this (at most one more is in flight).
    pub fn stop(&self) {
        self.stop.store(true, Ordering::SeqCst);
    }
}

/// Whether a picture of this size can be sent (`Server.swift:996-997`): the frame header's
/// u16 sizes and u16 tile count.
pub fn sendable(width: usize, height: usize, bytes_per_row: usize) -> bool {
    width > 0
        && height > 0
        && width <= 0xFFFF
        && height <= 0xFFFF
        && bytes_per_row >= width * 4
        && width.div_ceil(TILE_SIZE) * height.div_ceil(TILE_SIZE) <= 0xFFFF
}

/// Quantizes `frame` for `mode` (`Server.swift:990-1014`); None when it cannot be sent or the
/// buffer is shorter than its stated rows (a platform bug, dropped rather than trapped on).
pub fn quantize_frame(frame: &Frame, mode: Mode) -> Option<(Vec<u8>, Option<Vec<u8>>)> {
    if !sendable(frame.width, frame.height, frame.bytes_per_row) {
        return None;
    }
    let needed = frame.bytes_per_row * (frame.height - 1) + frame.width * 4;
    if frame.bgra.len() < needed {
        return None;
    }
    let samples = quantize(&frame.bgra, frame.width, frame.height, frame.bytes_per_row, mode);
    let raw = if matches!(mode, Mode::Duogray | Mode::Duocolor) {
        let row = frame.width * 4;
        let mut out = Vec::with_capacity(row * frame.height);
        for y in 0..frame.height {
            let start = y * frame.bytes_per_row;
            out.extend_from_slice(&frame.bgra[start..start + row]);
        }
        Some(out)
    } else {
        None
    };
    Some((samples, raw))
}

fn usable(region: &CanvasRect) -> bool {
    region.w >= 1.0 && region.h >= 1.0 && region.x.is_finite() && region.y.is_finite()
}

struct Loop {
    capture: Box<dyn Capture>,
    params: Arc<Mutex<CaptureParams>>,
    slot: Arc<Mutex<Option<Quantized>>>,
    latest: Arc<Mutex<Option<Frame>>>,
    stop: Arc<AtomicBool>,
    alive: Arc<AtomicBool>,
    clock: Arc<dyn Clock>,
    tx: Sender<Event>,
    seq: u64,
    redraw_seen: u64,
}

impl Loop {
    fn running(&self) -> bool {
        self.alive.load(Ordering::SeqCst) && !self.stop.load(Ordering::SeqCst)
    }

    /// Puts `q` in the slot; the session is told only when the slot was empty, so at most one
    /// notice is queued and the session always takes the newest picture.
    fn deliver(&self, q: Quantized) -> bool {
        let was_empty = {
            let mut slot = locked(&self.slot);
            let was = slot.is_none();
            *slot = Some(q);
            was
        };
        !was_empty || self.tx.send(Event::FrameReady).is_ok()
    }

    fn run(mut self) {
        while self.running() {
            let p = *locked(&self.params);
            let interval = 1.0 / p.fps.max(1) as f64;
            let started = self.clock.now();
            if p.redraw != self.redraw_seen {
                self.redraw_seen = p.redraw;
                // A new encoder starts with a full frame: quantize the last picture for the new mode.
                let last = locked(&self.latest).clone();
                if let Some(frame) = last {
                    if let Some((samples, raw)) = quantize_frame(&frame, p.mode) {
                        let q = Quantized {
                            samples,
                            raw,
                            width: frame.width,
                            height: frame.height,
                            region: frame.region,
                            mode: p.mode,
                            seq: self.seq,
                            captured: self.clock.now(),
                            fresh: false,
                        };
                        if !self.deliver(q) {
                            return;
                        }
                    }
                }
            }
            if usable(&p.region) {
                match self.capture.frame(p.region, p.density, self.clock.real(interval)) {
                    Ok(Some(frame)) => {
                        let captured = self.clock.now();
                        self.seq += 1;
                        // The mode may have switched during the call: quantize for the newest one.
                        let mode = locked(&self.params).mode;
                        let q = quantize_frame(&frame, mode).map(|(samples, raw)| Quantized {
                            samples,
                            raw,
                            width: frame.width,
                            height: frame.height,
                            region: frame.region,
                            mode,
                            seq: self.seq,
                            captured,
                            fresh: true,
                        });
                        *locked(&self.latest) = Some(frame);
                        if let Some(q) = q {
                            if !self.running() || !self.deliver(q) {
                                return;
                            }
                        }
                    }
                    Ok(None) => {}
                    Err(reason) => {
                        if self.running() {
                            let _ = self.tx.send(Event::CaptureStopped(reason));
                        }
                        return;
                    }
                }
            }
            // At most `fps` calls a second, whatever the platform does: a capture that returns
            // at once with nothing new (or an empty region) must not spin.
            let spent = self.clock.now() - started;
            if spent < interval && self.running() {
                self.clock.sleep(interval - spent);
            }
        }
    }
}

impl Session {
    /// Captures run at 1 fps while paused (`Server.swift:1196`).
    fn capture_rate(&self) -> i64 {
        if self.outbox.paused() {
            1
        } else {
            self.fps.max(1)
        }
    }

    /// Pixels per point asked of the platform: what B asked, at most the display's own.
    fn capture_density(&self) -> f32 {
        let scale = if self.scale > 0.0 { self.scale } else { 1.0 };
        self.density.min(scale)
    }

    fn current_params(&self, redraw: u64) -> CaptureParams {
        CaptureParams {
            region: self.region.unwrap_or(CanvasRect::new(0.0, 0.0, 0.0, 0.0)),
            density: self.capture_density(),
            fps: self.capture_rate(),
            mode: self.mode,
            redraw,
        }
    }

    /// Starts the capture thread with the `Capture` the target opened with.
    pub(crate) fn start_capture_thread(&mut self) {
        let Some(capture) = self.capture_source.take() else { return };
        let params = Arc::new(Mutex::new(self.current_params(0)));
        let slot = Arc::new(Mutex::new(None));
        let latest = Arc::new(Mutex::new(None));
        let stop = Arc::new(AtomicBool::new(false));
        let worker = Loop {
            capture,
            params: params.clone(),
            slot: slot.clone(),
            latest: latest.clone(),
            stop: stop.clone(),
            alive: self.alive.clone(),
            clock: self.inner.clock.clone(),
            tx: self.tx.clone(),
            seq: 0,
            redraw_seen: 0,
        };
        let spawned = std::thread::Builder::new().name("rapp-host capture".into()).spawn(move || worker.run());
        if let Err(e) = spawned {
            self.fail(&format!("capture stopped: {e}"));
            return;
        }
        self.newest_submitted_seq = 0;
        self.capture = Some(CaptureHandle { params, slot, latest, stop });
    }

    /// The region, density or rate changed: the capture thread uses the new ones from its next call.
    pub(crate) fn capture_params_changed(&mut self) {
        let Some(handle) = self.capture.as_ref() else { return };
        let redraw = handle.params().redraw;
        let next = self.current_params(redraw);
        handle.set(|p| *p = next);
    }

    pub(crate) fn stop_capture(&mut self) {
        if let Some(handle) = self.capture.take() {
            handle.stop();
        }
    }

    /// The capture thread left a picture in the slot.
    pub(crate) fn frame_ready(&mut self) {
        let Some(q) = self.capture.as_ref().and_then(|h| h.take()) else { return };
        self.frame_arrived(q);
    }

    /// `Server.swift:1022-1032` (`submit`).
    pub(crate) fn frame_arrived(&mut self, q: Quantized) {
        if self.ended || self.capture.is_none() {
            return;
        }
        // Paused: the change only lights B's activity lamp; the frame waits in `paced` for resume.
        if q.fresh {
            let now = self.now();
            if let Some(m) = self.outbox.changed(now) {
                self.transmit(m);
            }
        }
        if q.mode != self.mode || q.seq < self.newest_submitted_seq {
            return;
        }
        self.newest_submitted_seq = q.seq;
        self.last_width = q.width;
        self.last_height = q.height;
        let now = self.now();
        if let Some(p) = self.paced.as_mut() {
            let out = p.offer(q.samples, q.raw, q.width, q.height, q.region, q.captured, now);
            self.sender_outputs(out);
        }
    }

    /// `Server.swift:1156-1184`: the stream the saving ladder chose.
    pub(crate) fn set_stream(&mut self, mode: Mode, fps: i64, density: f32) {
        let old = self.mode;
        if mode == old && fps == self.fps && density == self.density {
            return;
        }
        if fps != self.fps || density != self.density {
            self.fps = fps;
            self.density = density;
            if let Some(p) = self.paced.as_mut() {
                p.set_fps(fps);
            }
            // No encoder reset: the encoder sends a full frame itself when the density changes by more than 1 %.
            self.capture_params_changed();
        }
        self.inner.out.log(&format!("stream -> {}", self.stream_description(mode)));
        if mode == old {
            return;
        }
        // A new encoder starts with a full frame, which also restarts both ends' compression
        // streams. Old-mode samples still on the way are dropped by `frame_arrived`.
        self.mode = mode;
        if let Some(p) = self.paced.as_mut() {
            p.set_mode(mode);
        }
        if let Some(handle) = self.capture.as_ref() {
            handle.set(|p| {
                p.mode = mode;
                p.redraw += 1;
            });
        }
    }

    /// `setStream` from B (`Server.swift:449-461`).
    pub(crate) fn set_stream_request(&mut self, mode: Mode, fps: u8, density: f32, pinned: bool, focus: bool) {
        self.requested_focus = focus;
        self.sync_focus();
        self.requested_mode = mode;
        self.requested_density = density;
        // fps 0 pauses (v15) and keeps the ceiling's rate: the saving ladder never sees 0.
        // Before set_pinned/set_steps: their level change must use the new ceiling.
        if fps > 0 {
            self.requested_fps = i64::from(fps);
        }
        let steps = crate::pacing::save_ladder_steps(self.ceiling());
        if let Some(p) = self.paced.as_mut() {
            let out = p.set_pinned(pinned);
            self.sender_outputs(out);
        }
        if let Some(p) = self.paced.as_mut() {
            let out = p.set_steps(steps);
            self.sender_outputs(out);
        }
        let level = self.paced.as_ref().map_or(0, |p| p.level());
        self.apply_level(level);
        self.set_paused(fps == 0);
    }

    /// `Server.swift:1201-1210`: resuming sends what was held first, then the held frame as a
    /// diff against the last one B got.
    pub(crate) fn set_paused(&mut self, on: bool) {
        if on == self.outbox.paused() {
            return;
        }
        let now = self.now();
        let held = self.outbox.set_paused(on, now);
        self.inner.out.log(if on { "paused: B is not showing this session" } else { "resumed" });
        for m in held {
            self.transmit(m);
        }
        self.capture_params_changed();
        let now = self.now();
        if let Some(p) = self.paced.as_mut() {
            let out = p.set_paused(on, now);
            self.sender_outputs(out);
        }
    }
}
