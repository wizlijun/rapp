//! Input and window commands from B (`Server.swift:443-487`, `:1134-1148`,
//! `Sources/rapp-host/InputInjector.swift`), on the session thread.
//!
//! The point a mouse or scroll names is in window points; it becomes a global point as
//! `InputInjector.globalPoint` does (display origin + window origin + x, y, kept on the display).
//! Plan B says `geometry::global_point`, which takes fractions of the window: see the draft notes.

use crate::cli::WorkerEvent;
use crate::geometry::{chunk_utf16, window_size, Point, Rect, Size};
use crate::hints::opens_things;
use crate::hit_test::top_window_owner;
use crate::input::{BLOCKED_NOTICE_EVERY, INPUT_REPORT_EVERY};
use crate::protocol::{Message, MouseButton, MouseKind, WindowInfo};
use crate::wintable::clamped_window_origin;

use super::hold;
use super::session::Session;
use super::tracker::global_frame;

/// Text goes out in pieces of this many UTF-16 units (`chunkUTF16`'s default).
pub const TEXT_CHUNK: usize = 20;
/// Pause after each text piece (`usleep(5_000)`).
pub const TEXT_CHUNK_GAP: f64 = 0.005;
/// After activating the target for text or a key (`activateIfNeeded`).
pub const ACTIVATE_WAIT: f64 = 0.05;
/// The top-window check waits this long for the target to come up (`clearToPointerInput`).
pub const RAISE_WAIT: f64 = 0.05;
/// How often the top window is looked at while waiting.
pub const RAISE_POLL: f64 = 0.005;
/// A covered scroll burst does not try to raise again for this long.
pub const SCROLL_RAISE_PAUSE: f64 = 0.15;
/// Wheel deltas are kept within this many pixels.
pub const SCROLL_LIMIT: f32 = 10_000.0;
/// `selectInput` waits this long for the platform to report the new source.
pub const SELECT_WAIT: f64 = 0.3;
pub const SELECT_POLL: f64 = 0.01;
/// And then gives the app a moment before B's next input.
pub const SELECT_SETTLE: f64 = 0.05;

/// `fitted(_:limit:)` (`ClipboardWatcher.swift:7`): at most `limit` UTF-8 bytes, cut on a
/// character boundary. Swift cuts on grapheme clusters; this cuts on `char`s, which can split
/// a cluster of several scalars (only a log line uses it).
pub(crate) fn fitted(s: &str, limit: usize) -> String {
    if s.len() <= limit {
        return s.to_string();
    }
    let mut out = String::new();
    for ch in s.chars() {
        if out.len() + ch.len_utf8() > limit {
            break;
        }
        out.push(ch);
    }
    out
}

impl Session {
    /// The target opened: input can reach it from now on (Swift creates the injector here).
    pub(crate) fn input_ready(&mut self) {
        self.input_on = true;
    }

    /// `text`, `key`, `mouse` and `scroll` after the gate (`Server.swift:443-446`).
    pub(crate) fn input(&mut self, m: Message) {
        if self.ended || self.failing || !self.input_on || self.ops.is_none() {
            return;
        }
        // An elevated window refuses input from an ordinary process (spec §6.5): B is told why.
        if let Some(by) = self.elevated_at(&m) {
            self.input_blocked_by(by);
            return;
        }
        if opens_things(&m) {
            self.last_input_at = Some(self.now());
        }
        self.inject(&m);
        self.focus_input(&m);
    }

    /// The window `m` names, if it is in the table.
    fn input_window(&self, id: u32) -> Option<WindowInfo> {
        self.table.iter().find(|w| w.id == id).cloned()
    }

    /// `InputInjector.globalPoint`: display origin + window top-left + (x, y), kept on the display.
    pub(crate) fn point_on_display(&self, w: &WindowInfo, x: f32, y: f32) -> Point {
        let d = self.display;
        let px = d.min_x() + f64::from(w.rect.x) + f64::from(x);
        let py = d.min_y() + f64::from(w.rect.y) + f64::from(y);
        Point::new(px.max(d.min_x()).min(d.max_x() - 1.0), py.max(d.min_y()).min(d.max_y() - 1.0))
    }

    /// Where the platform is asked whether an elevated window takes the input. Mouse and
    /// scroll: their point. Keys and text: the middle of the focused window in the table (the
    /// window they would land in); none focused, nothing is asked.
    fn elevated_at(&mut self, m: &Message) -> Option<String> {
        let point = match m {
            Message::Mouse { window, x, y, .. } | Message::Scroll { window, x, y, .. } => {
                let w = self.input_window(*window)?;
                self.point_on_display(&w, *x, *y)
            }
            Message::Text(_) | Message::Key { .. } => {
                let w = self.table.iter().find(|w| w.focused)?;
                let f = global_frame(w, self.display);
                Point::new(f.mid_x(), f.mid_y())
            }
            _ => return None,
        };
        let ops = self.ops.as_ref()?;
        let by = hold(&ops.input).blocked_by(point);
        by
    }

    /// Input that cannot be delivered: `inputBlocked` at most every 0.5 s, the worker event at
    /// most every 0.25 s (the same pacing as the yield gate's).
    pub(crate) fn input_blocked_by(&mut self, by: String) {
        let now = self.now();
        if self.blocked_event_at.is_none_or(|at| now - at >= INPUT_REPORT_EVERY) {
            self.blocked_event_at = Some(now);
            self.inner.out.emit(&WorkerEvent::InputBlocked { by: by.clone() });
        }
        if self.blocked_notice_at.is_none_or(|at| now - at >= BLOCKED_NOTICE_EVERY) {
            self.blocked_notice_at = Some(now);
            self.send(Message::InputBlocked { by });
        }
    }

    /// `InputInjector.handle`.
    fn inject(&mut self, m: &Message) {
        match m {
            Message::Mouse { kind, button, window, x, y, click_count } => {
                let Some(w) = self.input_window(*window) else { return };
                let point = self.point_on_display(&w, *x, *y);
                self.mouse(*kind, *button, point, &w, *click_count);
            }
            Message::Scroll { window, x, y, dx, dy } => {
                let Some(w) = self.input_window(*window) else { return };
                let point = self.point_on_display(&w, *x, *y);
                if !self.clear_to_pointer_input(point, &w, true) {
                    return;
                }
                let clamp = |v: f32| v.round().clamp(-SCROLL_LIMIT, SCROLL_LIMIT);
                let Some(ops) = self.ops.as_ref() else { return };
                let mut input = hold(&ops.input);
                input.mouse(MouseKind::Move, MouseButton::Left, point, 1);
                input.scroll(point, clamp(*dx), clamp(*dy));
            }
            Message::Text(text) => {
                self.activate_if_needed();
                let clock = self.inner.clock.clone();
                let Some(ops) = self.ops.as_ref() else { return };
                for chunk in chunk_utf16(text, TEXT_CHUNK) {
                    hold(&ops.input).text(&chunk);
                    clock.sleep(TEXT_CHUNK_GAP);
                }
            }
            Message::Key { key_code, modifiers, down } => {
                self.activate_if_needed();
                let Some(ops) = self.ops.as_ref() else { return };
                // Key codes and the 64-bit flags go to the platform untouched (spec §6.5).
                hold(&ops.input).key(*key_code, *modifiers, *down);
                if *down {
                    self.held.press_key(*key_code);
                } else {
                    self.held.release_key(*key_code);
                }
            }
            _ => {}
        }
    }

    /// `InputInjector.mouse`: a press must pass the top-window check; a dropped press drops
    /// its drags and its up too, so the app never sees half a click.
    fn mouse(&mut self, kind: MouseKind, button: MouseButton, point: Point, w: &WindowInfo, click_count: u8) {
        match kind {
            MouseKind::Move => {
                if let Some(ops) = self.ops.as_ref() {
                    hold(&ops.input).mouse(MouseKind::Move, button, point, 1);
                }
                return;
            }
            MouseKind::Down => {
                if !self.clear_to_pointer_input(point, w, false) {
                    self.dropped_buttons.insert(button);
                    return;
                }
                self.dropped_buttons.remove(&button);
                // The pointer goes there first so hover-dependent controls are ready.
                if let Some(ops) = self.ops.as_ref() {
                    hold(&ops.input).mouse(MouseKind::Move, button, point, 1);
                }
            }
            MouseKind::Up => {
                if self.dropped_buttons.remove(&button) {
                    return;
                }
            }
            MouseKind::Drag => {
                if self.dropped_buttons.contains(&button) {
                    return;
                }
            }
        }
        let Some(ops) = self.ops.as_ref() else { return };
        hold(&ops.input).mouse(kind, button, point, click_count.max(1));
        match kind {
            MouseKind::Down => self.held.press_button(button),
            MouseKind::Up => self.held.release_button(button),
            _ => {}
        }
    }

    /// The owner of the frontmost window at `point` (`InputInjector.topOwner`). The platform
    /// lists the windows; it has no system-wide hit test to offer, so overlays count as seen.
    fn top_owner(&self, point: Point) -> (i32, String) {
        let Some(ops) = self.ops.as_ref() else { return (0, "nothing".to_string()) };
        let screen = hold(&ops.windows).screen();
        let displays: Vec<Rect> = self.inner.platform.displays().iter().map(|d| d.frame).collect();
        top_window_owner(point, &screen, None, &displays, &mut || None)
    }

    /// `InputInjector.clearToPointerInput`: the window on top at `point` must be the target's.
    /// If not, the target and the window come to the front and the check repeats every 5 ms for
    /// at most 50 ms; still covered drops the input and, for another app's window, tells B.
    fn clear_to_pointer_input(&mut self, point: Point, w: &WindowInfo, scrolling: bool) -> bool {
        if self.desktop {
            return true;
        }
        let Some(ops) = self.ops.as_ref() else { return false };
        let target = ops.target.clone();
        let windows = ops.windows.clone();
        let pid = hold(&target).pid();
        let clock = self.inner.clock.clone();
        // A wheel event does not activate an otherwise visible inactive app the way a press does.
        let ready = |s: &Session, top: &(i32, String)| -> bool {
            top.0 == pid && (!scrolling || s.ops.as_ref().is_some_and(|o| hold(&o.target).frontmost()))
        };
        let mut top = self.top_owner(point);
        if ready(self, &top) {
            self.scroll_raise_after = 0.0;
            return true;
        }
        if scrolling && self.now() < self.scroll_raise_after {
            return false;
        }
        // Only decorated windows are raised (a popup has no window of its own to raise).
        hold(&target).activate();
        if w.kind.is_decorated() {
            hold(&windows).raise(w.id);
        }
        let deadline = self.now() + RAISE_WAIT;
        top = self.top_owner(point);
        while !ready(self, &top) && self.now() < deadline {
            clock.sleep(RAISE_POLL);
            top = self.top_owner(point);
        }
        if ready(self, &top) {
            self.scroll_raise_after = 0.0;
            return true;
        }
        if scrolling {
            self.scroll_raise_after = self.now() + SCROLL_RAISE_PAUSE;
        }
        let input = if scrolling { "scroll" } else { "click" };
        if hold(&self.lock).locked() {
            self.inner.out.log(&format!("{input} dropped: A is locked"));
        } else if top.0 == pid {
            self.inner.out.log(&format!("{input} dropped: target app is not active yet"));
        } else {
            self.inner.out.log(&format!("{input} dropped: covered by {}", top.1));
            if top.0 != 0 {
                self.covered(top.0, top.1.clone(), point);
            }
        }
        false
    }

    /// `activateIfNeeded`: app sessions bring the target to the front before text or a key.
    fn activate_if_needed(&mut self) {
        if self.desktop {
            return;
        }
        let Some(ops) = self.ops.as_ref() else { return };
        let mut target = hold(&ops.target);
        if target.frontmost() {
            return;
        }
        target.activate();
        drop(target);
        self.inner.clock.sleep(ACTIVATE_WAIT);
    }

    /// Releases every key and button still held (`releaseAll`), at the session's end.
    pub(crate) fn release_all_input(&mut self) {
        let (keys, buttons) = self.held.drain();
        if keys.is_empty() && buttons.is_empty() {
            return;
        }
        if let Some(ops) = self.ops.as_ref() {
            hold(&ops.input).release(&keys, &buttons);
        }
    }

    // MARK: Window commands (`Server.swift:467-487`)
    //
    // Commands naming a window no longer in the table are dropped, not errors: B may not
    // have seen the newest table yet (spec §2.4). Desktop sessions have no app (Swift's
    // `guard let app`): their one table entry is the display itself, so they are refused
    // by `self.desktop`, not by the window's kind.

    /// A decorated window of the table (`decoratedWindow`).
    fn decorated_window(&self, id: u32) -> Option<WindowInfo> {
        self.table.iter().find(|w| w.id == id && w.kind.is_decorated()).cloned()
    }

    pub(crate) fn resize_window(&mut self, id: u32, width: u16, height: u16) {
        if self.desktop || self.ended {
            return;
        }
        let Some(w) = self.decorated_window(id) else { return };
        if !w.resizable {
            return;
        }
        let frame = global_frame(&w, self.display);
        // The content size B asked for plus A's title row, kept on the display (`resize`).
        let size = window_size(
            Size::new(f64::from(width), f64::from(height)),
            f64::from(w.title_bar),
            frame.origin(),
            self.display,
        );
        let Some(ops) = self.ops.as_ref() else { return };
        hold(&ops.windows).resize(w.id, size);
    }

    pub(crate) fn focus_window(&mut self, id: u32) {
        if self.desktop || self.ended {
            return;
        }
        let Some(w) = self.input_window(id) else { return };
        let Some(ops) = self.ops.as_ref() else { return };
        hold(&ops.target).activate();
        if w.kind.is_decorated() {
            hold(&ops.windows).raise(w.id);
        }
    }

    pub(crate) fn close_window(&mut self, id: u32) {
        if self.desktop || self.ended {
            return;
        }
        let Some(w) = self.decorated_window(id) else { return };
        let Some(ops) = self.ops.as_ref() else { return };
        hold(&ops.windows).close(w.id);
    }

    pub(crate) fn move_window(&mut self, id: u32, x: f32, y: f32) {
        if self.desktop || self.ended {
            return;
        }
        let Some(w) = self.decorated_window(id) else { return };
        // Never off A's display: the window would leave the table and B could not move it back.
        let canvas = clamped_window_origin(
            Point::new(f64::from(x), f64::from(y)),
            Size::new(f64::from(w.rect.w), f64::from(w.rect.h)),
            f64::from(w.title_bar),
            Size::new(self.display.w(), self.display.h()),
        );
        let origin = Point::new(self.display.min_x() + canvas.x, self.display.min_y() + canvas.y);
        let Some(ops) = self.ops.as_ref() else { return };
        if !hold(&ops.windows).move_to(w.id, origin) {
            self.inner.out.log("could not move a window (the app may not allow it)");
        }
    }

    // MARK: Input sources (`Server.swift:1134-1148`)

    /// Selects `id` ("" = a plain English layout), waits up to 0.3 s for the platform to report
    /// it, then reports what A has (also when `id` is unknown). Synchronous: the text or key B
    /// sent next lands in the new source.
    pub(crate) fn select_input(&mut self, id: &str) {
        if self.ended {
            return;
        }
        let Some(ops) = self.ops.as_ref() else { return };
        let sources = ops.input_source.clone();
        let is_target = |s: &crate::platform::InputSource| if id.is_empty() { s.english } else { s.id == id };
        // Swift's `switched`: false when the source was already the current one (no wait then).
        let already = hold(&sources).current().is_some_and(|s| is_target(&s));
        let selected = if id.is_empty() { hold(&sources).select_english() } else { hold(&sources).select(id) };
        if selected && !already {
            let clock = self.inner.clock.clone();
            let deadline = clock.now() + SELECT_WAIT;
            loop {
                let arrived = hold(&sources).current().is_some_and(|s| is_target(&s));
                if arrived || clock.now() >= deadline {
                    break;
                }
                clock.sleep(SELECT_POLL);
            }
            // The app hears of the switch on its own path; give it a moment before B's next input.
            clock.sleep(SELECT_SETTLE);
        } else if !selected {
            let name = if id.is_empty() { "(ASCII layout)".to_string() } else { fitted(id, 200) };
            self.inner.out.log(&format!("could not select input source {name}"));
        }
        self.send_input_source(true);
    }
}

#[cfg(test)]
mod tests {
    use super::fitted;

    #[test]
    fn fitted_cuts_on_a_character_boundary() {
        assert_eq!(fitted("abc", 3), "abc");
        assert_eq!(fitted("abcd", 3), "abc");
        // "é" is 2 bytes: a 3-byte limit keeps "aé", a 2-byte one only "a".
        assert_eq!(fitted("aéb", 3), "aé");
        assert_eq!(fitted("aéb", 2), "a");
        assert_eq!(fitted("", 0), "");
    }
}
