//! Points, sizes and rects as CoreGraphics has them, plus the coordinate helpers the
//! host uses (`Sources/RappCore/Geometry.swift`, `windowTitle` from `Protocol.swift:760`).
//!
//! `Rect` follows `CGRect`: `x`/`y` are the origin, `width`/`height` may in principle be
//! negative (CoreGraphics then standardises), and "no rect" (`CGRect.null`) is `None`
//! wherever Swift can produce it.

use serde::{Deserialize, Serialize};
use unicode_segmentation::UnicodeSegmentation;

#[derive(Debug, Clone, Copy, PartialEq, Default, Serialize, Deserialize)]
pub struct Point {
    pub x: f64,
    pub y: f64,
}

#[derive(Debug, Clone, Copy, PartialEq, Default, Serialize, Deserialize)]
pub struct Size {
    pub width: f64,
    pub height: f64,
}

#[derive(Debug, Clone, Copy, PartialEq, Default, Serialize, Deserialize)]
pub struct Rect {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

impl Point {
    pub const fn new(x: f64, y: f64) -> Self {
        Point { x, y }
    }
}

impl Size {
    pub const fn new(width: f64, height: f64) -> Self {
        Size { width, height }
    }
}

/// Swift's `max(a, b)`: `b >= a ? b : a`. Not `f64::max`, which differs on signed zeros.
pub(crate) fn swift_max<T: PartialOrd + Copy>(a: T, b: T) -> T {
    if b >= a {
        b
    } else {
        a
    }
}

/// Swift's `min(a, b)`: `b < a ? b : a`.
pub(crate) fn swift_min<T: PartialOrd + Copy>(a: T, b: T) -> T {
    if b < a {
        b
    } else {
        a
    }
}

impl Rect {
    pub const fn new(x: f64, y: f64, width: f64, height: f64) -> Self {
        Rect { x, y, width, height }
    }

    pub const ZERO: Rect = Rect::new(0.0, 0.0, 0.0, 0.0);

    pub fn min_x(&self) -> f64 {
        if self.width < 0.0 {
            self.x + self.width
        } else {
            self.x
        }
    }
    pub fn min_y(&self) -> f64 {
        if self.height < 0.0 {
            self.y + self.height
        } else {
            self.y
        }
    }
    pub fn max_x(&self) -> f64 {
        if self.width < 0.0 {
            self.x
        } else {
            self.x + self.width
        }
    }
    pub fn max_y(&self) -> f64 {
        if self.height < 0.0 {
            self.y
        } else {
            self.y + self.height
        }
    }
    /// `CGRect.width` is the standardised (non-negative) width.
    pub fn w(&self) -> f64 {
        self.width.abs()
    }
    /// `CGRect.height` is the standardised (non-negative) height.
    pub fn h(&self) -> f64 {
        self.height.abs()
    }
    pub fn mid_x(&self) -> f64 {
        self.min_x() + self.w() / 2.0
    }
    pub fn mid_y(&self) -> f64 {
        self.min_y() + self.h() / 2.0
    }
    pub fn origin(&self) -> Point {
        Point::new(self.x, self.y)
    }

    /// `CGRect.isEmpty`: no area.
    pub fn is_empty(&self) -> bool {
        self.width == 0.0 || self.height == 0.0
    }

    /// `CGRect.contains(CGPoint)`: half open, the max edges are outside.
    pub fn contains_point(&self, p: Point) -> bool {
        p.x >= self.min_x() && p.x < self.max_x() && p.y >= self.min_y() && p.y < self.max_y()
    }

    /// `CGRect.intersection`: `None` (Swift's `.null`) when they do not meet; rects that only
    /// touch give a zero-width or zero-height rect, as CoreGraphics does.
    pub fn intersection(&self, other: &Rect) -> Option<Rect> {
        let x1 = swift_max(self.min_x(), other.min_x());
        let y1 = swift_max(self.min_y(), other.min_y());
        let x2 = swift_min(self.max_x(), other.max_x());
        let y2 = swift_min(self.max_y(), other.max_y());
        if x1 > x2 || y1 > y2 {
            return None;
        }
        Some(Rect::new(x1, y1, x2 - x1, y2 - y1))
    }

    /// `CGRect.union` of two real rects.
    pub fn union(&self, other: &Rect) -> Rect {
        let x1 = swift_min(self.min_x(), other.min_x());
        let y1 = swift_min(self.min_y(), other.min_y());
        let x2 = swift_max(self.max_x(), other.max_x());
        let y2 = swift_max(self.max_y(), other.max_y());
        Rect::new(x1, y1, x2 - x1, y2 - y1)
    }

    /// `CGRect.contains(CGRect)`: the other rect lies wholly inside (edges included).
    pub fn contains_rect(&self, other: &Rect) -> bool {
        other.min_x() >= self.min_x()
            && other.min_y() >= self.min_y()
            && other.max_x() <= self.max_x()
            && other.max_y() <= self.max_y()
    }
}

/// `union` where either side may be `CGRect.null`.
pub fn union_opt(a: Option<Rect>, b: Option<Rect>) -> Option<Rect> {
    match (a, b) {
        (None, b) => b,
        (a, None) => a,
        (Some(a), Some(b)) => Some(a.union(&b)),
    }
}

/// A point given as a fraction of `window_frame` (0...1 each way, clamped) in global
/// coordinates; never past the last pixel row or column (Geometry.swift:21).
pub fn global_point(x: f32, y: f32, window_frame: Rect) -> Point {
    let nx = swift_min(swift_max(x, 0.0), 1.0) as f64;
    let ny = swift_min(swift_max(y, 0.0), 1.0) as f64;
    Point::new(
        swift_min(window_frame.min_x() + nx * window_frame.w(), window_frame.max_x() - 1.0),
        swift_min(window_frame.min_y() + ny * window_frame.h(), window_frame.max_y() - 1.0),
    )
}

/// Limits a requested window size so a window whose top-left stays at `origin` does not
/// extend past the screen, and is at least 100 x 100 (Geometry.swift:29).
pub fn clamp_size(requested: Size, origin: Point, screen: Rect) -> Size {
    Size::new(
        swift_max(100.0, swift_min(requested.width, screen.max_x() - origin.x)),
        swift_max(100.0, swift_min(requested.height, screen.max_y() - origin.y)),
    )
}

/// Splits text into runs of at most `max` UTF-16 units without separating a surrogate
/// pair (Geometry.swift:35). Callers pass 20.
///
/// Swift loops forever on `max == 0`; this port treats 0 as 1.
pub fn chunk_utf16(s: &str, max: usize) -> Vec<Vec<u16>> {
    let max = max.max(1);
    let units: Vec<u16> = s.encode_utf16().collect();
    let mut chunks = Vec::new();
    let mut start = 0usize;
    while start < units.len() {
        let mut end = swift_min(start.saturating_add(max), units.len());
        if end < units.len() && end - start > 1 && (0xD800..=0xDBFF).contains(&units[end - 1]) {
            end -= 1;
        }
        chunks.push(units[start..end].to_vec());
        start = end;
    }
    chunks
}

/// The window size that gives `for_content` below a title row of `title_row`, clamped as
/// `clamp_size` does (Geometry.swift:95).
pub fn window_size(for_content: Size, title_row: f64, origin: Point, screen: Rect) -> Size {
    clamp_size(Size::new(for_content.width, for_content.height + title_row), origin, screen)
}

/// The title shown on the client: the window's title, or the app's name when the window has
/// none, at most 200 characters (grapheme clusters) (Protocol.swift:760).
pub fn window_title(raw: Option<&str>, app_name: Option<&str>) -> String {
    let raw = raw.filter(|r| !r.is_empty());
    let title = raw.or(app_name).unwrap_or("rApp");
    title.graphemes(true).take(200).collect()
}
