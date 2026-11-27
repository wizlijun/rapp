//! Rule 2 and the coordinate helpers of the focus pane (`Sources/RappCore/FocusPane.swift`).
//! `EncodeReport` is the tile encoder's (`crate::tile`); Swift keeps it in this file.

use crate::geometry::{swift_min, Point, Rect, Size};
use crate::protocol::CanvasRect;
use crate::tile::{EncodeReport, TILE_SIZE};

/// Why no panel was picked. `name` is Swift's raw value.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum PanelMiss {
    Small,
    Large,
    Blocked,
}

impl PanelMiss {
    pub fn name(self) -> &'static str {
        match self {
            PanelMiss::Small => "small",
            PanelMiss::Large => "large",
            PanelMiss::Blocked => "blocked",
        }
    }

    pub fn from_name(name: &str) -> Option<PanelMiss> {
        match name {
            "small" => Some(PanelMiss::Small),
            "large" => Some(PanelMiss::Large),
            "blocked" => Some(PanelMiss::Blocked),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct PanelPick {
    pub rect: Rect,
    pub depth: i64,
    pub share: f64,
}

/// One frame's tiles, in window points.
#[derive(Debug, Clone, PartialEq)]
pub struct WindowTiles {
    /// A tile belongs to the window when its centre is inside.
    pub changed: Vec<Rect>,
    /// Tiles whose centre is inside the window.
    pub total: i64,
    /// Intersected with the window.
    pub copy_bounds: Option<Rect>,
    pub full: bool,
}

pub const MAX_DEPTH: usize = 40;
pub const MIN_SHARE: f64 = 0.15;
pub const MAX_SHARE: f64 = 0.85;
pub const MIN_WIDTH: f64 = 240.0;
pub const MIN_HEIGHT: f64 = 160.0;

/// Rule 2: pick the panel containing the focused control. `chain`: rects in window points,
/// the start control first, then each parent. Only the first 40 layers are looked at; each
/// is intersected with (0,0,window) first. Among layers with share < 0.85 the largest wins
/// (ties: the outer layer). No such layer: `Large`. The pick is `Small` if share < 0.15,
/// width < 240 or height < 160. An empty chain is `Small`. `depth` is the index in `chain`.
pub fn panel(chain: &[Rect], window: Size) -> Result<PanelPick, PanelMiss> {
    if chain.is_empty() {
        return Err(PanelMiss::Small);
    }
    let bounds = Rect::new(0.0, 0.0, window.width, window.height);
    let area = window.width * window.height;
    if !(area > 0.0) {
        return Err(PanelMiss::Small);
    }
    let mut best: Option<PanelPick> = None;
    for (i, raw) in chain.iter().take(MAX_DEPTH).enumerate() {
        let r = raw.intersection(&bounds);
        let share = match r {
            None => 0.0,
            Some(r) => r.w() * r.h() / area,
        };
        if share >= MAX_SHARE {
            continue;
        }
        if best.is_none_or(|b| share >= b.share) {
            best = Some(PanelPick { rect: r.unwrap_or(Rect::ZERO), depth: i as i64, share });
        }
    }
    let Some(p) = best else { return Err(PanelMiss::Large) };
    if p.share < MIN_SHARE || p.rect.w() < MIN_WIDTH || p.rect.h() < MIN_HEIGHT {
        return Err(PanelMiss::Small);
    }
    Ok(p)
}

/// A global accessibility rect in window points (title bar included, like `mouse`).
pub fn window_rect(global: Rect, display: Rect, window: CanvasRect) -> Rect {
    Rect::new(
        global.min_x() - display.min_x() - f64::from(window.x),
        global.min_y() - display.min_y() - f64::from(window.y),
        global.w(),
        global.h(),
    )
}

/// The report's tiles and copy box in the window's points.
pub fn window_tiles(r: &EncodeReport, window: CanvasRect) -> WindowTiles {
    let full = r.full;
    if !(r.width > 0 && r.height > 0 && r.region.w > 0.0 && r.region.h > 0.0) {
        return WindowTiles { changed: Vec::new(), total: 0, copy_bounds: None, full };
    }
    let sx = r.width as f64 / f64::from(r.region.w);
    let sy = r.height as f64 / f64::from(r.region.h);
    let ox = f64::from(r.region.x) - f64::from(window.x);
    let oy = f64::from(r.region.y) - f64::from(window.y);
    let bounds = Rect::new(0.0, 0.0, f64::from(window.w), f64::from(window.h));
    let ts = TILE_SIZE;
    let cols = r.width.div_ceil(ts);
    let rows = r.height.div_ceil(ts);
    let tile_rect = |tx: usize, ty: usize| -> Rect {
        let x0 = tx * ts;
        let y0 = ty * ts;
        let tw = swift_min(ts, r.width - x0);
        let th = swift_min(ts, r.height - y0);
        Rect::new(ox + x0 as f64 / sx, oy + y0 as f64 / sy, tw as f64 / sx, th as f64 / sy)
    };
    let inside = |t: &Rect| bounds.contains_point(Point::new(t.mid_x(), t.mid_y()));
    let mut total: i64 = 0;
    for ty in 0..rows {
        for tx in 0..cols {
            if inside(&tile_rect(tx, ty)) {
                total += 1;
            }
        }
    }
    let mut changed = Vec::new();
    for &i in &r.changed {
        if i < cols * rows {
            let t = tile_rect(i % cols, i / cols);
            if inside(&t) {
                changed.push(t);
            }
        }
    }
    let mut copy_bounds = None;
    if let Some(c) = r.copy_bounds {
        let w = Rect::new(ox + c.min_x() / sx, oy + c.min_y() / sy, c.w() / sx, c.h() / sy);
        if let Some(i) = w.intersection(&bounds) {
            if i.w() > 0.0 && i.h() > 0.0 {
                copy_bounds = Some(i);
            }
        }
    }
    WindowTiles { changed, total, copy_bounds, full }
}
