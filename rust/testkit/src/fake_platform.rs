//! A scripted platform for `rapp-host-core` (plan B, Task 13): one 1280x800 display at
//! scale 2.0, one app `fake.app` ("Fake") with one 800x600 window that shows a fixed test
//! pattern. Every platform call is written to a log the tests read; typed text, passwords and
//! clipboard contents never are, only their length.
//!
//! All handles of one `FakePlatform` (and every `Parts` it opens) share one state, so a test can
//! change what the "screen" shows while a session runs.

use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::Duration;

use rapp_host_core::cli::SharedApp;
use rapp_host_core::clipboard::ClipSource;
use rapp_host_core::clock::Clock;
use rapp_host_core::desktop::DesktopDisplay;
use rapp_host_core::focus::{PanelMiss, Query};
use rapp_host_core::hit_test::ScreenWindow;
use rapp_host_core::platform::{
    Capture, ClipRead, ClipSnapshot, ClipboardOps, ControlOps, DisplayInfo, Frame, InputOps, InputSource,
    InputSourceOps, LockOps, OpenError, OpenedApp, Parts, Permissions, Platform, RawWindow, Target, TargetOps,
    WindowOps,
};
use rapp_host_core::protocol::{CanvasRect, MouseButton, MouseKind, WindowKind};
use rapp_host_core::query::QueryDeadline;
use rapp_host_core::state::detectors::TextReader;
use rapp_host_core::state::{RuleImage, RuleRect};
use rapp_host_core::transfers::{FileRef, ReceivedItem};
use rapp_host_core::{Point, Rect, Size};

/// The fake app's process id.
pub const FAKE_PID: i32 = 4100;
/// The process that owns the covering window `set_cover` puts up.
pub const COVER_PID: i32 = 4242;
pub const COVER_APP: &str = "com.fake.cover";
pub const FAKE_APP: &str = "fake.app";
pub const FAKE_APP_NAME: &str = "Fake";
pub const FAKE_COMPUTER: &str = "Fake PC";
pub const FAKE_WINDOW_TITLE: &str = "Fake Window";
pub const ENGLISH_SOURCE: &str = "com.fake.en";
pub const CHINESE_SOURCE: &str = "com.fake.zh";
/// The window's title row, in points.
pub const TITLE_BAR: f32 = 28.0;

struct State {
    displays: Vec<DesktopDisplay>,
    scale: f32,
    windows: Vec<RawWindow>,
    scroll: i64,
    /// Bumped on every change to what the screen shows; capture sends a frame when it moved.
    generation: u64,
    alive: bool,
    frontmost: bool,
    open_error: Option<OpenError>,
    capture_error: Option<String>,
    /// `Capture::frame` calls so far (whether or not they returned a picture).
    frame_calls: usize,
    /// Forces the pixel size of the next pictures (a broken platform's empty frame).
    frame_size: Option<(usize, usize)>,

    locked: bool,
    password: Vec<u16>,
    /// Units typed at the lock screen since the last return, and whether each matched so far.
    typed: usize,
    typed_ok: bool,
    can_unlock: bool,
    /// Why the next `lock` call cannot be made (`None`: it locks).
    lock_error: Option<String>,
    awake: bool,
    /// What `locked_app_windows` answers for the fake app (`None`: the platform cannot say).
    locked_windows: Option<Vec<Rect>>,

    clip: Option<ClipRead>,
    change: i64,
    written: Option<ReceivedItem>,
    pastes: Vec<Option<ReceivedItem>>,

    cover: Option<(Rect, bool)>,
    elevated: Option<Rect>,
    focus_chain: Option<Vec<Rect>>,
    /// Host seconds each focus query takes (`set_focus_delay`).
    focus_delay: Option<f64>,
    keyboard_moved: bool,
    secure: bool,
    opened: Option<OpenedApp>,
    text_lines: Vec<String>,

    sources: Vec<InputSource>,
    source: usize,

    data_root: PathBuf,
    log: Vec<String>,
}

/// Clone shares the state: hand one clone to the host, keep one to drive and inspect it.
#[derive(Clone)]
pub struct FakePlatform {
    state: Arc<Mutex<State>>,
}

fn lock_state(state: &Arc<Mutex<State>>) -> MutexGuard<'_, State> {
    state.lock().unwrap_or_else(|e| e.into_inner())
}

fn note(state: &Arc<Mutex<State>>, line: String) {
    lock_state(state).log.push(line);
}

/// The pattern's own generator (a 64-bit LCG step plus a fold), so the picture never changes
/// with a dependency's version.
fn mix(v: u64) -> u64 {
    let s = v.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
    s ^ (s >> 33)
}

fn button_name(b: &MouseButton) -> &'static str {
    match b {
        MouseButton::Left => "left",
        MouseButton::Right => "right",
    }
}

fn kind_name(k: &MouseKind) -> &'static str {
    match k {
        MouseKind::Down => "down",
        MouseKind::Up => "up",
        MouseKind::Drag => "drag",
        MouseKind::Move => "move",
    }
}

/// What a clipboard read amounts to as an item (what `paste_key` would paste).
fn as_item(c: &ClipRead) -> Option<ReceivedItem> {
    match &c.source {
        ClipSource::Text => c.text.clone().map(ReceivedItem::Text),
        ClipSource::Image => c.image_png.clone().map(ReceivedItem::Image),
        ClipSource::Files => c.files.first().map(|f| ReceivedItem::File(f.path.clone())),
        ClipSource::Data { uti } => c.data.clone().map(|bytes| ReceivedItem::Data { uti: uti.clone(), bytes }),
        ClipSource::None => None,
    }
}

/// The clipboard after `item` was written to it.
fn as_read(item: &ReceivedItem) -> ClipRead {
    let mut c = ClipRead {
        source: ClipSource::None,
        text: None,
        image_png: None,
        files: Vec::new(),
        data: None,
        concealed: false,
    };
    match item {
        ReceivedItem::Text(t) => {
            c.source = ClipSource::Text;
            c.text = Some(t.clone());
        }
        ReceivedItem::Image(png) => {
            c.source = ClipSource::Image;
            c.image_png = Some(png.clone());
        }
        ReceivedItem::Data { uti, bytes } => {
            c.source = ClipSource::Data { uti: uti.clone() };
            c.data = Some(bytes.clone());
        }
        ReceivedItem::File(path) => {
            c.source = ClipSource::Files;
            let meta = std::fs::metadata(path).ok();
            c.files = vec![FileRef {
                path: path.clone(),
                size: meta.as_ref().map_or(0, |m| m.len()),
                modified: meta.and_then(|m| m.modified().ok()).unwrap_or(std::time::UNIX_EPOCH),
            }];
        }
    }
    c
}

fn item_kind(item: &ReceivedItem) -> String {
    match item {
        ReceivedItem::Text(t) => format!("text {}", t.encode_utf16().count()),
        ReceivedItem::Image(png) => format!("image {}", png.len()),
        ReceivedItem::Data { bytes, .. } => format!("data {}", bytes.len()),
        ReceivedItem::File(_) => "file".to_string(),
    }
}

static NEXT_ROOT: AtomicU64 = AtomicU64::new(0);

impl Default for FakePlatform {
    fn default() -> Self {
        FakePlatform::new()
    }
}

impl FakePlatform {
    pub fn new() -> FakePlatform {
        let n = NEXT_ROOT.fetch_add(1, Ordering::SeqCst);
        let data_root = std::env::temp_dir().join(format!("rapp-fake-platform-{}-{n}", std::process::id()));
        let _ = std::fs::create_dir_all(&data_root);
        let state = State {
            displays: vec![DesktopDisplay {
                id: 1,
                name: "Fake Display".to_string(),
                main: true,
                frame: Rect::new(0.0, 0.0, 1280.0, 800.0),
            }],
            scale: 2.0,
            windows: vec![FakePlatform::window(1, Rect::new(240.0, 100.0, 800.0, 600.0))],
            scroll: 0,
            generation: 1,
            alive: true,
            frontmost: true,
            open_error: None,
            capture_error: None,
            frame_calls: 0,
            frame_size: None,
            locked: false,
            password: Vec::new(),
            typed: 0,
            typed_ok: true,
            can_unlock: true,
            lock_error: None,
            awake: false,
            locked_windows: None,
            clip: None,
            change: 0,
            written: None,
            pastes: Vec::new(),
            cover: None,
            elevated: None,
            focus_chain: None,
            focus_delay: None,
            keyboard_moved: false,
            secure: false,
            opened: None,
            text_lines: Vec::new(),
            sources: vec![
                InputSource { id: ENGLISH_SOURCE.to_string(), name: "English".to_string(), english: true },
                InputSource { id: CHINESE_SOURCE.to_string(), name: "中文".to_string(), english: false },
            ],
            source: 0,
            data_root,
            log: Vec::new(),
        };
        FakePlatform { state: Arc::new(Mutex::new(state)) }
    }

    /// A normal, resizable window of the fake app with a 28 pt title row.
    pub fn window(id: u32, rect: Rect) -> RawWindow {
        RawWindow {
            id,
            rect,
            title: FAKE_WINDOW_TITLE.to_string(),
            kind: WindowKind::Normal,
            resizable: true,
            close_button: true,
            title_bar: TITLE_BAR,
            owner: FAKE_PID,
            minimized: false,
            foreground: true,
            appeared: 0.0,
        }
    }

    /// Deterministic BGRA (opaque, `width * 4` bytes per row): a ground of 32 px blocks in light
    /// colours, with text-like rows every 16 px (dark marks in the middle 8 rows of each band).
    /// `scroll` moves the content up by that many pixels.
    pub fn pattern(width: usize, height: usize, scroll: i64) -> Vec<u8> {
        let mut out = vec![0u8; width * height * 4];
        for y in 0..height {
            let row = y as i64 + scroll;
            let band = row.div_euclid(16) as u64;
            let line = row.rem_euclid(16);
            let block_row = row.div_euclid(32) as u64;
            for x in 0..width {
                let block = mix((x / 32) as u64 ^ (block_row << 20));
                let ground = [
                    180 + (block & 0x3f) as u8,
                    180 + ((block >> 8) & 0x3f) as u8,
                    180 + ((block >> 16) & 0x3f) as u8,
                ];
                let glyph = mix((x / 6) as u64 ^ (band << 24) ^ 0x9e37_79b9);
                let ink = (4..12).contains(&line) && x % 6 < 4 && glyph & 3 != 0;
                let [b, g, r] = if ink { [30, 30, 40] } else { ground };
                let o = (y * width + x) * 4;
                out[o..o + 4].copy_from_slice(&[b, g, r, 255]);
            }
        }
        out
    }

    fn st(&self) -> MutexGuard<'_, State> {
        lock_state(&self.state)
    }

    fn changed(s: &mut State) {
        s.generation += 1;
    }

    pub fn set_windows(&self, w: Vec<RawWindow>) {
        let mut s = self.st();
        s.windows = w;
        FakePlatform::changed(&mut s);
    }

    pub fn windows(&self) -> Vec<RawWindow> {
        self.st().windows.clone()
    }

    pub fn set_displays(&self, d: Vec<DesktopDisplay>) {
        self.st().displays = d;
    }

    pub fn scroll_by(&self, dy: i64) {
        let mut s = self.st();
        s.scroll += dy;
        FakePlatform::changed(&mut s);
    }

    pub fn scroll(&self) -> i64 {
        self.st().scroll
    }

    /// Makes the next capture send a frame even though nothing moved.
    pub fn touch(&self) {
        FakePlatform::changed(&mut self.st());
    }

    pub fn set_locked(&self, on: bool) {
        let mut s = self.st();
        s.locked = on;
        s.typed = 0;
        s.typed_ok = true;
    }

    pub fn locked(&self) -> bool {
        self.st().locked
    }

    pub fn set_password(&self, p: &str) {
        self.st().password = p.encode_utf16().collect();
    }

    pub fn set_can_unlock(&self, on: bool) {
        self.st().can_unlock = on;
    }

    /// Makes `lock` fail with `reason` (`None`: it locks again).
    pub fn set_lock_error(&self, reason: Option<&str>) {
        self.st().lock_error = reason.map(str::to_string);
    }

    /// The window frames the platform lists for the fake app while A is locked (`None`, the
    /// default: it cannot list them, and a session started locked announces the main display).
    pub fn set_locked_app_windows(&self, w: Option<Vec<Rect>>) {
        self.st().locked_windows = w;
    }

    /// Whether the session holds A awake.
    pub fn awake(&self) -> bool {
        self.st().awake
    }

    /// What the user copied on A.
    pub fn set_clipboard(&self, c: ClipRead) {
        let mut s = self.st();
        s.clip = Some(c);
        s.change += 1;
    }

    /// The last item the host wrote to the clipboard.
    pub fn clipboard(&self) -> Option<ReceivedItem> {
        self.st().written.clone()
    }

    pub fn change_count(&self) -> i64 {
        self.st().change
    }

    /// What the clipboard holds now (after the host's writes and restores).
    pub fn current_clipboard(&self) -> Option<ClipRead> {
        self.st().clip.clone()
    }

    /// What the clipboard held at each `paste_key`, in order.
    pub fn pastes(&self) -> Vec<Option<ReceivedItem>> {
        self.st().pastes.clone()
    }

    /// Another app's window over `rect`; `dismissable`: a regular app whose window can be closed.
    pub fn set_cover(&self, at: Option<(Rect, bool)>) {
        let mut s = self.st();
        s.cover = at;
        FakePlatform::changed(&mut s);
    }

    pub fn set_elevated(&self, r: Option<Rect>) {
        self.st().elevated = r;
    }

    pub fn fail_capture(&self, reason: Option<&str>) {
        self.st().capture_error = reason.map(str::to_string);
    }

    /// The app quits.
    pub fn kill_target(&self) {
        let mut s = self.st();
        s.alive = false;
        s.windows.clear();
        FakePlatform::changed(&mut s);
    }

    pub fn set_open_error(&self, e: Option<OpenError>) {
        self.st().open_error = e;
    }

    pub fn set_frontmost(&self, on: bool) {
        self.st().frontmost = on;
    }

    /// The focused control and its parents in global points; `None`: the query misses.
    pub fn set_focus_chain(&self, chain: Option<Vec<Rect>>) {
        let mut s = self.st();
        s.focus_chain = chain;
        s.keyboard_moved = true;
    }

    /// Each focus query takes `delay` host seconds before it answers (None: at once). The
    /// state lock is not held while it waits.
    pub fn set_focus_delay(&self, delay: Option<f64>) {
        self.st().focus_delay = delay;
    }

    pub fn set_secure(&self, on: bool) {
        self.st().secure = on;
    }

    /// Another app comes to the front (as if input opened it).
    pub fn open_other_app(&self, app: OpenedApp) {
        self.st().opened = Some(app);
    }

    /// What the text reader recognises anywhere on the picture.
    pub fn set_text_lines(&self, lines: Vec<String>) {
        self.st().text_lines = lines;
    }

    /// The user switched A's input source by hand.
    pub fn set_input_source(&self, id: &str) {
        let mut s = self.st();
        if let Some(i) = s.sources.iter().position(|x| x.id == id) {
            s.source = i;
        }
    }

    pub fn input_source(&self) -> String {
        let s = self.st();
        s.sources[s.source].id.clone()
    }

    pub fn data_root(&self) -> PathBuf {
        self.st().data_root.clone()
    }

    /// Every platform call so far, in order.
    /// How many times the capture was polled.
    pub fn frame_calls(&self) -> usize {
        self.st().frame_calls
    }

    /// Pictures come out `size` pixels big whatever the region (`None`: the region's size).
    pub fn set_frame_size(&self, size: Option<(usize, usize)>) {
        let mut s = self.st();
        s.frame_size = size;
        FakePlatform::changed(&mut s);
    }

    /// The display's pixels per point (what capture density is capped at).
    pub fn set_scale(&self, scale: f32) {
        self.st().scale = scale;
    }

    pub fn log(&self) -> Vec<String> {
        self.st().log.clone()
    }

    pub fn clear_log(&self) {
        self.st().log.clear();
    }

    fn parts(&self) -> Parts {
        let s = || self.state.clone();
        Parts {
            target: Box::new(FakeTarget(s())),
            windows: Box::new(FakeWindows(s())),
            capture: Box::new(FakeCapture { state: s(), served: None }),
            input: Box::new(FakeInput(s())),
            input_source: Box::new(FakeSources(s())),
            clipboard: Box::new(FakeClipboard(s())),
            controls: Box::new(FakeControls(s())),
            text: Some(Box::new(FakeText(s()))),
            lock: Box::new(FakeLock(s())),
        }
    }
}

impl Platform for FakePlatform {
    fn name(&self) -> &'static str {
        "fake"
    }

    fn computer_name(&self) -> String {
        FAKE_COMPUTER.to_string()
    }

    fn data_root(&self) -> PathBuf {
        FakePlatform::data_root(self)
    }

    /// The four "no picture" reasons show as `error`; a not-installed app or any other open
    /// failure does not.
    fn permissions(&self) -> Permissions {
        let error = self.st().open_error.clone().filter(|e| {
            matches!(e, OpenError::NoDisplay | OpenError::SessionDisconnected | OpenError::NotInteractive | OpenError::OtherUser)
        });
        Permissions {
            screen_recording: error.is_none(),
            accessibility: true,
            platform: "fake".to_string(),
            applications: true,
            error,
        }
    }

    fn displays(&self) -> Vec<DesktopDisplay> {
        self.st().displays.clone()
    }

    fn applications(&self) -> Result<Vec<SharedApp>, String> {
        Ok(vec![SharedApp { app: FAKE_APP.to_string(), name: FAKE_APP_NAME.to_string() }])
    }

    fn lock(&self) -> Box<dyn LockOps> {
        Box::new(FakeLock(self.state.clone()))
    }

    fn locked_app_windows(&self, app: &str) -> Option<Vec<Rect>> {
        let s = self.st();
        if app != FAKE_APP || !s.alive {
            return None;
        }
        s.locked_windows.clone()
    }

    fn open(&self, target: &Target) -> Result<Parts, OpenError> {
        let mut s = self.st();
        match target {
            Target::App(id) => s.log.push(format!("open app {id}")),
            Target::Desktop(None) => s.log.push("open desktop main".to_string()),
            Target::Desktop(Some(id)) => s.log.push(format!("open desktop {id}")),
        }
        if let Some(e) = &s.open_error {
            return Err(e.clone());
        }
        match target {
            Target::App(id) if id != FAKE_APP => return Err(OpenError::NotFound(id.clone())),
            Target::App(_) => {
                // Opening launches the app when it is not running.
                if !s.alive {
                    s.alive = true;
                    s.windows = vec![FakePlatform::window(1, Rect::new(240.0, 100.0, 800.0, 600.0))];
                    FakePlatform::changed(&mut s);
                }
            }
            Target::Desktop(Some(id)) if !s.displays.iter().any(|d| d.id == *id) => {
                return Err(OpenError::NotFound(format!("desktop:{id}")));
            }
            Target::Desktop(_) => {}
        }
        drop(s);
        Ok(self.parts())
    }
}

struct FakeTarget(Arc<Mutex<State>>);

impl TargetOps for FakeTarget {
    fn alive(&mut self) -> bool {
        lock_state(&self.0).alive
    }
    fn name(&self) -> String {
        FAKE_APP_NAME.to_string()
    }
    fn version(&self) -> Option<String> {
        Some("1.0".to_string())
    }
    fn pid(&self) -> i32 {
        FAKE_PID
    }
    fn display(&mut self) -> DisplayInfo {
        let s = lock_state(&self.0);
        let d = s.displays.iter().find(|d| d.main).or(s.displays.first());
        DisplayInfo { frame: d.map_or(Rect::new(0.0, 0.0, 1280.0, 800.0), |d| d.frame), scale: s.scale }
    }
    fn activate(&mut self) -> bool {
        let mut s = lock_state(&self.0);
        s.log.push("activate".to_string());
        // Nothing comes to the front over the lock screen.
        if s.locked {
            return false;
        }
        s.frontmost = true;
        true
    }
    fn frontmost(&mut self) -> bool {
        lock_state(&self.0).frontmost
    }
}

struct FakeWindows(Arc<Mutex<State>>);

impl WindowOps for FakeWindows {
    fn list(&mut self) -> Vec<RawWindow> {
        lock_state(&self.0).windows.clone()
    }
    fn screen(&mut self) -> Vec<ScreenWindow> {
        let s = lock_state(&self.0);
        let mut out = Vec::new();
        if let Some((rect, _)) = s.cover {
            out.push(ScreenWindow { pid: COVER_PID, name: "Cover".to_string(), layer: 0, alpha: 1.0, frame: rect });
        }
        out.extend(s.windows.iter().filter(|w| !w.minimized).map(|w| ScreenWindow {
            pid: w.owner,
            name: w.title.clone(),
            layer: 0,
            alpha: 1.0,
            frame: w.rect,
        }));
        out
    }
    fn raise(&mut self, id: u32) {
        let mut s = lock_state(&self.0);
        s.log.push(format!("raise {id}"));
        if let Some(i) = s.windows.iter().position(|w| w.id == id) {
            let w = s.windows.remove(i);
            s.windows.insert(0, w);
            for (n, w) in s.windows.iter_mut().enumerate() {
                w.foreground = n == 0;
            }
            FakePlatform::changed(&mut s);
        }
    }
    fn close(&mut self, id: u32) {
        let mut s = lock_state(&self.0);
        s.log.push(format!("close {id}"));
        s.windows.retain(|w| w.id != id);
        FakePlatform::changed(&mut s);
    }
    fn move_to(&mut self, id: u32, origin: Point) {
        let mut s = lock_state(&self.0);
        s.log.push(format!("move {id} to {},{}", origin.x, origin.y));
        if let Some(w) = s.windows.iter_mut().find(|w| w.id == id) {
            w.rect = Rect::new(origin.x, origin.y, w.rect.w(), w.rect.h());
        }
        FakePlatform::changed(&mut s);
    }
    fn resize(&mut self, id: u32, size: Size) {
        let mut s = lock_state(&self.0);
        s.log.push(format!("resize {id} to {}x{}", size.width, size.height));
        if let Some(w) = s.windows.iter_mut().find(|w| w.id == id) {
            w.rect = Rect::new(w.rect.min_x(), w.rect.min_y(), size.width, size.height);
        }
        FakePlatform::changed(&mut s);
    }
    fn opened_app(&mut self) -> Option<OpenedApp> {
        lock_state(&self.0).opened.take()
    }
}

/// Sends a frame when the picture, the region or the density changed since the last one;
/// otherwise waits `wait` and says nothing new.
struct FakeCapture {
    state: Arc<Mutex<State>>,
    served: Option<(u64, CanvasRect, f32)>,
}

impl Capture for FakeCapture {
    fn frame(&mut self, region: CanvasRect, density: f32, wait: Duration) -> Result<Option<Frame>, String> {
        let (generation, scroll, error, forced) = {
            let mut s = lock_state(&self.state);
            s.frame_calls += 1;
            (s.generation, s.scroll, s.capture_error.clone(), s.frame_size)
        };
        if let Some(reason) = error {
            return Err(reason);
        }
        if self.served == Some((generation, region, density)) {
            std::thread::sleep(wait);
            return Ok(None);
        }
        self.served = Some((generation, region, density));
        let (width, height) = forced.unwrap_or((
            ((region.w * density).round() as usize).max(1),
            ((region.h * density).round() as usize).max(1),
        ));
        Ok(Some(Frame {
            bgra: FakePlatform::pattern(width, height, scroll),
            width,
            height,
            bytes_per_row: width * 4,
            region,
        }))
    }
}

struct FakeInput(Arc<Mutex<State>>);

impl InputOps for FakeInput {
    fn mouse(&mut self, kind: MouseKind, button: MouseButton, at: Point, click_count: u8) {
        note(
            &self.0,
            format!("mouse {} {} {},{} {}", kind_name(&kind), button_name(&button), at.x, at.y, click_count),
        );
    }
    /// The wheel scrolls the pattern: a wheel turn of `dy` points down moves the content up.
    fn scroll(&mut self, at: Point, dx: f32, dy: f32) {
        let mut s = lock_state(&self.0);
        s.log.push(format!("scroll {},{} {} {}", at.x, at.y, dx, dy));
        let px = (f64::from(-dy) * f64::from(s.scale)).round() as i64;
        if px != 0 {
            s.scroll += px;
            FakePlatform::changed(&mut s);
        }
    }
    fn key(&mut self, key_code: u16, modifiers: u64, down: bool) {
        let state = if down { "down" } else { "up" };
        note(
            &self.0,
            if modifiers == 0 {
                format!("key {key_code} {state}")
            } else {
                format!("key {key_code} {state} mods={modifiers}")
            },
        );
    }
    fn text(&mut self, units: &[u16]) {
        note(&self.0, format!("text {}", units.len()));
    }
    fn paste_key(&mut self) {
        let mut s = lock_state(&self.0);
        s.log.push("paste_key".to_string());
        let held = s.clip.as_ref().and_then(as_item);
        s.pastes.push(held);
    }
    fn release(&mut self, keys: &[u16], buttons: &[MouseButton]) {
        let names: Vec<&str> = buttons.iter().map(button_name).collect();
        note(&self.0, format!("release keys={keys:?} buttons=[{}]", names.join(", ")));
    }
    fn blocked_by(&mut self, at: Point) -> Option<String> {
        let s = lock_state(&self.0);
        s.elevated.filter(|r| r.contains_point(at)).map(|_| "elevated".to_string())
    }
}

struct FakeSources(Arc<Mutex<State>>);

impl InputSourceOps for FakeSources {
    fn current(&mut self) -> Option<InputSource> {
        let s = lock_state(&self.0);
        s.sources.get(s.source).cloned()
    }
    fn list(&mut self) -> Vec<InputSource> {
        lock_state(&self.0).sources.clone()
    }
    fn select(&mut self, id: &str) -> bool {
        let mut s = lock_state(&self.0);
        s.log.push(format!("select_input {id}"));
        match s.sources.iter().position(|x| x.id == id) {
            Some(i) => {
                s.source = i;
                true
            }
            None => false,
        }
    }
    fn select_english(&mut self) -> bool {
        let mut s = lock_state(&self.0);
        s.log.push("select_english".to_string());
        match s.sources.iter().position(|x| x.english) {
            Some(i) => {
                s.source = i;
                true
            }
            None => false,
        }
    }
}

struct FakeClipboard(Arc<Mutex<State>>);

impl ClipboardOps for FakeClipboard {
    fn change_count(&mut self) -> i64 {
        lock_state(&self.0).change
    }
    fn read(&mut self) -> Option<ClipRead> {
        lock_state(&self.0).clip.clone()
    }
    fn write(&mut self, item: &ReceivedItem) -> Result<i64, String> {
        let mut s = lock_state(&self.0);
        s.log.push(format!("clipboard write {}", item_kind(item)));
        s.clip = Some(as_read(item));
        s.written = Some(item.clone());
        s.change += 1;
        Ok(s.change)
    }
    fn snapshot(&mut self) -> Option<ClipSnapshot> {
        let mut s = lock_state(&self.0);
        s.log.push("clipboard snapshot".to_string());
        let held: Option<ClipRead> = s.clip.clone();
        Some(ClipSnapshot(Box::new(held)))
    }
    fn restore(&mut self, snap: ClipSnapshot) -> Option<i64> {
        let mut s = lock_state(&self.0);
        s.log.push("clipboard restore".to_string());
        let held = snap.0.downcast::<Option<ClipRead>>().ok()?;
        s.clip = *held;
        s.change += 1;
        Some(s.change)
    }
}

struct FakeControls(Arc<Mutex<State>>);

impl ControlOps for FakeControls {
    fn focus_chain(
        &mut self,
        _query: &Query,
        _window: &RawWindow,
        _deadline: QueryDeadline,
        clock: &dyn Clock,
    ) -> Result<Vec<Rect>, PanelMiss> {
        let (chain, delay) = {
            let s = lock_state(&self.0);
            (s.focus_chain.clone(), s.focus_delay)
        };
        if let Some(d) = delay {
            clock.sleep(d);
        }
        chain.ok_or(PanelMiss::Blocked)
    }
    fn keyboard_changed(&mut self) -> bool {
        std::mem::take(&mut lock_state(&self.0).keyboard_moved)
    }
    fn secure_focus(&mut self) -> bool {
        lock_state(&self.0).secure
    }
    fn cover_at(&mut self, at: Point) -> Option<(i32, String, bool)> {
        let s = lock_state(&self.0);
        s.cover.filter(|(r, _)| r.contains_point(at)).map(|(_, regular)| (COVER_PID, COVER_APP.to_string(), regular))
    }
    fn close_cover(&mut self, pid: i32, _at: Point) -> bool {
        let mut s = lock_state(&self.0);
        s.log.push(format!("close_cover {pid}"));
        if pid == COVER_PID && s.cover.is_some_and(|(_, regular)| regular) {
            s.cover = None;
            FakePlatform::changed(&mut s);
            true
        } else {
            false
        }
    }
}

struct FakeText(Arc<Mutex<State>>);

impl TextReader for FakeText {
    fn lines(&mut self, _image: &RuleImage, _rect: RuleRect) -> Vec<String> {
        lock_state(&self.0).text_lines.clone()
    }
}

/// The lock screen: typed units are compared with the password here and never kept.
struct FakeLock(Arc<Mutex<State>>);

impl LockOps for FakeLock {
    fn locked(&mut self) -> bool {
        lock_state(&self.0).locked
    }
    fn lock(&mut self) -> Option<String> {
        let mut s = lock_state(&self.0);
        s.log.push("lock".to_string());
        if let Some(reason) = s.lock_error.clone() {
            return Some(reason);
        }
        s.locked = true;
        s.typed = 0;
        s.typed_ok = true;
        None
    }
    fn can_unlock(&self) -> bool {
        lock_state(&self.0).can_unlock
    }
    fn wake(&mut self) {
        note(&self.0, "wake".to_string());
    }
    fn type_units(&mut self, units: &[u16]) {
        let mut s = lock_state(&self.0);
        s.log.push(format!("type_units {}", units.len()));
        if !s.locked {
            return;
        }
        for u in units {
            let at = s.typed;
            let ok = s.password.get(at) == Some(u);
            s.typed_ok &= ok;
            s.typed += 1;
        }
    }
    fn press_return(&mut self) {
        let mut s = lock_state(&self.0);
        s.log.push("press_return".to_string());
        if s.locked && s.typed_ok && s.typed == s.password.len() && !s.password.is_empty() {
            s.locked = false;
            FakePlatform::changed(&mut s);
        }
        s.typed = 0;
        s.typed_ok = true;
    }
    fn stay_awake(&mut self, on: bool) {
        let mut s = lock_state(&self.0);
        s.log.push(format!("stay_awake {}", if on { "on" } else { "off" }));
        s.awake = on;
    }
}
