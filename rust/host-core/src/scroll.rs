//! Scroll offset voting for the tile encoder, ported from `ScrollDetect.swift`.
//!
//! Finds likely vertical scroll offsets between the old picture (after the
//! canvas move) and the new frame, for `FrameEncoder` to try as copy sources.
//!
//! Rows are fingerprinted per 64 px column strip (the tile columns), so a
//! fixed side bar or scroll bar in some strips does not hide the scroll in the
//! others. Only strips with a changed tile that lie wholly inside the old
//! picture's columns are looked at. In each, every new row of a changed tile
//! whose fingerprint occurs in at most `MAX_REPEATS` old rows votes for
//! `dy = old_row - new_row` (`dy != 0`); rows of one colour do not vote. The
//! votes of all strips are added up. The offsets are only guesses: the
//! encoder checks every copy exactly.

use crate::tile::TILE_SIZE;

/// The part of the new canvas the old picture covers, in pixels. Signed:
/// after a big move `x1`/`y1` can be at or below `x0`/`y0` (nothing covered).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Cover {
    pub x0: isize,
    pub y0: isize,
    pub x1: isize,
    pub y1: isize,
}

#[derive(Debug, Default)]
pub struct ScrollDetector {
    // Open-addressing table from fingerprint to the old rows that have it.
    keys: Vec<u64>,
    counts: Vec<i32>,
    rows: Vec<i32>,
    votes: Vec<i32>,
}

impl ScrollDetector {
    /// A fingerprint seen in more old rows than this (repeated content) does not vote.
    pub const MAX_REPEATS: usize = 4;

    pub fn new() -> Self {
        Self::default()
    }

    /// Up to `limit` offsets with the most votes, most first.
    ///
    /// `cur` and `old` are planes of `width` x `height` pixels of `bpp` bytes
    /// with rows `width * bpp` bytes apart. `changed[ty * cols + tx]` says
    /// which tiles changed; `cover` is the part of the canvas the old picture
    /// covers (old rows outside it do not count).
    #[allow(clippy::too_many_arguments)]
    pub fn candidates(
        &mut self,
        cur: &[u8],
        old: &[u8],
        bpp: usize,
        width: usize,
        height: usize,
        changed: &[bool],
        cover: Cover,
        limit: usize,
    ) -> Vec<isize> {
        // Swift: `guard let curBase = cur.baseAddress, let oldBase = old.baseAddress` (an empty
        // array has no base address).
        if cur.is_empty() || old.is_empty() || cover.y1 <= cover.y0 || cover.x1 <= cover.x0 {
            return Vec::new();
        }
        let cols = width.div_ceil(TILE_SIZE);
        let tile_rows = height.div_ceil(TILE_SIZE);
        let stride = width * bpp;
        let mut capacity: usize = 1;
        while capacity < 2 * height {
            capacity <<= 1;
        }
        if self.keys.len() != capacity {
            self.keys = vec![0; capacity];
            self.counts = vec![0; capacity];
            self.rows = vec![0; capacity * Self::MAX_REPEATS];
        }
        self.votes = vec![0; 2 * height + 1];
        let mask = capacity - 1;
        let height_i = height as isize;

        for tx in 0..cols {
            let x0 = tx * TILE_SIZE;
            let tw = TILE_SIZE.min(width - x0);
            if !((x0 as isize) >= cover.x0 && (x0 + tw) as isize <= cover.x1) {
                continue;
            }
            if !(0..tile_rows).any(|ty| changed[ty * cols + tx]) {
                continue;
            }
            let n = tw * bpp;

            // The old rows of the strip, into the table.
            for c in self.counts.iter_mut() {
                *c = 0;
            }
            for y in cover.y0..cover.y1 {
                let y = y as usize;
                let f = Self::fingerprint(&old[y * stride + x0 * bpp..], n, bpp);
                if f == 0 {
                    continue;
                }
                // Swift: `Int(truncatingIfNeeded: f) & mask`; the mask keeps only low bits.
                let mut slot = (f as usize) & mask;
                while self.counts[slot] != 0 && self.keys[slot] != f {
                    slot = (slot + 1) & mask;
                }
                let c = self.counts[slot] as usize;
                self.keys[slot] = f;
                self.counts[slot] = (c + 1).min(Self::MAX_REPEATS + 1) as i32;
                if c < Self::MAX_REPEATS {
                    self.rows[slot * Self::MAX_REPEATS + c] = y as i32;
                }
            }

            // The new rows of the strip's changed tiles vote.
            for ty in 0..tile_rows {
                if !changed[ty * cols + tx] {
                    continue;
                }
                let y0 = ty * TILE_SIZE;
                for y in y0..height.min(y0 + TILE_SIZE) {
                    let f = Self::fingerprint(&cur[y * stride + x0 * bpp..], n, bpp);
                    if f == 0 {
                        continue;
                    }
                    let mut slot = (f as usize) & mask;
                    while self.counts[slot] != 0 && self.keys[slot] != f {
                        slot = (slot + 1) & mask;
                    }
                    let c = self.counts[slot] as usize;
                    if !(c > 0 && c <= Self::MAX_REPEATS) {
                        continue;
                    }
                    for k in 0..c {
                        let dy = self.rows[slot * Self::MAX_REPEATS + k] as isize - y as isize;
                        if dy != 0 {
                            self.votes[(dy + height_i) as usize] += 1;
                        }
                    }
                }
            }
        }

        // The `limit` best offsets: a strictly higher count goes first, ties keep the
        // smaller offset first (it was seen first).
        let mut best: Vec<(isize, i32)> = Vec::new();
        for (i, &v) in self.votes.iter().enumerate() {
            if v <= 0 {
                continue;
            }
            if best.len() == limit && v <= best[limit - 1].1 {
                continue;
            }
            let at = best.iter().position(|b| v > b.1).unwrap_or(best.len());
            best.insert(at, (i as isize - height_i, v));
            if best.len() > limit {
                best.pop();
            }
        }
        best.into_iter().map(|b| b.0).collect()
    }

    /// A 64-bit fingerprint of the first `n` bytes of `p`, never 0; 0 when every
    /// pixel (`bpp` bytes, `bpp` dividing 8) is the same.
    ///
    /// Swift reads the words with `loadUnaligned(as: UInt64.self)`, which is
    /// little-endian on every machine the host runs on; `from_le_bytes` matches it.
    #[inline(always)]
    pub fn fingerprint(p: &[u8], n: usize, bpp: usize) -> u64 {
        let k: u64 = 0x9E37_79B9_7F4A_7C15;
        let word = |i: usize| u64::from_le_bytes(p[i..i + 8].try_into().expect("8 bytes"));
        let mut first: u64 = 0;
        for (i, &b) in p[..bpp].iter().enumerate() {
            first |= (b as u64) << (8 * i as u64);
        }
        let pattern = if bpp == 1 {
            first.wrapping_mul(0x0101_0101_0101_0101)
        } else if bpp == 2 {
            first.wrapping_mul(0x0001_0001_0001_0001)
        } else {
            first.wrapping_mul(0x0000_0001_0000_0001)
        };
        let mut a: u64 = 0x243F_6A88_85A3_08D3;
        let mut b: u64 = 0x1319_8A2E_0370_7344;
        let mut c: u64 = 0xA409_3822_299F_31D0;
        let mut d: u64 = 0x082E_FA98_EC4E_6C89;
        let mut diff: u64 = 0;
        let mut i = 0;
        while i + 32 <= n {
            let w0 = word(i);
            let w1 = word(i + 8);
            let w2 = word(i + 16);
            let w3 = word(i + 24);
            a = (a ^ w0).wrapping_mul(k);
            b = (b ^ w1).wrapping_mul(k);
            c = (c ^ w2).wrapping_mul(k);
            d = (d ^ w3).wrapping_mul(k);
            diff |= (w0 ^ pattern) | (w1 ^ pattern) | (w2 ^ pattern) | (w3 ^ pattern);
            i += 32;
        }
        while i + 8 <= n {
            let w = word(i);
            a = (a ^ w).wrapping_mul(k);
            diff |= w ^ pattern;
            i += 8;
        }
        while i < n {
            // `i` is a multiple of 8 here plus whole pixels, so i % bpp is the byte within the pixel.
            let v = p[i] as u64;
            b = (b ^ v).wrapping_mul(k);
            // Swift: `v ^ (pattern >> UInt64(8 * (i % bpp)) & 0xFF)`; the shift binds tighter than `&`.
            diff |= v ^ ((pattern >> (8 * (i % bpp)) as u64) & 0xFF);
            i += 1;
        }
        if diff == 0 {
            return 0;
        }
        let mut h = a ^ b.rotate_left(17) ^ c.rotate_left(31) ^ d.rotate_left(47) ^ n as u64;
        h = (h ^ (h >> 33)).wrapping_mul(0xFF51_AFD7_ED55_8CCD);
        h = (h ^ (h >> 33)).wrapping_mul(0xC4CE_B9FE_1A85_EC53);
        h ^= h >> 33;
        h | 1
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn one_colour_rows_have_no_fingerprint() {
        assert_eq!(ScrollDetector::fingerprint(&[7u8; 64], 64, 1), 0);
        let two: Vec<u8> = [0x34u8, 0x12].repeat(40);
        assert_eq!(ScrollDetector::fingerprint(&two, 80, 2), 0);
        let four: Vec<u8> = [1u8, 2, 3, 4].repeat(17);
        assert_eq!(ScrollDetector::fingerprint(&four, 68, 4), 0);
        // One differing byte in the tail loop counts.
        let mut tail = vec![9u8; 13];
        tail[12] = 8;
        assert_ne!(ScrollDetector::fingerprint(&tail, 13, 1), 0);
    }

    #[test]
    fn fingerprints_are_odd_and_depend_on_length() {
        let row: Vec<u8> = (0..64u8).collect();
        let f = ScrollDetector::fingerprint(&row, 64, 1);
        assert_eq!(f & 1, 1);
        assert_ne!(f, ScrollDetector::fingerprint(&row, 63, 1));
    }

    #[test]
    fn a_scrolled_picture_votes_for_its_offset() {
        // 64 x 128 grey picture of distinct rows, scrolled up by 5 rows.
        let (w, h) = (64usize, 128usize);
        let row = |y: usize| -> Vec<u8> { (0..w).map(|x| ((x * 7 + y * 13 + (x ^ y)) % 251) as u8).collect() };
        let old: Vec<u8> = (0..h).flat_map(row).collect();
        let cur: Vec<u8> = (0..h).flat_map(|y| row(y + 5)).collect();
        let mut d = ScrollDetector::new();
        let cover = Cover { x0: 0, y0: 0, x1: w as isize, y1: h as isize };
        let got = d.candidates(&cur, &old, 1, w, h, &[true, true], cover, 3);
        assert_eq!(got.first(), Some(&5));
    }
}
