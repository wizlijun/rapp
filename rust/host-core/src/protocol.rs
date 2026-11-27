//! The picture protocol, ported from `Sources/RappCore/Protocol.swift` (v16).
//!
//! On the wire each message is a 1-byte type, a 4-byte little-endian payload
//! length, then the payload. Strings are a u16 length followed by UTF-8, except
//! `text`, `stateRules` and `appState`, whose payload is the UTF-8 text itself.
//! Every type that appears inside a `Message` lives here, also those Swift keeps
//! in `Quantize.swift`, `TileCodec.swift` and `Clipboard.swift`.
//!
//! Error texts are Swift's, byte for byte (`tests/protocol.rs` checks them
//! against `protocol-rejects.json`).

use std::collections::HashSet;
use std::fmt;

use serde::{Deserialize, Serialize};
use unicode_segmentation::UnicodeSegmentation;
use zeroize::Zeroizing;

// MARK: - Limits (Protocol.swift, Clipboard.swift)

/// The host and client must both speak exactly this version (Protocol.swift:14).
/// An alias of the controller's constant: host-core defines no version of its own.
pub const PROTOCOL_VERSION: u8 = rapp_client_core::protocol::VERSION;
/// The longest rules pack `stateRules` carries, in UTF-8 bytes.
pub const STATE_RULES_LIMIT: usize = 65536;
/// The longest report `appState` carries, in UTF-8 bytes.
pub const APP_STATE_LIMIT: usize = 4096;
/// The longest system password `unlock` carries, in UTF-8 bytes.
pub const UNLOCK_PASSWORD_LIMIT: usize = 1024;
/// The most rects one `focusRegion` carries.
pub const MAX_FOCUS_RECTS: usize = 3;
pub const DEFAULT_PORT: u16 = 47800;
/// Upper bound for one message's payload; anything larger is treated as garbage.
pub const MAX_MESSAGE_LENGTH: usize = 64 * 1024 * 1024;
/// Frame rates a client may ask for at hello.
pub const ALLOWED_FPS: [u8; 4] = [30, 15, 5, 1];
/// Frame rates `setStream` may carry: 0 pauses the pictures (v15).
pub const ALLOWED_STREAM_FPS: [u8; 5] = [30, 15, 5, 1, 0];
pub const MAX_WINDOWS: usize = 256;
pub const MAX_MENU_DEPTH: usize = 6;
pub const MAX_MENU_ITEMS: usize = 5000;
pub const MAX_MENU_PICK_DEPTH: usize = 8;
/// In extended grapheme clusters, as Swift's `String.count`.
pub const MAX_TITLE_CHARACTERS: usize = 200;
/// Clipboard.swift:24-29.
pub const MAX_CLIP_TEXT: usize = 1 << 20;
pub const MAX_CLIP_FILES: usize = 100;
/// A `paste` carries text inline only below this many UTF-8 bytes.
pub const INLINE_PASTE_LIMIT: usize = 60_000;
pub const CHUNK_SIZE: usize = 256 * 1024;
pub const MAX_SIDE_CONNECTIONS: usize = 4;

/// A capture density (pixels per A point) is finite and in (0, 8].
pub fn is_valid_density(d: f32) -> bool {
    d.is_finite() && d > 0.0 && d <= 8.0
}

/// Compares two secrets without stopping at the first difference (Protocol.swift `constantTimeEquals`).
pub fn constant_time_equals(a: &str, b: &str) -> bool {
    let (x, y) = (a.as_bytes(), b.as_bytes());
    let mut diff: u8 = if x.len() == y.len() { 0 } else { 1 };
    for i in 0..x.len().max(y.len()) {
        diff |= x.get(i).copied().unwrap_or(0) ^ y.get(i).copied().unwrap_or(0);
    }
    diff == 0
}

// MARK: - Errors

/// Thrown when encoded data cannot be decoded (Deflate.swift:4). A protocol
/// version mismatch (Swift's separate `ProtocolVersionMismatch`) is carried as its text.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CodecError(pub String);

impl CodecError {
    pub fn new(text: impl Into<String>) -> Self {
        CodecError(text.into())
    }
    /// Swift's `ProtocolVersionMismatch(client:)` description.
    pub fn version_mismatch(client: u8) -> Self {
        CodecError(format!(
            "protocol version mismatch: host {PROTOCOL_VERSION}, client {client} (update both sides)"
        ))
    }
}

impl fmt::Display for CodecError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for CodecError {}

fn err<T>(text: impl Into<String>) -> Result<T, CodecError> {
    Err(CodecError(text.into()))
}

// MARK: - Value types

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum MouseKind {
    Down = 0,
    Up = 1,
    Drag = 2,
    Move = 3,
}

impl MouseKind {
    pub fn from_byte(b: u8) -> Option<Self> {
        Some(match b {
            0 => MouseKind::Down,
            1 => MouseKind::Up,
            2 => MouseKind::Drag,
            3 => MouseKind::Move,
            _ => return None,
        })
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum MouseButton {
    Left = 0,
    Right = 1,
}

impl MouseButton {
    pub fn from_byte(b: u8) -> Option<Self> {
        match b {
            0 => Some(MouseButton::Left),
            1 => Some(MouseButton::Right),
            _ => None,
        }
    }
}

/// A rectangle on the canvas: points, origin at the top-left of A's display, y down.
#[derive(Debug, Clone, Copy, PartialEq, Default, Serialize, Deserialize)]
pub struct CanvasRect {
    pub x: f32,
    pub y: f32,
    pub w: f32,
    pub h: f32,
}

impl CanvasRect {
    pub const fn new(x: f32, y: f32, w: f32, h: f32) -> Self {
        CanvasRect { x, y, w, h }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum WindowKind {
    Normal = 0,
    Dialog = 1,
    Floating = 2,
    Sheet = 3,
    Popover = 4,
    Menu = 5,
    Tooltip = 6,
}

impl WindowKind {
    pub const ALL: [WindowKind; 7] = [
        WindowKind::Normal,
        WindowKind::Dialog,
        WindowKind::Floating,
        WindowKind::Sheet,
        WindowKind::Popover,
        WindowKind::Menu,
        WindowKind::Tooltip,
    ];

    pub fn from_byte(b: u8) -> Option<Self> {
        WindowKind::ALL.get(b as usize).copied()
    }

    /// Normal, dialog and floating windows get a B window with a title bar;
    /// the rest are borderless popups attached to a parent.
    pub fn is_decorated(self) -> bool {
        matches!(self, WindowKind::Normal | WindowKind::Dialog | WindowKind::Floating)
    }
}

/// One item of the window table (spec §2.2).
#[derive(Debug, Clone, PartialEq)]
pub struct WindowInfo {
    pub id: u32,
    pub parent: u32,
    pub kind: WindowKind,
    pub resizable: bool,
    pub focused: bool,
    pub rect: CanvasRect,
    pub title_bar: f32,
    pub title: String,
}

/// One item of the mirrored menu bar. `modifiers`: bit0 shift, bit1 control,
/// bit2 option, bit3 command. host-core never sends one (see `DISPOSITION`).
#[derive(Debug, Clone, PartialEq)]
pub struct MenuItem {
    pub title: String,
    pub enabled: bool,
    pub checked: bool,
    pub separator: bool,
    pub key: String,
    pub modifiers: u8,
    pub children: Vec<MenuItem>,
}

impl MenuItem {
    /// Swift's defaults: enabled, nothing else.
    pub fn new(title: impl Into<String>) -> Self {
        MenuItem {
            title: title.into(),
            enabled: true,
            checked: false,
            separator: false,
            key: String::new(),
            modifiers: 0,
            children: Vec::new(),
        }
    }
}

/// A colour depth (Quantize.swift:2). Every pixel is reduced to one "sample" of this mode.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Mode {
    /// 16 grey levels, one byte per sample holding 0...15.
    Gray4 = 0,
    /// Fixed 256-colour palette (6x6x6 colour cube + 40 greys), one byte per sample.
    Color8 = 1,
    /// RGB565, two bytes per sample, little-endian.
    Color16 = 2,
    /// Two tones per 16x16 block, as 16 grey levels (samples like gray4).
    Duogray = 3,
    /// Two tones per 16x16 block, as RGB565 (samples like color16).
    Duocolor = 4,
}

impl Mode {
    pub const ALL: [Mode; 5] = [Mode::Gray4, Mode::Color8, Mode::Color16, Mode::Duogray, Mode::Duocolor];

    pub fn from_byte(b: u8) -> Option<Self> {
        Mode::ALL.get(b as usize).copied()
    }

    pub fn bytes_per_sample(self) -> usize {
        if matches!(self, Mode::Color16 | Mode::Duocolor) {
            2
        } else {
            1
        }
    }

    pub fn name(self) -> &'static str {
        match self {
            Mode::Gray4 => "gray4",
            Mode::Color8 => "color8",
            Mode::Color16 => "color16",
            Mode::Duogray => "duogray",
            Mode::Duocolor => "duocolor",
        }
    }

    pub fn from_name(name: &str) -> Option<Self> {
        Mode::ALL.into_iter().find(|m| m.name() == name)
    }

    /// The two-tone modes (duogray, duocolor).
    pub fn is_duo(self) -> bool {
        matches!(self, Mode::Duogray | Mode::Duocolor)
    }
}

/// Frame flags (TileCodec.swift:23).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub struct FrameFlags(pub u8);

impl FrameFlags {
    pub const FULL: FrameFlags = FrameFlags(1);
    pub const START: FrameFlags = FrameFlags(2);
    pub const END: FrameFlags = FrameFlags(4);
    pub const COPIES: FrameFlags = FrameFlags(8);

    pub fn contains(self, other: FrameFlags) -> bool {
        self.0 & other.0 == other.0
    }
    pub fn insert(&mut self, other: FrameFlags) {
        self.0 |= other.0;
    }
}

impl std::ops::BitOr for FrameFlags {
    type Output = FrameFlags;
    fn bitor(self, rhs: FrameFlags) -> FrameFlags {
        FrameFlags(self.0 | rhs.0)
    }
}

/// One encoded frame slice: the sample mode, the canvas size, the frame flags
/// (and for a non-full `start` slice the canvas move) and the deflate-compressed tile data.
#[derive(Debug, Clone, PartialEq)]
pub struct FramePayload {
    pub mode: Mode,
    pub width: u16,
    pub height: u16,
    pub flags: FrameFlags,
    pub dx: i32,
    pub dy: i32,
    pub data: Vec<u8>,
}

impl FramePayload {
    pub fn is_full(&self) -> bool {
        self.flags.contains(FrameFlags::FULL)
    }
}

/// What a clipboard entry holds (Clipboard.swift:4). `put` only accepts 0...3.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ClipKind {
    Text = 0,
    Image = 1,
    Files = 2,
    Data = 3,
    Unsupported = 4,
}

impl ClipKind {
    pub fn from_byte(b: u8) -> Option<Self> {
        Some(match b {
            0 => ClipKind::Text,
            1 => ClipKind::Image,
            2 => ClipKind::Files,
            3 => ClipKind::Data,
            4 => ClipKind::Unsupported,
            _ => return None,
        })
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ClipFile {
    pub name: String,
    pub bytes: u64,
}

/// One clipboard entry as announced by A.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ClipInfo {
    Text { text: String, truncated: bool },
    Image { width: u16, height: u16, bytes: u64 },
    Files(Vec<ClipFile>),
    Data { uti: String, bytes: u64 },
    Unsupported(String),
}

/// Where a `paste` takes its content from: text carried in the message, or an uploaded item.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PasteSource {
    Text(String),
    Item(u32),
}

/// The system password `unlock` carries, as UTF-8 bytes wiped on drop. Its
/// `Debug` never prints it. (Swift keeps it in a plain `String`, Protocol.swift:148.)
#[derive(Clone, PartialEq, Eq)]
pub struct Password(Zeroizing<Vec<u8>>);

impl Password {
    pub fn new(password: &str) -> Self {
        Password(Zeroizing::new(password.as_bytes().to_vec()))
    }
    /// Takes the bytes of a decoded string without copying them.
    fn from_string(s: String) -> Self {
        Password(Zeroizing::new(s.into_bytes()))
    }
    pub fn as_str(&self) -> &str {
        // Always valid UTF-8: built from a `&str` or a decoded `String`.
        std::str::from_utf8(&self.0).unwrap_or("")
    }
    pub fn as_bytes(&self) -> &[u8] {
        &self.0
    }
    pub fn len(&self) -> usize {
        self.0.len()
    }
    pub fn is_empty(&self) -> bool {
        self.0.is_empty()
    }
    /// The wiping buffer itself (the shape plan B names for this field).
    pub fn into_inner(self) -> Zeroizing<Vec<u8>> {
        self.0
    }
}

impl std::ops::Deref for Password {
    type Target = [u8];
    fn deref(&self) -> &[u8] {
        &self.0
    }
}

impl From<Zeroizing<Vec<u8>>> for Password {
    /// The bytes must be UTF-8; `as_str` answers "" otherwise.
    fn from(bytes: Zeroizing<Vec<u8>>) -> Self {
        Password(bytes)
    }
}

impl From<&str> for Password {
    fn from(s: &str) -> Self {
        Password::new(s)
    }
}

impl fmt::Debug for Password {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("<redacted>")
    }
}

// MARK: - Messages

/// Everything that travels over the connection (Protocol.swift:109-167). Field
/// names are Swift's labels in snake_case. Coordinates are points: mouse and
/// scroll are relative to the top-left of the given A window, everything else is
/// on the canvas (A's display). Types 10 and 12 are gone.
#[derive(Debug, Clone, PartialEq)]
pub enum Message {
    /// 1, client -> host. `version` is `PROTOCOL_VERSION` for every decoded hello.
    Hello { token: String, bundle_id: String, mode: Mode, fps: u8, density: f32, version: u8 },
    /// 2, host -> client (canvas points).
    Ready { app_name: String, width: u16, height: u16 },
    /// 3, host -> client.
    Error(String),
    /// 4, host -> client.
    Frame { region: CanvasRect, payload: FramePayload },
    /// 5, client -> host.
    Text(String),
    /// 6, macOS virtual key code + CGEventFlags.
    Key { key_code: u16, modifiers: u64, down: bool },
    /// 7.
    Mouse { kind: MouseKind, button: MouseButton, window: u32, x: f32, y: f32, click_count: u8 },
    /// 8.
    Scroll { window: u32, x: f32, y: f32, dx: f32, dy: f32 },
    /// 9, client -> host (content points).
    Resize { window: u32, width: u16, height: u16 },
    /// 11, client -> host; ends with a flag byte: bit0 pinned, bit1 focus.
    SetStream { mode: Mode, fps: u8, density: f32, pinned: bool, focus: bool },
    /// 13, host -> client, front to back.
    Windows(Vec<WindowInfo>),
    /// 14, client -> host.
    Focus(u32),
    /// 15, client -> host.
    Close(u32),
    /// 16, client -> host (canvas).
    Move { window: u32, x: f32, y: f32 },
    /// 17, host -> client. Not handled by host-core.
    MenuBar(Vec<MenuItem>),
    /// 18, client -> host. Not handled by host-core.
    MenuPick(Vec<u16>),
    /// 19, host -> client.
    Clip { id: u32, info: ClipInfo },
    /// 20, client -> host.
    Paste { seq: u32, source: PasteSource },
    /// 21, host -> client.
    Pasted { seq: u32, error: String },
    /// 22, side connection, carries the version.
    Fetch { token: String, clip: u32, file: u16, offset: u64 },
    /// 23, side connection, carries the version.
    Put { token: String, item: u32, kind: ClipKind, uti: String, name: String, total: u64 },
    /// 24, side connection.
    TransferStart(u64),
    /// 25, side connection, payload is the data.
    Chunk(Vec<u8>),
    /// 26, host -> client.
    InputBlocked { by: String },
    /// 27, client -> host.
    FrameAck { processing_ms: u16 },
    /// 28, host -> client. Not sent by host-core.
    Weak(bool),
    /// 29, host -> client. `ascii`: a plain keyboard layout, not an input method.
    InputSource { id: String, name: String, ascii: bool },
    /// 30, client -> host; "" selects the current ASCII-capable layout.
    SelectInput { id: String },
    /// 31, client -> host.
    Ping(u32),
    /// 32, host -> client.
    Pong(u32),
    /// 33, host -> client: 0 = B's ceiling, 1 = at most 5 fps, 2 = the weak floor.
    Saving(u8),
    /// 34, host -> client.
    ScreenLocked(bool),
    /// 35, client -> host.
    Unlock { password: Password },
    /// 36, host -> client; no rects = the whole window.
    FocusRegion { window: u32, rects: Vec<CanvasRect> },
    /// 37, host -> client.
    Covered { id: u32, name: String, bundle_id: String, dismissable: bool },
    /// 41, client -> host.
    SetView { window: u32, rect: CanvasRect },
    /// 38, client -> host.
    DismissCover(u32),
    /// 39, host -> client.
    AppOpened { bundle_id: String, name: String },
    /// 40, host -> client.
    SecureFocus(bool),
    /// 42, host -> client.
    Changed,
    /// 43, client -> host: one rules pack (UTF-8 JSON); empty = no rules.
    StateRules(String),
    /// 44, host -> client: the app-state report (UTF-8 JSON).
    AppState(String),
}

/// What host-core does with each message type (spec §6.3, §14.1).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Disposition {
    /// The session reads it from the client.
    FromClient,
    /// The session sends it to the client.
    ToClient,
    /// Only on a side (transfer) connection.
    Side,
    /// Defined by the protocol, never sent or acted on by host-core.
    NotHandled,
}

/// Every message type: its byte, Swift's case name, and what host-core does with it.
pub const DISPOSITION: &[(u8, &str, Disposition)] = {
    use Disposition::*;
    &[
        (1, "hello", FromClient),
        (2, "ready", ToClient),
        (3, "error", ToClient),
        (4, "frame", ToClient),
        (5, "text", FromClient),
        (6, "key", FromClient),
        (7, "mouse", FromClient),
        (8, "scroll", FromClient),
        (9, "resize", FromClient),
        (11, "setStream", FromClient),
        (13, "windows", ToClient),
        (14, "focus", FromClient),
        (15, "close", FromClient),
        (16, "move", FromClient),
        (17, "menuBar", NotHandled),
        (18, "menuPick", NotHandled),
        (19, "clip", ToClient),
        (20, "paste", FromClient),
        (21, "pasted", ToClient),
        (22, "fetch", Side),
        (23, "put", Side),
        (24, "transferStart", Side),
        (25, "chunk", Side),
        (26, "inputBlocked", ToClient),
        (27, "frameAck", FromClient),
        (28, "weak", NotHandled),
        (29, "inputSource", ToClient),
        (30, "selectInput", FromClient),
        (31, "ping", FromClient),
        (32, "pong", ToClient),
        (33, "saving", ToClient),
        (34, "screenLocked", ToClient),
        (35, "unlock", FromClient),
        (36, "focusRegion", ToClient),
        (37, "covered", ToClient),
        (38, "dismissCover", FromClient),
        (39, "appOpened", ToClient),
        (40, "secureFocus", ToClient),
        (41, "setView", FromClient),
        (42, "changed", ToClient),
        (43, "stateRules", FromClient),
        (44, "appState", ToClient),
    ]
};

/// The disposition of one type byte; `None` for an unknown type.
pub fn disposition(type_byte: u8) -> Option<Disposition> {
    DISPOSITION.iter().find(|e| e.0 == type_byte).map(|e| e.2)
}

/// Protocol.swift `knownTypes`.
fn is_known_type(t: u8) -> bool {
    matches!(t, 1..=9 | 11 | 13..=44)
}

impl Message {
    pub fn type_byte(&self) -> u8 {
        match self {
            Message::Hello { .. } => 1,
            Message::Ready { .. } => 2,
            Message::Error(_) => 3,
            Message::Frame { .. } => 4,
            Message::Text(_) => 5,
            Message::Key { .. } => 6,
            Message::Mouse { .. } => 7,
            Message::Scroll { .. } => 8,
            Message::Resize { .. } => 9,
            Message::SetStream { .. } => 11,
            Message::Windows(_) => 13,
            Message::Focus(_) => 14,
            Message::Close(_) => 15,
            Message::Move { .. } => 16,
            Message::MenuBar(_) => 17,
            Message::MenuPick(_) => 18,
            Message::Clip { .. } => 19,
            Message::Paste { .. } => 20,
            Message::Pasted { .. } => 21,
            Message::Fetch { .. } => 22,
            Message::Put { .. } => 23,
            Message::TransferStart(_) => 24,
            Message::Chunk(_) => 25,
            Message::InputBlocked { .. } => 26,
            Message::FrameAck { .. } => 27,
            Message::Weak(_) => 28,
            Message::InputSource { .. } => 29,
            Message::SelectInput { .. } => 30,
            Message::Ping(_) => 31,
            Message::Pong(_) => 32,
            Message::Saving(_) => 33,
            Message::ScreenLocked(_) => 34,
            Message::Unlock { .. } => 35,
            Message::FocusRegion { .. } => 36,
            Message::Covered { .. } => 37,
            Message::DismissCover(_) => 38,
            Message::AppOpened { .. } => 39,
            Message::SecureFocus(_) => 40,
            Message::SetView { .. } => 41,
            Message::Changed => 42,
            Message::StateRules(_) => 43,
            Message::AppState(_) => 44,
        }
    }

    /// Swift's case name (the second column of `DISPOSITION`).
    pub fn case_name(&self) -> &'static str {
        let t = self.type_byte();
        DISPOSITION.iter().find(|e| e.0 == t).map(|e| e.1).unwrap_or("")
    }

    /// Input that counts as the user acting (SaveLadder.swift: text, key, mouse,
    /// scroll, paste and menuPick); the saving ladder steps back to the ceiling on it.
    pub fn is_user_input(&self) -> bool {
        matches!(
            self,
            Message::Text(_)
                | Message::Key { .. }
                | Message::Mouse { .. }
                | Message::Scroll { .. }
                | Message::Paste { .. }
                | Message::MenuPick(_)
        )
    }

    /// `u8 type, u32 LE length, payload`. Panics where Swift's `encoded()` has a
    /// precondition (a value the protocol cannot carry is a programming error).
    pub fn encoded(&self) -> Vec<u8> {
        let mut w = Writer::default();
        match self {
            Message::Hello { token, bundle_id, mode, fps, density, version } => {
                w.u8(*version);
                w.string(token);
                w.string(bundle_id);
                w.u8(*mode as u8);
                w.u8(*fps);
                w.f32(*density);
            }
            Message::Ready { app_name, width, height } => {
                w.string(app_name);
                w.u16(*width);
                w.u16(*height);
            }
            Message::Error(text) => w.string(text),
            Message::Frame { region, payload: f } => {
                w.u8(f.mode as u8);
                w.rect(region);
                w.u16(f.width);
                w.u16(f.height);
                w.u8(f.flags.0);
                if f.flags.contains(FrameFlags::START) && !f.flags.contains(FrameFlags::FULL) {
                    w.u32(f.dx as u32);
                    w.u32(f.dy as u32);
                }
                w.bytes.extend_from_slice(&f.data);
            }
            Message::Text(text) => w.bytes.extend_from_slice(text.as_bytes()),
            Message::Key { key_code, modifiers, down } => {
                w.u16(*key_code);
                w.u64(*modifiers);
                w.u8(*down as u8);
            }
            Message::Mouse { kind, button, window, x, y, click_count } => {
                w.u8(*kind as u8);
                w.u8(*button as u8);
                w.u32(*window);
                w.f32(*x);
                w.f32(*y);
                w.u8(*click_count);
            }
            Message::Scroll { window, x, y, dx, dy } => {
                w.u32(*window);
                w.f32(*x);
                w.f32(*y);
                w.f32(*dx);
                w.f32(*dy);
            }
            Message::Resize { window, width, height } => {
                w.u32(*window);
                w.u16(*width);
                w.u16(*height);
            }
            Message::SetStream { mode, fps, density, pinned, focus } => {
                w.u8(*mode as u8);
                w.u8(*fps);
                w.f32(*density);
                w.u8((*pinned as u8) | ((*focus as u8) << 1));
            }
            Message::FocusRegion { window, rects } => {
                assert!(rects.len() <= MAX_FOCUS_RECTS, "too many focus rects");
                w.u32(*window);
                w.u8(rects.len() as u8);
                for r in rects {
                    w.rect(r);
                }
            }
            Message::Windows(items) => {
                w.u16(items.len().min(0xFFFF) as u16);
                for i in items {
                    w.u32(i.id);
                    w.u32(i.parent);
                    w.u8(i.kind as u8);
                    w.u8((i.resizable as u8) | ((i.focused as u8) << 1));
                    w.rect(&i.rect);
                    w.f32(i.title_bar);
                    w.string(&i.title);
                }
            }
            Message::Focus(id) | Message::Close(id) => w.u32(*id),
            Message::Move { window, x, y } => {
                w.u32(*window);
                w.f32(*x);
                w.f32(*y);
            }
            Message::MenuBar(items) => w.menu_items(items),
            Message::MenuPick(path) => {
                w.u8(path.len().min(0xFF) as u8);
                for i in path {
                    w.u16(*i);
                }
            }
            Message::Clip { id, info } => {
                w.u32(*id);
                w.clip_info(info);
            }
            Message::Paste { seq, source } => {
                w.u32(*seq);
                match source {
                    PasteSource::Text(t) => {
                        assert!(t.len() < INLINE_PASTE_LIMIT, "paste text too long");
                        w.u8(0);
                        w.string(t);
                    }
                    PasteSource::Item(n) => {
                        w.u8(1);
                        w.u32(*n);
                    }
                }
            }
            Message::Pasted { seq, error } => {
                w.u32(*seq);
                w.string(error);
            }
            Message::Fetch { token, clip, file, offset } => {
                w.u8(PROTOCOL_VERSION);
                w.string(token);
                w.u32(*clip);
                w.u16(*file);
                w.u64(*offset);
            }
            Message::Put { token, item, kind, uti, name, total } => {
                assert!(*kind != ClipKind::Unsupported, "put cannot carry an unsupported clip");
                w.u8(PROTOCOL_VERSION);
                w.string(token);
                w.u32(*item);
                w.u8(*kind as u8);
                w.string(uti);
                w.string(name);
                w.u64(*total);
            }
            Message::TransferStart(n) => w.u64(*n),
            Message::Chunk(data) => {
                assert!(data.len() <= CHUNK_SIZE, "chunk too large");
                w.bytes.extend_from_slice(data);
            }
            Message::InputBlocked { by } => w.string(by),
            Message::FrameAck { processing_ms } => w.u16(*processing_ms),
            Message::Weak(on) | Message::ScreenLocked(on) | Message::SecureFocus(on) => w.u8(*on as u8),
            Message::InputSource { id, name, ascii } => {
                w.string(id);
                w.string(name);
                w.u8(*ascii as u8);
            }
            Message::SelectInput { id } => w.string(id),
            Message::Ping(seq) | Message::Pong(seq) => w.u32(*seq),
            Message::Saving(level) => w.u8(*level),
            Message::Unlock { password } => {
                assert!(password.len() <= UNLOCK_PASSWORD_LIMIT, "password too long");
                w.string(password.as_str());
            }
            Message::Covered { id, name, bundle_id, dismissable } => {
                w.u32(*id);
                w.string(name);
                w.string(bundle_id);
                w.u8(*dismissable as u8);
            }
            Message::SetView { window, rect } => {
                w.u32(*window);
                w.rect(rect);
            }
            Message::DismissCover(id) => w.u32(*id),
            Message::AppOpened { bundle_id, name } => {
                w.string(bundle_id);
                w.string(name);
            }
            Message::Changed => {}
            Message::StateRules(json) => {
                assert!(json.len() <= STATE_RULES_LIMIT, "rules too large");
                w.bytes.extend_from_slice(json.as_bytes());
            }
            Message::AppState(json) => {
                assert!(json.len() <= APP_STATE_LIMIT, "state too large");
                w.bytes.extend_from_slice(json.as_bytes());
            }
        }
        assert!(w.bytes.len() <= MAX_MESSAGE_LENGTH, "message too large");
        let n = w.bytes.len() as u32;
        let mut out = Vec::with_capacity(5 + w.bytes.len());
        out.push(self.type_byte());
        out.extend_from_slice(&n.to_le_bytes());
        out.extend_from_slice(&w.bytes);
        // The password's copy in the writer is wiped with it.
        if matches!(self, Message::Unlock { .. }) {
            zeroize::Zeroize::zeroize(&mut w.bytes);
        }
        out
    }

    /// Decodes one payload of a known type (Protocol.swift `decode(type:payload:)`).
    pub fn decode(type_byte: u8, payload: &[u8]) -> Result<Message, CodecError> {
        let mut r = Reader::new(payload);
        let message = match type_byte {
            1 => {
                let version = r.u8()?;
                if version != PROTOCOL_VERSION {
                    return Err(CodecError::version_mismatch(version));
                }
                let token = r.string()?;
                let bundle_id = r.string()?;
                let mode = r.mode()?;
                let (fps, density) = r.stream(false)?;
                Message::Hello { token, bundle_id, mode, fps, density, version }
            }
            2 => Message::Ready { app_name: r.string()?, width: r.u16()?, height: r.u16()? },
            3 => Message::Error(r.string()?),
            4 => {
                let mode = r.mode()?;
                let region = r.rect()?;
                let width = r.u16()?;
                let height = r.u16()?;
                let flags = FrameFlags(r.u8()?);
                let (mut dx, mut dy) = (0, 0);
                if flags.contains(FrameFlags::START) && !flags.contains(FrameFlags::FULL) {
                    dx = r.u32()? as i32;
                    dy = r.u32()? as i32;
                }
                let data = r.rest().to_vec();
                Message::Frame { region, payload: FramePayload { mode, width, height, flags, dx, dy, data } }
            }
            5 => Message::Text(utf8(r.rest())?),
            6 => {
                let key_code = r.u16()?;
                let modifiers = r.u64()?;
                let down = r.u8()?;
                if down > 1 {
                    return err("bad key state");
                }
                Message::Key { key_code, modifiers, down: down == 1 }
            }
            7 => {
                let Some(kind) = MouseKind::from_byte(r.u8()?) else { return err("unknown mouse event") };
                let Some(button) = MouseButton::from_byte(r.u8()?) else { return err("unknown mouse button") };
                Message::Mouse { kind, button, window: r.u32()?, x: r.f32()?, y: r.f32()?, click_count: r.u8()? }
            }
            8 => Message::Scroll { window: r.u32()?, x: r.f32()?, y: r.f32()?, dx: r.f32()?, dy: r.f32()? },
            9 => Message::Resize { window: r.u32()?, width: r.u16()?, height: r.u16()? },
            11 => {
                let mode = r.mode()?;
                let (fps, density) = r.stream(true)?;
                let flag = r.u8()?;
                if flag & !3 != 0 {
                    return err("bad stream flags");
                }
                Message::SetStream { mode, fps, density, pinned: flag & 1 != 0, focus: flag & 2 != 0 }
            }
            13 => Message::Windows(r.windows()?),
            14 => Message::Focus(r.u32()?),
            15 => Message::Close(r.u32()?),
            16 => Message::Move { window: r.u32()?, x: r.f32()?, y: r.f32()? },
            17 => {
                let mut budget = MAX_MENU_ITEMS as i64;
                Message::MenuBar(r.menu_items(1, &mut budget)?)
            }
            18 => {
                let n = r.u8()? as usize;
                if !(1..=MAX_MENU_PICK_DEPTH).contains(&n) {
                    return err("menu path must have 1 to 8 levels");
                }
                let mut path = Vec::with_capacity(n);
                for _ in 0..n {
                    path.push(r.u16()?);
                }
                Message::MenuPick(path)
            }
            19 => {
                let id = r.u32()?;
                Message::Clip { id, info: r.clip_info()? }
            }
            20 => {
                let seq = r.u32()?;
                match r.u8()? {
                    0 => {
                        let t = r.string()?;
                        if t.len() >= INLINE_PASTE_LIMIT {
                            return err(format!("paste text must be under {INLINE_PASTE_LIMIT} bytes"));
                        }
                        Message::Paste { seq, source: PasteSource::Text(t) }
                    }
                    1 => Message::Paste { seq, source: PasteSource::Item(r.u32()?) },
                    _ => return err("unknown paste source"),
                }
            }
            21 => Message::Pasted { seq: r.u32()?, error: r.string()? },
            22 => {
                r.version()?;
                Message::Fetch { token: r.string()?, clip: r.u32()?, file: r.u16()?, offset: r.u64()? }
            }
            23 => {
                r.version()?;
                let token = r.string()?;
                let item = r.u32()?;
                let kind = match ClipKind::from_byte(r.u8()?) {
                    Some(k) if k != ClipKind::Unsupported => k,
                    _ => return err("unknown put kind"),
                };
                Message::Put { token, item, kind, uti: r.string()?, name: r.string()?, total: r.u64()? }
            }
            24 => Message::TransferStart(r.u64()?),
            25 => {
                let data = r.rest();
                if data.len() > CHUNK_SIZE {
                    return err(format!("chunk larger than {CHUNK_SIZE} bytes"));
                }
                Message::Chunk(data.to_vec())
            }
            26 => Message::InputBlocked { by: r.string()? },
            27 => Message::FrameAck { processing_ms: r.u16()? },
            28 => Message::Weak(r.flag("bad weak flag")?),
            29 => {
                let id = r.string()?;
                let name = r.string()?;
                let ascii = r.flag("bad ascii flag")?;
                Message::InputSource { id, name, ascii }
            }
            30 => Message::SelectInput { id: r.string()? },
            31 => Message::Ping(r.u32()?),
            32 => Message::Pong(r.u32()?),
            33 => {
                let level = r.u8()?;
                if level > 2 {
                    return err("bad saving level");
                }
                Message::Saving(level)
            }
            34 => Message::ScreenLocked(r.flag("bad locked flag")?),
            35 => {
                let password = Password::from_string(r.string()?);
                if password.len() > UNLOCK_PASSWORD_LIMIT {
                    return err(format!("password longer than {UNLOCK_PASSWORD_LIMIT} bytes"));
                }
                Message::Unlock { password }
            }
            36 => {
                let window = r.u32()?;
                let count = r.u8()? as usize;
                if count > MAX_FOCUS_RECTS {
                    return err("too many focus rects");
                }
                let mut rects = Vec::with_capacity(count);
                for _ in 0..count {
                    rects.push(r.rect()?);
                }
                Message::FocusRegion { window, rects }
            }
            37 => {
                let id = r.u32()?;
                let name = r.string()?;
                let bundle_id = r.string()?;
                let dismissable = r.flag("bad dismissable flag")?;
                Message::Covered { id, name, bundle_id, dismissable }
            }
            41 => Message::SetView { window: r.u32()?, rect: r.rect()? },
            38 => Message::DismissCover(r.u32()?),
            39 => Message::AppOpened { bundle_id: r.string()?, name: r.string()? },
            40 => Message::SecureFocus(r.flag("bad secure flag")?),
            42 => Message::Changed,
            43 => {
                let bytes = r.rest();
                if bytes.len() > STATE_RULES_LIMIT {
                    return err("rules too large");
                }
                let Some(s) = foundation_utf8(bytes) else { return err("rules not UTF-8") };
                Message::StateRules(s)
            }
            44 => {
                let bytes = r.rest();
                if bytes.len() > APP_STATE_LIMIT {
                    return err("state too large");
                }
                let Some(s) = foundation_utf8(bytes) else { return err("state not UTF-8") };
                Message::AppState(s)
            }
            t => return err(format!("unknown message type {t}")),
        };
        if !r.is_at_end() {
            return err(format!("unexpected bytes after message {type_byte}"));
        }
        Ok(message)
    }
}

// MARK: - Parser

/// Turns a byte stream into messages. Feed it whatever the socket delivers
/// with `append`, then call `next()` until it returns `Ok(None)`. An error means
/// the connection should be dropped.
#[derive(Debug, Default)]
pub struct MessageParser {
    buffer: Vec<u8>,
}

impl MessageParser {
    pub fn new() -> Self {
        MessageParser::default()
    }

    pub fn append(&mut self, bytes: &[u8]) {
        self.buffer.extend_from_slice(bytes);
    }

    /// Bytes buffered and not yet returned as a message.
    pub fn buffered(&self) -> usize {
        self.buffer.len()
    }

    /// The next complete message, or `None` when more bytes are needed. An
    /// unknown type is rejected at the header, before the length (Protocol.swift:505-516),
    /// and an oversized length before anything is allocated for it.
    #[allow(clippy::should_implement_trait)]
    pub fn next(&mut self) -> Result<Option<Message>, CodecError> {
        if self.buffer.len() < 5 {
            return Ok(None);
        }
        let t = self.buffer[0];
        if !is_known_type(t) {
            return err(format!("unknown message type {t}"));
        }
        let length = u32::from_le_bytes([self.buffer[1], self.buffer[2], self.buffer[3], self.buffer[4]]) as usize;
        if length > MAX_MESSAGE_LENGTH {
            return err(format!("message too large ({length} bytes)"));
        }
        if self.buffer.len() < 5 + length {
            return Ok(None);
        }
        let message = Message::decode(t, &self.buffer[5..5 + length]);
        if t == 35 {
            // The password bytes do not outlive the message.
            zeroize::Zeroize::zeroize(&mut self.buffer[5..5 + length]);
        }
        let message = message?;
        self.buffer.drain(..5 + length);
        Ok(Some(message))
    }
}

// MARK: - Writer and reader

#[derive(Default)]
struct Writer {
    bytes: Vec<u8>,
}

impl Writer {
    fn u8(&mut self, v: u8) {
        self.bytes.push(v);
    }
    fn u16(&mut self, v: u16) {
        self.bytes.extend_from_slice(&v.to_le_bytes());
    }
    fn u32(&mut self, v: u32) {
        self.bytes.extend_from_slice(&v.to_le_bytes());
    }
    fn u64(&mut self, v: u64) {
        self.bytes.extend_from_slice(&v.to_le_bytes());
    }
    fn f32(&mut self, v: f32) {
        self.u32(v.to_bits());
    }
    fn rect(&mut self, r: &CanvasRect) {
        self.f32(r.x);
        self.f32(r.y);
        self.f32(r.w);
        self.f32(r.h);
    }
    fn string(&mut self, s: &str) {
        assert!(s.len() <= 0xFFFF, "string too long");
        self.u16(s.len() as u16);
        self.bytes.extend_from_slice(s.as_bytes());
    }
    fn menu_items(&mut self, items: &[MenuItem]) {
        self.u16(items.len().min(0xFFFF) as u16);
        for i in items {
            self.string(&i.title);
            self.u8((i.enabled as u8) | ((i.checked as u8) << 1) | ((i.separator as u8) << 2));
            self.string(&i.key);
            self.u8(i.modifiers);
            self.menu_items(&i.children);
        }
    }
    fn clip_info(&mut self, info: &ClipInfo) {
        match info {
            ClipInfo::Text { text, truncated } => {
                assert!(text.len() <= MAX_CLIP_TEXT, "clip text too long");
                self.u8(ClipKind::Text as u8);
                self.u8(*truncated as u8);
                self.u32(text.len() as u32);
                self.bytes.extend_from_slice(text.as_bytes());
            }
            ClipInfo::Image { width, height, bytes } => {
                self.u8(ClipKind::Image as u8);
                self.u16(*width);
                self.u16(*height);
                self.u64(*bytes);
            }
            ClipInfo::Files(files) => {
                assert!(files.len() <= MAX_CLIP_FILES, "too many clip files");
                self.u8(ClipKind::Files as u8);
                self.u16(files.len() as u16);
                for f in files {
                    self.string(&f.name);
                    self.u64(f.bytes);
                }
            }
            ClipInfo::Data { uti, bytes } => {
                self.u8(ClipKind::Data as u8);
                self.string(uti);
                self.u64(*bytes);
            }
            ClipInfo::Unsupported(why) => {
                self.u8(ClipKind::Unsupported as u8);
                self.string(why);
            }
        }
    }
}

fn utf8(bytes: &[u8]) -> Result<String, CodecError> {
    match foundation_utf8(bytes) {
        Some(s) => Ok(s),
        None => err("text is not valid UTF-8"),
    }
}

/// Swift's `String(bytes:encoding: .utf8)`: valid UTF-8 or nothing, and one leading byte
/// order mark dropped (a second one stays). The `protocol-rejects.json` BOM cases.
fn foundation_utf8(bytes: &[u8]) -> Option<String> {
    let s = std::str::from_utf8(bytes).ok()?;
    Some(s.strip_prefix('\u{FEFF}').unwrap_or(s).to_string())
}

struct Reader<'a> {
    data: &'a [u8],
    pos: usize,
}

impl<'a> Reader<'a> {
    fn new(data: &'a [u8]) -> Self {
        Reader { data, pos: 0 }
    }

    fn is_at_end(&self) -> bool {
        self.pos == self.data.len()
    }

    fn take(&mut self, n: usize) -> Result<&'a [u8], CodecError> {
        if self.data.len() - self.pos < n {
            return err("message is truncated");
        }
        let out = &self.data[self.pos..self.pos + n];
        self.pos += n;
        Ok(out)
    }

    fn rest(&mut self) -> &'a [u8] {
        let out = &self.data[self.pos..];
        self.pos = self.data.len();
        out
    }

    fn u8(&mut self) -> Result<u8, CodecError> {
        Ok(self.take(1)?[0])
    }
    fn u16(&mut self) -> Result<u16, CodecError> {
        Ok(u16::from_le_bytes(self.take(2)?.try_into().unwrap()))
    }
    fn u32(&mut self) -> Result<u32, CodecError> {
        Ok(u32::from_le_bytes(self.take(4)?.try_into().unwrap()))
    }
    fn u64(&mut self) -> Result<u64, CodecError> {
        Ok(u64::from_le_bytes(self.take(8)?.try_into().unwrap()))
    }
    /// A coordinate: finite, or the message is rejected.
    fn f32(&mut self) -> Result<f32, CodecError> {
        let v = f32::from_bits(self.u32()?);
        if !v.is_finite() {
            return err("coordinate is not a finite number");
        }
        Ok(v)
    }
    fn rect(&mut self) -> Result<CanvasRect, CodecError> {
        Ok(CanvasRect { x: self.f32()?, y: self.f32()?, w: self.f32()?, h: self.f32()? })
    }
    fn string(&mut self) -> Result<String, CodecError> {
        let n = self.u16()? as usize;
        utf8(self.take(n)?)
    }
    fn mode(&mut self) -> Result<Mode, CodecError> {
        match Mode::from_byte(self.u8()?) {
            Some(m) => Ok(m),
            None => err("unknown mode"),
        }
    }
    /// A 0/1 byte; anything else is rejected with `text`.
    fn flag(&mut self, text: &str) -> Result<bool, CodecError> {
        let v = self.u8()?;
        if v > 1 {
            return err(text);
        }
        Ok(v == 1)
    }
    /// The version byte that opens `fetch` and `put`.
    fn version(&mut self) -> Result<(), CodecError> {
        let v = self.u8()?;
        if v != PROTOCOL_VERSION {
            return Err(CodecError::version_mismatch(v));
        }
        Ok(())
    }
    /// The fps byte and density shared by `hello` and `setStream` (which also allows 0).
    /// The density is read without the coordinate finite check, then validated.
    fn stream(&mut self, set_stream: bool) -> Result<(u8, f32), CodecError> {
        let fps = self.u8()?;
        let allowed: &[u8] = if set_stream { &ALLOWED_STREAM_FPS } else { &ALLOWED_FPS };
        if !allowed.contains(&fps) {
            return err(if set_stream { "fps must be 30, 15, 5, 1 or 0" } else { "fps must be 30, 15, 5 or 1" });
        }
        let density = f32::from_bits(self.u32()?);
        if !is_valid_density(density) {
            return err("density must be in (0, 8]");
        }
        Ok((fps, density))
    }

    fn clip_info(&mut self) -> Result<ClipInfo, CodecError> {
        let Some(kind) = ClipKind::from_byte(self.u8()?) else { return err("unknown clip kind") };
        Ok(match kind {
            ClipKind::Text => {
                let flag = self.u8()?;
                if flag > 1 {
                    return err("bad truncated flag");
                }
                let n = self.u32()? as usize;
                if n > MAX_CLIP_TEXT {
                    return err(format!("clip text larger than {MAX_CLIP_TEXT} bytes"));
                }
                let text = utf8(self.take(n)?)?;
                ClipInfo::Text { text, truncated: flag == 1 }
            }
            ClipKind::Image => ClipInfo::Image { width: self.u16()?, height: self.u16()?, bytes: self.u64()? },
            ClipKind::Files => {
                let n = self.u16()? as usize;
                if n > MAX_CLIP_FILES {
                    return err(format!("more than {MAX_CLIP_FILES} clip files"));
                }
                let mut files = Vec::with_capacity(n);
                for _ in 0..n {
                    files.push(ClipFile { name: self.string()?, bytes: self.u64()? });
                }
                ClipInfo::Files(files)
            }
            ClipKind::Data => ClipInfo::Data { uti: self.string()?, bytes: self.u64()? },
            ClipKind::Unsupported => ClipInfo::Unsupported(self.string()?),
        })
    }

    fn windows(&mut self) -> Result<Vec<WindowInfo>, CodecError> {
        let n = self.u16()? as usize;
        if n > MAX_WINDOWS {
            return err(format!("more than {MAX_WINDOWS} windows"));
        }
        let mut items = Vec::with_capacity(n);
        for _ in 0..n {
            let id = self.u32()?;
            let parent = self.u32()?;
            if id == 0 {
                return err("window id 0");
            }
            let Some(kind) = WindowKind::from_byte(self.u8()?) else { return err("unknown window kind") };
            let flags = self.u8()?;
            if flags & !3 != 0 {
                return err("unknown window flags");
            }
            let rect = self.rect()?;
            let title_bar = self.f32()?;
            let title = self.string()?;
            if !(rect.w > 0.0 && rect.h > 0.0) {
                return err("window size must be positive");
            }
            if !(title_bar >= 0.0 && title_bar < rect.h) {
                return err("title bar must be in [0, height)");
            }
            if title.graphemes(true).count() > MAX_TITLE_CHARACTERS {
                return err("window title too long");
            }
            items.push(WindowInfo {
                id,
                parent,
                kind,
                resizable: flags & 1 != 0,
                focused: flags & 2 != 0,
                rect,
                title_bar,
                title,
            });
        }
        let ids: HashSet<u32> = items.iter().map(|i| i.id).collect();
        if ids.len() != items.len() {
            return err("duplicate window id");
        }
        if !items.iter().all(|i| i.parent == 0 || (i.parent != i.id && ids.contains(&i.parent))) {
            return err("window parent not in table");
        }
        Ok(items)
    }

    fn menu_items(&mut self, depth: usize, budget: &mut i64) -> Result<Vec<MenuItem>, CodecError> {
        let n = self.u16()? as usize;
        if n != 0 && depth > MAX_MENU_DEPTH {
            return err(format!("menu deeper than {MAX_MENU_DEPTH} levels"));
        }
        *budget -= n as i64;
        if *budget < 0 {
            return err(format!("more than {MAX_MENU_ITEMS} menu items"));
        }
        let mut items = Vec::with_capacity(n);
        for _ in 0..n {
            let title = self.string()?;
            let flags = self.u8()?;
            if flags & !7 != 0 {
                return err("unknown menu flags");
            }
            let key = self.string()?;
            let modifiers = self.u8()?;
            if modifiers & !15 != 0 {
                return err("unknown menu modifiers");
            }
            let children = self.menu_items(depth + 1, budget)?;
            items.push(MenuItem {
                title,
                enabled: flags & 1 != 0,
                checked: flags & 2 != 0,
                separator: flags & 4 != 0,
                key,
                modifiers,
                children,
            });
        }
        Ok(items)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse_all(bytes: &[u8]) -> Result<Vec<Message>, CodecError> {
        let mut p = MessageParser::new();
        p.append(bytes);
        let mut out = Vec::new();
        while let Some(m) = p.next()? {
            out.push(m);
        }
        Ok(out)
    }

    #[test]
    fn version_is_the_controllers() {
        assert_eq!(PROTOCOL_VERSION, rapp_client_core::protocol::VERSION);
    }

    #[test]
    fn round_trips_a_few_messages() {
        let samples = vec![
            Message::Hello {
                token: "t".into(),
                bundle_id: "com.example".into(),
                mode: Mode::Duocolor,
                fps: 30,
                density: 2.0,
                version: PROTOCOL_VERSION,
            },
            Message::Text("桌面 é🇨🇳".into()),
            Message::Scroll { window: 7, x: 1.5, y: -2.0, dx: -3.0, dy: 4.25 },
            Message::Changed,
            Message::StateRules(String::new()),
            Message::Unlock { password: Password::new("secret") },
        ];
        for m in samples {
            let bytes = m.encoded();
            assert_eq!(bytes[0], m.type_byte());
            let len = u32::from_le_bytes([bytes[1], bytes[2], bytes[3], bytes[4]]) as usize;
            assert_eq!(len + 5, bytes.len());
            assert_eq!(parse_all(&bytes).unwrap(), vec![m]);
        }
    }

    #[test]
    fn unknown_type_is_rejected_at_the_header() {
        for t in [0u8, 10, 12, 45, 255] {
            let e = parse_all(&[t, 0, 0, 0, 0]).unwrap_err();
            assert_eq!(e.0, format!("unknown message type {t}"));
        }
    }

    #[test]
    fn oversized_length_is_rejected_from_the_header() {
        let e = parse_all(&[42, 0xFF, 0xFF, 0xFF, 0xFF]).unwrap_err();
        assert_eq!(e.0, format!("message too large ({} bytes)", u32::MAX));
    }

    #[test]
    fn incomplete_input_waits() {
        let bytes = Message::Ping(9).encoded();
        let mut p = MessageParser::new();
        for b in &bytes[..bytes.len() - 1] {
            p.append(&[*b]);
            assert_eq!(p.next().unwrap(), None);
        }
        p.append(&bytes[bytes.len() - 1..]);
        assert_eq!(p.next().unwrap(), Some(Message::Ping(9)));
        assert_eq!(p.buffered(), 0);
    }

    #[test]
    fn password_is_never_printed() {
        let m = Message::Unlock { password: Password::new("hunter2") };
        let text = format!("{m:?}");
        assert!(!text.contains("hunter2"));
        assert!(text.contains("<redacted>"));
    }

    #[test]
    fn disposition_table_is_complete() {
        let known: Vec<u8> = (0..=255u8).filter(|t| is_known_type(*t)).collect();
        let table: Vec<u8> = DISPOSITION.iter().map(|e| e.0).collect();
        assert_eq!(known, table);
        let not_handled: Vec<u8> =
            DISPOSITION.iter().filter(|e| e.2 == Disposition::NotHandled).map(|e| e.0).collect();
        assert_eq!(not_handled, vec![17, 18, 28]);
    }

    #[test]
    fn density_bounds() {
        assert!(!is_valid_density(0.0));
        assert!(is_valid_density(8.0));
        assert!(!is_valid_density(8.5));
        assert!(!is_valid_density(f32::NAN));
    }
}
