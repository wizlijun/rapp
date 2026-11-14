//! Swift TileCodec-compatible persistent zlib decoding. Full frames reset the dictionary.
use crate::protocol::Reader;
use anyhow::{bail, ensure, Result};
use flate2::{Decompress, FlushDecompress, Status};

pub const FULL: u8 = 1;
pub const START: u8 = 2;
pub const END: u8 = 4;
pub const COPIES: u8 = 8;
const KIND_COPY: u8 = 5;

/// Mirrors the Swift `FrameDecoder` state machine; see Sources/RappCore/TileCodec.swift.
pub struct Decoder {
    z: Decompress,
    pub width: usize,
    pub height: usize,
    mode: u8,
    samples: Vec<u16>,
    open: bool,
    hold: bool,
    shown: bool,
    reference: Option<Vec<u16>>,
}
impl Default for Decoder {
    fn default() -> Self {
        Self {
            z: Decompress::new(true),
            width: 0,
            height: 0,
            mode: 0,
            samples: Vec::new(),
            open: false,
            hold: false,
            shown: false,
            reference: None,
        }
    }
}
/// new(x, y) = old(x + dx, y + dy) in a w x h canvas; anything outside the old one is 0.
fn moved_canvas(
    src: &[u16],
    width: usize,
    height: usize,
    w: usize,
    h: usize,
    dx: i32,
    dy: i32,
) -> Vec<u16> {
    let mut moved = vec![0; w * h];
    let (dx, dy) = (dx as i64, dy as i64);
    let x0 = 0.max(-dx);
    let x1 = (w as i64).min(width as i64 - dx);
    let y0 = 0.max(-dy);
    let y1 = (h as i64).min(height as i64 - dy);
    if x1 <= x0 || y1 <= y0 {
        return moved;
    }
    let n = (x1 - x0) as usize;
    for y in y0..y1 {
        let from = ((y + dy) as usize) * width + (x0 + dx) as usize;
        let to = y as usize * w + x0 as usize;
        moved[to..to + n].copy_from_slice(&src[from..from + n]);
    }
    moved
}
impl Decoder {
    /// `None`: the picture is not to be shown yet (nothing was expanded).
    #[allow(clippy::too_many_arguments)]
    pub fn decode(
        &mut self,
        mode: u8,
        w: usize,
        h: usize,
        flags: u8,
        dx: i32,
        dy: i32,
        compressed: &[u8],
    ) -> Result<Option<Vec<u8>>> {
        let mut pixels = Vec::new();
        Ok(self
            .decode_into(mode, w, h, flags, dx, dy, compressed, &mut pixels)?
            .then_some(pixels))
    }
    /// Decodes one slice; true when `pixels` now holds the canvas to show. After an error
    /// the canvas is emptied and only a full frame resumes decoding.
    #[allow(clippy::too_many_arguments)]
    pub fn decode_into(
        &mut self,
        mode: u8,
        w: usize,
        h: usize,
        flags: u8,
        dx: i32,
        dy: i32,
        compressed: &[u8],
        pixels: &mut Vec<u8>,
    ) -> Result<bool> {
        match self.decode_slice(mode, w, h, flags, dx, dy, compressed) {
            Ok(true) => {
                pixels.resize(self.samples.len() * 4, 0);
                for (pixel, sample) in pixels.as_chunks_mut::<4>().0.iter_mut().zip(&self.samples) {
                    pixel.copy_from_slice(&bgra(self.mode, *sample));
                }
                Ok(true)
            }
            Ok(false) => Ok(false),
            Err(e) => {
                self.open = false;
                self.hold = false;
                self.reference = None;
                self.width = 0;
                self.height = 0;
                self.samples = Vec::new();
                Err(e)
            }
        }
    }
    /// The canvas as the Swift `FrameDecoder.samples`: 1 or 2 bytes per sample, little-endian.
    pub fn samples_le(&self) -> Vec<u8> {
        if self.mode == 2 || self.mode == 4 {
            self.samples.iter().flat_map(|s| s.to_le_bytes()).collect()
        } else {
            self.samples.iter().map(|s| *s as u8).collect()
        }
    }
    #[allow(clippy::too_many_arguments)]
    fn decode_slice(
        &mut self,
        mode: u8,
        w: usize,
        h: usize,
        flags: u8,
        dx: i32,
        dy: i32,
        compressed: &[u8],
    ) -> Result<bool> {
        ensure!(flags & 0xF0 == 0, "unknown frame flags");
        ensure!(flags & FULL == 0 || flags & START != 0, "full frame without start");
        ensure!(flags & COPIES == 0 || flags & START != 0, "copies without start");
        ensure!(mode <= 4, "invalid frame size/mode");
        if flags & START != 0 {
            ensure!(
                w > 0 && h > 0 && w <= 65535 && h <= 65535 && w * h <= 8192 * 8192,
                "invalid frame size/mode"
            );
            ensure!(w.div_ceil(64) * h.div_ceil(64) <= 65535, "too many tiles");
            if flags & FULL != 0 {
                self.z.reset(true);
                self.mode = mode;
                self.width = w;
                self.height = h;
                self.samples = vec![0; w * h];
                self.hold = self.shown;
            } else {
                ensure!(!self.open, "frame started while another is open");
                ensure!(self.width > 0, "update frame before any full frame");
                ensure!(mode == self.mode, "update frame mode does not match canvas");
                self.hold = w != self.width || h != self.height || dx != 0 || dy != 0;
                if self.hold {
                    self.samples =
                        moved_canvas(&self.samples, self.width, self.height, w, h, dx, dy);
                    self.width = w;
                    self.height = h;
                }
            }
            self.open = true;
            self.reference = (flags & COPIES != 0).then(|| self.samples.clone());
        } else {
            ensure!(self.open, "slice without an open frame");
            ensure!(
                w == self.width && h == self.height,
                "update frame size does not match canvas"
            );
            ensure!(mode == self.mode, "update frame mode does not match canvas");
        }
        let display = !self.hold || flags & END != 0;
        if flags & END != 0 {
            self.open = false;
            self.shown = true;
        }
        let result = self.decode_tiles(compressed);
        if flags & END != 0 {
            self.reference = None;
        }
        result?;
        Ok(display)
    }
    fn decode_tiles(&mut self, compressed: &[u8]) -> Result<()> {
        let (w, h, mode) = (self.width, self.height, self.mode);
        let cols = w.div_ceil(64);
        let rows = h.div_ceil(64);
        let tiles = cols * rows;
        let bps = if mode == 2 || mode == 4 { 2 } else { 1 };
        // Every frame is terminated by Z_SYNC_FLUSH, not an independent zlib stream.
        ensure!(
            compressed.ends_with(&[0, 0, 255, 255]),
            "incomplete zlib sync flush"
        );
        let limit = 2 + tiles * (3 + 64 * 64 * bps);
        let mut body = Vec::new();
        let mut consumed = 0;
        loop {
            let mut chunk = [0; 65536];
            let before_in = self.z.total_in();
            let before_out = self.z.total_out();
            let status =
                self.z
                    .decompress(&compressed[consumed..], &mut chunk, FlushDecompress::Sync)?;
            let used = (self.z.total_in() - before_in) as usize;
            let n = (self.z.total_out() - before_out) as usize;
            consumed += used;
            ensure!(
                body.len() + n <= limit,
                "decompressed frame exceeds size limit"
            );
            body.extend_from_slice(&chunk[..n]);
            ensure!(
                status != Status::StreamEnd,
                "unexpected end of persistent zlib stream"
            );
            if consumed == compressed.len() && n < chunk.len() {
                break;
            }
            ensure!(used > 0 || n > 0, "invalid compressed data");
        }
        let mut r = Reader::new(&body);
        let count = r.u16()? as usize;
        ensure!(
            count <= tiles,
            "excessive tile count"
        );
        let mut seen = vec![false; tiles];
        for _ in 0..count {
            let index = r.u16()? as usize;
            let kind = r.u8()?;
            ensure!(
                index < tiles && !seen[index],
                "invalid or duplicate tile index"
            );
            seen[index] = true;
            let x = index % cols * 64;
            let y = index / cols * 64;
            let tw = 64.min(w - x);
            let th = 64.min(h - y);
            match kind {
                0 => {
                    let v = sample(&mut r, bps)?;
                    for row in y..y + th {
                        self.samples[row * w + x..row * w + x + tw].fill(v);
                    }
                }
                255 => {
                    for row in y..y + th {
                        for col in x..x + tw {
                            self.samples[row * w + col] = sample(&mut r, bps)?;
                        }
                    }
                }
                1 | 2 | 4 => {
                    let n = r.u8()? as usize;
                    ensure!(n > 0 && n <= 1usize << kind, "bad palette size");
                    let palette = (0..n)
                        .map(|_| sample(&mut r, bps))
                        .collect::<Result<Vec<_>>>()?;
                    self.palette(&mut r, x, y, tw, th, kind as usize, &palette)?;
                }
                3 => {
                    for sy in (y..y + th).step_by(16) {
                        for sx in (x..x + tw).step_by(16) {
                            let sw = 16.min(x + tw - sx);
                            let sh = 16.min(y + th - sy);
                            let n = r.u8()?;
                            ensure!(n == 1 || n == 2, "bad two-tone sub-block");
                            let lo = sample(&mut r, bps)?;
                            if n == 1 {
                                for row in sy..sy + sh {
                                    self.samples[row * w + sx..row * w + sx + sw].fill(lo);
                                }
                            } else {
                                let hi = sample(&mut r, bps)?;
                                self.palette(&mut r, sx, sy, sw, sh, 1, &[lo, hi])?;
                            }
                        }
                    }
                }
                KIND_COPY => {
                    let sx = r.u16()? as usize;
                    let sy = r.u16()? as usize;
                    let Some(reference) = &self.reference else {
                        bail!("copy tile without copies flag");
                    };
                    ensure!(sx + tw <= w && sy + th <= h, "copy source outside canvas");
                    for row in 0..th {
                        let src = (sy + row) * w + sx;
                        let dst = (y + row) * w + x;
                        self.samples[dst..dst + tw].copy_from_slice(&reference[src..src + tw]);
                    }
                }
                _ => bail!("unknown tile kind {kind}"),
            }
        }
        r.end()?;
        Ok(())
    }
    #[allow(clippy::too_many_arguments)]
    fn palette(
        &mut self,
        r: &mut Reader<'_>,
        x: usize,
        y: usize,
        w: usize,
        h: usize,
        bits: usize,
        palette: &[u16],
    ) -> Result<()> {
        for row in y..y + h {
            let packed = r.take((w * bits).div_ceil(8))?;
            for col in 0..w {
                let bit = col * bits;
                let i = ((packed[bit / 8] >> (8 - bits - bit % 8)) & ((1 << bits) - 1)) as usize;
                ensure!(i < palette.len(), "palette index out of range");
                self.samples[row * self.width + x + col] = palette[i];
            }
        }
        Ok(())
    }
}
fn sample(r: &mut Reader<'_>, bps: usize) -> Result<u16> {
    if bps == 2 {
        r.u16()
    } else {
        Ok(r.u8()? as u16)
    }
}
pub fn bgra(mode: u8, s: u16) -> [u8; 4] {
    let (r, g, b) = match mode {
        0 | 3 => {
            let v = (s & 15) * 17;
            (v, v, v)
        }
        1 if s >= 216 => {
            let v = ((s - 216) * 255 + 19) / 39;
            (v, v, v)
        }
        1 => (s / 36 * 51, s / 6 % 6 * 51, s % 6 * 51),
        _ => {
            let r = s >> 11;
            let g = s >> 5 & 63;
            let b = s & 31;
            (r << 3 | r >> 2, g << 2 | g >> 4, b << 3 | b >> 2)
        }
    };
    [b as u8, g as u8, r as u8, 255]
}
