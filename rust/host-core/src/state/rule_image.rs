//! The frame the rules look at, and the colour helpers (`StateRules/RuleImage.swift`).

use crate::geometry::{swift_max, swift_min};

/// A rectangle in image points, y down.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord, Default)]
pub struct RuleRect {
    pub x: i64,
    pub y: i64,
    pub w: i64,
    pub h: i64,
}

impl RuleRect {
    pub const fn new(x: i64, y: i64, w: i64, h: i64) -> Self {
        RuleRect { x, y, w, h }
    }
    /// Swift's `x + w` traps on overflow; the rect values here come from images and clamped
    /// numbers, so plain addition is kept (a debug build panics like Swift).
    pub fn max_x(&self) -> i64 {
        self.x + self.w
    }
    pub fn max_y(&self) -> i64 {
        self.y + self.h
    }
}

/// A frame sampled at one pixel per point. BGRA, `width * 4` bytes per row.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct RuleImage {
    pub width: usize,
    pub height: usize,
    pub pixels: Vec<u8>,
}

/// Cap on the sampled image so a hostile or buggy `scale` cannot ask for gigabytes.
pub(crate) const MAX_SAMPLE_PIXELS: usize = 64 * 1024 * 1024;

impl RuleImage {
    pub fn new(width: usize, height: usize, pixels: Vec<u8>) -> Self {
        RuleImage { width, height, pixels }
    }

    /// Crops `crop` (pixels of the source) and scales it to one pixel per point by nearest
    /// neighbour: each point takes the top-left pixel of its `scale` x `scale` cell. Returns
    /// `None` when `crop` is empty or leaves the source, when `scale` is not a positive finite
    /// number, or when the buffer is too short for the stated geometry.
    pub fn sample(
        bgra: &[u8],
        width: usize,
        height: usize,
        bytes_per_row: usize,
        crop: RuleRect,
        scale: f64,
    ) -> Option<RuleImage> {
        let (wi, hi) = (width as i64, height as i64);
        // Swift's `width * 4` and `(height - 1) * bytesPerRow + width * 4` trap on overflow;
        // checked arithmetic turns that into "too short" here.
        let need = (height.checked_sub(1)?).checked_mul(bytes_per_row)?.checked_add(width.checked_mul(4)?)?;
        if !(width > 0
            && height > 0
            && bytes_per_row >= width.checked_mul(4)?
            && scale.is_finite()
            && scale > 0.0
            && crop.w > 0
            && crop.h > 0
            && crop.x >= 0
            && crop.y >= 0
            && crop.x <= wi - crop.w
            && crop.y <= hi - crop.h
            && bgra.len() >= need)
        {
            return None;
        }
        // A tiny scale makes the quotient overflow; clamp before converting.
        let cap = MAX_SAMPLE_PIXELS as f64;
        let dw = swift_max(1i64, swift_min(cap, (crop.w as f64 / scale).floor()) as i64) as usize;
        let dh = swift_max(1i64, swift_min(cap, (crop.h as f64 / scale).floor()) as i64) as usize;
        if dw > MAX_SAMPLE_PIXELS / dh {
            return None;
        }
        let mut out = vec![0u8; dw * dh * 4];
        // Source columns are the same for every row.
        let mut cols = vec![0usize; dw];
        for (dx, c) in cols.iter_mut().enumerate() {
            *c = (crop.x + swift_min(crop.w - 1, ((dx as f64) * scale).floor() as i64)) as usize;
        }
        for dy in 0..dh {
            let sy = (crop.y + swift_min(crop.h - 1, ((dy as f64) * scale).floor() as i64)) as usize;
            let row = sy * bytes_per_row;
            let mut o = dy * dw * 4;
            for &col in &cols {
                let p = row + col * 4;
                out[o..o + 4].copy_from_slice(&bgra[p..p + 4]);
                o += 4;
            }
        }
        Some(RuleImage { width: dw, height: dh, pixels: out })
    }

    /// Caller keeps `x`, `y` inside the image. Returns `(r, g, b)`.
    pub fn rgb(&self, x: i64, y: i64) -> (u8, u8, u8) {
        let i = ((y * self.width as i64 + x) * 4) as usize;
        (self.pixels[i + 2], self.pixels[i + 1], self.pixels[i])
    }
}

/// `h` 0..<360, `s`/`l` 0...100.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Hsl {
    pub h: f64,
    pub s: f64,
    pub l: f64,
}

/// Swift's three-argument `max`/`min` fold left with the two-argument ones.
fn max3(a: f64, b: f64, c: f64) -> f64 {
    swift_max(swift_max(a, b), c)
}
fn min3(a: f64, b: f64, c: f64) -> f64 {
    swift_min(swift_min(a, b), c)
}

pub fn hsl(r: u8, g: u8, b: u8) -> Hsl {
    let rf = r as f64 / 255.0;
    let gf = g as f64 / 255.0;
    let bf = b as f64 / 255.0;
    let hi = max3(rf, gf, bf);
    let lo = min3(rf, gf, bf);
    let d = hi - lo;
    let l = (hi + lo) / 2.0;
    if d == 0.0 {
        return Hsl { h: 0.0, s: 0.0, l: l * 100.0 };
    }
    let s = d / (1.0 - (2.0 * l - 1.0).abs());
    let mut h: f64;
    if hi == rf {
        h = (gf - bf) / d;
        if h < 0.0 {
            h += 6.0;
        }
    } else if hi == gf {
        h = (bf - rf) / d + 2.0;
    } else {
        h = (rf - gf) / d + 4.0;
    }
    h *= 60.0;
    if h >= 360.0 {
        h -= 360.0;
    }
    Hsl { h, s: swift_min(100.0, s * 100.0), l: l * 100.0 }
}

/// Largest per-channel difference.
pub fn color_distance(a: (u8, u8, u8), b: (u8, u8, u8)) -> i64 {
    let dr = (a.0 as i64 - b.0 as i64).abs();
    let dg = (a.1 as i64 - b.1 as i64).abs();
    let db = (a.2 as i64 - b.2 as i64).abs();
    swift_max(swift_max(dr, dg), db)
}

/// Edge: a column differs from the reference by this much.
pub const REGION_CONTRAST: i64 = 10;
/// Blob / shape foreground threshold.
pub const BLOB_CONTRAST: i64 = 24;
