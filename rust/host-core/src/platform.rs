//! The platform interface (spec §6.1, §6.2). Task 9 created this file
//! with the two answer types; Task 13 added the traits below them.

/// Why a session cannot show a screen, or the app it asked for is missing.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum OpenError {
    /// No display is attached.
    NoDisplay,
    /// The owner's desktop is not on this machine's screen (disconnected remote session, or switched away).
    SessionDisconnected,
    /// No signed-in desktop.
    NotInteractive,
    /// Someone other than the owner is signed in on this machine's screen.
    OtherUser,
    /// The app id given is not installed.
    NotFound(String),
    /// Any other failure, as text.
    Other(String),
}

impl OpenError {
    /// The fixed text the client and service match on (spec §6.1). `NotFound` is spec §6.4's
    /// `<id> not found`, not the Swift host's "no app with bundle id … is installed"
    /// (`Sources/rapp-host/WindowCapture.swift:55`), which plan B names; see the draft notes.
    pub fn reason(&self) -> String {
        match self {
            OpenError::NoDisplay => "no display".to_string(),
            OpenError::SessionDisconnected => "session disconnected".to_string(),
            OpenError::NotInteractive => "not interactive".to_string(),
            OpenError::OtherUser => "other user".to_string(),
            OpenError::NotFound(app) => format!("{app} not found"),
            OpenError::Other(text) => text.clone(),
        }
    }
}

impl std::fmt::Display for OpenError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.reason())
    }
}

impl std::error::Error for OpenError {}

/// What `check` and `list-apps` report (spec §6.1): `screen_recording` is whether a picture can
/// be shown, `accessibility` is always true on Windows, `applications` is whether single-app
/// sessions can be opened (false for the pre-login instance), `error` the reason no picture can be shown.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Permissions {
    pub screen_recording: bool,
    pub accessibility: bool,
    pub platform: String,
    pub applications: bool,
    pub error: Option<OpenError>,
}

// MARK: The platform interface (spec §6.2, plan B Task 13)
//
// host-core calls down; the platform never calls back. Everything is polled. Each group is
// one trait object; `Parts` is what one session gets from `Platform::open`.

use std::path::PathBuf;
use std::time::Duration;

use crate::cli::SharedApp;
use crate::clipboard::ClipSource;
use crate::clock::Clock;
use crate::desktop::DesktopDisplay;
use crate::focus::{PanelMiss, Query};
use crate::geometry::{Point, Rect, Size};
use crate::hit_test::ScreenWindow;
use crate::protocol::{CanvasRect, MouseButton, MouseKind, WindowKind};
use crate::query::QueryDeadline;
use crate::state::detectors::TextReader;
use crate::transfers::{FileRef, ReceivedItem};

/// What a session shows: a whole display (`None` = the main one) or one app by its id.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Target {
    Desktop(Option<u32>),
    App(String),
}

pub trait Platform: Send + Sync {
    /// `"windows"`; the fake says `"fake"`.
    fn name(&self) -> &'static str;
    fn computer_name(&self) -> String;
    fn data_root(&self) -> PathBuf;
    fn permissions(&self) -> Permissions;
    fn displays(&self) -> Vec<DesktopDisplay>;
    fn applications(&self) -> Result<Vec<SharedApp>, String>;
    /// Usable without a target: the `lock` command.
    fn lock(&self) -> Box<dyn LockOps>;
    /// While A is locked: the frames (global points) of app `app`'s ordinary on-screen windows
    /// (Swift `lockedAppDisplay`, `WindowCapture.swift:273-287`: the window server's layer-0
    /// windows of the app's process). host-core picks the display with `lock::locked_start_display`.
    /// `None` when the app is not running or the platform cannot list windows while A is
    /// locked: the session then announces the main display.
    fn locked_app_windows(&self, app: &str) -> Option<Vec<Rect>>;
    fn open(&self, target: &Target) -> Result<Parts, OpenError>;
}

/// One session's handles on the platform.
pub struct Parts {
    pub target: Box<dyn TargetOps>,
    pub windows: Box<dyn WindowOps>,
    pub capture: Box<dyn Capture>,
    pub input: Box<dyn InputOps>,
    pub input_source: Box<dyn InputSourceOps>,
    pub clipboard: Box<dyn ClipboardOps>,
    pub controls: Box<dyn ControlOps>,
    pub text: Option<Box<dyn TextReader>>,
    pub lock: Box<dyn LockOps>,
}

/// The display a target is on: its frame in global points and its pixels per point.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct DisplayInfo {
    pub frame: Rect,
    pub scale: f32,
}

/// One window as the platform lists it, front to back. `kind` is the platform's first-step
/// class (Swift `classifyWindow`); host-core applies the rest of the window-table rules.
#[derive(Debug, Clone, PartialEq)]
pub struct RawWindow {
    pub id: u32,
    /// Global points.
    pub rect: Rect,
    pub title: String,
    pub kind: WindowKind,
    pub resizable: bool,
    pub close_button: bool,
    pub title_bar: f32,
    pub owner: i32,
    pub minimized: bool,
    pub foreground: bool,
    /// When the window was first seen, on the session clock.
    pub appeared: f64,
}

/// One captured picture: BGRA rows of `bytes_per_row` (at least `width * 4`), showing `region`.
#[derive(Debug, Clone)]
pub struct Frame {
    pub bgra: Vec<u8>,
    pub width: usize,
    pub height: usize,
    pub bytes_per_row: usize,
    pub region: CanvasRect,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct InputSource {
    pub id: String,
    pub name: String,
    /// A plain English keyboard layout (the protocol's `ascii`).
    pub english: bool,
}

/// What the clipboard holds now. `concealed`: marked as a password manager's (never announced).
#[derive(Debug, Clone)]
pub struct ClipRead {
    pub source: ClipSource,
    pub text: Option<String>,
    pub image_png: Option<Vec<u8>>,
    pub files: Vec<FileRef>,
    pub data: Option<Vec<u8>>,
    pub concealed: bool,
}

/// The platform's own copy of the clipboard, put back by `ClipboardOps::restore`.
pub struct ClipSnapshot(pub Box<dyn std::any::Any + Send>);

/// The app that came to the front.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OpenedApp {
    pub id: String,
    pub name: String,
    pub pid: i32,
    pub regular: bool,
}

pub trait TargetOps: Send {
    fn alive(&mut self) -> bool;
    fn name(&self) -> String;
    fn version(&self) -> Option<String>;
    fn pid(&self) -> i32;
    fn display(&mut self) -> DisplayInfo;
    fn activate(&mut self) -> bool;
    fn frontmost(&mut self) -> bool;
}

pub trait WindowOps: Send {
    fn list(&mut self) -> Vec<RawWindow>;
    fn screen(&mut self) -> Vec<ScreenWindow>;
    fn raise(&mut self, id: u32);
    fn close(&mut self, id: u32);
    /// Global points.
    fn move_to(&mut self, id: u32, origin: Point);
    fn resize(&mut self, id: u32, size: Size);
    /// The app that came to the front since the last call, if any.
    fn opened_app(&mut self) -> Option<OpenedApp>;
}

/// Moves to the capture thread. `frame` blocks at most `wait`; `Ok(None)`: nothing new.
/// `Err(reason)`: the platform could not recover; the session ends with `capture stopped: <reason>`.
pub trait Capture: Send {
    fn frame(&mut self, region: CanvasRect, density: f32, wait: Duration) -> Result<Option<Frame>, String>;
}

/// Points are global. Key codes and modifier flags are the protocol's, passed untouched.
pub trait InputOps: Send {
    fn mouse(&mut self, kind: MouseKind, button: MouseButton, at: Point, click_count: u8);
    fn scroll(&mut self, at: Point, dx: f32, dy: f32);
    fn key(&mut self, key_code: u16, modifiers: u64, down: bool);
    fn text(&mut self, units: &[u16]);
    fn paste_key(&mut self);
    fn release(&mut self, keys: &[u16], buttons: &[MouseButton]);
    /// `Some("elevated")` on Windows when the window under `at` belongs to a higher-privilege process.
    fn blocked_by(&mut self, at: Point) -> Option<String>;
}

pub trait InputSourceOps: Send {
    fn current(&mut self) -> Option<InputSource>;
    fn list(&mut self) -> Vec<InputSource>;
    fn select(&mut self, id: &str) -> bool;
    fn select_english(&mut self) -> bool;
}

pub trait ClipboardOps: Send {
    fn change_count(&mut self) -> i64;
    fn read(&mut self) -> Option<ClipRead>;
    /// The change count after the write.
    fn write(&mut self, item: &ReceivedItem) -> Result<i64, String>;
    fn snapshot(&mut self) -> Option<ClipSnapshot>;
    /// The change count after the restore.
    fn restore(&mut self, s: ClipSnapshot) -> Option<i64>;
}

pub trait ControlOps: Send {
    /// The focused control's rect and its parents', in global points, start control first.
    fn focus_chain(&mut self, query: &Query, window: &RawWindow, deadline: QueryDeadline, clock: &dyn Clock)
        -> Result<Vec<Rect>, PanelMiss>;
    fn keyboard_changed(&mut self) -> bool;
    fn secure_focus(&mut self) -> bool;
    /// The other app's window covering `at`: its pid, app id and whether it is a regular app.
    fn cover_at(&mut self, at: Point) -> Option<(i32, String, bool)>;
    fn close_cover(&mut self, pid: i32, at: Point) -> bool;
}

pub trait LockOps: Send {
    fn locked(&mut self) -> bool;
    /// `None` when the lock call was made; otherwise why it could not be.
    fn lock(&mut self) -> Option<String>;
    fn can_unlock(&self) -> bool;
    fn wake(&mut self);
    fn type_units(&mut self, units: &[u16]);
    fn press_return(&mut self);
    fn stay_awake(&mut self, on: bool);
}
