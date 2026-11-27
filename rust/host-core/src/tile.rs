//! The tile encoder, ported from the encoder half of `TileCodec.swift` (`:4-700`).
//! `FrameDecoder` (`:704`) is controller code and is not ported; the controller's
//! own decoder is `rapp_client_core::codec::Decoder`.
//!
//! Frame message format (protocol v9, little endian). A frame is one or more
//! slices; each slice is one message (type 4):
//!   u8 mode; rect region (4 x f32); u16 width; u16 height; u8 flags;
//!   [only when `start` and not `full`: i32 dx; i32 dy]; deflate data
//! flags: bit0 `full` (replace the canvas: zeroed, stream restarts; needs `start`),
//! bit1 `start` (first slice of a frame), bit2 `end` (last slice), bit3 `copies`
//! (the frame may use copy tiles; only on a `start` slice). Other bits must be 0.
//! A slice without `start` continues the open frame and must follow in order.
//! Canvas move (`start`, not `full`): the new canvas is width x height with
//! new(x, y) = old(x + dx, y + dy); anything outside the old canvas is 0.
//! Reference canvas: the canvas after the move and before any tile of the frame
//! is written. Copy tiles (kind 5) read from it, never from the half-built frame.
//! Slice body: u16 count, then per tile u16 index, u8 kind, kind data. Kind 5
//! (copy) data: u16 sx; u16 sy, the top left of a source rectangle of the tile's
//! own size in the reference canvas; it must lie inside it (sx + tw <= width,
//! sy + th <= height) and is only valid in a frame that has `copies`.
//!
//! Frame body before compression (little-endian):
//!
//! ```text
//! u16 tileCount
//! tileCount times:
//!   u16 tileIndex   row-major, ceil(width / 64) tiles per row
//!   u8  kind        0 solid, 1/2/4 palette with that many bits per pixel,
//!                   3 two-tone sub-blocks, 5 copy, 255 raw
//!   kind 0:     one sample
//!   kind 1/2/4: u8 n, n samples (ascending), then index bits row by row,
//!               most significant bit first, each row padded to a whole byte
//!   kind 3:     the tile's 16x16 sub-blocks row by row, each:
//!               u8 n (1 or 2), n samples (ascending), and for n = 2 one bit
//!               per pixel (0 = the smaller sample) row by row, most
//!               significant bit first, each row padded to a whole byte
//!   kind 255:   every sample of the tile, row by row
//! ```
//!
//! Edge tiles are min(64, width - x0) by min(64, height - y0) pixels, and
//! edge sub-blocks likewise keep their real size. Kind 3 is chosen whenever a
//! tile has at least 3 distinct samples and every sub-block has at most 2,
//! whatever the mode.

use std::collections::HashMap;

use crate::deflate::DeflateStream;
use crate::geometry::Rect;
use crate::protocol::{CanvasRect, FrameFlags, FramePayload, Mode};
use crate::scroll::{Cover, ScrollDetector};

/// Frames are cut into square tiles of this many pixels per side.
pub const TILE_SIZE: usize = 64;

// Tile kinds on the wire. Palette kinds are named by their bits per pixel.
const KIND_SOLID: u8 = 0;
const KIND_DUO: u8 = 3;
const KIND_COPY: u8 = 5;
const KIND_RAW: u8 = 255;
/// Side of a two-tone sub-block inside a tile.
const SUB_BLOCK: usize = 16;
const MAX_TILES: usize = 65535;

fn tile_grid(width: usize, height: usize) -> (usize, usize) {
    (width.div_ceil(TILE_SIZE), height.div_ceil(TILE_SIZE))
}

/// What the last `encode_slices` call sent (FocusPane.swift:13, where Swift keeps it).
#[derive(Debug, Clone, PartialEq)]
pub struct EncodeReport {
    pub region: CanvasRect,
    pub width: usize,
    pub height: usize,
    /// Whole frame encoded, or the frame size changed.
    pub full: bool,
    /// Tile indexes ty*cols+tx sent this frame (any kind, copies too).
    pub changed: Vec<usize>,
    /// Pixels; bounding box of this frame's copy tiles.
    pub copy_bounds: Option<Rect>,
}

/// The canvas move shared by encoder and decoder: `src` (`width` x `height`,
/// `bpp` bytes each) moved into a new `w` x `h` canvas with
/// new(x, y) = old(x + dx, y + dy); anything outside the old canvas is 0.
#[allow(clippy::too_many_arguments)]
pub fn moved_canvas(src: &[u8], width: usize, height: usize, bpp: usize, w: usize, h: usize, dx: isize, dy: isize) -> Vec<u8> {
    let mut moved = vec![0u8; w * h * bpp];
    let (width, height, w, h) = (width as isize, height as isize, w as isize, h as isize);
    let x0 = 0.max(-dx);
    let x1 = w.min(width - dx);
    let y0 = 0.max(-dy);
    let y1 = h.min(height - dy);
    if !(x1 > x0 && y1 > y0) {
        return moved;
    }
    let bpp_i = bpp as isize;
    let n = ((x1 - x0) * bpp_i) as usize;
    for y in y0..y1 {
        let from = (((y + dy) * width + x0 + dx) * bpp_i) as usize;
        let to = ((y * w + x0) * bpp_i) as usize;
        moved[to..to + n].copy_from_slice(&src[from..from + n]);
    }
    moved
}

/// Whether the `w`-byte by `h`-row rectangle at byte `x0` of row `y0` in `a`
/// is the same as the one `dy` rows lower in `b`. Swift returns false when
/// either buffer has no base address (is empty).
#[inline(always)]
#[allow(clippy::too_many_arguments)]
fn tile_equal(a: &[u8], b: &[u8], stride: usize, x0: usize, y0: usize, w: usize, h: usize, dy: isize) -> bool {
    if a.is_empty() || b.is_empty() {
        return false;
    }
    for y in y0..y0 + h {
        let pa = y * stride + x0;
        let pb = ((y as isize + dy) as usize) * stride + x0;
        if a[pa..pa + w] != b[pb..pb + w] {
            return false;
        }
    }
    true
}

/// A gathered settle tile: where it is, and where it ends in the body.
struct SettleTile {
    x0: usize,
    y0: usize,
    tw: usize,
    th: usize,
    end: usize,
}

/// Encodes a stream of frames. Each frame is compared with the encoder's model
/// of the client's canvas (moved first when the region moves), and only tiles that differ are sent.
pub struct FrameEncoder {
    mode: Mode,
    bps: usize,
    deflate: DeflateStream,
    /// The model of the decoder's canvas: what the client shows after the last frame.
    previous: Vec<u8>,
    previous_width: usize,
    previous_height: usize,
    /// The raw BGRA of the last frame, kept only in two-tone modes when the frame
    /// came with raw pixels. Every model sample is a correct quantization of the
    /// key pixel at the same place (maybe under another 16x16 block alignment).
    previous_key: Option<Vec<u8>>,
    /// The captured region (points) and pixels per point of the last frame.
    previous_region: CanvasRect,
    previous_scale: f64,
    /// Makes the next encode full (Swift `forceFull`, internal there). After dropping
    /// slices the caller must set it.
    pub force_full: bool,
    /// Compressed / raw size of the previous frame, used to estimate slice sizes.
    ratio: f64,
    /// Number of tiles in the frame most recently returned by `encode` or `encode_slices`.
    last_tile_count: usize,
    /// What the last `encode_slices` call sent. `changed` is empty when it returned
    /// no slices. `encode_settle` leaves it alone. None before the first call.
    last_report: Option<EncodeReport>,
    /// True when the last encode left some tile unsent only because its raw
    /// pixels matched, so the canvas there differs from this frame's samples.
    last_encode_diverged: bool,
    /// True when the last encode made the canvas newly approximate: a tile was
    /// accepted on raw pixels only as a copy, or against the old picture moved
    /// by a nonzero offset. Full frames and `encode_settle` clear it.
    last_encode_added_approximation: bool,
    /// True from such an encode until a full frame, or the `encode_settle` call
    /// that sends the last differing tile, makes the canvas exact again.
    needs_settle: bool,
    /// Whether frames may use copy tiles (off only to measure against).
    pub copies_enabled: bool,
    /// The samples of the last frame, for `encode_settle`.
    last_samples: Vec<u8>,
    /// The scroll offset most copy tiles of the last frame with copies used.
    last_dy: Option<isize>,
    detector: ScrollDetector,
    /// Compressed / uncompressed size of the last settle frame, to guess how
    /// many tiles the next one can take.
    settle_ratio: f64,
    /// The tile streams before deflate of the slices last returned (tests only).
    last_streams: Vec<Vec<u8>>,
}

impl FrameEncoder {
    /// At most this many voted scroll offsets are tried per frame (plus `last_dy`).
    const MAX_CANDIDATES: usize = 3;

    pub fn new(mode: Mode) -> Self {
        FrameEncoder {
            mode,
            bps: mode.bytes_per_sample(),
            // Swift `DeflateStream()`: level 6.
            deflate: DeflateStream::new(6),
            previous: Vec::new(),
            previous_width: 0,
            previous_height: 0,
            previous_key: None,
            previous_region: CanvasRect::new(0.0, 0.0, 0.0, 0.0),
            previous_scale: 0.0,
            force_full: true,
            ratio: 1.0,
            last_tile_count: 0,
            last_report: None,
            last_encode_diverged: false,
            last_encode_added_approximation: false,
            needs_settle: false,
            copies_enabled: true,
            last_samples: Vec::new(),
            last_dy: None,
            detector: ScrollDetector::new(),
            settle_ratio: 1.0,
            last_streams: Vec::new(),
        }
    }

    /// Makes the next `encode` produce a full frame.
    pub fn reset(&mut self) {
        self.force_full = true;
    }

    pub fn mode(&self) -> Mode {
        self.mode
    }

    pub fn last_tile_count(&self) -> usize {
        self.last_tile_count
    }

    pub fn last_report(&self) -> Option<&EncodeReport> {
        self.last_report.as_ref()
    }

    pub fn last_encode_diverged(&self) -> bool {
        self.last_encode_diverged
    }

    pub fn last_encode_added_approximation(&self) -> bool {
        self.last_encode_added_approximation
    }

    pub fn needs_settle(&self) -> bool {
        self.needs_settle
    }

    /// The decoder's canvas as this encoder models it (Swift `model`, for tests).
    #[doc(hidden)]
    pub fn model(&self) -> &[u8] {
        &self.previous
    }

    /// The tile stream before deflate of the last slice returned by the last call
    /// (empty when it returned none).
    #[doc(hidden)]
    pub fn last_tile_stream(&self) -> &[u8] {
        self.last_streams.last().map(|s| s.as_slice()).unwrap_or(&[])
    }

    /// The tile streams before deflate of every slice the last call returned, in order.
    #[doc(hidden)]
    pub fn last_tile_streams(&self) -> &[Vec<u8>] {
        &self.last_streams
    }

    pub(crate) fn kind_for_distinct_count(n: usize) -> u8 {
        match n {
            1 => KIND_SOLID,
            2 => 1,
            3..=4 => 2,
            5..=16 => 4,
            _ => KIND_RAW,
        }
    }

    /// Returns None when nothing changed. See `encode_slices` for the arguments
    /// and for when a frame is full.
    pub fn encode(
        &mut self,
        samples: &[u8],
        raw: Option<&[u8]>,
        width: usize,
        height: usize,
        region: Option<CanvasRect>,
    ) -> Option<FramePayload> {
        self.encode_slices(samples, raw, width, height, region, usize::MAX, None).into_iter().next()
    }

    /// Pixel offset between two region origins (points) at `scale` pixels per
    /// point. Clamped to ±65536: any bigger offset leaves nothing of a canvas of
    /// at most 65535 pixels, exactly like the real one would.
    fn pixel_offset(a: f32, b: f32, scale: f64) -> isize {
        // Swift `.rounded()` is to nearest, ties away from zero, like `f64::round`.
        let d = (b as f64 * scale).round() - (a as f64 * scale).round();
        if !d.is_finite() {
            return 0;
        }
        (-65536.0f64).max(65536.0f64.min(d)) as isize
    }

    /// Sends the next part of the correction: the tiles where the canvas
    /// differs from the last frame's samples (compared on samples only), top
    /// to bottom, as one independent frame of one slice: `start` and `end`,
    /// never full, no move, no copy tiles. The slice's data is at most `limit`
    /// bytes (checked by compressing; only a frame of a single tile, which is
    /// always sent, could be larger). Repeated calls end with the canvas equal
    /// to the last frame's samples; a frame encoded in between is fine, later
    /// calls go on from it.
    ///
    /// Returns at most one payload, and `[]` when `needs_settle` is false, no
    /// tile differs or the next frame must be full anyway. `needs_settle` stays
    /// true until the call that sends the last differing tile.
    pub fn encode_settle(&mut self, limit: usize) -> Vec<FramePayload> {
        if !self.needs_settle || self.force_full {
            return Vec::new();
        }
        let bps = self.bps;
        let (width, height) = (self.previous_width, self.previous_height);
        let (cols, rows) = tile_grid(width, height);
        let row_bytes = width * bps;
        // Tile bytes to gather: what the last settle frame suggests fits, a little under the limit.
        // Swift: `max(limit, Int(Double(limit) * 0.9 / settleRatio))`; `as usize` saturates
        // where Swift's `Int(_:)` would trap (only for a limit near Int.max).
        let budget = limit.max((limit as f64 * 0.9 / self.settle_ratio) as usize);
        let mut body: Vec<u8> = vec![0, 0];
        // The differing tiles gathered, and where each ends in `body`.
        let mut tiles: Vec<SettleTile> = Vec::new();
        let mut more = false;
        {
            let cur = &self.last_samples;
            let old = &self.previous;
            'scan: for ty in 0..rows {
                let y0 = ty * TILE_SIZE;
                let th = TILE_SIZE.min(height - y0);
                for tx in 0..cols {
                    let x0 = tx * TILE_SIZE;
                    let tw = TILE_SIZE.min(width - x0);
                    if tile_equal(cur, old, row_bytes, x0 * bps, y0, tw * bps, th, 0) {
                        continue;
                    }
                    if !tiles.is_empty() && body.len() >= budget {
                        more = true;
                        break 'scan;
                    }
                    let index = ty * cols + tx;
                    body.push((index & 0xFF) as u8);
                    body.push((index >> 8) as u8);
                    encode_tile(cur, bps, row_bytes, x0, y0, tw, th, &mut body);
                    tiles.push(SettleTile { x0, y0, tw, th, end: body.len() });
                }
            }
        }
        self.last_encode_diverged = false;
        self.last_encode_added_approximation = false;
        if tiles.is_empty() {
            self.needs_settle = false;
            self.last_streams = Vec::new();
            return Vec::new();
        }

        // Compress the first n tiles; while that is over the limit, try fewer.
        let mut n = tiles.len();
        let data: Vec<u8>;
        let mut group: Vec<u8>;
        loop {
            group = body[0..tiles[n - 1].end].to_vec();
            group[0] = (n & 0xFF) as u8;
            group[1] = (n >> 8) as u8;
            if n == 1 {
                data = self.deflate.compress(&group);
                break;
            }
            let (fits, trial) = self.deflate.compress_if_at_most(&group, limit);
            if fits {
                data = trial;
                break;
            }
            // Swift: `max(1, min(n - 1, Int(Double(n) * Double(limit) * 0.9 / Double(trial.data.count))))`.
            let guess = (n as f64 * limit as f64 * 0.9 / trial.len() as f64) as usize;
            n = 1usize.max((n - 1).min(guess));
        }
        if n < tiles.len() {
            more = true;
        }
        self.settle_ratio = 1f64.min(0.05f64.max(data.len() as f64 / tiles[n - 1].end as f64));

        // The canvas now has the last frame's samples in the tiles sent.
        for t in &tiles[0..n] {
            for y in t.y0..t.y0 + t.th {
                let o = y * row_bytes + t.x0 * bps;
                let len = t.tw * bps;
                self.previous[o..o + len].copy_from_slice(&self.last_samples[o..o + len]);
            }
        }
        self.needs_settle = more;
        self.last_tile_count = n;
        self.last_streams = vec![group];
        vec![FramePayload {
            mode: self.mode,
            width: width as u16,
            height: height as u16,
            flags: FrameFlags::START | FrameFlags::END,
            dx: 0,
            dy: 0,
            data,
        }]
    }

    /// Encodes the tiles that differ from the client's canvas and cuts them into
    /// slices by tile rows, top to bottom. A slice is closed once its estimated
    /// compressed size (raw bytes of its tiles times the previous frame's
    /// compression ratio, a copy tile counting 4 bytes) exceeds `limit`
    /// (`first_limit` for the first slice); a slice always holds at least one row.
    ///
    /// A changed tile whose content is found, exactly, some rows up or down in
    /// the old picture (after the move, wholly inside the part it covers) is
    /// sent as a copy tile; the offsets tried are the ones `ScrollDetector`
    /// votes for and the one the last copies used. Samples must match, or in
    /// two-tone modes the raw pixels (that also sets `last_encode_diverged`).
    ///
    /// `region` is the captured area in points (None: `(0, 0, width, height)`).
    /// `raw` is the frame's tightly packed BGRA (`width * height * 4` bytes); it
    /// is used only in two-tone modes, where a tile whose raw pixels match the
    /// last frame's is not sent even if its samples differ (see `needs_settle`).
    ///
    /// The frame is full (`is_full`, and it restarts the compression stream) for
    /// the first frame, after `reset()` and when the pixels per point change by
    /// more than 1 %. Otherwise a new size or region origin moves the canvas: the
    /// first slice carries the size and offset, the old picture is kept where it
    /// still covers the new canvas, and only tiles that changed or reach outside
    /// it are sent.
    ///
    /// The first slice has `START` (and `FULL` for a full frame), the last `END`;
    /// the slices must be decoded in order. Returns `[]` when nothing changed and
    /// the canvas does not move; a move with no changed tile is one empty slice.
    /// The encoder treats the whole frame as sent: after dropping slices the
    /// caller must set `force_full`.
    #[allow(clippy::too_many_arguments)]
    pub fn encode_slices(
        &mut self,
        samples: &[u8],
        raw: Option<&[u8]>,
        width: usize,
        height: usize,
        region: Option<CanvasRect>,
        limit: usize,
        first_limit: Option<usize>,
    ) -> Vec<FramePayload> {
        let bps = self.bps;
        assert!(width > 0 && height > 0 && width <= 0xFFFF && height <= 0xFFFF, "bad frame size");
        assert!(samples.len() == width * height * bps, "sample count does not match frame size");
        let (cols, rows) = tile_grid(width, height);
        assert!(cols * rows <= MAX_TILES, "frame too large");
        let raw = if self.mode.is_duo() { raw } else { None };
        if let Some(r) = raw {
            assert!(r.len() == width * height * 4, "raw pixel count does not match frame size");
        }
        let region = region.unwrap_or(CanvasRect::new(0.0, 0.0, width as f32, height as f32));
        let scale = width as f64 / region.w as f64;

        // Density change; written as !(<=) so a NaN previous scale also means full.
        let full = self.force_full
            || !(scale.is_finite() && scale > 0.0)
            || !((scale / self.previous_scale - 1.0).abs() <= 0.01);
        let resized = width != self.previous_width || height != self.previous_height;
        let mut dx: isize = 0;
        let mut dy: isize = 0;
        let mut moved = false;
        // The model after the move, the raw key moved likewise (only when both
        // frames have raw), and the part of the new canvas the old picture covers.
        // `previous` and `previous_key` are both replaced below, so they are taken, not copied.
        let mut old: Vec<u8> = std::mem::take(&mut self.previous);
        let mut key: Option<Vec<u8>> = None;
        let previous_key = self.previous_key.take();
        let mut cover = Cover { x0: 0, y0: 0, x1: width as isize, y1: height as isize };
        if !full {
            dx = Self::pixel_offset(self.previous_region.x, region.x, scale);
            dy = Self::pixel_offset(self.previous_region.y, region.y, scale);
            moved = dx != 0 || dy != 0 || width != self.previous_width || height != self.previous_height;
            key = if raw.is_none() { None } else { previous_key };
            if moved {
                let (pw, ph) = (self.previous_width, self.previous_height);
                old = moved_canvas(&old, pw, ph, bps, width, height, dx, dy);
                key = key.map(|k| moved_canvas(&k, pw, ph, 4, width, height, dx, dy));
                cover = Cover {
                    x0: 0.max(-dx),
                    y0: 0.max(-dy),
                    x1: (width as isize).min(pw as isize - dx),
                    y1: (height as isize).min(ph as isize - dy),
                };
            }
        }

        let row_bytes = width * bps;
        let mut groups: Vec<Vec<u8>> = Vec::new();
        let mut body: Vec<u8> = vec![0, 0];
        let mut count: usize = 0;
        let mut group_raw: usize = 0;
        let mut total_count: usize = 0;
        let mut total_raw: usize = 0;
        let mut current_limit = first_limit.unwrap_or(limit);
        // Tiles left unsent only because their raw pixels matched: (x0, y0, tw, th).
        let mut diverged: Vec<(usize, usize, usize, usize)> = Vec::new();
        // Copy tiles that matched on raw pixels only: (x0, y0, tw, th, source y).
        let mut raw_copies: Vec<(usize, usize, usize, usize, usize)> = Vec::new();
        // Copy tiles per scroll offset used.
        let mut used: HashMap<isize, usize> = HashMap::new();
        // The report: tile indexes sent, and the box of the copy tiles (pixels).
        let mut sent_tiles: Vec<usize> = Vec::new();
        let mut copy_box: Option<(usize, usize, usize, usize)> = None;
        let use_copies = self.copies_enabled && !full;

        let raw_cur: &[u8] = raw.unwrap_or(&[]);
        let raw_old: &[u8] = key.as_deref().unwrap_or(&[]);
        let compare_raw = key.is_some();
        let cur = samples;
        let inside_x = |x0: usize, tw: usize, c: &Cover| (x0 as isize) >= c.x0 && ((x0 + tw) as isize) <= c.x1;
        {
            let old: &[u8] = &old;
            // First pass: the tiles that changed in place. Only a tile wholly
            // inside the old picture can be left as it is.
            let mut changed = vec![true; cols * rows];
            let mut changed_count = 0usize;
            for ty in 0..rows {
                let y0 = ty * TILE_SIZE;
                let th = TILE_SIZE.min(height - y0);
                for tx in 0..cols {
                    let x0 = tx * TILE_SIZE;
                    let tw = TILE_SIZE.min(width - x0);
                    if !full
                        && inside_x(x0, tw, &cover)
                        && (y0 as isize) >= cover.y0
                        && ((y0 + th) as isize) <= cover.y1
                    {
                        if tile_equal(cur, old, row_bytes, x0 * bps, y0, tw * bps, th, 0) {
                            changed[ty * cols + tx] = false;
                            continue;
                        }
                        if compare_raw && tile_equal(raw_cur, raw_old, width * 4, x0 * 4, y0, tw * 4, th, 0) {
                            changed[ty * cols + tx] = false;
                            diverged.push((x0, y0, tw, th));
                            continue;
                        }
                    }
                    changed_count += 1;
                }
            }

            // The scroll offsets to try: voted ones when enough changed, and the last used.
            let mut candidates: Vec<isize> = Vec::new();
            if use_copies && changed_count > 0 {
                if changed_count >= 4 {
                    candidates = if compare_raw {
                        self.detector.candidates(raw_cur, raw_old, 4, width, height, &changed, cover, Self::MAX_CANDIDATES)
                    } else {
                        self.detector.candidates(cur, old, bps, width, height, &changed, cover, Self::MAX_CANDIDATES)
                    };
                }
                if let Some(d) = self.last_dy {
                    if !candidates.contains(&d) {
                        candidates.push(d);
                    }
                }
            }

            // Second pass: copy what is found in the old picture, encode the rest.
            for ty in 0..rows {
                let y0 = ty * TILE_SIZE;
                let th = TILE_SIZE.min(height - y0);
                for tx in 0..cols {
                    if !changed[ty * cols + tx] {
                        continue;
                    }
                    let x0 = tx * TILE_SIZE;
                    let tw = TILE_SIZE.min(width - x0);
                    let index = ty * cols + tx;
                    sent_tiles.push(index);
                    body.push((index & 0xFF) as u8);
                    body.push((index >> 8) as u8);
                    if !candidates.is_empty() && inside_x(x0, tw, &cover) {
                        let fits = |d: isize| y0 as isize + d >= cover.y0 && y0 as isize + d + th as isize <= cover.y1;
                        // Samples first (exact), then raw pixels.
                        let mut source: Option<isize> = None;
                        for &d in candidates.iter().filter(|&&d| fits(d)) {
                            if tile_equal(cur, old, row_bytes, x0 * bps, y0, tw * bps, th, d) {
                                source = Some(d);
                                break;
                            }
                        }
                        if source.is_none() && compare_raw {
                            for &d in candidates.iter().filter(|&&d| fits(d)) {
                                if tile_equal(raw_cur, raw_old, width * 4, x0 * 4, y0, tw * 4, th, d) {
                                    source = Some(d);
                                    raw_copies.push((x0, y0, tw, th, (y0 as isize + d) as usize));
                                    break;
                                }
                            }
                        }
                        if let Some(d) = source {
                            let sy = (y0 as isize + d) as usize;
                            body.push(KIND_COPY);
                            body.extend_from_slice(&[
                                (x0 & 0xFF) as u8,
                                (x0 >> 8) as u8,
                                (sy & 0xFF) as u8,
                                (sy >> 8) as u8,
                            ]);
                            *used.entry(d).or_insert(0) += 1;
                            copy_box = Some(match copy_box {
                                Some(b) => (b.0.min(x0), b.1.min(y0), b.2.max(x0 + tw), b.3.max(y0 + th)),
                                None => (x0, y0, x0 + tw, y0 + th),
                            });
                            count += 1;
                            group_raw += 4;
                            continue;
                        }
                    }
                    encode_tile(cur, bps, row_bytes, x0, y0, tw, th, &mut body);
                    count += 1;
                    group_raw += tw * th * bps;
                }
                // Close the slice at a row boundary once it is estimated over the limit.
                if count > 0 && group_raw as f64 * self.ratio > current_limit as f64 {
                    close_group(&mut groups, &mut body, &mut count, &mut group_raw, &mut total_count, &mut total_raw);
                    current_limit = limit;
                }
            }
        }
        if count > 0 || (groups.is_empty() && moved) {
            close_group(&mut groups, &mut body, &mut count, &mut group_raw, &mut total_count, &mut total_raw);
        }
        self.last_report = Some(EncodeReport {
            region,
            width,
            height,
            full: full || resized,
            changed: sent_tiles,
            copy_bounds: copy_box.map(|b| Rect {
                x: b.0 as f64,
                y: b.1 as f64,
                width: (b.2 - b.0) as f64,
                height: (b.3 - b.1) as f64,
            }),
        });

        // The new model is this frame's samples, except in tiles that only
        // matched on raw pixels: those keep the old samples, moved, from the
        // same place or the copy source (the old picture before any tile, like
        // the decoder's reference canvas).
        if diverged.is_empty() && raw_copies.is_empty() {
            self.previous = samples.to_vec();
        } else {
            let mut model = samples.to_vec();
            for &(x0, y0, tw, th) in &diverged {
                for y in y0..y0 + th {
                    let o = y * row_bytes + x0 * bps;
                    model[o..o + tw * bps].copy_from_slice(&old[o..o + tw * bps]);
                }
            }
            for &(x0, y0, tw, th, sy) in &raw_copies {
                for y in 0..th {
                    let o = (y0 + y) * row_bytes + x0 * bps;
                    let s = (sy + y) * row_bytes + x0 * bps;
                    model[o..o + tw * bps].copy_from_slice(&old[s..s + tw * bps]);
                }
            }
            self.previous = model;
        }
        if full {
            self.last_dy = None;
        } else if let Some(best) = best_offset(&used) {
            self.last_dy = Some(best);
        }
        self.last_encode_diverged = !diverged.is_empty() || !raw_copies.is_empty();
        self.last_encode_added_approximation = !raw_copies.is_empty() || (!diverged.is_empty() && (dx != 0 || dy != 0));
        self.needs_settle = self.last_encode_diverged || (self.needs_settle && !full);
        self.last_samples = samples.to_vec();
        self.previous_key = raw.map(|r| r.to_vec());
        self.previous_width = width;
        self.previous_height = height;
        self.previous_region = region;
        self.previous_scale = scale;
        if groups.is_empty() {
            self.last_streams = Vec::new();
            return Vec::new();
        }

        if full {
            self.deflate.reset();
        }
        let mut slices = Vec::with_capacity(groups.len());
        let mut compressed = 0usize;
        let last = groups.len() - 1;
        for (i, group) in groups.iter().enumerate() {
            let data = self.deflate.compress(group);
            compressed += data.len();
            let mut flags = FrameFlags(0);
            if i == 0 {
                flags.insert(FrameFlags::START);
                if full {
                    flags.insert(FrameFlags::FULL);
                }
                if !used.is_empty() {
                    flags.insert(FrameFlags::COPIES);
                }
            }
            if i == last {
                flags.insert(FrameFlags::END);
            }
            slices.push(FramePayload {
                mode: self.mode,
                width: width as u16,
                height: height as u16,
                flags,
                dx: if i == 0 { dx as i32 } else { 0 },
                dy: if i == 0 { dy as i32 } else { 0 },
                data,
            });
        }
        self.force_full = false;
        self.last_tile_count = total_count;
        if total_raw > 0 {
            self.ratio = 1f64.min(0.05f64.max(compressed as f64 / total_raw as f64));
        }
        self.last_streams = groups;
        slices
    }
}

/// Swift `closeGroup()`: writes the tile count into the body and starts a new one.
/// (The caller resets `current_limit` to `limit`, as Swift does inside it.)
fn close_group(
    groups: &mut Vec<Vec<u8>>,
    body: &mut Vec<u8>,
    count: &mut usize,
    group_raw: &mut usize,
    total_count: &mut usize,
    total_raw: &mut usize,
) {
    body[0] = (*count & 0xFF) as u8;
    body[1] = (*count >> 8) as u8;
    groups.push(std::mem::replace(body, vec![0, 0]));
    *total_count += *count;
    *total_raw += *group_raw;
    *count = 0;
    *group_raw = 0;
}

/// The scroll offset with the most copy tiles; on a tie the smaller offset (Swift:
/// `used.max(by: { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) })`).
fn best_offset(used: &HashMap<isize, usize>) -> Option<isize> {
    let mut best: Option<(isize, usize)> = None;
    for (&k, &v) in used {
        best = match best {
            None => Some((k, v)),
            Some((bk, bv)) => {
                if v > bv || (v == bv && k < bk) {
                    Some((k, v))
                } else {
                    Some((bk, bv))
                }
            }
        };
    }
    best.map(|b| b.0)
}

#[inline(always)]
fn sample(p: &[u8], bps: usize, offset: usize) -> u16 {
    if bps == 1 {
        p[offset] as u16
    } else {
        p[offset] as u16 | (p[offset + 1] as u16) << 8
    }
}

fn append_sample(v: u16, bps: usize, body: &mut Vec<u8>) {
    body.push((v & 0xFF) as u8);
    if bps == 2 {
        body.push((v >> 8) as u8);
    }
}

#[allow(clippy::too_many_arguments)]
fn encode_tile(cur: &[u8], bps: usize, row_bytes: usize, x0: usize, y0: usize, tw: usize, th: usize, body: &mut Vec<u8>) {
    // Collect the distinct samples, giving up once there are more than 16.
    let mut palette: Vec<u16> = Vec::with_capacity(17);
    let mut last: u16 = 0;
    let mut have_last = false;
    'scan: for y in y0..y0 + th {
        let mut o = y * row_bytes + x0 * bps;
        for _ in 0..tw {
            let v = sample(cur, bps, o);
            o += bps;
            if have_last && v == last {
                continue;
            }
            last = v;
            have_last = true;
            if !palette.contains(&v) {
                palette.push(v);
                if palette.len() > 16 {
                    break 'scan;
                }
            }
        }
    }

    if palette.len() >= 3 && encode_duo_tile(cur, bps, row_bytes, x0, y0, tw, th, body) {
        return;
    }
    let kind = FrameEncoder::kind_for_distinct_count(palette.len());
    body.push(kind);
    if kind == KIND_RAW {
        for y in y0..y0 + th {
            let start = y * row_bytes + x0 * bps;
            body.extend_from_slice(&cur[start..start + tw * bps]);
        }
        return;
    }
    palette.sort_unstable();
    if kind == KIND_SOLID {
        append_sample(palette[0], bps, body);
        return;
    }
    body.push(palette.len() as u8);
    for &v in &palette {
        append_sample(v, bps, body);
    }

    let bits = kind as usize;
    let mut last_index: u8 = 0;
    have_last = false;
    for y in y0..y0 + th {
        let mut o = y * row_bytes + x0 * bps;
        let mut acc: u8 = 0;
        let mut used = 0usize;
        for _ in 0..tw {
            let v = sample(cur, bps, o);
            o += bps;
            if !(have_last && v == last) {
                last = v;
                have_last = true;
                last_index = palette.iter().position(|&p| p == v).expect("sample in palette") as u8;
            }
            acc |= last_index << (8 - bits - used);
            used += bits;
            if used == 8 {
                body.push(acc);
                acc = 0;
                used = 0;
            }
        }
        if used > 0 {
            body.push(acc);
        }
    }
}

/// Writes the tile as kind 3 and returns true, or writes nothing and
/// returns false when some sub-block has more than two samples.
#[allow(clippy::too_many_arguments)]
fn encode_duo_tile(cur: &[u8], bps: usize, row_bytes: usize, x0: usize, y0: usize, tw: usize, th: usize, body: &mut Vec<u8>) -> bool {
    // First pass: the (low, high) pair of every sub-block, or give up.
    let mut pairs: Vec<(u16, u16)> = Vec::with_capacity(16);
    for sy in (y0..y0 + th).step_by(SUB_BLOCK) {
        let sh = SUB_BLOCK.min(y0 + th - sy);
        for sx in (x0..x0 + tw).step_by(SUB_BLOCK) {
            let sw = SUB_BLOCK.min(x0 + tw - sx);
            let a = sample(cur, bps, sy * row_bytes + sx * bps);
            let mut b = a;
            for y in sy..sy + sh {
                let mut o = y * row_bytes + sx * bps;
                for _ in 0..sw {
                    let v = sample(cur, bps, o);
                    o += bps;
                    if v == a || v == b {
                        continue;
                    }
                    if a != b {
                        return false;
                    }
                    b = v;
                }
            }
            pairs.push((a.min(b), a.max(b)));
        }
    }
    // Second pass: write them.
    body.push(KIND_DUO);
    let mut k = 0;
    for sy in (y0..y0 + th).step_by(SUB_BLOCK) {
        let sh = SUB_BLOCK.min(y0 + th - sy);
        for sx in (x0..x0 + tw).step_by(SUB_BLOCK) {
            let sw = SUB_BLOCK.min(x0 + tw - sx);
            let (lo, hi) = pairs[k];
            k += 1;
            if lo == hi {
                body.push(1);
                append_sample(lo, bps, body);
                continue;
            }
            body.push(2);
            append_sample(lo, bps, body);
            append_sample(hi, bps, body);
            for y in sy..sy + sh {
                let mut o = y * row_bytes + sx * bps;
                let mut acc: u8 = 0;
                let mut used = 0usize;
                for _ in 0..sw {
                    if sample(cur, bps, o) == hi {
                        acc |= 0x80 >> used;
                    }
                    o += bps;
                    used += 1;
                    if used == 8 {
                        body.push(acc);
                        acc = 0;
                        used = 0;
                    }
                }
                if used > 0 {
                    body.push(acc);
                }
            }
        }
    }
    true
}

#[cfg(test)]
mod tests {
    use super::*;

    fn gray(width: usize, height: usize, f: impl Fn(usize, usize) -> u8) -> Vec<u8> {
        (0..height).flat_map(|y| (0..width).map(move |x| (x, y))).map(|(x, y)| f(x, y)).collect()
    }

    #[test]
    fn kinds_by_distinct_count() {
        let want = [(1, 0), (2, 1), (3, 2), (4, 2), (5, 4), (16, 4), (17, 255)];
        for (n, k) in want {
            assert_eq!(FrameEncoder::kind_for_distinct_count(n), k, "{n}");
        }
    }

    #[test]
    fn first_frame_is_full_and_second_identical_is_nothing() {
        let mut e = FrameEncoder::new(Mode::Gray4);
        let s = gray(100, 70, |x, y| ((x / 8 + y / 8) % 16) as u8);
        let first = e.encode(&s, None, 100, 70, None).expect("first frame");
        assert!(first.is_full());
        assert!(first.flags.contains(FrameFlags::START) && first.flags.contains(FrameFlags::END));
        assert_eq!(e.last_tile_count(), 4);
        assert!(e.encode(&s, None, 100, 70, None).is_none());
        assert_eq!(e.last_report().expect("report").changed, Vec::<usize>::new());
    }

    #[test]
    fn solid_tile_stream() {
        let mut e = FrameEncoder::new(Mode::Gray4);
        let s = vec![7u8; 64 * 64];
        e.encode(&s, None, 64, 64, None).expect("frame");
        // count 1; index 0; kind 0; sample 7.
        assert_eq!(e.last_tile_stream(), &[1, 0, 0, 0, 0, 7]);
    }

    #[test]
    fn moved_canvas_shifts_and_zero_fills() {
        let src = [1u8, 2, 3, 4, 5, 6]; // 3 x 2
        assert_eq!(moved_canvas(&src, 3, 2, 1, 3, 2, 1, 0), vec![2, 3, 0, 5, 6, 0]);
        assert_eq!(moved_canvas(&src, 3, 2, 1, 2, 3, 0, -1), vec![0, 0, 1, 2, 4, 5]);
        assert_eq!(moved_canvas(&src, 3, 2, 1, 3, 2, 5, 0), vec![0; 6]);
    }

    #[test]
    fn region_move_sends_one_slice_with_the_offset() {
        let mut e = FrameEncoder::new(Mode::Gray4);
        let s = gray(128, 128, |x, y| ((x * 3 + y * 5) % 16) as u8);
        e.encode(&s, None, 128, 128, Some(CanvasRect::new(0.0, 0.0, 128.0, 128.0)));
        let p = e
            .encode(&s, None, 128, 128, Some(CanvasRect::new(10.0, 0.0, 128.0, 128.0)))
            .expect("a move is never empty");
        assert!(!p.is_full());
        assert_eq!((p.dx, p.dy), (10, 0));
    }

    #[test]
    fn density_change_is_full() {
        let mut e = FrameEncoder::new(Mode::Gray4);
        let s = gray(64, 64, |x, _| (x % 16) as u8);
        e.encode(&s, None, 64, 64, Some(CanvasRect::new(0.0, 0.0, 64.0, 64.0)));
        let p = e.encode(&s, None, 64, 64, Some(CanvasRect::new(0.0, 0.0, 32.0, 32.0))).expect("frame");
        assert!(p.is_full());
    }

    #[test]
    fn best_offset_breaks_ties_to_the_smaller() {
        let used: HashMap<isize, usize> = [(16, 3), (-4, 3), (2, 1)].into_iter().collect();
        assert_eq!(best_offset(&used), Some(-4));
        assert_eq!(best_offset(&HashMap::new()), None);
    }
}
