//! What the session tells B besides frames and tables, on the session thread:
//!
//! - covers and the app that came to the front (`Server.swift:544-612`),
//! - password-field focus (`SecureFocusWatcher.swift`),
//! - the focus pane (`Sources/rapp-host/FocusSession.swift`, `FocusReader.swift`),
//! - the state rules (`Sources/rapp-host/AppStateWatcher.swift`).
//!
//! Swift learns of activations, focus moves and password fields from observers; the platform
//! layer here has polls instead (`WindowOps::opened_app`, `ControlOps::keyboard_changed`,
//! `ControlOps::secure_focus`), which the session asks every 0.1 s.

use std::collections::{BTreeSet, HashMap, HashSet};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::mpsc::{channel, Receiver, RecvTimeoutError, Sender};
use std::sync::{Arc, Mutex, MutexGuard, TryLockError};
use std::thread;

use crate::clock::Clock;
use crate::focus::{panel, window_rect, window_tiles, Action, FocusTracker, Output, PanelMiss, PanelPick, Pointer, Query};
use crate::geometry::{Point, Rect, Size};
use crate::hints::{app_opened_worth_telling, cover_dismissable};
use crate::platform::{Frame, RawWindow, TargetOps};
use crate::protocol::{CanvasRect, Message, MouseKind, WindowInfo, WindowKind};
use crate::query::{QueryCoalescer, QueryDeadline};
use crate::run::Output as Out;
use crate::state::detectors::TextReader;
use crate::state::{AppStateReport, RuleEnv, RuleImage, RuleRect, StateEngine};
use crate::tile::EncodeReport;

use super::intake::read_timeout;
use super::session::{Session, Timer};
use super::tracker::raw_for;
use super::{hold, shared, Event, Shared};

/// How often the opened-app and password-field polls run.
pub const HINTS_EVERY: f64 = 0.1;
/// The focus tracker's timer (`FocusSession` init: every 0.1 s).
pub const FOCUS_TICK_EVERY: f64 = 0.1;
/// What one focus query may take (`FocusReader.budget`).
pub const FOCUS_BUDGET: f64 = 0.05;
/// The state rules run this often (`AppStateWatcher.interval`).
pub const STATE_EVERY: f64 = 0.5;

/// Like `hold`, but `None` while another thread has the handle: a poll skips a round rather
/// than wait behind a slow focus query or cover close.
fn try_hold<T: ?Sized>(m: &Mutex<Box<T>>) -> Option<MutexGuard<'_, Box<T>>> {
    match m.try_lock() {
        Ok(g) => Some(g),
        Err(TryLockError::Poisoned(e)) => Some(e.into_inner()),
        Err(TryLockError::WouldBlock) => None,
    }
}

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

// MARK: Covers, opened apps, password fields

impl Session {
    /// From ready on: dropped presses, other apps' activations (app sessions) and
    /// password-field focus (`startHints`).
    pub(crate) fn start_hints(&mut self) {
        if self.ended || self.hints_on {
            return;
        }
        self.hints_on = true;
        self.schedule(Timer::Hints, HINTS_EVERY);
    }

    pub(crate) fn hints_tick(&mut self) {
        if self.ended || self.failing || !self.hints_on || self.ops.is_none() {
            return;
        }
        self.schedule(Timer::Hints, HINTS_EVERY);
        if !self.desktop {
            self.check_opened_app();
        }
        self.check_secure_focus();
    }

    /// Another app became frontmost: if it came right after this session's input, B is told
    /// it opened (`activated`).
    fn check_opened_app(&mut self) {
        let Some(ops) = self.ops.as_ref() else { return };
        let Some(other) = hold(&ops.windows).opened_app() else { return };
        let session_pid = hold(&ops.target).pid();
        let now = self.now();
        let since = self.last_input_at.map(|t| now - t);
        if !app_opened_worth_telling(
            Some(other.id.as_str()),
            other.pid,
            other.regular,
            session_pid,
            std::process::id() as i32,
            since,
        ) {
            return;
        }
        // Once per input: a second activation from the same press is not news.
        self.last_input_at = None;
        let name = if other.name.is_empty() { other.id.clone() } else { other.name.clone() };
        self.inner.out.log(&format!("{name} came to the front after input"));
        self.send(Message::AppOpened { bundle_id: other.id, name });
    }

    /// `SecureFocusWatcher.check`: sends a change of "focus is in a password field". Also called
    /// from the 1 s tick as a backstop. Desktop sessions watch it too (Swift passes no pid).
    pub(crate) fn check_secure_focus(&mut self) {
        if self.ended || self.failing || !self.hints_on {
            return;
        }
        let secure = {
            let Some(ops) = self.ops.as_ref() else { return };
            let Some(mut controls) = try_hold(&ops.controls) else { return };
            controls.secure_focus()
        };
        if secure == self.sent_secure {
            return;
        }
        self.sent_secure = secure;
        self.inner.out.log(if secure { "focus is in a password field" } else { "focus left the password field" });
        self.send(Message::SecureFocus(secure));
    }

    /// A press was dropped under `pid`'s window: tells B once per owner per few seconds (v13),
    /// with whether `dismissCover` may close it. `name` is the window list's name for `pid`;
    /// the app id and whether it is a regular app come from `ControlOps::cover_at`, and only
    /// when it names the same pid (Swift asks `NSRunningApplication(pid)`).
    pub(crate) fn covered(&mut self, pid: i32, name: String, point: Point) {
        let now = self.now();
        if self.ended || !self.cover_notices.should_send(pid, now) {
            return;
        }
        let Some(ops) = self.ops.as_ref() else { return };
        let owner = hold(&ops.controls).cover_at(point);
        let (bundle, regular) = match owner {
            Some((p, bundle, regular)) if p == pid => (bundle, regular),
            _ => (String::new(), false),
        };
        let dismissable = cover_dismissable(Some(bundle.as_str()), regular);
        self.cover_notices.reported(pid, dismissable, point);
        self.send(Message::Covered { id: pid as u32, name, bundle_id: bundle, dismissable });
    }

    /// Closes the window of a `covered` this session reported as dismissable; anything else is
    /// dropped. The owner is judged again now: a pid reused by a security prompt is never closed.
    pub(crate) fn dismiss_cover(&mut self, id: u32) {
        if self.ended {
            return;
        }
        let pid = id as i32;
        let point = if self.input_on && self.ops.is_some() { self.cover_notices.dismiss_point(pid) } else { None };
        let Some(point) = point else {
            self.inner.out.log("dismiss dropped: no such cover");
            return;
        };
        self.cover_notices.forget(pid);
        let Some(ops) = self.ops.as_ref() else { return };
        let owner = hold(&ops.controls).cover_at(point);
        let allowed = matches!(&owner, Some((p, bundle, regular)) if *p == pid && cover_dismissable(Some(bundle.as_str()), *regular));
        if !allowed {
            self.inner.out.log("dismiss dropped: the cover may not be closed");
            return;
        }
        let name = hold(&ops.windows)
            .screen()
            .into_iter()
            .find(|w| w.pid == pid && !w.name.is_empty())
            .map(|w| w.name)
            .unwrap_or_else(|| format!("pid {pid}"));
        // Closing may take a while (a confirmation sheet): off the session thread, as on
        // Swift's menu queue.
        let controls = ops.controls.clone();
        let out = self.inner.out.clone();
        let spawned = thread::Builder::new().name("rapp-host cover".into()).spawn(move || {
            if hold(&controls).close_cover(pid, point) {
                out.log(&format!("closed the cover of {name}"));
            } else {
                out.log(&format!("could not close the cover of {name}"));
            }
        });
        if spawned.is_err() {
            self.inner.out.log("could not close the cover: no thread");
        }
    }

    /// Everything this module started stops (`end`: focus session, state watcher, pending
    /// rules, secure watcher).
    pub(crate) fn stop_hints(&mut self) {
        self.hints_on = false;
        if let Some(mut pane) = self.focus.take() {
            pane.stopped = true;
        }
        if let Some(state) = self.app_state.take() {
            state.stop();
        }
        self.pending_rules = None;
    }
}

// MARK: The focus pane

static PANE_IDS: AtomicU64 = AtomicU64::new(1);

/// What the latest query found, for the log line.
#[derive(Debug, Clone)]
struct Found {
    start: String,
    picked: String,
    depth: usize,
    share: f64,
    ms: i64,
}

impl Default for Found {
    fn default() -> Self {
        Found { start: "-".to_string(), picked: "-".to_string(), depth: 0, share: 0.0, ms: 0 }
    }
}

/// One focus query with what it was asked about (Swift's `FocusReader.Job`).
struct FocusJob {
    pane: u64,
    query: Query,
    generation: i64,
    window: WindowInfo,
    raw: Option<RawWindow>,
}

/// The focus pane of one session (`FocusSession`): feeds `FocusTracker` with input, the
/// window table, frames and query answers, and sends what it decides.
pub(crate) struct FocusPane {
    id: u64,
    tracker: FocusTracker,
    window: Option<WindowInfo>,
    seen: HashSet<u32>,
    appeared: HashMap<u32, f64>,
    found: Found,
    stopped: bool,
    /// One query runs at a time; at most one more waits per kind (`QueryCoalescer`).
    queries: QueryCoalescer<FocusJob>,
}

impl FocusPane {
    fn new() -> FocusPane {
        FocusPane {
            id: PANE_IDS.fetch_add(1, Ordering::Relaxed),
            tracker: FocusTracker::new(),
            window: None,
            seen: HashSet::new(),
            appeared: HashMap::new(),
            found: Found::default(),
            stopped: false,
            queries: QueryCoalescer::new(),
        }
    }
}

/// `x,y,wxh`, each rounded (`FocusSession.text`).
fn rect_text(r: Rect) -> String {
    format!(
        "{},{},{}x{}",
        r.min_x().round() as i64,
        r.min_y().round() as i64,
        r.w().round() as i64,
        r.h().round() as i64
    )
}

impl Session {
    /// Creates or drops the focus pane to match B's focus bit (F5: nothing exists while it is
    /// off). Desktop sessions have none.
    pub(crate) fn sync_focus(&mut self) {
        if self.ended {
            return;
        }
        if self.requested_focus && !self.desktop && self.ops.is_some() && self.focus.is_none() {
            self.focus = Some(FocusPane::new());
            let table = self.table.clone();
            self.focus_windows(&table);
            self.focus_locked(self.sent_locked.unwrap_or(false));
            let now = self.now();
            let actions = match self.focus.as_mut() {
                Some(p) => p.tracker.start(now),
                None => Vec::new(),
            };
            self.focus_dispatch(actions);
            self.schedule(Timer::FocusTick, FOCUS_TICK_EVERY);
        } else if !self.requested_focus {
            if let Some(mut pane) = self.focus.take() {
                pane.stopped = true;
            }
            self.timers.remove(&Timer::FocusTick);
        }
    }

    /// The table changed: the focus pane follows the focused window and the state rules the
    /// main window (the largest normal one, the first of equals as Swift's `max(by:)`).
    pub(crate) fn windows_changed(&mut self, next: &[WindowInfo]) {
        self.focus_windows(next);
        let mut main: Option<CanvasRect> = None;
        for w in next.iter().filter(|w| w.kind == WindowKind::Normal) {
            if main.is_none_or(|m| w.rect.w * w.rect.h > m.w * m.h) {
                main = Some(w.rect);
            }
        }
        if let Some(state) = self.app_state.as_ref() {
            state.set_window(main);
        }
    }

    fn focus_windows(&mut self, table: &[WindowInfo]) {
        let now = self.now();
        let Some(p) = self.focus.as_mut() else { return };
        if p.stopped {
            return;
        }
        let focused = table.iter().find(|w| w.focused).cloned();
        if let Some(f) = focused.as_ref() {
            if p.seen.insert(f.id) {
                p.appeared.insert(f.id, now);
            }
        }
        let size = focused
            .as_ref()
            .map_or(Size::new(0.0, 0.0), |f| Size::new(f64::from(f.rect.w), f64::from(f.rect.h)));
        let appeared = focused.as_ref().and_then(|f| p.appeared.get(&f.id).copied());
        let id = focused.as_ref().map(|f| f.id);
        p.window = focused;
        let actions = p.tracker.window(id, size, appeared, now);
        self.focus_dispatch(actions);
    }

    pub(crate) fn focus_locked(&mut self, on: bool) {
        let now = self.now();
        let Some(p) = self.focus.as_mut() else { return };
        if p.stopped {
            return;
        }
        let actions = p.tracker.locked(on, now);
        self.focus_dispatch(actions);
    }

    /// B's input, after it was delivered (`FocusSession.input`). `paste` counts as a key.
    pub(crate) fn focus_input(&mut self, m: &Message) {
        let now = self.now();
        let Some(p) = self.focus.as_mut() else { return };
        if p.stopped {
            return;
        }
        let window = p.window.as_ref().map(|w| w.id);
        let actions = match m {
            Message::Mouse { kind, window: id, x, y, .. } => {
                if Some(*id) != window {
                    return;
                }
                let at = Point::new(f64::from(*x), f64::from(*y));
                match kind {
                    MouseKind::Down => p.tracker.pointer(Pointer::Click, at, now),
                    MouseKind::Drag => p.tracker.pointer(Pointer::Drag, at, now),
                    MouseKind::Move => p.tracker.pointer(Pointer::Move, at, now),
                    MouseKind::Up => return,
                }
            }
            Message::Scroll { window: id, x, y, .. } => {
                if Some(*id) != window {
                    return;
                }
                p.tracker.pointer(Pointer::Scroll, Point::new(f64::from(*x), f64::from(*y)), now)
            }
            Message::Key { .. } | Message::Text(_) | Message::Paste { .. } => p.tracker.key(now),
            _ => return,
        };
        self.focus_dispatch(actions);
    }

    /// One encoded frame (`FocusSession.encoded`): scrolls and follows.
    pub(crate) fn encoded(&mut self, report: EncodeReport) {
        let now = self.now();
        let Some(p) = self.focus.as_mut() else { return };
        if p.stopped {
            return;
        }
        let Some(w) = p.window.as_ref() else { return };
        let tiles = window_tiles(&report, w.rect);
        let actions = p.tracker.frame(&tiles, now);
        self.focus_dispatch(actions);
    }

    /// The tracker's 0.1 s timer, and the platform's "the keyboard focus moved" poll (Swift's
    /// AX observer).
    pub(crate) fn focus_tick(&mut self) {
        if self.ended || self.focus.as_ref().is_none_or(|p| p.stopped) {
            return;
        }
        self.schedule(Timer::FocusTick, FOCUS_TICK_EVERY);
        let moved = match self.ops.as_ref() {
            Some(ops) => try_hold(&ops.controls).is_some_and(|mut c| c.keyboard_changed()),
            None => false,
        };
        let now = self.now();
        let Some(p) = self.focus.as_mut() else { return };
        let mut actions = Vec::new();
        if moved {
            actions.extend(p.tracker.keyboard_changed(now));
        }
        actions.extend(p.tracker.tick(now));
        self.focus_dispatch(actions);
    }

    fn focus_dispatch(&mut self, actions: Vec<Action>) {
        for action in actions {
            match action {
                Action::Query(q, generation) => self.focus_ask(q, generation),
                Action::Send(out) => self.focus_emit(out),
            }
        }
    }

    fn focus_ask(&mut self, q: Query, generation: i64) {
        if self.ops.is_none() {
            return;
        }
        let Some(p) = self.focus.as_mut() else { return };
        if p.stopped {
            return;
        }
        let Some(w) = p.window.clone() else { return };
        let raw = raw_for(&self.raw, w.id).cloned();
        let job = FocusJob { pane: p.id, query: q, generation, window: w, raw };
        if let Some(job) = p.queries.submit(q.kind(), job) {
            self.run_focus_job(job);
        }
    }

    /// `FocusReader.read` off the session thread. The platform gets the query with its point
    /// in global points (Swift converts window points the same way before asking AX); the
    /// answer goes back to the tracker with the query as the tracker asked it.
    fn run_focus_job(&mut self, job: FocusJob) {
        let Some(ops) = self.ops.as_ref() else { return };
        let controls = ops.controls.clone();
        let clock = self.inner.clock.clone();
        let tx = self.tx.clone();
        let display = self.display;
        let spawned = thread::Builder::new().name("rapp-host focus".into()).spawn(move || {
            let started = clock.now();
            let deadline = QueryDeadline::new(started, FOCUS_BUDGET);
            let global = |p: Point| {
                Point::new(
                    display.min_x() + f64::from(job.window.rect.x) + p.x,
                    display.min_y() + f64::from(job.window.rect.y) + p.y,
                )
            };
            let asked = match job.query {
                Query::Keyboard => Query::Keyboard,
                Query::Pointer(p) => Query::Pointer(global(p)),
                Query::Follow(p) => Query::Follow(global(p)),
            };
            let result = match job.raw.as_ref() {
                Some(raw) => hold(&controls).focus_chain(&asked, raw, deadline, clock.as_ref()),
                // The table entry has no raw window behind it: nothing can be read.
                None => Err(PanelMiss::Blocked),
            };
            // A chain that finished after the deadline does not count (`FocusReader.swift:161`).
            let result = match result {
                Ok(chain) if !chain.is_empty() && !deadline.expired(clock.now()) => Ok(chain
                    .into_iter()
                    .map(|g| window_rect(g, display, job.window.rect))
                    .collect::<Vec<Rect>>()),
                Ok(_) => Err(PanelMiss::Blocked),
                Err(miss) => Err(miss),
            };
            let ms = ((clock.now() - started) * 1000.0).round() as i64;
            Session::post(&tx, Box::new(move |s: &mut Session| s.focus_answered(job, result, ms)));
        });
        if spawned.is_err() {
            // No thread: the query is lost; let the next waiting one run.
            self.inner.out.log("focus: could not start a query");
            if let Some(next) = self.focus.as_mut().and_then(|p| p.queries.finish()) {
                self.run_focus_job(next);
            }
        }
    }

    fn focus_answered(&mut self, job: FocusJob, result: Result<Vec<Rect>, PanelMiss>, ms: i64) {
        let now = self.now();
        let Some(p) = self.focus.as_mut() else { return };
        if p.id != job.pane {
            // An answer for a pane that was dropped since.
            return;
        }
        let next = p.queries.finish();
        if !p.stopped {
            if let Some(w) = p.window.as_ref() {
                let size = Size::new(f64::from(w.rect.w), f64::from(w.rect.h));
                // depth= is the layers read. Roles are not part of the platform's answer, so
                // start= stays "-" and picked= names the layer by its depth.
                let picked: Result<PanelPick, PanelMiss> = match &result {
                    Err(miss) => {
                        p.found = Found { start: "-".into(), picked: miss.name().into(), depth: 0, share: 0.0, ms };
                        Err(*miss)
                    }
                    Ok(chain) => {
                        let pick = panel(chain, size);
                        p.found = match &pick {
                            Ok(pp) => Found {
                                start: "-".into(),
                                picked: format!("depth{}", pp.depth),
                                depth: chain.len(),
                                share: pp.share,
                                ms,
                            },
                            Err(miss) => Found {
                                start: "-".into(),
                                picked: miss.name().into(),
                                depth: chain.len(),
                                share: 0.0,
                                ms,
                            },
                        };
                        pick
                    }
                };
                let actions = p.tracker.result(job.query, job.generation, picked, now);
                self.focus_dispatch(actions);
            }
        }
        if let Some(next) = next {
            if self.focus.as_ref().is_some_and(|p| p.id == next.pane) {
                self.run_focus_job(next);
            }
        }
    }

    fn focus_emit(&mut self, out: Output) {
        let rects: Vec<CanvasRect> = out
            .rects
            .iter()
            .map(|r| CanvasRect::new(r.min_x() as f32, r.min_y() as f32, r.w() as f32, r.h() as f32))
            .collect();
        self.send(Message::FocusRegion { window: out.window, rects });
        let Some(p) = self.focus.as_ref() else { return };
        let t = &p.tracker;
        let kb = t
            .keyboard_panel()
            .map(rect_text)
            .or_else(|| t.keyboard_miss().map(|m| m.name().to_string()))
            .unwrap_or_else(|| "-".to_string());
        let ptr = t
            .pointer_panel()
            .map(rect_text)
            .or_else(|| t.pointer_miss().map(|m| m.name().to_string()))
            .unwrap_or_else(|| "-".to_string());
        let follow = t.follow_panel().map(rect_text).unwrap_or_else(|| "-".to_string());
        let out_text = if out.rects.is_empty() {
            "whole".to_string()
        } else {
            out.rects.iter().map(|r| rect_text(*r)).collect::<Vec<_>>().join(" ")
        };
        let f = &p.found;
        let line = format!(
            "[focus] win={} cause={} start={} depth={} picked={} share={:.2} kb={} ptr={} follow={} out={} axMs={}",
            out.window,
            out.cause.name(),
            f.start,
            f.depth,
            f.picked,
            f.share,
            kb,
            ptr,
            follow,
            out_text,
            f.ms
        );
        self.inner.out.log(&line);
    }
}

// MARK: The state rules

/// The parts of the state thread the session thread changes.
#[derive(Debug, Default)]
struct StateShared {
    /// The app's main window in canvas points; `None` when there is none.
    window: Option<CanvasRect>,
    /// Look at the newest frame on the next round even if it was looked at before (rules
    /// arrived, or the window moved: a still window sends no new frame).
    reseed: bool,
    stopped: bool,
}

/// The session's side of the state thread (`AppStateWatcher`).
pub(crate) struct AppStateHandle {
    rules: Sender<String>,
    shared: Arc<Mutex<StateShared>>,
}

impl AppStateHandle {
    /// "" stops the rules; rules that cannot be read send one invalid report.
    fn set_rules(&self, json: String) {
        let _ = self.rules.send(json);
    }

    fn set_window(&self, rect: Option<CanvasRect>) {
        let mut s = lock(&self.shared);
        if s.window != rect {
            s.window = rect;
            s.reseed = true;
        }
    }

    fn stop(self) {
        let mut s = lock(&self.shared);
        s.stopped = true;
        s.window = None;
        // Dropping `rules` wakes the thread, which then ends.
    }
}

/// The session's text reader, shared by every engine the session makes (each `stateRules`
/// makes a new one; Swift hands the same `VisionText` to each).
struct SharedText(Shared<dyn TextReader>);

impl TextReader for SharedText {
    fn lines(&mut self, image: &RuleImage, rect: RuleRect) -> Vec<String> {
        hold(&self.0).lines(image, rect)
    }

    fn ready(&self) -> bool {
        hold(&self.0).ready()
    }
}

/// The locale the rules see. Swift takes the first preferred language; host-core has no OS
/// call for it, so `RAPP_LOCALE` stands in, and "en" without it.
fn rule_locale() -> String {
    match std::env::var("RAPP_LOCALE") {
        Ok(v) if !v.trim().is_empty() => v.trim().to_string(),
        _ => "en".to_string(),
    }
}

struct StateWorker {
    rules: Receiver<String>,
    shared: Arc<Mutex<StateShared>>,
    latest: Option<Arc<Mutex<Option<Arc<Frame>>>>>,
    target: Shared<dyn TargetOps>,
    text: Option<Shared<dyn TextReader>>,
    os: String,
    clock: Arc<dyn Clock>,
    out: Arc<Out>,
    tx: Sender<Event>,
    alive: Arc<AtomicBool>,
}

enum Sampled {
    Image(RuleImage),
    /// The window leaves the frame: not a picture of it.
    Clipped,
    Nothing,
}

/// The window's part of `frame` at one pixel per point (`AppStateWatcher.sample`).
fn sample(frame: &Frame, win: CanvasRect) -> Sampled {
    let region = frame.region;
    if !(region.w > 0.0 && region.h > 0.0 && win.w > 0.0 && win.h > 0.0) {
        return Sampled::Nothing;
    }
    let x0 = win.x.max(region.x);
    let y0 = win.y.max(region.y);
    let x1 = (win.x + win.w).min(region.x + region.w);
    let y1 = (win.y + win.h).min(region.y + region.h);
    if !(x1 > x0 && y1 > y0) {
        return Sampled::Clipped;
    }
    if x0 - win.x > 0.5 || y0 - win.y > 0.5 || (win.x + win.w) - x1 > 0.5 || (win.y + win.h) - y1 > 0.5 {
        return Sampled::Clipped;
    }
    let (width, height) = (frame.width, frame.height);
    let scale = width as f64 / f64::from(region.w);
    if !(scale.is_finite() && scale > 0.0) {
        return Sampled::Nothing;
    }
    let px0 = ((f64::from(x0 - region.x) * scale).floor() as i64).max(0);
    let py0 = ((f64::from(y0 - region.y) * scale).floor() as i64).max(0);
    let px1 = ((f64::from(x1 - region.x) * scale).ceil() as i64).min(width as i64);
    let py1 = ((f64::from(y1 - region.y) * scale).ceil() as i64).min(height as i64);
    if !(px1 > px0 && py1 > py0) {
        return Sampled::Nothing;
    }
    let crop = RuleRect::new(px0, py0, px1 - px0, py1 - py0);
    match RuleImage::sample(&frame.bgra, width, height, frame.bytes_per_row, crop, scale) {
        Some(image) => Sampled::Image(image),
        None => Sampled::Nothing,
    }
}

impl StateWorker {
    fn run(self) {
        let mut engine: Option<StateEngine> = None;
        // The frame the last round looked at: a round only looks at a newer one.
        let mut looked: Option<Arc<Frame>> = None;
        let mut next_round = f64::INFINITY;
        loop {
            if !self.alive.load(Ordering::SeqCst) || lock(&self.shared).stopped {
                return;
            }
            let wait = if engine.is_some() { (next_round - self.clock.now()).max(0.0) } else { 1.0 };
            match self.rules.recv_timeout(read_timeout(self.clock.as_ref(), wait)) {
                Ok(json) => {
                    engine = None;
                    looked = None;
                    next_round = f64::INFINITY;
                    if json.is_empty() {
                        continue;
                    }
                    if let Some(e) = self.engine(&json) {
                        engine = Some(e);
                        lock(&self.shared).reseed = true;
                        next_round = self.clock.now() + STATE_EVERY;
                    }
                    continue;
                }
                Err(RecvTimeoutError::Timeout) => {}
                Err(RecvTimeoutError::Disconnected) => return,
            }
            let Some(e) = engine.as_mut() else { continue };
            let now = self.clock.now();
            if now < next_round {
                continue;
            }
            next_round += STATE_EVERY;
            if next_round <= now {
                // A long round (text reading): no catching up.
                next_round = now + STATE_EVERY;
            }
            self.round(e, &mut looked);
        }
    }

    /// `setRules` for non-empty rules.
    fn engine(&self, json: &str) -> Option<StateEngine> {
        let version = hold(&self.target).version();
        let mut caps: BTreeSet<String> = BTreeSet::new();
        caps.insert("pixels".to_string());
        if self.text.is_some() {
            caps.insert("text".to_string());
        }
        let target = self.target.clone();
        let env = RuleEnv {
            app_version: version.clone(),
            os: self.os.clone(),
            locale: rule_locale(),
            caps: caps.clone(),
            reread_version: Box::new(move || hold(&target).version()),
        };
        let text = self.text.as_ref().map(|t| Box::new(SharedText(t.clone())) as Box<dyn TextReader>);
        match StateEngine::new(json.as_bytes(), env, text) {
            Ok(engine) => {
                let report = engine.report();
                self.out.log(&format!(
                    "state rules: {} rev {}, app {}",
                    report.pack.as_deref().unwrap_or("-"),
                    report.rev.map_or("-".to_string(), |r| r.to_string()),
                    version.as_deref().unwrap_or("-")
                ));
                Some(engine)
            }
            Err(err) => {
                self.out.log(&format!("state rules: invalid ({err})"));
                let report = AppStateReport::invalid(&err, caps.into_iter().collect(), version);
                let json = report.json();
                Session::post(&self.tx, Box::new(move |s: &mut Session| s.send(Message::AppState(json))));
                None
            }
        }
    }

    /// `AppStateWatcher.tick`.
    fn round(&self, engine: &mut StateEngine, looked: &mut Option<Arc<Frame>>) {
        let (win, reseed) = {
            let mut s = lock(&self.shared);
            let r = s.reseed;
            s.reseed = false;
            (s.window, r)
        };
        let newest = self.latest.as_ref().and_then(|l| lock(l).clone());
        let frame = match newest {
            Some(f) if reseed || !looked.as_ref().is_some_and(|l| Arc::ptr_eq(l, &f)) => {
                *looked = Some(f.clone());
                Some(f)
            }
            _ => None,
        };
        let mut image: Option<RuleImage> = None;
        let mut visible = win.is_some();
        if let (Some(win), Some(frame)) = (win, frame.as_ref()) {
            match sample(frame, win) {
                Sampled::Image(i) => image = Some(i),
                Sampled::Clipped => visible = false,
                Sampled::Nothing => {}
            }
        }
        if let Some(report) = engine.tick(image.as_ref(), visible, self.clock.now()) {
            let json = report.json();
            Session::post(&self.tx, Box::new(move |s: &mut Session| s.send(Message::AppState(json))));
        }
    }
}

impl Session {
    /// The state thread for an app session (`AppStateWatcher` in `appOpened`), with the rules
    /// that arrived before it.
    pub(crate) fn start_app_state(&mut self) {
        if self.desktop || self.ended || self.app_state.is_some() {
            return;
        }
        let Some(ops) = self.ops.as_ref() else { return };
        let target = ops.target.clone();
        let text: Option<Shared<dyn TextReader>> = self.text_reader.take().map(shared);
        let latest = self.capture.as_ref().map(|c| c.latest.clone());
        let (rules_tx, rules_rx) = channel::<String>();
        let state = Arc::new(Mutex::new(StateShared::default()));
        let worker = StateWorker {
            rules: rules_rx,
            shared: state.clone(),
            latest,
            target,
            text,
            os: self.inner.platform.name().to_string(),
            clock: self.inner.clock.clone(),
            out: self.inner.out.clone(),
            tx: self.tx.clone(),
            alive: self.alive.clone(),
        };
        if let Err(e) = thread::Builder::new().name("rapp-host state".into()).spawn(move || worker.run()) {
            self.inner.out.log(&format!("state rules: no thread ({e})"));
            return;
        }
        let handle = AppStateHandle { rules: rules_tx, shared: state };
        if let Some(rules) = self.pending_rules.take() {
            handle.set_rules(rules);
        }
        self.app_state = Some(handle);
    }

    /// `stateRules` from B. Not an input, so no `admit`. Desktop sessions have no app to read.
    pub(crate) fn state_rules(&mut self, json: String) {
        if self.desktop || self.ended {
            return;
        }
        match self.app_state.as_ref() {
            Some(state) => state.set_rules(json),
            None => self.pending_rules = Some(json),
        }
    }
}
