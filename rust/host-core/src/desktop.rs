//! Desktop sessions: a whole display of A instead of one app (`Sources/RappCore/Desktop.swift`).

use crate::geometry::Rect;
use crate::protocol::{CanvasRect, WindowInfo, WindowKind};
use serde_json::{json, Value};

/// The app-list entry and the main display's session; `desktop:<id>` is any other display.
pub const DESKTOP_APP: &str = "desktop:";
/// The name the app list gives the desktop entry.
pub const DESKTOP_APP_NAME: &str = "桌面";

/// Which display a desktop session shows.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DesktopTarget {
    Main,
    Display(u32),
}

/// `desktop:` is the main display, `desktop:<decimal id>` that display; anything else is not
/// a desktop id. Like Swift's `UInt32(String)`: an optional leading `+`, ASCII digits only,
/// no overflow.
pub fn desktop_target(app: &str) -> Option<DesktopTarget> {
    let rest = app.strip_prefix(DESKTOP_APP)?;
    if rest.is_empty() {
        return Some(DesktopTarget::Main);
    }
    if !rest.is_ascii() {
        return None;
    }
    parse_swift_u32(rest).map(DesktopTarget::Display)
}

/// Swift's `UInt32(_ text:)`: optional sign, then one or more ASCII digits, in range.
/// A `-` sign is accepted by Swift only for a value of zero ("-0").
pub(crate) fn parse_swift_u32(text: &str) -> Option<u32> {
    let (negative, digits) = match text.as_bytes().first() {
        Some(b'+') => (false, &text[1..]),
        Some(b'-') => (true, &text[1..]),
        _ => (false, text),
    };
    if digits.is_empty() || !digits.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    let mut value: u32 = 0;
    for b in digits.bytes() {
        value = value.checked_mul(10)?.checked_add(u32::from(b - b'0'))?;
    }
    if negative && value != 0 {
        return None;
    }
    Some(value)
}

pub fn is_desktop_app(app: &str) -> bool {
    desktop_target(app).is_some()
}

/// One of A's displays as the app list reports it. `frame` is in global points (top-left origin).
#[derive(Debug, Clone, PartialEq)]
pub struct DesktopDisplay {
    pub id: u32,
    pub name: String,
    pub main: bool,
    pub frame: Rect,
}

/// Swift's `Int(x.rounded())`, which traps out of range; here it saturates (a display is
/// never that large).
pub(crate) fn rounded_int(x: f64) -> i64 {
    let r = x.round();
    if !r.is_finite() {
        return 0;
    }
    if r >= i64::MAX as f64 {
        i64::MAX
    } else if r <= i64::MIN as f64 {
        i64::MIN
    } else {
        r as i64
    }
}

impl DesktopDisplay {
    pub fn width(&self) -> i64 {
        rounded_int(self.frame.w())
    }
    pub fn height(&self) -> i64 {
        rounded_int(self.frame.h())
    }
}

/// The main display first, then left to right, then top to bottom (Desktop.swift orderedDisplays).
pub fn ordered_displays(d: Vec<DesktopDisplay>) -> Vec<DesktopDisplay> {
    let mut d = d;
    // Swift's sort is not stable, but the comparison is total over distinct ids.
    d.sort_by(|a, b| {
        use std::cmp::Ordering;
        let less = |a: &DesktopDisplay, b: &DesktopDisplay| -> bool {
            if a.main != b.main {
                return a.main;
            }
            if a.frame.min_x() != b.frame.min_x() {
                return a.frame.min_x() < b.frame.min_x();
            }
            if a.frame.min_y() != b.frame.min_y() {
                return a.frame.min_y() < b.frame.min_y();
            }
            a.id < b.id
        };
        if less(a, b) {
            Ordering::Less
        } else if less(b, a) {
            Ordering::Greater
        } else {
            Ordering::Equal
        }
    });
    d
}

/// The single window's title, e.g. `Mac mini · 屏幕 2`.
pub fn desktop_title(computer: &str, number: i64) -> String {
    let screen = format!("屏幕 {number}");
    let name = computer.trim();
    if name.is_empty() {
        screen
    } else {
        format!("{name} · {screen}")
    }
}

/// The fixed window table of a desktop session: one undecorated full-display window that
/// cannot be moved, sized or closed.
pub fn desktop_table(width: f64, height: f64, title: &str) -> Vec<WindowInfo> {
    vec![WindowInfo {
        id: 1,
        parent: 0,
        kind: WindowKind::Normal,
        resizable: false,
        focused: true,
        rect: CanvasRect { x: 0.0, y: 0.0, w: width as f32, h: height as f32 },
        title_bar: 0.0,
        title: title.to_string(),
    }]
}

/// The `apps` entry for the desktop, `None` when A reports no display (Desktop.swift desktopEntry).
pub fn desktop_entry(displays: &[DesktopDisplay]) -> Option<Value> {
    if displays.is_empty() {
        return None;
    }
    let list: Vec<Value> = ordered_displays(displays.to_vec())
        .iter()
        .map(|d| {
            json!({
                "id": d.id.to_string(),
                "name": d.name,
                "main": d.main,
                "width": d.width(),
                "height": d.height(),
            })
        })
        .collect();
    Some(json!({ "app": DESKTOP_APP, "name": DESKTOP_APP_NAME, "displays": list }))
}
