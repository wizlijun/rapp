//! Focus pane rules (spec 2026-11-16-rapp-focus-pane-rules): picking a panel from an
//! accessibility chain (`pane`) and the state machine that decides what to send (`tracker`).

pub mod pane;
pub mod tracker;

pub use pane::{panel, window_rect, window_tiles, PanelMiss, PanelPick, WindowTiles};
pub use tracker::{Action, Cause, FocusTracker, Output, Pointer, Query};
