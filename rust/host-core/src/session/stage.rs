//! Session steps that later tasks of plan B fill in. Each task moves its items out of this
//! file into its own module and deletes them here; Task 17 deletes the file.
//!
//! What stays until then: the session answers hello, ping and the window table, and drops
//! the commands below without acting on them.

use crate::platform::Frame;
use crate::protocol::{Mode, Password, PasteSource, WindowInfo};
use crate::tile::EncodeReport;

use super::session::Session;

impl Session {
    // Task 14: capture, encode, send.
    pub(crate) fn start_capture_thread(&mut self) {}
    pub(crate) fn capture_params_changed(&mut self) {}
    pub(crate) fn stop_capture(&mut self) {}
    pub(crate) fn frame_arrived(&mut self, _frame: Frame) {}
    pub(crate) fn set_stream(&mut self, _mode: Mode, _fps: i64, _density: f32) {}
    pub(crate) fn set_stream_request(&mut self, _mode: Mode, _fps: u8, _density: f32, _pinned: bool, _focus: bool) {}

    // Task 15: input, covers, focus pane, state rules.
    pub(crate) fn input_ready(&mut self) {}
    pub(crate) fn input(&mut self, _m: crate::protocol::Message) {}
    pub(crate) fn resize_window(&mut self, _id: u32, _w: u16, _h: u16) {}
    pub(crate) fn focus_window(&mut self, _id: u32) {}
    pub(crate) fn close_window(&mut self, _id: u32) {}
    pub(crate) fn move_window(&mut self, _id: u32, _x: f32, _y: f32) {}
    pub(crate) fn select_input(&mut self, _id: &str) {}
    pub(crate) fn dismiss_cover(&mut self, _id: u32) {}
    pub(crate) fn state_rules(&mut self, _json: String) {}
    pub(crate) fn start_app_state(&mut self) {}
    pub(crate) fn windows_changed(&mut self, _next: &[WindowInfo]) {}
    pub(crate) fn sync_focus(&mut self) {}
    pub(crate) fn start_hints(&mut self) {}
    pub(crate) fn check_secure_focus(&mut self) {}
    pub(crate) fn focus_locked(&mut self, _locked: bool) {}
    pub(crate) fn encoded(&mut self, _report: EncodeReport) {}

    // Task 16: clipboard and paste.
    pub(crate) fn start_clipboard(&mut self, _desktop: bool) {}
    pub(crate) fn paste(&mut self, _seq: u32, _source: PasteSource) {}

    // Task 17: unlock.
    pub(crate) fn unlock(&mut self, _password: Password) {}
}
