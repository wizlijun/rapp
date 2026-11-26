//! The window table (`Sources/rapp-host/WindowTracker.swift`): the platform's raw list,
//! front to back, turned into what the `windows` message carries. The platform classifies
//! (Swift `classifyWindow` plus the accessibility look-up, which `RawWindow` already holds);
//! everything after that is the shared window-table rules of `wintable`.

use crate::geometry::{swift_max, swift_min, window_title, Rect, Size};
use crate::platform::RawWindow;
use crate::protocol::{CanvasRect, WindowInfo, MAX_WINDOWS};
use crate::wintable::{assign_parents, demote_chromeless, drop_stray_indicators, drop_title_bar_accessories, promote_main_window};

/// `WindowTracker.poll()` without the caching Swift needs for its slow accessibility calls:
/// the platform lists every window with its class already made.
///
/// `display` is the canvas display's global frame; canvas = global - display origin.
pub fn window_table(raw: &[RawWindow], display: Rect, app_name: Option<&str>) -> Vec<WindowInfo> {
    let mut table = Vec::new();
    for w in raw {
        // WindowTracker.swift:48-54: on screen, at least 4 x 4, on the canvas display.
        if w.minimized || !(w.rect.w() >= 4.0 && w.rect.h() >= 4.0) || w.rect.intersection(&display).is_none() {
            continue;
        }
        let size = Size::new(w.rect.w(), w.rect.h());
        let kind = demote_chromeless(w.kind, w.close_button, Some(w.title.as_str()), size);
        let decorated = kind.is_decorated();
        let (title, title_bar) = if decorated {
            // Always below the window's height (spec §2.2).
            let row = swift_min(swift_max(w.title_bar, 0.0), w.rect.h() as f32 - 1.0);
            (window_title(Some(w.title.as_str()), app_name), row)
        } else {
            (String::new(), 0.0)
        };
        table.push(WindowInfo {
            id: w.id,
            parent: 0,
            kind,
            resizable: w.resizable && decorated,
            focused: decorated && w.foreground,
            rect: CanvasRect::new(
                (w.rect.min_x() - display.min_x()) as f32,
                (w.rect.min_y() - display.min_y()) as f32,
                w.rect.w() as f32,
                w.rect.h() as f32,
            ),
            title_bar,
            title,
        });
    }
    let shown: Vec<WindowInfo> = promote_main_window(drop_title_bar_accessories(drop_stray_indicators(table)))
        .into_iter()
        .map(|mut w| {
            if w.kind.is_decorated() && w.title.is_empty() {
                w.title = window_title(None, app_name); // promoted
            }
            w
        })
        .collect();
    assign_parents(shown).into_iter().take(MAX_WINDOWS).collect()
}

/// `WindowInfo.globalFrame(display:)`.
pub fn global_frame(w: &WindowInfo, display: Rect) -> Rect {
    Rect::new(
        display.min_x() + f64::from(w.rect.x),
        display.min_y() + f64::from(w.rect.y),
        f64::from(w.rect.w),
        f64::from(w.rect.h),
    )
}

/// The raw window a table entry came from.
pub fn raw_for<'a>(raw: &'a [RawWindow], id: u32) -> Option<&'a RawWindow> {
    raw.iter().find(|w| w.id == id)
}
