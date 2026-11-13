//! Swift TileCodec-compatible persistent zlib decoding. Full frames reset the dictionary.
use crate::protocol::Reader;
use anyhow::{bail, ensure, Result};
use flate2::{Decompress, FlushDecompress, Status};

pub struct Decoder {
    z: Decompress,
    pub width: usize,
    pub height: usize,
    mode: u8,
    samples: Vec<u16>,
}
impl Default for Decoder {
    fn default() -> Self {
        Self {
            z: Decompress::new(true),
            width: 0,
            height: 0,
            mode: 0,
            samples: Vec::new(),
        }
    }
}
impl Decoder {
    pub fn decode(
        &mut self,
        mode: u8,
        w: usize,
        h: usize,
        full: bool,
        compressed: &[u8],
    ) -> Result<Vec<u8>> {
        let mut pixels = Vec::new();
        self.decode_into(mode, w, h, full, compressed, &mut pixels)?;
        Ok(pixels)
    }
    /// Reuse the expanded pixel allocation between frames (headless renderer).
    #[allow(clippy::too_many_arguments)]
    pub fn decode_into(
        &mut self,
        mode: u8,
        w: usize,
        h: usize,
        full: bool,
        compressed: &[u8],
        pixels: &mut Vec<u8>,
    ) -> Result<()> {
        ensure!(
            mode <= 4 && w > 0 && h > 0 && w <= 65535 && h <= 65535 && w * h <= 8192 * 8192,
            "invalid frame size/mode"
        );
        let cols = w.div_ceil(64);
        let rows = h.div_ceil(64);
        let tiles = cols * rows;
        ensure!(tiles <= 65535, "too many tiles");
        let bps = if mode == 2 || mode == 4 { 2 } else { 1 };
        if full {
            self.z.reset(true);
            self.width = w;
            self.height = h;
            self.mode = mode;
            self.samples = vec![0; w * h];
        } else {
            ensure!(
                self.width == w
                    && self.height == h
                    && self.mode == mode
                    && !self.samples.is_empty(),
                "delta without matching full frame"
            );
        }
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
        // A full frame may be only the first slice of the picture (the rest arrive as later
        // non-full slices); the tiles it lacks stay zero, as in the Swift FrameDecoder.
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
                _ => bail!("unknown tile kind {kind}"),
            }
        }
        r.end()?;
        pixels.resize(self.samples.len() * 4, 0);
        for (pixel, sample) in pixels.as_chunks_mut::<4>().0.iter_mut().zip(&self.samples) {
            pixel.copy_from_slice(&bgra(mode, *sample));
        }
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
