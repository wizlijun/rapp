//! The OS-independent part of the rApp host, ported from `Sources/RappCore/`
//! and `Sources/rapp-host/` (spec: docs/superpowers/specs, plan B). Everything
//! here is plain Rust: no OS-specific code, every timestamp and wait goes
//! through `clock::Clock`, and the one `unsafe` block lives in `deflate.rs`.
//! `tests/boundary.rs` enforces this.

// Encode and send (Tasks 1–6).
pub mod clock;
pub mod deflate;
pub mod pacing;
pub mod pause;
pub mod protocol;
pub mod quantize;
pub mod scroll;
pub mod tile;

// Rules (Tasks 7–12).
pub mod clipboard;
pub mod desktop;
pub mod filename;
pub mod focus;
pub mod geometry;
pub mod hints;
pub mod hit_test;
pub mod input;
pub mod lock;
pub mod query;
pub mod state;
pub mod transfers;
pub mod wintable;

// Worker command line, platform interface, session, entry point (Tasks 9, 13–17).
pub mod cli;
pub mod platform;
pub mod run;
pub mod session;

pub use clock::{Clock, ScaledClock, SystemClock};
pub use deflate::{DeflateStream, InflateStream};
pub use pacing::{
    save_ladder_steps, save_ladder_stream, PacedSender, SendPacer, SenderOutput, Stats, StreamSpec, WeakTier,
};
pub use pause::PauseOutbox;
pub use protocol::{
    CanvasRect, ClipFile, ClipInfo, ClipKind, CodecError, Disposition, FrameFlags, FramePayload, MenuItem,
    Message, MessageParser, Mode, MouseButton, MouseKind, PasteSource, Password, WindowInfo, WindowKind,
    DISPOSITION,
};
pub use quantize::{quantize, DUO_BLOCK};
pub use tile::{EncodeReport, FrameEncoder, TILE_SIZE};

// Later tasks' main names (Task 7 geometry). Tasks 7–19 may add their own
// re-exports here; keep this list in step with what those modules define.
pub use geometry::{Point, Rect, Size};
