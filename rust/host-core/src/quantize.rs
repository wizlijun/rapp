//! Reduces captured BGRA pixels to the samples of a `Mode`, ported from
//! `Sources/RappCore/Quantize.swift` (`Quantizer.quantize` and its helpers).
//! Every integer step is Swift's: `Int` is 64-bit there, so the arithmetic is
//! done in `i64`, and Swift's `/` truncates toward zero like Rust's.
//! `Quantizer.expand` (the viewer's direction) is not needed by the host and
//! is not ported.

use crate::protocol::Mode;

/// Side of the square blocks the two-tone modes work on (Quantize.swift `duoBlock`).
pub const DUO_BLOCK: usize = 16;

#[inline(always)]
fn luma(r: i64, g: i64, b: i64) -> i64 {
    (77 * r + 150 * g + 29 * b) >> 8
}

/// Writes the sample for one pixel at `dst[o]` (two bytes for color16 and duocolor).
#[inline(always)]
fn store(r: i64, g: i64, b: i64, mode: Mode, dst: &mut [u8], o: usize) {
    match mode {
        Mode::Gray4 | Mode::Duogray => {
            dst[o] = ((luma(r, g, b) * 15 + 127) / 255) as u8;
        }
        Mode::Color8 => {
            let mx = r.max(g.max(b));
            let mn = r.min(g.min(b));
            if mx - mn < 16 {
                dst[o] = (216 + (luma(r, g, b) * 39 + 127) / 255) as u8;
            } else {
                let ri = (r * 5 + 127) / 255;
                let gi = (g * 5 + 127) / 255;
                let bi = (b * 5 + 127) / 255;
                dst[o] = (ri * 36 + gi * 6 + bi) as u8;
            }
        }
        Mode::Color16 | Mode::Duocolor => {
            let s = (r >> 3) << 11 | (g >> 2) << 5 | (b >> 3);
            dst[o] = (s & 0xFF) as u8;
            dst[o + 1] = (s >> 8) as u8;
        }
    }
}

/// Reduces a BGRA image to samples. `bgra` holds B, G, R, A bytes with
/// `bytes_per_row` bytes per row (rows may be padded). The result has
/// `width * height * mode.bytes_per_sample()` bytes, row by row.
///
/// Rounded window corners: fully transparent pixels (alpha 0) before a row's
/// first visible pixel take that pixel's sample, and likewise after the last
/// visible one. A row with no visible pixel copies the row above (white for
/// the first row). Partly transparent pixels are kept, un-premultiplied.
///
/// Two-tone modes apply the same corner rule to the colours first, then reduce
/// every 16×16 block to two base tones plus two blend levels between them.
///
/// Panics, like Swift's `precondition`, when the buffer is too small for the
/// stated size: that is a platform bug, not peer input (the caller checks).
pub fn quantize(bgra: &[u8], width: usize, height: usize, bytes_per_row: usize, mode: Mode) -> Vec<u8> {
    // Swift: bytesPerRow >= width * 4 && bgra.count >= (height - 1) * bytesPerRow + width * 4,
    // in signed Int (so height 0 passes whatever the buffer).
    let needed = (height as i128 - 1) * bytes_per_row as i128 + width as i128 * 4;
    assert!(
        bytes_per_row >= width * 4 && bgra.len() as i128 >= needed,
        "pixel buffer too small"
    );
    if width == 0 || height == 0 {
        return vec![0u8; width * height * mode.bytes_per_sample()];
    }
    match mode {
        Mode::Gray4 | Mode::Color8 | Mode::Color16 => {
            corner_filled(bgra, width, height, bytes_per_row, mode.bytes_per_sample(), |r, g, b, dst, o| {
                store(r, g, b, mode, dst, o)
            })
        }
        Mode::Duogray | Mode::Duocolor => {
            let rgb = corner_filled(bgra, width, height, bytes_per_row, 3, |r, g, b, dst, o| {
                dst[o] = r as u8;
                dst[o + 1] = g as u8;
                dst[o + 2] = b as u8;
            });
            two_tone(&rgb, width, height, mode)
        }
    }
}

/// The per-row corner rule, writing `bps` bytes per pixel through `put`
/// (Quantize.swift `cornerFilled`).
#[inline(always)]
fn corner_filled<F>(bgra: &[u8], width: usize, height: usize, bytes_per_row: usize, bps: usize, put: F) -> Vec<u8>
where
    F: Fn(i64, i64, i64, &mut [u8], usize),
{
    let row_samples = width * bps;
    let mut dst = vec![0u8; width * height * bps];
    for y in 0..height {
        let row = y * bytes_per_row;
        let row_out = y * row_samples;
        let mut first = 0usize;
        while first < width && bgra[row + first * 4 + 3] == 0 {
            first += 1;
        }
        if first == width {
            if y == 0 {
                put(255, 255, 255, &mut dst, 0);
                for x in 1..width {
                    for k in 0..bps {
                        dst[x * bps + k] = dst[k];
                    }
                }
            } else {
                for k in 0..row_samples {
                    dst[row_out + k] = dst[row_out - row_samples + k];
                }
            }
            continue;
        }
        let mut last = width - 1;
        while bgra[row + last * 4 + 3] == 0 {
            last -= 1;
        }
        let mut i = row + first * 4;
        for x in first..=last {
            let a = bgra[i + 3] as i64;
            if a == 255 || a == 0 {
                put(bgra[i + 2] as i64, bgra[i + 1] as i64, bgra[i] as i64, &mut dst, row_out + x * bps);
            } else {
                // Capture pixels are premultiplied: recover the colour itself.
                put(
                    255.min((bgra[i + 2] as i64 * 255 + a / 2) / a),
                    255.min((bgra[i + 1] as i64 * 255 + a / 2) / a),
                    255.min((bgra[i] as i64 * 255 + a / 2) / a),
                    &mut dst,
                    row_out + x * bps,
                );
            }
            i += 4;
        }
        for x in 0..first {
            for k in 0..bps {
                dst[row_out + x * bps + k] = dst[row_out + first * bps + k];
            }
        }
        if last + 1 < width {
            for x in (last + 1)..width {
                for k in 0..bps {
                    dst[row_out + x * bps + k] = dst[row_out + last * bps + k];
                }
            }
        }
    }
    dst
}

/// Two brightness groups per block from packed RGB (3 bytes per pixel)
/// (Quantize.swift `twoTone`).
fn two_tone(rgb: &[u8], width: usize, height: usize, mode: Mode) -> Vec<u8> {
    let bps = mode.bytes_per_sample();
    let n = DUO_BLOCK;
    let mut dst = vec![0u8; width * height * bps];
    let mut lum = vec![0i64; n * n];
    let src = rgb;
    for by in (0..height).step_by(n) {
        let bh = n.min(height - by);
        for bx in (0..width).step_by(n) {
            let bw = n.min(width - bx);
            let mut lo: i64 = 255;
            let mut hi: i64 = 0;
            for y in 0..bh {
                let mut i = ((by + y) * width + bx) * 3;
                for x in 0..bw {
                    let l = luma(src[i] as i64, src[i + 1] as i64, src[i + 2] as i64);
                    lum[y * n + x] = l;
                    lo = lo.min(l);
                    hi = hi.max(l);
                    i += 3;
                }
            }
            // Two base tones: the mean colour of the darkest eighth of the brightness
            // range and of the lightest eighth; a block spanning less than 24 levels
            // gets its mean colour.
            let mut sum = [0i64; 6];
            let mut cnt = [0i64; 2];
            let split = hi - lo >= 24;
            let q = (hi - lo) / 8;
            for y in 0..bh {
                let mut i = ((by + y) * width + bx) * 3;
                for x in 0..bw {
                    let l = lum[y * n + x];
                    // Swift: `!split || l <= lo + q ? 0 : l >= hi - q ? 1 : -1`
                    let g: i64 = if !split || l <= lo + q {
                        0
                    } else if l >= hi - q {
                        1
                    } else {
                        -1
                    };
                    if g >= 0 {
                        let g = g as usize;
                        sum[g * 3] += src[i] as i64;
                        sum[g * 3 + 1] += src[i + 1] as i64;
                        sum[g * 3 + 2] += src[i + 2] as i64;
                        cnt[g] += 1;
                    }
                    i += 3;
                }
            }
            let levels = if split { 4 } else { 1 };
            let d = [sum[0] / cnt[0], sum[1] / cnt[0], sum[2] / cnt[0]];
            let lt = if split { [sum[3] / cnt[1], sum[4] / cnt[1], sum[5] / cnt[1]] } else { d };
            let ld = luma(d[0], d[1], d[2]);
            let span = 1i64.max(luma(lt[0], lt[1], lt[2]) - ld);
            let mut tone = [0u8; 8];
            for k in 0..levels {
                let mix = |c: usize| d[c] + ((lt[c] - d[c]) * k * 2 + 3) / 6;
                store(mix(0), mix(1), mix(2), mode, &mut tone, k as usize * bps);
            }
            for y in 0..bh {
                for x in 0..bw {
                    let k = if split { 3i64.min(0i64.max(((lum[y * n + x] - ld) * 6 + span) / (span * 2))) } else { 0 };
                    let o = ((by + y) * width + bx + x) * bps;
                    let k = k as usize;
                    dst[o..o + bps].copy_from_slice(&tone[k * bps..k * bps + bps]);
                }
            }
        }
    }
    dst
}

#[cfg(test)]
mod tests {
    use super::*;

    fn q(r: u8, g: u8, b: u8, mode: Mode) -> Vec<u8> {
        quantize(&[b, g, r, 255], 1, 1, 4, mode)
    }

    /// Rows of (R, G, B, A) pixels to BGRA.
    fn img(rows: &[&[(u8, u8, u8, u8)]]) -> Vec<u8> {
        rows.iter().flat_map(|r| r.iter().flat_map(|p| [p.2, p.1, p.0, p.3])).collect()
    }

    #[test]
    fn corner_fill_left_and_right() {
        let px = img(&[&[(0, 0, 0, 0), (0, 0, 0, 0), (255, 255, 255, 255), (0, 0, 0, 255), (0, 0, 0, 0)]]);
        assert_eq!(quantize(&px, 5, 1, 20, Mode::Gray4), vec![15, 15, 15, 0, 0]);
    }

    #[test]
    fn transparent_rows() {
        let px = img(&[&[(0, 0, 0, 255), (255, 255, 255, 255)], &[(0, 0, 0, 0), (0, 0, 0, 0)]]);
        assert_eq!(quantize(&px, 2, 2, 8, Mode::Gray4), vec![0, 15, 0, 15]);
        let px = img(&[&[(0, 0, 0, 0), (0, 0, 0, 0)], &[(0, 0, 0, 255), (0, 0, 0, 255)]]);
        assert_eq!(quantize(&px, 2, 2, 8, Mode::Gray4), vec![15, 15, 0, 0]);
    }

    #[test]
    fn unpremultiplies() {
        let px = img(&[&[(255, 255, 255, 255), (64, 64, 64, 128), (255, 255, 255, 255)]]);
        assert_eq!(quantize(&px, 3, 1, 12, Mode::Gray4), vec![15, 8, 15]);
    }

    #[test]
    fn single_pixels() {
        assert_eq!(q(255, 255, 255, Mode::Gray4), vec![15]);
        assert_eq!(q(128, 128, 128, Mode::Gray4), vec![8]);
        assert_eq!(q(255, 0, 0, Mode::Color8), vec![180]);
        assert_eq!(q(128, 128, 128, Mode::Color8), vec![236]);
        assert_eq!(q(0, 0, 0, Mode::Color8), vec![216]);
        assert_eq!(q(255, 0, 0, Mode::Color16), vec![0x00, 0xF8]);
        assert_eq!(q(8, 4, 8, Mode::Color16), vec![0x21, 0x08]);
    }

    #[test]
    fn row_padding_is_skipped() {
        let mut bgra = Vec::new();
        bgra.extend_from_slice(&[255, 255, 255, 255, 0, 0, 0, 255, 0x7F, 0x7F, 0x7F, 0x7F]);
        bgra.extend_from_slice(&[0, 0, 0, 255, 255, 255, 255, 255, 0x7F, 0x7F, 0x7F, 0x7F]);
        assert_eq!(quantize(&bgra, 2, 2, 12, Mode::Gray4), vec![15, 0, 0, 15]);
    }

    #[test]
    fn empty_sizes() {
        assert!(quantize(&[], 0, 5, 0, Mode::Color16).is_empty());
        assert!(quantize(&[], 7, 0, 28, Mode::Duogray).is_empty());
    }
}
