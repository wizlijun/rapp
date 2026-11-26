//! Who owns the frontmost window at a point (`Sources/RappCore/HitTest.swift`).
//!
//! `pid`, `layer` and `dock_pid` keep their Swift meaning; on Windows the platform crate
//! maps its own facts onto them (process id, z-order band, the shell's process id).

use crate::geometry::{Point, Rect};

/// One on-screen window as the window server lists it, front to back.
#[derive(Debug, Clone, PartialEq)]
pub struct ScreenWindow {
    pub pid: i32,
    pub name: String,
    pub layer: i64,
    pub alpha: f64,
    pub frame: Rect,
}

/// Share of the display a window must cover to be taken for a possible overlay.
pub const OVERLAY_COVERAGE: f64 = 0.85;

/// The owner of the frontmost window containing `at`, skipping invisible ones and the
/// screen-saver/cursor levels (HitTest.swift:27). `hit_test_pid` (None when it fails) is
/// asked at most once:
/// - a Dock window counts only on a hit; a failed test looks through it;
/// - any other possible overlay counts on a hit or on a failed test;
/// - ordinary opaque windows always count, without asking.
pub fn top_window_owner(
    at: Point,
    windows: &[ScreenWindow],
    dock_pid: Option<i32>,
    displays: &[Rect],
    hit_test_pid: &mut dyn FnMut() -> Option<i32>,
) -> (i32, String) {
    let mut hit: Option<Option<i32>> = None;
    let mut hit_pid = |hit: &mut Option<Option<i32>>| -> Option<i32> {
        if hit.is_none() {
            *hit = Some(hit_test_pid());
        }
        hit.unwrap_or(None)
    };
    let display = displays.iter().find(|d| d.contains_point(at)).copied();
    for window in windows {
        if !(window.alpha > 0.0 && window.layer < 1000 && window.frame.contains_point(at)) {
            continue;
        }
        if let Some(dock) = dock_pid.filter(|d| *d == window.pid) {
            if hit_pid(&mut hit) != Some(dock) {
                continue;
            }
        } else if may_be_overlay(window, display) {
            if let Some(pid) = hit_pid(&mut hit) {
                if pid != window.pid {
                    continue;
                }
            }
        }
        return (window.pid, window.name.clone());
    }
    (0, "nothing".to_string())
}

/// Whether `window` may be a see-through overlay: translucent, or covering most of `display`.
pub fn may_be_overlay(window: &ScreenWindow, display: Option<Rect>) -> bool {
    if window.alpha < 1.0 {
        return true;
    }
    let Some(display) = display else { return false };
    if !(display.w() > 0.0 && display.h() > 0.0) {
        return false;
    }
    let Some(covered) = window.frame.intersection(&display) else { return false };
    covered.w() * covered.h() >= OVERLAY_COVERAGE * (display.w() * display.h())
}
