//! The same 64-pixel tile and persistent zlib stream consumed by every rapp client.
use anyhow::{ensure, Result};
use flate2::{Compress, Compression, FlushCompress};
use rapp_client_core::protocol::{packet, Rect};

pub struct Encoder {
    z: Compress,
    previous: Vec<u16>,
    shape: (usize, usize, u8),
    region: Rect,
}
impl Default for Encoder {
    fn default() -> Self {
        Self {
            z: Compress::new(Compression::fast(), true),
            previous: vec![],
            shape: (0, 0, 0),
            region: Rect::default(),
        }
    }
}

pub fn sample(mode: u8, p: &[u8]) -> u16 {
    let (b, g, r) = (p[0] as u16, p[1] as u16, p[2] as u16);
    match mode {
        0 | 3 => ((r as u32 * 77 + g as u32 * 150 + b as u32 * 29 + 128) / 256 / 17) as u16,
        1 => ((r + 25) / 51) * 36 + ((g + 25) / 51) * 6 + (b + 25) / 51,
        _ => (r >> 3) << 11 | (g >> 2) << 5 | b >> 3,
    }
}

impl Encoder {
    pub fn reset(&mut self) {
        self.previous.clear();
    }

    /// Pixel dimensions may differ from the desktop's logical dimensions (HiDPI).
    #[cfg(test)]
    pub fn frame(
        &mut self,
        bgra: &[u8],
        w: usize,
        h: usize,
        logical: (u16, u16),
        mode: u8,
    ) -> Result<Option<Vec<u8>>> {
        self.frame_region(
            bgra,
            w,
            h,
            Rect {
                x: 0.,
                y: 0.,
                w: logical.0 as f32,
                h: logical.1 as f32,
            },
            mode,
        )
    }

    pub fn frame_region(
        &mut self,
        bgra: &[u8],
        w: usize,
        h: usize,
        region: Rect,
        mode: u8,
    ) -> Result<Option<Vec<u8>>> {
        ensure!(
            mode <= 4 && w > 0 && h > 0 && w <= 8192 && h <= 8192 && bgra.len() == w * h * 4,
            "invalid capture dimensions"
        );
        let full = self.previous.is_empty() || self.shape != (w, h, mode) || self.region != region;
        let next: Vec<_> = bgra
            .as_chunks::<4>()
            .0
            .iter()
            .map(|p| sample(mode, p))
            .collect();
        let mut body = vec![0, 0];
        let mut count = 0u16;
        let cols = w.div_ceil(64);
        for y in (0..h).step_by(64) {
            for x in (0..w).step_by(64) {
                let (tw, th) = (64.min(w - x), 64.min(h - y));
                if !full
                    && (y..y + th).all(|row| {
                        next[row * w + x..row * w + x + tw]
                            == self.previous[row * w + x..row * w + x + tw]
                    })
                {
                    continue;
                }
                count += 1;
                body.extend(((y / 64 * cols + x / 64) as u16).to_le_bytes());
                let first = next[y * w + x];
                let solid = (y..y + th).all(|row| {
                    next[row * w + x..row * w + x + tw]
                        .iter()
                        .all(|v| *v == first)
                });
                body.push(if solid { 0 } else { 255 });
                let mut put = |v: u16| {
                    body.push(v as u8);
                    if mode == 2 || mode == 4 {
                        body.push((v >> 8) as u8);
                    }
                };
                if solid {
                    put(first);
                } else {
                    for row in y..y + th {
                        for v in &next[row * w + x..row * w + x + tw] {
                            put(*v);
                        }
                    }
                }
            }
        }
        if count == 0 {
            return Ok(None);
        }
        body[..2].copy_from_slice(&count.to_le_bytes());
        if full {
            self.z.reset();
        }
        let mut compressed = Vec::new();
        let mut used = 0;
        loop {
            let mut out = [0; 65536];
            let (before_in, before_out) = (self.z.total_in(), self.z.total_out());
            self.z
                .compress(&body[used..], &mut out, FlushCompress::Sync)?;
            used += (self.z.total_in() - before_in) as usize;
            let n = (self.z.total_out() - before_out) as usize;
            compressed.extend_from_slice(&out[..n]);
            if used == body.len() && n < out.len() {
                break;
            }
        }
        self.shape = (w, h, mode);
        self.region = region;
        self.previous = next;
        let mut payload = vec![mode];
        for f in [region.x, region.y, region.w, region.h] {
            payload.extend(f.to_le_bytes());
        }
        payload.extend((w as u16).to_le_bytes());
        payload.extend((h as u16).to_le_bytes());
        payload.push(if full { 7 } else { 6 });
        if !full {
            payload.extend([0; 8]);
        }
        payload.extend(compressed);
        Ok(Some(packet(4, payload)))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use rapp_client_core::{
        codec::Decoder,
        protocol::{read_message, Incoming},
    };
    #[test]
    fn moving_view_resets_decoder_even_when_pixels_and_dimensions_match() {
        let mut encoder = Encoder::default();
        let mut decoder = Decoder::default();
        let pixels = vec![255; 4 * 4 * 4];
        for x in [0., 100., 0.] {
            let region = Rect {
                x,
                y: 20.,
                w: 2.,
                h: 2.,
            };
            let bytes = encoder
                .frame_region(&pixels, 4, 4, region, 2)
                .unwrap()
                .unwrap();
            let (
                Incoming::Frame {
                    region: actual,
                    mode,
                    width,
                    height,
                    flags,
                    dx,
                    dy,
                    data,
                },
                _,
            ) = read_message(&mut &bytes[..]).unwrap()
            else {
                panic!()
            };
            assert_eq!(actual, region);
            assert_ne!(flags & 1, 0);
            assert_eq!(
                decoder
                    .decode(mode, width, height, flags, dx, dy, &data)
                    .unwrap()
                    .unwrap(),
                pixels
            );
        }
    }
    #[test]
    fn every_mode_roundtrips_partial_tiles_deltas_and_resets() {
        for mode in 0..=4 {
            let (w, h) = (131, 67);
            let mut pixels: Vec<_> = (0..w * h)
                .flat_map(|n| [(n * 17) as u8, (n * 31) as u8, (n * 7) as u8, 255])
                .collect();
            let mut enc = Encoder::default();
            let mut dec = Decoder::default();
            for step in 0..4 {
                if step == 1 {
                    pixels[(65 * w + 130) * 4..(65 * w + 130) * 4 + 4]
                        .copy_from_slice(&[255, 255, 255, 255]);
                }
                if step == 2 {
                    enc.reset();
                }
                if step == 3 {
                    pixels.fill(0);
                }
                let message = enc.frame(&pixels, w, h, (131, 67), mode).unwrap().unwrap();
                let (
                    Incoming::Frame {
                        mode,
                        width,
                        height,
                        flags,
                        dx,
                        dy,
                        data,
                        ..
                    },
                    _,
                ) = read_message(&mut &message[..]).unwrap()
                else {
                    panic!()
                };
                let out = dec
                    .decode(mode, width, height, flags, dx, dy, &data)
                    .unwrap()
                    .unwrap();
                let expected: Vec<_> = pixels
                    .as_chunks::<4>()
                    .0
                    .iter()
                    .flat_map(|p| rapp_client_core::codec::bgra(mode, sample(mode, p)))
                    .collect();
                assert_eq!(out, expected);
                assert!(enc.frame(&pixels, w, h, (131, 67), mode).unwrap().is_none());
            }
        }
    }
}
