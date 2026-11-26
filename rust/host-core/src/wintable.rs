//! Window-table rules (`Sources/RappCore/Windows.swift`; renamed so it is not confused
//! with the operating system). Canvas coordinates are A points with the origin at the
//! display's top-left.
//!
//! Not ported: `classifyWindow` (reads a macOS window level; the platform crate does its
//! own first step), and everything only the controller uses (`cropRect`, `visiblePart`,
//! `WindowPlacement`, `popupFrame`, `moveToTopLeftMessages`, `menuItem`).

use crate::geometry::{swift_max, swift_min, Point, Size};
use crate::protocol::{CanvasRect, WindowInfo, WindowKind};

/// The plan lists it with the window-table rules; it lives in `geometry.rs` beside the
/// other text helpers (`Protocol.swift:760`).
pub use crate::geometry::window_title;

/// Largest size of a chromeless window drawn in place (see `demote_chromeless`).
pub const CHROMELESS_MAX: Size = Size::new(640.0, 1000.0);

/// Step between stacked top-left slots: about a title bar.
pub const STACK_STEP: f32 = 28.0;

/// How many polls a window below the pop-up level waits for its Accessibility window
/// before its level-only classification is kept.
pub const CLASSIFICATION_ATTEMPTS: i64 = 10;

fn is_decorated(kind: WindowKind) -> bool {
    matches!(kind, WindowKind::Normal | WindowKind::Dialog | WindowKind::Floating)
}

/// A small normal or floating window with no close button or no title is an app's own
/// menu or dropdown: drawn in place over its parent like a popover (Windows.swift:38).
pub fn demote_chromeless(kind: WindowKind, close_button: bool, title: Option<&str>, size: Size) -> WindowKind {
    let kind_ok = matches!(kind, WindowKind::Normal | WindowKind::Floating);
    let chrome_missing = !close_button || title.unwrap_or("").is_empty();
    if kind_ok && chrome_missing && size.width <= CHROMELESS_MAX.width && size.height <= CHROMELESS_MAX.height {
        WindowKind::Popover
    } else {
        kind
    }
}

/// Removes windows too small to be anything but an indicator: at most 120 x 48 points.
/// Menus stay (Windows.swift:48).
pub fn drop_stray_indicators(windows: Vec<WindowInfo>) -> Vec<WindowInfo> {
    windows
        .into_iter()
        .filter(|w| matches!(w.kind, WindowKind::Menu) || w.rect.w > 120.0 || w.rect.h > 48.0)
        .collect()
}

/// With no decorated window left, the largest popover becomes the normal window
/// (Windows.swift:55). Ties keep the first, as Swift's `max(by:)` does.
pub fn promote_main_window(windows: Vec<WindowInfo>) -> Vec<WindowInfo> {
    if windows.iter().any(|w| is_decorated(w.kind)) {
        return windows;
    }
    let area = |w: &WindowInfo| w.rect.w * w.rect.h;
    let mut main: Option<usize> = None;
    for (i, w) in windows.iter().enumerate() {
        if !matches!(w.kind, WindowKind::Popover) {
            continue;
        }
        match main {
            None => main = Some(i),
            Some(m) => {
                if area(&windows[m]) < area(w) {
                    main = Some(i);
                }
            }
        }
    }
    let Some(main) = main else { return windows };
    let mut out = windows;
    out[main].kind = WindowKind::Normal;
    out
}

fn overlap_area(a: &CanvasRect, b: &CanvasRect) -> f32 {
    let w = swift_min(a.x + a.w, b.x + b.w) - swift_max(a.x, b.x);
    let h = swift_min(a.y + a.h, b.y + b.h) - swift_max(a.y, b.y);
    if w > 0.0 && h > 0.0 {
        w * h
    } else {
        0.0
    }
}

/// Sets each window's parent (Windows.swift:75). Decorated windows have none. A popup
/// belongs to the decorated window it overlaps most (the frontmost on a tie), or to the
/// frontmost decorated window if it overlaps none; with no decorated window its parent is 0.
pub fn assign_parents(windows: Vec<WindowInfo>) -> Vec<WindowInfo> {
    let decorated: Vec<(u32, CanvasRect)> =
        windows.iter().filter(|w| is_decorated(w.kind)).map(|w| (w.id, w.rect)).collect();
    windows
        .into_iter()
        .map(|window| {
            let mut out = window;
            if is_decorated(out.kind) {
                out.parent = 0;
                return out;
            }
            let mut best: Option<(u32, f32)> = None;
            for (id, rect) in &decorated {
                let area = overlap_area(&out.rect, rect);
                if area > best.map(|b| b.1).unwrap_or(0.0) {
                    best = Some((*id, area));
                }
            }
            out.parent = best.map(|b| b.0).or_else(|| decorated.first().map(|d| d.0)).unwrap_or(0);
            out
        })
        .collect()
}

/// Removes windows lying wholly inside a decorated window's title row; a title row that
/// could not be measured (0) counts as 28 points (Windows.swift:96).
pub fn drop_title_bar_accessories(windows: Vec<WindowInfo>) -> Vec<WindowInfo> {
    let bands: Vec<(u32, CanvasRect)> = windows
        .iter()
        .filter(|d| is_decorated(d.kind))
        .map(|d| {
            let h = if d.title_bar > 0.0 { d.title_bar } else { 28.0 };
            (d.id, CanvasRect { x: d.rect.x, y: d.rect.y, w: d.rect.w, h })
        })
        .collect();
    windows
        .into_iter()
        .filter(|w| {
            !bands.iter().any(|(id, band)| {
                *id != w.id
                    && w.rect.x >= band.x
                    && w.rect.y >= band.y
                    && w.rect.x + w.rect.w <= band.x + band.w
                    && w.rect.y + w.rect.h <= band.y + band.h
            })
        })
        .collect()
}

/// The capture region: the union of all windows, clipped to the display, rounded out to
/// multiples of 8 points and clipped again. `None` when there are no windows or none is
/// on the display (Windows.swift:111).
pub fn capture_region(windows: &[WindowInfo], display: Size) -> Option<CanvasRect> {
    let first = windows.first()?;
    let mut min_x = first.rect.x;
    let mut min_y = first.rect.y;
    let mut max_x = first.rect.x + first.rect.w;
    let mut max_y = first.rect.y + first.rect.h;
    for w in &windows[1..] {
        min_x = swift_min(min_x, w.rect.x);
        min_y = swift_min(min_y, w.rect.y);
        max_x = swift_max(max_x, w.rect.x + w.rect.w);
        max_y = swift_max(max_y, w.rect.y + w.rect.h);
    }
    clipped_rounded_out(min_x, min_y, max_x, max_y, display)
}

/// Clips the box to the display, rounds it out to multiples of 8 points and clips again
/// (Windows.swift:126).
fn clipped_rounded_out(min_x: f32, min_y: f32, max_x: f32, max_y: f32, display: Size) -> Option<CanvasRect> {
    let width = display.width as f32;
    let height = display.height as f32;
    let mut min_x = swift_max(min_x, 0.0);
    let mut min_y = swift_max(min_y, 0.0);
    let mut max_x = swift_min(max_x, width);
    let mut max_y = swift_min(max_y, height);
    if !(max_x > min_x && max_y > min_y) {
        return None;
    }
    min_x = (min_x / 8.0).floor() * 8.0;
    min_y = (min_y / 8.0).floor() * 8.0;
    max_x = swift_min((max_x / 8.0).ceil() * 8.0, width);
    max_y = swift_min((max_y / 8.0).ceil() * 8.0, height);
    Some(CanvasRect { x: min_x, y: min_y, w: max_x - min_x, h: max_y - min_y })
}

/// What A captures while B shows only `view.1` (window content coordinates) of window
/// `view.0`: that rect on the canvas plus the frames of the window's popups, inside the
/// usual capture region, rounded out to 8 points (Windows.swift:142).
pub fn view_region(view: Option<(u32, CanvasRect)>, windows: &[WindowInfo], display: Size) -> Option<CanvasRect> {
    let base = capture_region(windows, display);
    let (Some((view_window, view_rect)), Some(base)) = (view, base) else { return base };
    let Some(win) = windows.iter().find(|w| w.id == view_window) else { return Some(base) };
    let mut min_x = view_rect.x + win.rect.x;
    let mut min_y = view_rect.y + win.rect.y + win.title_bar;
    let mut max_x = min_x + view_rect.w;
    let mut max_y = min_y + view_rect.h;
    for child in windows.iter().filter(|c| c.parent == view_window && c.id != view_window) {
        min_x = swift_min(min_x, child.rect.x);
        min_y = swift_min(min_y, child.rect.y);
        max_x = swift_max(max_x, child.rect.x + child.rect.w);
        max_y = swift_max(max_y, child.rect.y + child.rect.h);
    }
    min_x = swift_max(min_x, base.x);
    min_y = swift_max(min_y, base.y);
    max_x = swift_min(max_x, base.x + base.w);
    max_y = swift_min(max_y, base.y + base.h);
    Some(clipped_rounded_out(min_x, min_y, max_x, max_y, display).unwrap_or(base))
}

/// The view a `setView` leaves behind: window 0 clears it (Windows.swift:161).
pub fn view_for(window: u32, rect: CanvasRect) -> Option<(u32, CanvasRect)> {
    if window == 0 {
        None
    } else {
        Some((window, rect))
    }
}

/// The capture region to apply after the view or the window table changed; `None` when it
/// equals `current` (or there is no region) (Windows.swift:167).
pub fn region_change(
    view: Option<(u32, CanvasRect)>,
    windows: &[WindowInfo],
    display: Size,
    current: Option<CanvasRect>,
) -> Option<CanvasRect> {
    let next = view_region(view, windows, display)?;
    if Some(next) == current {
        None
    } else {
        Some(next)
    }
}

/// A move target pulled back so the window's title row stays on A's display: at least 40
/// points of width and the title row (20 points if it has none) (Windows.swift:265).
pub fn clamped_window_origin(origin: Point, size: Size, title_bar: f64, canvas: Size) -> Point {
    let keep = swift_min(size.width, 40.0);
    let grab = if title_bar > 0.0 { title_bar } else { 20.0 };
    Point::new(
        swift_min(swift_max(origin.x, keep - size.width), canvas.width - keep),
        swift_min(swift_max(origin.y, 0.0), swift_max(canvas.height - grab, 0.0)),
    )
}

/// Whether a window's classification can be kept: made with the Accessibility window, or
/// at or above the pop-up level, or after `CLASSIFICATION_ATTEMPTS` polls.
pub fn classification_is_final(found_accessibility: bool, below_pop_up: bool, attempts: i64) -> bool {
    found_accessibility || !below_pop_up || attempts >= CLASSIFICATION_ATTEMPTS
}
