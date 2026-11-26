//! One client session (`Server.swift:233-1300`, `Session`). All state lives on the session
//! thread; see `session/mod.rs` for the threads around it.

use std::collections::{BTreeMap, HashSet};
use std::io::{ErrorKind, Read, Write};
use std::net::{Shutdown, SocketAddr, TcpStream};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{channel, Receiver, RecvTimeoutError, Sender};
use std::sync::Arc;

use crate::cli::{check_hello, input_blocked_notice, taken_over_error, WorkerEvent};
use crate::desktop::{desktop_table, desktop_target, desktop_title, ordered_displays, rounded_int, DesktopTarget};
use crate::geometry::{window_title, Rect, Size};
use crate::hints::CoverNotices;
use crate::input::{HeldInput, InputYield, YieldDecision, INPUT_REPORT_EVERY};
use crate::lock::locked_start_display;
use crate::pacing::{save_ladder_steps, save_ladder_stream, PacedSender, SenderOutput, StreamSpec};
use crate::pause::PauseOutbox;
use crate::platform::{
    Capture, ClipboardOps, ControlOps, DisplayInfo, InputOps, InputSource, InputSourceOps, LockOps, OpenError,
    Parts, RawWindow, Target, TargetOps, WindowOps,
};
use crate::protocol::{CanvasRect, Message, MessageParser, Mode, MouseButton, WindowInfo};
use crate::state::detectors::TextReader;
use crate::wintable::{capture_region, region_change};

use super::intake::{bad_data_reason, read_timeout, READ_SLICE};
use super::clip::ClipState;
use super::server::{Inner, SessionHandle, TransferSlot};
use super::hints::{AppStateHandle, FocusPane};
use super::tracker::window_table;
use super::{hold, shared, Event, Job, Shared};

/// A cover is announced at most this often per owner (`CoverNotices(every: 5)`).
pub const COVER_NOTICE_EVERY: f64 = 5.0;
/// How often the window table is polled (spec §3.2).
pub const POLL_EVERY: f64 = 0.1;
/// The stats and backstop tick.
pub const TICK_EVERY: f64 = 1.0;
/// The settle check (a canvas left inexact is corrected after 300 ms of calm).
pub const SETTLE_EVERY: f64 = 0.1;
/// While A is locked at session start, its lock state is checked this often.
pub const LOCK_WAIT_EVERY: f64 = 1.0;
/// How often A's input source is read: the platform has no change notice (Swift's
/// `InputSourceWatcher` listens for TIS's).
pub const INPUT_SOURCE_EVERY: f64 = 0.25;
/// A blocking write gives up after this many host seconds: B stopped reading.
pub const WRITE_TIMEOUT: f64 = 10.0;

/// The session's timers. Each fires once when due; repeating ones schedule themselves again.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum Timer {
    InputReport,
    Tick,
    Settle,
    LockWait,
    InputSource,
    /// The focus tracker's 0.1 s timer, while the focus pane exists.
    FocusTick,
    /// The opened-app and password-field polls (`hints`).
    Hints,
    /// The clipboard restore check after a paste burst (`session/clip.rs`).
    PasteRestore,
}

/// The platform handles a session uses after its target opened. Each is shared so a
/// background job (paste, unlock, focus query, cover close) can call it off the session thread.
pub struct Ops {
    pub target: Shared<dyn TargetOps>,
    pub windows: Shared<dyn WindowOps>,
    pub input: Shared<dyn InputOps>,
    pub input_source: Shared<dyn InputSourceOps>,
    pub clipboard: Shared<dyn ClipboardOps>,
    pub controls: Shared<dyn ControlOps>,
}

pub struct Session {
    pub(crate) inner: Arc<Inner>,
    pub(crate) id: u64,
    /// The writing half; the reader thread has its own clone.
    pub(crate) stream: TcpStream,
    pub(crate) tx: Sender<Event>,
    pub(crate) peer: Option<SocketAddr>,
    pub(crate) peer_name: Option<String>,
    /// Shared with the server: whether a valid hello opened this session.
    started_flag: Arc<AtomicBool>,
    /// Cleared at the end: background threads (reader, window poll, capture) stop.
    pub(crate) alive: Arc<AtomicBool>,

    greeted: bool,
    pub(crate) started: bool,
    pub(crate) ended: bool,
    /// `fail()` was called: the session's input must not reach anyone.
    pub(crate) failing: bool,
    /// A write failed; the session ends with this once the current event is handled.
    send_error: Option<String>,

    yield_: InputYield,
    yielded_by: String,

    pub(crate) app_id: String,
    pub(crate) mode: Mode,
    pub(crate) fps: i64,
    pub(crate) density: f32,
    pub(crate) requested_mode: Mode,
    pub(crate) requested_density: f32,
    pub(crate) requested_fps: i64,
    pub(crate) paced: Option<PacedSender>,
    pub(crate) outbox: PauseOutbox,

    /// A desktop session (`desktop:` or `desktop:<id>`): the whole display, no app.
    pub(crate) desktop: bool,
    /// The platform lock handle: the platform's before the target opens, the target's after.
    pub(crate) lock: Shared<dyn LockOps>,
    pub(crate) ops: Option<Ops>,
    /// The capture source, until the capture thread takes it.
    pub(crate) capture_source: Option<Box<dyn Capture>>,
    /// The running capture thread's handle.
    pub(crate) capture: Option<super::capture::CaptureHandle>,
    /// The newest capture sequence number offered to `paced`.
    pub(crate) newest_submitted_seq: u64,
    /// B's focus bit from the last `setStream` (the focus pane, Task 15).
    pub(crate) requested_focus: bool,
    pub(crate) text_reader: Option<Box<dyn TextReader>>,
    /// The app's name, for the ready title and the quit reason.
    pub(crate) app_name: String,
    /// The canvas display in global points.
    pub(crate) display: Rect,
    pub(crate) scale: f32,
    /// The window table last sent, and the raw list it came from.
    pub(crate) table: Vec<WindowInfo>,
    pub(crate) raw: Vec<RawWindow>,
    pub(crate) region: Option<CanvasRect>,
    pub(crate) view: Option<(u32, CanvasRect)>,
    /// Set when the app session was opened while A is locked: `ready` already went out with this size.
    pub(crate) announced: Option<(u16, u16)>,
    pub(crate) sent_locked: Option<bool>,
    /// The unlock password is being typed (`session/unlock.rs`).
    pub(crate) unlocking: bool,
    pub(crate) input_source_on: bool,
    pub(crate) sent_input_source: Option<InputSource>,

    pub(crate) timers: BTreeMap<Timer, f64>,

    // Input (`session/input.rs`).
    /// The target opened: input reaches it (Swift's `injector != nil`).
    pub(crate) input_on: bool,
    /// Keys and buttons posted down and not yet up, released at the end.
    pub(crate) held: HeldInput,
    /// Buttons whose press was dropped: their drags and up are dropped too.
    pub(crate) dropped_buttons: HashSet<MouseButton>,
    /// A covered scroll burst does not raise again before this.
    pub(crate) scroll_raise_after: f64,
    pub(crate) blocked_notice_at: Option<f64>,
    pub(crate) blocked_event_at: Option<f64>,
    /// When B last sent input that may open things (`opens_things`), for `appOpened`.
    pub(crate) last_input_at: Option<f64>,

    // Hints, focus pane, state rules (`session/hints.rs`).
    pub(crate) hints_on: bool,
    pub(crate) cover_notices: CoverNotices,
    pub(crate) sent_secure: bool,
    pub(crate) focus: Option<FocusPane>,
    pub(crate) app_state: Option<AppStateHandle>,
    /// Rules that came before the state thread started.
    pub(crate) pending_rules: Option<String>,

    // Clipboard, paste, transfers (`session/clip.rs`).
    pub(crate) clip: Option<ClipState>,
    /// Shared with the server: where side connections find this session's store.
    pub(crate) transfers_slot: TransferSlot,

    pub(crate) bytes_this_second: usize,
    pub(crate) frames_this_second: i64,
    pub(crate) last_width: usize,
    pub(crate) last_height: usize,
}

impl Session {
    /// Starts the session thread and the reader thread for a connection whose first message
    /// (a hello) and any bytes after it are already read.
    pub fn spawn(
        inner: Arc<Inner>,
        id: u64,
        stream: TcpStream,
        peer: Option<SocketAddr>,
        peer_name: Option<String>,
        first: Message,
        parser: MessageParser,
    ) -> SessionHandle {
        let (tx, rx) = channel();
        let started = Arc::new(AtomicBool::new(false));
        let alive = Arc::new(AtomicBool::new(true));
        let transfers_slot: TransferSlot = Arc::new(std::sync::Mutex::new(None));
        let handle = SessionHandle { id, tx: tx.clone(), started: started.clone(), transfers: transfers_slot.clone() };
        let reader = stream.try_clone();
        let _ = stream.set_write_timeout(Some(inner.clock.real(WRITE_TIMEOUT)));
        let lock = shared(inner.platform.lock());
        let session = Session {
            inner: inner.clone(),
            id,
            stream,
            tx: tx.clone(),
            peer,
            peer_name,
            started_flag: started,
            alive: alive.clone(),
            greeted: false,
            started: false,
            ended: false,
            failing: false,
            send_error: None,
            yield_: InputYield::new(),
            yielded_by: String::new(),
            app_id: String::new(),
            mode: Mode::Gray4,
            fps: 15,
            density: 2.0,
            requested_mode: Mode::Gray4,
            requested_density: 2.0,
            requested_fps: 15,
            paced: None,
            outbox: PauseOutbox::new(),
            desktop: false,
            lock,
            ops: None,
            capture_source: None,
            capture: None,
            newest_submitted_seq: 0,
            requested_focus: false,
            text_reader: None,
            app_name: String::new(),
            display: Rect::new(0.0, 0.0, 0.0, 0.0),
            scale: 1.0,
            table: Vec::new(),
            raw: Vec::new(),
            region: None,
            view: None,
            announced: None,
            sent_locked: None,
            unlocking: false,
            input_source_on: false,
            sent_input_source: None,
            timers: BTreeMap::new(),
            input_on: false,
            held: HeldInput::new(),
            dropped_buttons: HashSet::new(),
            scroll_raise_after: 0.0,
            blocked_notice_at: None,
            blocked_event_at: None,
            last_input_at: None,
            hints_on: false,
            cover_notices: CoverNotices::new(COVER_NOTICE_EVERY),
            sent_secure: false,
            focus: None,
            app_state: None,
            pending_rules: None,
            clip: None,
            transfers_slot,
            bytes_this_second: 0,
            frames_this_second: 0,
            last_width: 0,
            last_height: 0,
        };
        let _ = std::thread::Builder::new()
            .name("rapp-host session".into())
            .spawn(move || session.run(rx, first, parser, reader));
        handle
    }

    fn run(mut self, rx: Receiver<Event>, first: Message, parser: MessageParser, reader: std::io::Result<TcpStream>) {
        self.handle(first);
        self.flush_send_error();
        match reader {
            Ok(r) if !self.ended => spawn_reader(r, parser, self.tx.clone(), self.alive.clone(), self.inner.clone()),
            Ok(_) => {}
            Err(e) => self.end(&format!("connection error: {e}"), None),
        }
        while !self.ended {
            self.fire_timers();
            if self.ended {
                break;
            }
            let wait = self
                .timers
                .values()
                .copied()
                .fold(None, |a: Option<f64>, t| Some(a.map_or(t, |a| a.min(t))))
                .map(|t| (t - self.now()).max(0.0))
                .unwrap_or(TICK_EVERY);
            match rx.recv_timeout(read_timeout(self.inner.clock.as_ref(), wait)) {
                Ok(event) => self.event(event),
                Err(RecvTimeoutError::Timeout) => {}
                // Every sender gone: the server and the reader both ended.
                Err(RecvTimeoutError::Disconnected) => self.end("connection closed", None),
            }
            self.flush_send_error();
        }
        // Late events (a takeover or stop racing the end) still get their answer.
        while let Ok(event) = rx.try_recv() {
            match event {
                Event::TakeOver { ack, .. } | Event::Stop { ack } => {
                    let _ = ack.send(());
                }
                _ => {}
            }
        }
    }

    pub(crate) fn now(&self) -> f64 {
        self.inner.clock.now()
    }

    fn flush_send_error(&mut self) {
        if let Some(e) = self.send_error.take() {
            self.end(&format!("send failed: {e}"), None);
        }
    }

    fn event(&mut self, event: Event) {
        match event {
            Event::Message(m) => self.handle(m),
            Event::BadData(e) => self.fail(&bad_data_reason(&e)),
            Event::Closed(reason) => self.end(&reason, None),
            Event::TakeOver { by, ack } => {
                self.take_over(by.as_deref());
                let _ = ack.send(());
            }
            Event::Kick => self.fail("kicked by the host"),
            Event::Stop { ack } => {
                self.end("host stopped", None);
                let _ = ack.send(());
            }
            Event::Yield(by) => self.yielded(&by),
            Event::FrameReady => self.frame_ready(),
            Event::CaptureStopped(reason) => self.fail(&format!("capture stopped: {reason}")),
            Event::Table(next, raw) => self.table_changed(next, raw),
            Event::Run(job) => {
                if !self.ended {
                    job(self)
                }
            }
        }
    }

    /// Runs `job` on the session thread later (a background thread's result).
    pub(crate) fn post(tx: &Sender<Event>, job: Job) {
        let _ = tx.send(Event::Run(job));
    }

    // MARK: Timers

    pub(crate) fn schedule(&mut self, timer: Timer, after: f64) {
        let at = self.now() + after;
        self.timers.insert(timer, at);
    }

    fn fire_timers(&mut self) {
        loop {
            let now = self.now();
            let due = self.timers.iter().find(|(_, at)| **at <= now).map(|(t, _)| *t);
            let Some(timer) = due else { return };
            self.timers.remove(&timer);
            self.timer_fired(timer);
            self.flush_send_error();
            if self.ended {
                return;
            }
        }
    }

    fn timer_fired(&mut self, timer: Timer) {
        match timer {
            Timer::InputReport => {
                self.schedule(Timer::InputReport, INPUT_REPORT_EVERY);
                if self.yield_.tick(self.now()) {
                    self.inner.out.emit(&WorkerEvent::Input);
                }
            }
            Timer::Tick => {
                self.schedule(Timer::Tick, TICK_EVERY);
                self.tick();
            }
            Timer::Settle => {
                self.schedule(Timer::Settle, SETTLE_EVERY);
                let now = self.now();
                if let Some(p) = self.paced.as_mut() {
                    let out = p.settle_if_idle(now);
                    self.sender_outputs(out);
                }
            }
            Timer::LockWait => self.lock_wait_tick(),
            Timer::InputSource => {
                self.schedule(Timer::InputSource, INPUT_SOURCE_EVERY);
                self.send_input_source(false);
            }
            Timer::FocusTick => self.focus_tick(),
            Timer::Hints => self.hints_tick(),
            Timer::PasteRestore => self.paste_restore_check(),
        }
    }

    // MARK: Handling

    /// Every message from B. No wildcard arm: a new protocol message must be placed here
    /// (the test below checks this agrees with `DISPOSITION`).
    pub(crate) fn handle(&mut self, message: Message) {
        // Every command from B passes one gate; only input can be held back (R7).
        if gated(&message) && !(self.started && !self.failing && self.admit(&message)) {
            return;
        }
        match message {
            Message::Hello { token, bundle_id, mode, fps, density, .. } => self.hello(&token, &bundle_id, mode, fps, density),
            Message::Ping(seq) => {
                // Answered at once: B measures the whole path with it (spec §6.1).
                self.send(Message::Pong(seq));
            }
            m @ (Message::Text(_) | Message::Key { .. } | Message::Mouse { .. } | Message::Scroll { .. }) => self.input(m),
            Message::SetStream { mode, fps, density, pinned, focus } => self.set_stream_request(mode, fps, density, pinned, focus),
            Message::Resize { window, width, height } => self.resize_window(window, width, height),
            Message::Focus(window) => self.focus_window(window),
            Message::Close(window) => self.close_window(window),
            Message::Move { window, x, y } => self.move_window(window, x, y),
            Message::Paste { seq, source } => self.paste(seq, source),
            Message::SelectInput { id } => self.select_input(&id),
            Message::FrameAck { processing_ms } => {
                let now = self.now();
                if let Some(p) = self.paced.as_mut() {
                    let out = p.ack(processing_ms, now);
                    self.sender_outputs(out);
                }
            }
            Message::Unlock { password } => self.unlock(password),
            Message::DismissCover(id) => self.dismiss_cover(id),
            Message::SetView { window, rect } => {
                self.view = crate::wintable::view_for(window, rect);
                let table = self.table.clone();
                self.apply_region(&table);
            }
            Message::StateRules(json) => self.state_rules(json),
            // Windows has no menu bar to show (spec §6.9), and `weak` is a client-to-client hint.
            Message::MenuPick(_) | Message::MenuBar(_) | Message::Weak(_) => {}
            Message::Ready { .. }
            | Message::Error(_)
            | Message::Frame { .. }
            | Message::Windows(_)
            | Message::Clip { .. }
            | Message::Pasted { .. }
            | Message::Fetch { .. }
            | Message::Put { .. }
            | Message::TransferStart(_)
            | Message::Chunk(_)
            | Message::InputBlocked { .. }
            | Message::InputSource { .. }
            | Message::Pong(_)
            | Message::Saving(_)
            | Message::ScreenLocked(_)
            | Message::FocusRegion { .. }
            | Message::Covered { .. }
            | Message::AppOpened { .. }
            | Message::SecureFocus(_)
            | Message::Changed
            | Message::AppState(_) => self.fail("unexpected message from client"),
        }
    }

    fn hello(&mut self, token: &str, bundle_id: &str, mode: Mode, fps: u8, density: f32) {
        if self.greeted {
            self.fail("unexpected hello");
            return;
        }
        self.greeted = true;
        let app = match check_hello(token, bundle_id, &self.inner.options.token, self.inner.options.app.as_deref()) {
            Ok(app) => app,
            Err(e) => {
                self.fail(&e.to_string());
                return;
            }
        };
        self.app_id = app.clone();
        self.mode = mode;
        self.fps = i64::from(fps);
        self.density = density;
        self.requested_mode = mode;
        self.requested_density = density;
        self.requested_fps = i64::from(fps);
        self.make_paced_sender(mode, i64::from(fps));
        let steps = save_ladder_steps(self.ceiling());
        if let Some(p) = self.paced.as_mut() {
            let out = p.set_steps(steps);
            self.sender_outputs(out);
        }
        self.started = true;
        self.started_flag.store(true, Ordering::SeqCst);
        // Held from a valid hello to the end, so A doesn't idle-lock under B.
        hold(&self.lock).stay_awake(true);
        self.schedule(Timer::InputReport, INPUT_REPORT_EVERY);
        let from = self.peer_name.as_ref().map(|n| format!(", from {n}")).unwrap_or_default();
        self.inner.out.log(&format!("client connected: {app}, {}{from}", self.stream_description(mode)));
        self.inner.out.emit(&WorkerEvent::SessionStarted {
            client: self.client_description(),
            mode,
            fps: i64::from(fps),
        });
        match desktop_target(&app) {
            Some(target) => self.start_desktop(target),
            None => self.start_app(app),
        }
    }

    pub(crate) fn stream_description(&self, mode: Mode) -> String {
        format!("{}, {} fps, density {:.2}", mode.name(), self.fps, self.density)
    }

    /// The client's address as `ip:port`.
    fn client_description(&self) -> String {
        self.peer.map(|p| format!("{}:{}", p.ip(), p.port())).unwrap_or_else(|| "unknown".into())
    }

    /// What B asked for: the stream at saving level 0.
    pub(crate) fn ceiling(&self) -> StreamSpec {
        StreamSpec { mode: self.requested_mode, fps: self.requested_fps, density: self.requested_density }
    }

    fn make_paced_sender(&mut self, mode: Mode, fps: i64) {
        let mut paced = PacedSender::new(mode, fps);
        paced.set_timer(self.inner.clock.clone());
        self.paced = Some(paced);
    }

    /// What a `PacedSender` call reported, handled as Swift's callbacks would.
    pub(crate) fn sender_outputs(&mut self, outputs: Vec<SenderOutput>) {
        for o in outputs {
            if self.ended {
                return;
            }
            match o {
                SenderOutput::Frame { region, payload } => {
                    let bytes = Message::Frame { region, payload }.encoded();
                    self.bytes_this_second += bytes.len();
                    self.frames_this_second += 1;
                    self.write(&bytes);
                }
                SenderOutput::LevelChanged(level) => self.level_changed(level),
                SenderOutput::Encoded(report) => self.encoded(report),
            }
        }
    }

    fn level_changed(&mut self, level: i64) {
        if self.ended {
            return;
        }
        self.inner.out.log(&if level == 0 {
            "network recovered: back to the requested stream".to_string()
        } else {
            format!("slow network: saving level {level}")
        });
        self.apply_level(level);
        self.send(Message::Saving(level.clamp(0, 255) as u8));
    }

    pub(crate) fn apply_level(&mut self, level: i64) {
        let s = save_ladder_stream(level, self.ceiling());
        self.set_stream(s.mode, s.fps, s.density);
    }

    // MARK: Yielding to other devices

    /// Whether `message` goes ahead; reports this session's input and tells B when its input waits.
    fn admit(&mut self, message: &Message) -> bool {
        match self.yield_.admit(message, self.now()) {
            YieldDecision::Pass { report } => {
                if report {
                    self.inner.out.emit(&WorkerEvent::Input);
                }
                true
            }
            YieldDecision::Drop { notify } => {
                if let Some(by) = notify {
                    self.inner.out.emit(&WorkerEvent::InputBlocked { by: by.clone() });
                    self.send(Message::InputBlocked { by });
                }
                // B waits for every paste's answer before sending the next piece.
                if let Message::Paste { seq, .. } = message {
                    let error = input_blocked_notice(&self.yielded_by);
                    self.send(Message::Pasted { seq: *seq, error });
                }
                false
            }
        }
    }

    /// Another device operated A just now.
    fn yielded(&mut self, by: &str) {
        if self.ended {
            return;
        }
        self.yielded_by = by.to_string();
        self.yield_.yielded(by, self.now());
    }

    // MARK: Opening the target

    /// The name shown to B before a window exists: the listed app's, else the id.
    fn app_display_name(&self, id: &str) -> String {
        self.inner
            .platform
            .applications()
            .ok()
            .and_then(|apps| apps.into_iter().find(|a| a.app == id).map(|a| a.name))
            .unwrap_or_else(|| id.to_string())
    }

    /// The main display's size in points (the lock screen is there).
    fn main_display_size(&self) -> (u16, u16) {
        let displays = ordered_displays(self.inner.platform.displays());
        let d = displays.iter().find(|d| d.main).or(displays.first());
        d.map(|d| (clamp_u16(d.width()), clamp_u16(d.height()))).unwrap_or((0, 0))
    }

    fn start_app(&mut self, app: String) {
        if self.announced.is_none() && hold(&self.lock).locked() {
            self.wait_for_unlock(&app);
            return;
        }
        let platform = self.inner.platform.clone();
        let tx = self.tx.clone();
        let alive = self.alive.clone();
        std::thread::spawn(move || {
            let opened = platform.open(&Target::App(app));
            if alive.load(Ordering::SeqCst) {
                Session::post(&tx, Box::new(move |s: &mut Session| s.app_opened(opened)));
            }
        });
    }

    /// The canvas an app on a locked A is announced with (`Server.swift:677-678`): the display
    /// its largest window is on, else the main display. `true` when it is the app's display.
    fn locked_canvas(&self, app: &str) -> ((u16, u16), bool) {
        let displays: Vec<Rect> = ordered_displays(self.inner.platform.displays()).iter().map(|d| d.frame).collect();
        let on_app = self.inner.platform.locked_app_windows(app).and_then(|windows| locked_start_display(&windows, &displays));
        match on_app {
            Some(r) => ((clamp_u16(rounded_int(r.w())), clamp_u16(rounded_int(r.h()))), true),
            None => (self.main_display_size(), false),
        }
    }

    /// A is locked at session start (`Server.swift:674-697`): announce the app's display (or the
    /// main one), tell B, and check once a second for the unlock.
    fn wait_for_unlock(&mut self, app: &str) {
        let ((w, h), on_app) = self.locked_canvas(app);
        self.announced = Some((w, h));
        self.inner.out.log(&format!(
            "A is locked at start; waiting for unlock (canvas: {})",
            if on_app { "the app's display" } else { "main display" }
        ));
        let name = self.app_display_name(app);
        self.send(Message::Ready { app_name: window_title(Some(""), Some(&name)), width: w, height: h });
        self.send_locked();
        self.schedule(Timer::LockWait, LOCK_WAIT_EVERY);
    }

    fn lock_wait_tick(&mut self) {
        if self.ended || self.failing {
            return;
        }
        self.send_locked();
        if hold(&self.lock).locked() {
            self.schedule(Timer::LockWait, LOCK_WAIT_EVERY);
            return;
        }
        let app = self.app_id.clone();
        self.start_app(app);
    }

    fn app_opened(&mut self, opened: Result<Parts, OpenError>) {
        let parts = match opened {
            Ok(p) => p,
            Err(e) => {
                self.fail(&e.reason());
                return;
            }
        };
        let mut parts = parts;
        let display: DisplayInfo = parts.target.display();
        let size = Size::new(display.frame.w(), display.frame.h());
        let (w, h) = (clamp_u16(display.frame.w().round() as i64), clamp_u16(display.frame.h().round() as i64));
        if let Some(announced) = self.announced {
            if announced != (w, h) {
                self.fail("解锁后，应用窗口在另一块屏幕上；请重新打开");
                return;
            }
        }
        let name = parts.target.name();
        let raw = parts.windows.list();
        let table = window_table(&raw, display.frame, Some(&name));
        // Before the first poll lists it, the app's front window alone is the region.
        let found = raw
            .iter()
            .find(|r| !r.minimized && r.rect.intersection(&display.frame).is_some())
            .map(|r| WindowInfo {
                id: 1,
                parent: 0,
                kind: crate::protocol::WindowKind::Normal,
                resizable: false,
                focused: false,
                rect: CanvasRect::new(
                    (r.rect.min_x() - display.frame.min_x()) as f32,
                    (r.rect.min_y() - display.frame.min_y()) as f32,
                    r.rect.w() as f32,
                    r.rect.h() as f32,
                ),
                title_bar: 0.0,
                title: String::new(),
            });
        let region = capture_region(&table, size)
            .or_else(|| found.and_then(|f| capture_region(&[f], size)))
            .unwrap_or(CanvasRect::new(0.0, 0.0, size.width as f32, size.height as f32));
        self.app_name = name.clone();
        self.display = display.frame;
        self.scale = display.scale;
        self.region = Some(region);
        self.lock = shared(std::mem::replace(&mut parts.lock, self.inner.platform.lock()));
        self.text_reader = parts.text.take();
        self.capture_source = Some(parts.capture);
        self.ops = Some(Ops {
            target: shared(parts.target),
            windows: shared(parts.windows),
            input: shared(parts.input),
            input_source: shared(parts.input_source),
            clipboard: shared(parts.clipboard),
            controls: shared(parts.controls),
        });
        self.start_capture_thread();
        self.input_ready();
        if self.announced.is_none() {
            self.send(Message::Ready { app_name: window_title(Some(""), Some(&name)), width: w, height: h });
        }
        self.start_app_state();
        // Announced and empty: the first table always goes out.
        self.table = Vec::new();
        self.table_changed(table, raw);
        self.sync_focus();
        self.start_clipboard(false);
        self.start_input_source();
        self.start_hints();
        self.send_locked();
        self.start_timers();
        self.start_window_poll(name);
    }

    /// The whole display `target` names: one fixed window the size of the display, no menus.
    fn start_desktop(&mut self, target: DesktopTarget) {
        self.desktop = true;
        let displays = ordered_displays(self.inner.platform.displays());
        let index = match target {
            DesktopTarget::Main => displays.iter().position(|d| d.main).or(if displays.is_empty() { None } else { Some(0) }),
            DesktopTarget::Display(id) => displays.iter().position(|d| d.id == id),
        };
        let (open_as, main, number) = match index {
            Some(i) => {
                let d = &displays[i];
                let open_as = match target {
                    DesktopTarget::Main => Target::Desktop(None),
                    DesktopTarget::Display(_) => Target::Desktop(Some(d.id)),
                };
                (open_as, d.main, (i + 1) as i64)
            }
            None => {
                let missing = match target {
                    DesktopTarget::Main => "desktop:".to_string(),
                    DesktopTarget::Display(id) => format!("desktop:{id}"),
                };
                self.fail(&OpenError::NotFound(missing).reason());
                return;
            }
        };
        let title = desktop_title(&self.inner.platform.computer_name(), number);
        let platform = self.inner.platform.clone();
        let tx = self.tx.clone();
        let alive = self.alive.clone();
        std::thread::spawn(move || {
            let opened = platform.open(&open_as);
            if alive.load(Ordering::SeqCst) {
                Session::post(&tx, Box::new(move |s: &mut Session| s.desktop_ready(opened, main, title)));
            }
        });
    }

    fn desktop_ready(&mut self, opened: Result<Parts, OpenError>, main: bool, title: String) {
        let mut parts = match opened {
            Ok(p) => p,
            Err(e) => {
                self.fail(&e.reason());
                return;
            }
        };
        let display = parts.target.display();
        self.display = display.frame;
        self.scale = display.scale;
        let region = CanvasRect::new(0.0, 0.0, display.frame.w() as f32, display.frame.h() as f32);
        self.region = Some(region);
        self.app_name = title.clone();
        self.lock = shared(std::mem::replace(&mut parts.lock, self.inner.platform.lock()));
        self.capture_source = Some(parts.capture);
        self.ops = Some(Ops {
            target: shared(parts.target),
            windows: shared(parts.windows),
            input: shared(parts.input),
            input_source: shared(parts.input_source),
            clipboard: shared(parts.clipboard),
            controls: shared(parts.controls),
        });
        self.start_capture_thread();
        self.input_ready();
        let (w, h) = (clamp_u16(display.frame.w().round() as i64), clamp_u16(display.frame.h().round() as i64));
        self.send(Message::Ready { app_name: title.clone(), width: w, height: h });
        self.table = desktop_table(f64::from(w), f64::from(h), &title);
        self.send(Message::Windows(self.table.clone()));
        // One clipboard for the machine: only the main screen's session carries it.
        if main {
            self.start_clipboard(true);
        }
        self.start_input_source();
        self.start_hints();
        self.send_locked();
        self.start_timers();
    }

    /// The 1 s tick and the 0.1 s settle check, for app and desktop sessions alike.
    fn start_timers(&mut self) {
        self.schedule(Timer::Tick, TICK_EVERY);
        self.schedule(Timer::Settle, SETTLE_EVERY);
    }

    /// Windows are looked up 10 times a second (spec §3.2), off the session thread.
    fn start_window_poll(&mut self, app_name: String) {
        let Some(ops) = self.ops.as_ref() else { return };
        let windows = ops.windows.clone();
        let tx = self.tx.clone();
        let alive = self.alive.clone();
        let clock = self.inner.clock.clone();
        let display = self.display;
        let _ = std::thread::Builder::new().name("rapp-host windows".into()).spawn(move || {
            while alive.load(Ordering::SeqCst) {
                clock.sleep(POLL_EVERY);
                if !alive.load(Ordering::SeqCst) {
                    return;
                }
                let raw = hold(&windows).list();
                let table = window_table(&raw, display, Some(&app_name));
                if tx.send(Event::Table(table, raw)).is_err() {
                    return;
                }
            }
        });
    }

    // MARK: The window table

    /// Sends the table if it changed, and follows the windows with the capture region.
    /// An empty table keeps the region (spec §3.2).
    pub(crate) fn table_changed(&mut self, next: Vec<WindowInfo>, raw: Vec<RawWindow>) {
        if self.ended || self.ops.is_none() {
            return;
        }
        self.raw = raw;
        if next != self.table {
            let ids = |t: &[WindowInfo]| t.iter().map(|w| (w.id, w.kind)).collect::<Vec<_>>();
            if ids(&next) != ids(&self.table) {
                let list = if next.is_empty() {
                    "none".to_string()
                } else {
                    next.iter().map(|w| format!("{} {}", kind_name(w.kind), w.id)).collect::<Vec<_>>().join(", ")
                };
                self.inner.out.log(&format!("windows: {list}"));
            }
            self.table = next.clone();
            // The table first: B clears the focus on a size change, so a focusRegion for the
            // new size must arrive after it.
            self.send(Message::Windows(next.clone()));
            self.windows_changed(&next);
        }
        self.apply_region(&next);
    }

    /// Follows the view and the windows with the capture region. No encoder reset: each frame
    /// carries its own region.
    pub(crate) fn apply_region(&mut self, windows: &[WindowInfo]) {
        if self.ended || self.ops.is_none() {
            return;
        }
        let display = Size::new(self.display.w(), self.display.h());
        let Some(new) = region_change(self.view, windows, display, self.region) else { return };
        self.region = Some(new);
        self.inner
            .out
            .log(&format!("region: {},{} {}\u{00D7}{}", new.x as i64, new.y as i64, new.w as i64, new.h as i64));
        self.capture_params_changed();
    }

    // MARK: The tick

    fn tick(&mut self) {
        if self.ended || self.ops.is_none() {
            return;
        }
        let now = self.now();
        if let Some(p) = self.paced.as_mut() {
            let out = p.tick(now);
            self.sender_outputs(out);
        }
        if let Some(m) = self.outbox.due(now) {
            self.transmit(m);
        }
        let kbps = self.bytes_this_second as f64 * 8.0 / 1000.0;
        let p = self.paced.as_mut().map(|p| p.take_stats(now));
        if self.inner.out.json() {
            self.inner.out.emit(&WorkerEvent::Stats {
                kbps,
                fps: self.frames_this_second,
                width: self.last_width as i64,
                height: self.last_height as i64,
                rtt_ms: p.as_ref().and_then(|p| p.rtt_ms),
                base_rtt_ms: p.as_ref().and_then(|p| p.base_rtt_ms),
                latency_ms: p.as_ref().and_then(|p| p.latency_ms),
                weak: p.as_ref().is_some_and(|p| p.weak),
                fulls: p.as_ref().map_or(0, |p| p.full_frames),
                enc_ms: p.as_ref().and_then(|p| p.encode_ms_max),
            });
        } else {
            let n = |v: Option<i64>| v.map_or("-".to_string(), |v| v.to_string());
            self.inner.out.log(&format!(
                "[stats] {:.1} kbps {} fps {}x{} rtt {} base {} latency {} inflight {}/{} fulls {} encMs {}{}",
                kbps,
                self.frames_this_second,
                self.last_width,
                self.last_height,
                n(p.as_ref().and_then(|p| p.rtt_ms)),
                n(p.as_ref().and_then(|p| p.base_rtt_ms)),
                n(p.as_ref().and_then(|p| p.latency_ms)),
                p.as_ref().map_or(0, |p| p.in_flight),
                p.as_ref().map_or(0, |p| p.cap),
                p.as_ref().map_or(0, |p| p.full_frames),
                n(p.as_ref().and_then(|p| p.encode_ms_max)),
                if p.as_ref().is_some_and(|p| p.weak) { " weak" } else { "" },
            ));
        }
        self.bytes_this_second = 0;
        self.frames_this_second = 0;
        // Closing every window does not end the session; quitting the app does (spec §2.5).
        if !self.desktop {
            let alive = self.ops.as_ref().is_some_and(|o| hold(&o.target).alive());
            if !alive {
                let title = window_title(Some(""), Some(&self.app_name));
                self.fail(&format!("{title} quit"));
                return;
            }
        }
        // Backstop for a missed change.
        self.send_input_source(false);
        self.send_locked();
        self.check_secure_focus();
    }

    // MARK: Input source (v8)

    fn start_input_source(&mut self) {
        self.input_source_on = true;
        self.schedule(Timer::InputSource, INPUT_SOURCE_EVERY);
        self.send_input_source(false);
    }

    /// Sends A's input source if it differs from the last one sent, or always with `force`.
    pub(crate) fn send_input_source(&mut self, force: bool) {
        if self.ended || self.failing || !self.input_source_on {
            return;
        }
        let Some(ops) = self.ops.as_ref() else { return };
        let Some(now) = hold(&ops.input_source).current() else { return };
        if !force && Some(&now) == self.sent_input_source.as_ref() {
            return;
        }
        self.sent_input_source = Some(now.clone());
        self.send(Message::InputSource { id: now.id, name: now.name, ascii: now.english });
    }

    // MARK: Lock state

    /// Sends A's lock state if it changed since the last send (at ready, then every tick).
    pub(crate) fn send_locked(&mut self) {
        if self.ended || self.failing {
            return;
        }
        let locked = hold(&self.lock).locked();
        if Some(locked) == self.sent_locked {
            return;
        }
        self.sent_locked = Some(locked);
        self.focus_locked(locked);
        self.inner.out.log(if locked { "A is locked" } else { "A is unlocked" });
        self.send(Message::ScreenLocked(locked));
    }

    // MARK: Sending and ending

    /// Sends `message` unless a pause holds it back (`PauseOutbox`).
    pub(crate) fn send(&mut self, message: Message) {
        let now = self.now();
        if let Some(m) = self.outbox.pass(message, now) {
            self.transmit(m);
        }
    }

    pub(crate) fn transmit(&mut self, message: Message) {
        self.write(&message.encoded());
    }

    fn write(&mut self, bytes: &[u8]) {
        if self.ended || self.send_error.is_some() {
            return;
        }
        if let Err(e) = self.stream.write_all(bytes) {
            self.send_error = Some(e.to_string());
        }
    }

    /// Tells the client why, then ends the session.
    pub(crate) fn fail(&mut self, reason: &str) {
        self.failing = true;
        if self.ended {
            return;
        }
        self.end(reason, Some(Message::Error(reason.to_string())));
    }

    /// Another client's valid hello replaced this one: tell B who, then end as usual (R3, R5).
    fn take_over(&mut self, by: Option<&str>) {
        let reason = taken_over_error(by);
        self.end(&reason.clone(), Some(Message::Error(reason)));
    }

    /// With `farewell`, the connection closes once it is sent (a blocking write with the
    /// session's write timeout stands in for Swift's 1 s backstop).
    pub(crate) fn end(&mut self, reason: &str, farewell: Option<Message>) {
        if self.ended {
            return;
        }
        if let Some(m) = farewell {
            if self.send_error.is_none() {
                let _ = self.stream.set_write_timeout(Some(self.inner.clock.real(1.0)));
                let _ = self.stream.write_all(&m.encoded());
                let _ = self.stream.flush();
            }
        }
        self.ended = true;
        self.alive.store(false, Ordering::SeqCst);
        self.timers.clear();
        // Each part stops what it started. The paster goes first, as in Swift (`paster.end`).
        self.stop_clipboard();
        self.stop_capture();
        // Nothing B pressed stays pressed on A (`releaseAll`).
        self.release_all_input();
        self.stop_hints();
        if self.started {
            hold(&self.lock).stay_awake(false);
        }
        self.paced = None;
        self.ops = None;
        let _ = self.stream.shutdown(Shutdown::Both);
        self.inner.session_ended(self.id, reason, self.started);
    }
}

/// The messages that pass the yield gate (`Server.swift:414`). `menuPick` is in Swift's
/// list too; here it is not handled at all.
fn gated(m: &Message) -> bool {
    matches!(
        m,
        Message::Text(_)
            | Message::Key { .. }
            | Message::Mouse { .. }
            | Message::Scroll { .. }
            | Message::Paste { .. }
            | Message::Focus(_)
            | Message::SetStream { .. }
            | Message::SetView { .. }
            | Message::Resize { .. }
            | Message::Move { .. }
            | Message::Close(_)
            | Message::SelectInput { .. }
            | Message::Unlock { .. }
            | Message::DismissCover(_)
    )
}

pub(crate) fn kind_name(kind: crate::protocol::WindowKind) -> String {
    format!("{kind:?}").to_lowercase()
}

pub(crate) fn clamp_u16(v: i64) -> u16 {
    v.clamp(0, i64::from(u16::MAX)) as u16
}

/// Reads the client's connection for the session: messages, parse errors, the end.
fn spawn_reader(mut stream: TcpStream, mut parser: MessageParser, tx: Sender<Event>, alive: Arc<AtomicBool>, inner: Arc<Inner>) {
    let _ = std::thread::Builder::new().name("rapp-host reader".into()).spawn(move || {
        let mut buf = vec![0u8; 64 * 1024];
        loop {
            // Bytes that came with the first message are handled before more are read.
            loop {
                match parser.next() {
                    Ok(Some(m)) => {
                        if tx.send(Event::Message(m)).is_err() {
                            return;
                        }
                    }
                    Ok(None) => break,
                    Err(e) => {
                        let _ = tx.send(Event::BadData(e));
                        return;
                    }
                }
            }
            if !alive.load(Ordering::SeqCst) {
                return;
            }
            let _ = stream.set_read_timeout(Some(read_timeout(inner.clock.as_ref(), READ_SLICE)));
            match stream.read(&mut buf) {
                Ok(0) => {
                    let _ = tx.send(Event::Closed("client disconnected".into()));
                    return;
                }
                Ok(n) => parser.append(&buf[..n]),
                Err(e) if matches!(e.kind(), ErrorKind::WouldBlock | ErrorKind::TimedOut | ErrorKind::Interrupted) => {}
                Err(e) => {
                    if alive.load(Ordering::SeqCst) {
                        let _ = tx.send(Event::Closed(format!("connection error: {e}")));
                    }
                    return;
                }
            }
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::{disposition, ClipInfo, ClipKind, Disposition, FramePayload, Password, PasteSource};

    #[derive(Debug, PartialEq)]
    enum Reaction {
        Handled,
        Unexpected,
        Ignored,
    }

    /// What `Session::handle` does with each message: the arms above, by hand.
    fn reaction(m: &Message) -> Reaction {
        match m {
            Message::MenuPick(_) | Message::MenuBar(_) | Message::Weak(_) => Reaction::Ignored,
            Message::Ready { .. }
            | Message::Error(_)
            | Message::Frame { .. }
            | Message::Windows(_)
            | Message::Clip { .. }
            | Message::Pasted { .. }
            | Message::Fetch { .. }
            | Message::Put { .. }
            | Message::TransferStart(_)
            | Message::Chunk(_)
            | Message::InputBlocked { .. }
            | Message::InputSource { .. }
            | Message::Pong(_)
            | Message::Saving(_)
            | Message::ScreenLocked(_)
            | Message::FocusRegion { .. }
            | Message::Covered { .. }
            | Message::AppOpened { .. }
            | Message::SecureFocus(_)
            | Message::Changed
            | Message::AppState(_) => Reaction::Unexpected,
            _ => Reaction::Handled,
        }
    }

    fn samples() -> Vec<Message> {
        let r = CanvasRect::new(0.0, 0.0, 1.0, 1.0);
        vec![
            Message::Hello { token: "t".into(), bundle_id: "a".into(), mode: Mode::Gray4, fps: 15, density: 1.0, version: 16 },
            Message::Ready { app_name: "a".into(), width: 1, height: 1 },
            Message::Error("e".into()),
            Message::Frame {
                region: r,
                payload: FramePayload { mode: Mode::Gray4, width: 1, height: 1, flags: crate::protocol::FrameFlags::FULL, dx: 0, dy: 0, data: Vec::new() },
            },
            Message::Text("x".into()),
            Message::Key { key_code: 1, modifiers: 0, down: true },
            Message::Mouse { kind: crate::protocol::MouseKind::Down, button: crate::protocol::MouseButton::Left, window: 1, x: 0.0, y: 0.0, click_count: 1 },
            Message::Scroll { window: 1, x: 0.0, y: 0.0, dx: 0.0, dy: 1.0 },
            Message::Resize { window: 1, width: 100, height: 100 },
            Message::SetStream { mode: Mode::Gray4, fps: 15, density: 1.0, pinned: false, focus: false },
            Message::Windows(Vec::new()),
            Message::Focus(1),
            Message::Close(1),
            Message::Move { window: 1, x: 0.0, y: 0.0 },
            Message::MenuBar(Vec::new()),
            Message::MenuPick(vec![0]),
            Message::Clip { id: 1, info: ClipInfo::Text { text: "x".into(), truncated: false } },
            Message::Paste { seq: 1, source: PasteSource::Text("x".into()) },
            Message::Pasted { seq: 1, error: String::new() },
            Message::Fetch { token: "t".into(), clip: 1, file: 0, offset: 0 },
            Message::Put { token: "t".into(), item: 1, kind: ClipKind::Text, uti: String::new(), name: String::new(), total: 1 },
            Message::TransferStart(1),
            Message::Chunk(vec![1]),
            Message::InputBlocked { by: "b".into() },
            Message::FrameAck { processing_ms: 1 },
            Message::Weak(true),
            Message::InputSource { id: "i".into(), name: "n".into(), ascii: true },
            Message::SelectInput { id: "i".into() },
            Message::Ping(1),
            Message::Pong(1),
            Message::Saving(1),
            Message::ScreenLocked(true),
            Message::Unlock { password: Password::new("p") },
            Message::FocusRegion { window: 1, rects: Vec::new() },
            Message::Covered { id: 1, name: "n".into(), bundle_id: "b".into(), dismissable: false },
            Message::SetView { window: 1, rect: r },
            Message::DismissCover(1),
            Message::AppOpened { bundle_id: "b".into(), name: "n".into() },
            Message::SecureFocus(true),
            Message::Changed,
            Message::StateRules("{}".into()),
            Message::AppState("{}".into()),
        ]
    }

    #[test]
    fn handler_agrees_with_disposition() {
        let samples = samples();
        for m in &samples {
            let d = disposition(m.type_byte()).expect("known type");
            let want = match d {
                Disposition::FromClient => Reaction::Handled,
                Disposition::ToClient | Disposition::Side => Reaction::Unexpected,
                Disposition::NotHandled => Reaction::Ignored,
            };
            assert_eq!(reaction(m), want, "{}", m.case_name());
        }
        // One sample per table row.
        let mut seen: Vec<u8> = samples.iter().map(|m| m.type_byte()).collect();
        seen.sort_unstable();
        seen.dedup();
        assert_eq!(seen.len(), crate::protocol::DISPOSITION.len());
    }
}
