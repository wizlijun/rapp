import Foundation

/// Frames are cut into square tiles of this many pixels per side.
public let tileSize = 64

// Frame message format (protocol v9, little endian). A frame is one or more
// slices; each slice is one message (type 4):
//   u8 mode; rect region (4 x f32); u16 width; u16 height; u8 flags;
//   [only when `start` and not `full`: i32 dx; i32 dy]; deflate data
// flags: bit0 `full` (replace the canvas: zeroed, stream restarts; needs `start`),
// bit1 `start` (first slice of a frame), bit2 `end` (last slice), bit3 `copies`
// (the frame may use copy tiles; only on a `start` slice). Other bits must be 0.
// A slice without `start` continues the open frame and must follow in order.
// Canvas move (`start`, not `full`): the new canvas is width x height with
// new(x, y) = old(x + dx, y + dy); anything outside the old canvas is 0.
// Reference canvas: the canvas after the move and before any tile of the frame
// is written. Copy tiles (kind 5) read from it, never from the half-built frame.
// Slice body: u16 count, then per tile u16 index, u8 kind, kind data. Kind 5
// (copy) data: u16 sx; u16 sy, the top left of a source rectangle of the tile's
// own size in the reference canvas; it must lie inside it (sx + tw <= width,
// sy + th <= height) and is only valid in a frame that has `copies`.

public struct FrameFlags: OptionSet, Equatable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let full = FrameFlags(rawValue: 1)
    public static let start = FrameFlags(rawValue: 2)
    public static let end = FrameFlags(rawValue: 4)
    public static let copies = FrameFlags(rawValue: 8)
}

/// One encoded frame slice: the sample mode, the canvas size, the frame flags
/// (and for a non-full `start` slice the canvas move) and the deflate-compressed tile data.
public struct FramePayload: Equatable {
    public var mode: Mode
    public var width: UInt16
    public var height: UInt16
    public var flags: FrameFlags
    public var dx: Int32
    public var dy: Int32
    public var data: [UInt8]
    public var isFull: Bool { flags.contains(.full) }

    public init(mode: Mode = .gray4, width: UInt16, height: UInt16, flags: FrameFlags,
                dx: Int32 = 0, dy: Int32 = 0, data: [UInt8]) {
        self.mode = mode
        self.width = width
        self.height = height
        self.flags = flags
        self.dx = dx
        self.dy = dy
        self.data = data
    }
}

// Tile kinds on the wire. Palette kinds are named by their bits per pixel.
private let kindSolid: UInt8 = 0
private let kindDuo: UInt8 = 3
private let kindCopy: UInt8 = 5
private let kindRaw: UInt8 = 255
/// Side of a two-tone sub-block inside a tile.
private let subBlock = 16
private let maxTiles = 65535
/// The largest canvas a decoder accepts (8192 × 8192 samples), so a bad
/// header cannot make the client allocate hundreds of megabytes.
private let maxPixels = 8192 * 8192

private func tileGrid(width: Int, height: Int) -> (cols: Int, rows: Int) {
    ((width + tileSize - 1) / tileSize, (height + tileSize - 1) / tileSize)
}

/// The canvas move shared by encoder and decoder: `src` (`width` x `height`,
/// `bytesPerPixel` bytes each) moved into a new `w` x `h` canvas with
/// new(x, y) = old(x + dx, y + dy); anything outside the old canvas is 0.
func movedCanvas(_ src: [UInt8], width: Int, height: Int, bytesPerPixel bpp: Int,
                 to w: Int, _ h: Int, dx: Int, dy: Int) -> [UInt8] {
    var moved = [UInt8](repeating: 0, count: w * h * bpp)
    let x0 = max(0, -dx), x1 = min(w, width - dx)
    let y0 = max(0, -dy), y1 = min(h, height - dy)
    guard x1 > x0, y1 > y0 else { return moved }
    let n = (x1 - x0) * bpp
    src.withUnsafeBufferPointer { s in
        moved.withUnsafeMutableBufferPointer { d in
            for y in y0..<y1 {
                let from = ((y + dy) * width + x0 + dx) * bpp, to = (y * w + x0) * bpp
                (d.baseAddress! + to).update(from: s.baseAddress! + from, count: n)
            }
        }
    }
    return moved
}

/// Encodes a stream of frames. Each frame is compared with the encoder's model
/// of the client's canvas (moved first when the region moves), and only tiles that differ are sent.
///
/// Frame body before compression (little-endian):
///
///     u16 tileCount
///     tileCount times:
///       u16 tileIndex   row-major, ceil(width / 64) tiles per row
///       u8  kind        0 solid, 1/2/4 palette with that many bits per pixel,
///                       3 two-tone sub-blocks, 255 raw
///       kind 0:     one sample
///       kind 1/2/4: u8 n, n samples (ascending), then index bits row by row,
///                   most significant bit first, each row padded to a whole byte
///       kind 3:     the tile's 16x16 sub-blocks row by row, each:
///                   u8 n (1 or 2), n samples (ascending), and for n = 2 one bit
///                   per pixel (0 = the smaller sample) row by row, most
///                   significant bit first, each row padded to a whole byte
///       kind 255:   every sample of the tile, row by row
///
/// Edge tiles are min(64, width - x0) by min(64, height - y0) pixels, and
/// edge sub-blocks likewise keep their real size. Kind 3 is chosen whenever a
/// tile has at least 3 distinct samples and every sub-block has at most 2,
/// whatever the mode.
public final class FrameEncoder {
    private let mode: Mode
    private let bps: Int
    private let deflate = DeflateStream()
    /// The model of the decoder's canvas: what the client shows after the last frame.
    private var previous = [UInt8]()
    private var previousWidth = 0
    private var previousHeight = 0
    /// The raw BGRA of the last frame, kept only in two-tone modes when the frame
    /// came with raw pixels. Every model sample is a correct quantization of the
    /// key pixel at the same place (maybe under another 16x16 block alignment).
    private var previousKey: [UInt8]?
    /// The captured region (points) and pixels per point of the last frame.
    private var previousRegion = CanvasRect(x: 0, y: 0, w: 0, h: 0)
    private var previousScale = 0.0
    var forceFull = true
    /// Compressed / raw size of the previous frame, used to estimate slice sizes.
    private var ratio = 1.0

    /// Number of tiles in the frame most recently returned by `encode` or `encodeSlices`.
    public private(set) var lastTileCount = 0
    /// True when the last encode left some tile unsent only because its raw
    /// pixels matched, so the canvas there differs from this frame's samples.
    public private(set) var lastEncodeDiverged = false
    /// True when the last encode made the canvas newly approximate: a tile was
    /// accepted on raw pixels only as a copy, or against the old picture moved
    /// by a nonzero offset. A raw match in place on an unmoved canvas does not
    /// count; that approximation was already there. Full frames and
    /// `encodeSettle` clear it.
    public private(set) var lastEncodeAddedApproximation = false
    /// True from such an encode until a full frame, or the `encodeSettle` call
    /// that sends the last differing tile, makes the canvas exact again.
    public private(set) var needsSettle = false
    /// The decoder's canvas as this encoder models it (for tests).
    internal var model: [UInt8] { previous }
    /// Whether frames may use copy tiles (off only to measure against).
    var copiesEnabled = true
    /// The samples of the last frame, for `encodeSettle`.
    private var lastSamples = [UInt8]()
    /// The scroll offset most copy tiles of the last frame with copies used.
    private var lastDy: Int?
    private var detector = ScrollDetector()
    /// At most this many voted scroll offsets are tried per frame (plus `lastDy`).
    private static let maxCandidates = 3
    /// Compressed / uncompressed size of the last settle frame, to guess how
    /// many tiles the next one can take.
    private var settleRatio = 1.0

    public init(mode: Mode) {
        self.mode = mode
        self.bps = mode.bytesPerSample
    }

    /// Makes the next `encode` produce a full frame.
    public func reset() {
        forceFull = true
    }

    static func kind(forDistinctCount n: Int) -> UInt8 {
        switch n {
        case 1: return kindSolid
        case 2: return 1
        case 3...4: return 2
        case 5...16: return 4
        default: return kindRaw
        }
    }

    /// Returns nil when nothing changed. See `encodeSlices` for the arguments
    /// and for when a frame is full.
    public func encode(samples: [UInt8], raw: [UInt8]? = nil, width: Int, height: Int,
                       region: CanvasRect? = nil) -> FramePayload? {
        encodeSlices(samples: samples, raw: raw, width: width, height: height, region: region, limit: Int.max).first
    }

    /// Pixel offset between two region origins (points) at `scale` pixels per
    /// point. Clamped to ±65536: any bigger offset leaves nothing of a canvas of
    /// at most 65535 pixels, exactly like the real one would.
    private static func pixelOffset(from a: Float, to b: Float, scale: Double) -> Int {
        let d = (Double(b) * scale).rounded() - (Double(a) * scale).rounded()
        guard d.isFinite else { return 0 }
        return Int(max(-65536, min(65536, d)))
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
    /// Returns at most one payload, and `[]` when `needsSettle` is false, no
    /// tile differs or the next frame must be full anyway. `needsSettle` stays
    /// true until the call that sends the last differing tile.
    public func encodeSettle(limit: Int) -> [FramePayload] {
        guard needsSettle, !forceFull else { return [] }
        let width = previousWidth, height = previousHeight
        let (cols, rows) = tileGrid(width: width, height: height)
        let rowBytes = width * bps
        // Tile bytes to gather: what the last settle frame suggests fits, a little under the limit.
        let budget = max(limit, Int(Double(limit) * 0.9 / settleRatio))
        var body: [UInt8] = [0, 0]
        // The differing tiles gathered, and where each ends in `body`.
        var tiles = [(x0: Int, y0: Int, tw: Int, th: Int, end: Int)]()
        var more = false
        lastSamples.withUnsafeBufferPointer { cur in
        previous.withUnsafeBufferPointer { old in
            scan: for ty in 0..<rows {
                let y0 = ty * tileSize, th = min(tileSize, height - y0)
                for tx in 0..<cols {
                    let x0 = tx * tileSize, tw = min(tileSize, width - x0)
                    if tileEqual(cur, old, stride: rowBytes, x0: x0 * bps, y0: y0, w: tw * bps, h: th) { continue }
                    if !tiles.isEmpty && body.count >= budget {
                        more = true
                        break scan
                    }
                    let index = ty * cols + tx
                    body.append(UInt8(index & 0xFF))
                    body.append(UInt8(index >> 8))
                    encodeTile(cur, rowBytes: rowBytes, x0: x0, y0: y0, tw: tw, th: th, into: &body)
                    tiles.append((x0, y0, tw, th, body.count))
                }
            }
        }
        }
        lastEncodeDiverged = false
        lastEncodeAddedApproximation = false
        guard !tiles.isEmpty else {
            needsSettle = false
            return []
        }

        // Compress the first n tiles; while that is over the limit, try fewer.
        var n = tiles.count
        var data: [UInt8]
        while true {
            var group = Array(body[0..<tiles[n - 1].end])
            group[0] = UInt8(n & 0xFF)
            group[1] = UInt8(n >> 8)
            if n == 1 {
                data = deflate.compress(group)
                break
            }
            let trial = deflate.compress(group, ifAtMost: limit)
            if trial.fits {
                data = trial.data
                break
            }
            n = max(1, min(n - 1, Int(Double(n) * Double(limit) * 0.9 / Double(trial.data.count))))
        }
        if n < tiles.count { more = true }
        settleRatio = min(1, max(0.05, Double(data.count) / Double(tiles[n - 1].end)))

        // The canvas now has the last frame's samples in the tiles sent.
        for t in tiles[0..<n] {
            for y in t.y0..<(t.y0 + t.th) {
                let o = y * rowBytes + t.x0 * bps
                previous.replaceSubrange(o..<(o + t.tw * bps), with: lastSamples[o..<(o + t.tw * bps)])
            }
        }
        needsSettle = more
        lastTileCount = n
        return [FramePayload(mode: mode, width: UInt16(width), height: UInt16(height), flags: [.start, .end],
                             data: data)]
    }

    /// Encodes the tiles that differ from the client's canvas and cuts them into
    /// slices by tile rows, top to bottom. A slice is closed once its estimated
    /// compressed size (raw bytes of its tiles times the previous frame's
    /// compression ratio, a copy tile counting 4 bytes) exceeds `limit`
    /// (`firstLimit` for the first slice); a slice always holds at least one row.
    ///
    /// A changed tile whose content is found, exactly, some rows up or down in
    /// the old picture (after the move, wholly inside the part it covers) is
    /// sent as a copy tile; the offsets tried are the ones `ScrollDetector`
    /// votes for and the one the last copies used. Samples must match, or in
    /// two-tone modes the raw pixels (that also sets `lastEncodeDiverged`).
    ///
    /// `region` is the captured area in points (nil: `(0, 0, width, height)`).
    /// `raw` is the frame's tightly packed BGRA (`width * height * 4` bytes); it
    /// is used only in two-tone modes, where a tile whose raw pixels match the
    /// last frame's is not sent even if its samples differ (see `needsSettle`).
    ///
    /// The frame is full (`isFull`, and it restarts the compression stream) for
    /// the first frame, after `reset()` and when the pixels per point change by
    /// more than 1 %. Otherwise a new size or region origin moves the canvas: the
    /// first slice carries the size and offset, the old picture is kept where it
    /// still covers the new canvas, and only tiles that changed or reach outside
    /// it are sent.
    ///
    /// The first slice has `.start` (and `.full` for a full frame), the last `.end`;
    /// the slices must be decoded in order. Returns `[]` when nothing changed and
    /// the canvas does not move; a move with no changed tile is one empty slice.
    /// The encoder treats the whole frame as sent: after dropping slices the
    /// caller must set `forceFull`.
    public func encodeSlices(samples: [UInt8], raw: [UInt8]? = nil, width: Int, height: Int,
                             region: CanvasRect? = nil, limit: Int, firstLimit: Int? = nil) -> [FramePayload] {
        precondition(width > 0 && height > 0 && width <= 0xFFFF && height <= 0xFFFF, "bad frame size")
        precondition(samples.count == width * height * bps, "sample count does not match frame size")
        let (cols, rows) = tileGrid(width: width, height: height)
        precondition(cols * rows <= maxTiles, "frame too large")
        let raw = mode == .duogray || mode == .duocolor ? raw : nil
        if let raw { precondition(raw.count == width * height * 4, "raw pixel count does not match frame size") }
        let region = region ?? CanvasRect(x: 0, y: 0, w: Float(width), h: Float(height))
        let scale = Double(width) / Double(region.w)

        // Density change; written as !(<=) so a NaN previous scale also means full.
        let full = forceFull || !(scale.isFinite && scale > 0) || !(abs(scale / previousScale - 1) <= 0.01)
        var dx = 0, dy = 0
        var moved = false
        // The model after the move, the raw key moved likewise (only when both
        // frames have raw), and the part of the new canvas the old picture covers.
        var old = previous
        var key: [UInt8]?
        var cover = (x0: 0, y0: 0, x1: width, y1: height)
        if !full {
            dx = FrameEncoder.pixelOffset(from: previousRegion.x, to: region.x, scale: scale)
            dy = FrameEncoder.pixelOffset(from: previousRegion.y, to: region.y, scale: scale)
            moved = dx != 0 || dy != 0 || width != previousWidth || height != previousHeight
            key = raw == nil ? nil : previousKey
            if moved {
                old = movedCanvas(previous, width: previousWidth, height: previousHeight, bytesPerPixel: bps,
                                  to: width, height, dx: dx, dy: dy)
                if let k = key {
                    key = movedCanvas(k, width: previousWidth, height: previousHeight, bytesPerPixel: 4,
                                      to: width, height, dx: dx, dy: dy)
                }
                cover = (max(0, -dx), max(0, -dy), min(width, previousWidth - dx), min(height, previousHeight - dy))
            }
        }

        let rowBytes = width * bps
        var groups = [[UInt8]]()
        var body: [UInt8] = [0, 0]
        var count = 0
        var groupRaw = 0
        var totalCount = 0
        var totalRaw = 0
        var currentLimit = firstLimit ?? limit
        // Tiles left unsent only because their raw pixels matched: (x0, y0, tw, th).
        var diverged = [(Int, Int, Int, Int)]()
        // Copy tiles that matched on raw pixels only: (x0, y0, tw, th, source y).
        var rawCopies = [(Int, Int, Int, Int, Int)]()
        // Copy tiles per scroll offset used.
        var used = [Int: Int]()
        let useCopies = copiesEnabled && !full

        func closeGroup() {
            body[0] = UInt8(count & 0xFF)
            body[1] = UInt8(count >> 8)
            groups.append(body)
            totalCount += count
            totalRaw += groupRaw
            body = [0, 0]
            count = 0
            groupRaw = 0
            currentLimit = limit
        }

        let rawCur = raw ?? [], rawOld = key ?? []
        let compareRaw = key != nil
        samples.withUnsafeBufferPointer { cur in
        old.withUnsafeBufferPointer { old in
        rawCur.withUnsafeBufferPointer { rawCur in
        rawOld.withUnsafeBufferPointer { rawOld in
            // First pass: the tiles that changed in place. Only a tile wholly
            // inside the old picture can be left as it is.
            var changed = [Bool](repeating: true, count: cols * rows)
            var changedCount = 0
            for ty in 0..<rows {
                let y0 = ty * tileSize, th = min(tileSize, height - y0)
                for tx in 0..<cols {
                    let x0 = tx * tileSize, tw = min(tileSize, width - x0)
                    if !full && x0 >= cover.x0 && x0 + tw <= cover.x1 && y0 >= cover.y0 && y0 + th <= cover.y1 {
                        if tileEqual(cur, old, stride: rowBytes, x0: x0 * bps, y0: y0, w: tw * bps, h: th) {
                            changed[ty * cols + tx] = false
                            continue
                        }
                        if compareRaw && tileEqual(rawCur, rawOld, stride: width * 4, x0: x0 * 4, y0: y0,
                                                   w: tw * 4, h: th) {
                            changed[ty * cols + tx] = false
                            diverged.append((x0, y0, tw, th))
                            continue
                        }
                    }
                    changedCount += 1
                }
            }

            // The scroll offsets to try: voted ones when enough changed, and the last used.
            var candidates = [Int]()
            if useCopies && changedCount > 0 {
                if changedCount >= 4 {
                    candidates = compareRaw
                        ? detector.candidates(cur: rawCur, old: rawOld, bpp: 4, width: width, height: height,
                                              changed: changed, cover: cover, limit: FrameEncoder.maxCandidates)
                        : detector.candidates(cur: cur, old: old, bpp: bps, width: width, height: height,
                                              changed: changed, cover: cover, limit: FrameEncoder.maxCandidates)
                }
                if let d = lastDy, !candidates.contains(d) { candidates.append(d) }
            }

            // Second pass: copy what is found in the old picture, encode the rest.
            for ty in 0..<rows {
                let y0 = ty * tileSize, th = min(tileSize, height - y0)
                for tx in 0..<cols where changed[ty * cols + tx] {
                    let x0 = tx * tileSize, tw = min(tileSize, width - x0)
                    let index = ty * cols + tx
                    body.append(UInt8(index & 0xFF))
                    body.append(UInt8(index >> 8))
                    if !candidates.isEmpty && x0 >= cover.x0 && x0 + tw <= cover.x1 {
                        // Samples first (exact), then raw pixels.
                        var source: Int?
                        for d in candidates where y0 + d >= cover.y0 && y0 + d + th <= cover.y1 {
                            if tileEqual(cur, old, stride: rowBytes, x0: x0 * bps, y0: y0, w: tw * bps, h: th, dy: d) {
                                source = d
                                break
                            }
                        }
                        if source == nil && compareRaw {
                            for d in candidates where y0 + d >= cover.y0 && y0 + d + th <= cover.y1 {
                                if tileEqual(rawCur, rawOld, stride: width * 4, x0: x0 * 4, y0: y0, w: tw * 4, h: th,
                                             dy: d) {
                                    source = d
                                    rawCopies.append((x0, y0, tw, th, y0 + d))
                                    break
                                }
                            }
                        }
                        if let d = source {
                            let sy = y0 + d
                            body.append(kindCopy)
                            body.append(contentsOf: [UInt8(x0 & 0xFF), UInt8(x0 >> 8), UInt8(sy & 0xFF), UInt8(sy >> 8)])
                            used[d, default: 0] += 1
                            count += 1
                            groupRaw += 4
                            continue
                        }
                    }
                    encodeTile(cur, rowBytes: rowBytes, x0: x0, y0: y0, tw: tw, th: th, into: &body)
                    count += 1
                    groupRaw += tw * th * bps
                }
                // Close the slice at a row boundary once it is estimated over the limit.
                if count > 0 && Double(groupRaw) * ratio > Double(currentLimit) { closeGroup() }
            }
        }
        }
        }
        }
        if count > 0 || (groups.isEmpty && moved) { closeGroup() }

        // The new model is this frame's samples, except in tiles that only
        // matched on raw pixels: those keep the old samples, moved, from the
        // same place or the copy source (the old picture before any tile, like
        // the decoder's reference canvas).
        if diverged.isEmpty && rawCopies.isEmpty {
            previous = samples
        } else {
            var model = samples
            for (x0, y0, tw, th) in diverged {
                for y in y0..<(y0 + th) {
                    let o = y * rowBytes + x0 * bps
                    model.replaceSubrange(o..<(o + tw * bps), with: old[o..<(o + tw * bps)])
                }
            }
            for (x0, y0, tw, th, sy) in rawCopies {
                for y in 0..<th {
                    let o = (y0 + y) * rowBytes + x0 * bps, s = (sy + y) * rowBytes + x0 * bps
                    model.replaceSubrange(o..<(o + tw * bps), with: old[s..<(s + tw * bps)])
                }
            }
            previous = model
        }
        if full {
            lastDy = nil
        } else if let best = used.max(by: { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }) {
            lastDy = best.key
        }
        lastEncodeDiverged = !diverged.isEmpty || !rawCopies.isEmpty
        lastEncodeAddedApproximation = !rawCopies.isEmpty || (!diverged.isEmpty && (dx != 0 || dy != 0))
        needsSettle = lastEncodeDiverged || (needsSettle && !full)
        lastSamples = samples
        previousKey = raw
        previousWidth = width
        previousHeight = height
        previousRegion = region
        previousScale = scale
        if groups.isEmpty { return [] }

        if full { deflate.reset() }
        var slices = [FramePayload]()
        var compressed = 0
        for (i, group) in groups.enumerated() {
            let data = deflate.compress(group)
            compressed += data.count
            var flags: FrameFlags = []
            if i == 0 {
                flags.insert(.start)
                if full { flags.insert(.full) }
                if !used.isEmpty { flags.insert(.copies) }
            }
            if i == groups.count - 1 { flags.insert(.end) }
            slices.append(FramePayload(mode: mode, width: UInt16(width), height: UInt16(height), flags: flags,
                                       dx: i == 0 ? Int32(dx) : 0, dy: i == 0 ? Int32(dy) : 0, data: data))
        }
        forceFull = false
        lastTileCount = totalCount
        if totalRaw > 0 { ratio = min(1, max(0.05, Double(compressed) / Double(totalRaw))) }
        return slices
    }

    /// Whether the `w`-byte by `h`-row rectangle at byte `x0` of row `y0` in `a`
    /// is the same as the one `dy` rows lower in `b`.
    @inline(__always)
    private func tileEqual(_ a: UnsafeBufferPointer<UInt8>, _ b: UnsafeBufferPointer<UInt8>, stride: Int,
                           x0: Int, y0: Int, w: Int, h: Int, dy: Int = 0) -> Bool {
        guard let pa = a.baseAddress, let pb = b.baseAddress else { return false }
        for y in y0..<(y0 + h) where memcmp(pa + y * stride + x0, pb + (y + dy) * stride + x0, w) != 0 {
            return false
        }
        return true
    }

    @inline(__always)
    private func sample(_ p: UnsafeBufferPointer<UInt8>, _ offset: Int) -> UInt16 {
        bps == 1 ? UInt16(p[offset]) : UInt16(p[offset]) | UInt16(p[offset + 1]) << 8
    }

    private func appendSample(_ v: UInt16, to body: inout [UInt8]) {
        body.append(UInt8(v & 0xFF))
        if bps == 2 { body.append(UInt8(v >> 8)) }
    }

    private func encodeTile(_ cur: UnsafeBufferPointer<UInt8>, rowBytes: Int, x0: Int, y0: Int,
                            tw: Int, th: Int, into body: inout [UInt8]) {
        // Collect the distinct samples, giving up once there are more than 16.
        var palette = [UInt16]()
        palette.reserveCapacity(17)
        var last: UInt16 = 0
        var haveLast = false
        scan: for y in y0..<(y0 + th) {
            var o = y * rowBytes + x0 * bps
            for _ in 0..<tw {
                let v = sample(cur, o)
                o += bps
                if haveLast && v == last { continue }
                last = v
                haveLast = true
                if !palette.contains(v) {
                    palette.append(v)
                    if palette.count > 16 { break scan }
                }
            }
        }

        if palette.count >= 3 && encodeDuoTile(cur, rowBytes: rowBytes, x0: x0, y0: y0, tw: tw, th: th, into: &body) {
            return
        }
        let kind = FrameEncoder.kind(forDistinctCount: palette.count)
        body.append(kind)
        if kind == kindRaw {
            for y in y0..<(y0 + th) {
                let start = y * rowBytes + x0 * bps
                body.append(contentsOf: cur[start..<(start + tw * bps)])
            }
            return
        }
        palette.sort()
        if kind == kindSolid {
            appendSample(palette[0], to: &body)
            return
        }
        body.append(UInt8(palette.count))
        for v in palette { appendSample(v, to: &body) }

        let bits = Int(kind)
        var lastIndex: UInt8 = 0
        haveLast = false
        for y in y0..<(y0 + th) {
            var o = y * rowBytes + x0 * bps
            var acc: UInt8 = 0
            var used = 0
            for _ in 0..<tw {
                let v = sample(cur, o)
                o += bps
                if !(haveLast && v == last) {
                    last = v
                    haveLast = true
                    lastIndex = UInt8(palette.firstIndex(of: v)!)
                }
                acc |= lastIndex << UInt8(8 - bits - used)
                used += bits
                if used == 8 {
                    body.append(acc)
                    acc = 0
                    used = 0
                }
            }
            if used > 0 { body.append(acc) }
        }
    }

    /// Writes the tile as kind 3 and returns true, or writes nothing and
    /// returns false when some sub-block has more than two samples.
    private func encodeDuoTile(_ cur: UnsafeBufferPointer<UInt8>, rowBytes: Int, x0: Int, y0: Int,
                               tw: Int, th: Int, into body: inout [UInt8]) -> Bool {
        // First pass: the (low, high) pair of every sub-block, or give up.
        var pairs = [(UInt16, UInt16)]()
        pairs.reserveCapacity(16)
        for sy in stride(from: y0, to: y0 + th, by: subBlock) {
            let sh = min(subBlock, y0 + th - sy)
            for sx in stride(from: x0, to: x0 + tw, by: subBlock) {
                let sw = min(subBlock, x0 + tw - sx)
                let a = sample(cur, sy * rowBytes + sx * bps)
                var b = a
                for y in sy..<(sy + sh) {
                    var o = y * rowBytes + sx * bps
                    for _ in 0..<sw {
                        let v = sample(cur, o)
                        o += bps
                        if v == a || v == b { continue }
                        if a != b { return false }
                        b = v
                    }
                }
                pairs.append((min(a, b), max(a, b)))
            }
        }
        // Second pass: write them.
        body.append(kindDuo)
        var k = 0
        for sy in stride(from: y0, to: y0 + th, by: subBlock) {
            let sh = min(subBlock, y0 + th - sy)
            for sx in stride(from: x0, to: x0 + tw, by: subBlock) {
                let sw = min(subBlock, x0 + tw - sx)
                let (lo, hi) = pairs[k]
                k += 1
                if lo == hi {
                    body.append(1)
                    appendSample(lo, to: &body)
                    continue
                }
                body.append(2)
                appendSample(lo, to: &body)
                appendSample(hi, to: &body)
                for y in sy..<(sy + sh) {
                    var o = y * rowBytes + sx * bps
                    var acc: UInt8 = 0
                    var used = 0
                    for _ in 0..<sw {
                        if sample(cur, o) == hi { acc |= 0x80 >> UInt8(used) }
                        o += bps
                        used += 1
                        if used == 8 {
                            body.append(acc)
                            acc = 0
                            used = 0
                        }
                    }
                    if used > 0 { body.append(acc) }
                }
            }
        }
        return true
    }
}

/// Rebuilds the sample canvas from the frames of a `FrameEncoder`.
public final class FrameDecoder {
    /// The mode of the current canvas; a full frame adopts its own mode.
    public private(set) var mode: Mode
    private var bps: Int
    private let inflate = InflateStream()

    public private(set) var width = 0
    public private(set) var height = 0
    public private(set) var samples = [UInt8]()

    public init(mode: Mode = .gray4) {
        self.mode = mode
        self.bps = mode.bytesPerSample
    }

    private var open = false
    private var hold = false
    private var shown = false
    private var reference: [UInt8]?

    /// Decodes one slice. A full frame rebuilds the canvas at the frame's mode and
    /// size and restarts the decompression stream; a non-full `start` slice may move
    /// the canvas; other slices continue the open frame. Returns true when the
    /// display may be updated now: always for ordinary deltas and the session's
    /// first full frame, otherwise only after the `end` slice of a frame that
    /// replaces the picture or moves it.
    /// After a throw the canvas is undefined: it is emptied (`width` 0) and only a
    /// full frame can resume decoding.
    @discardableResult
    public func decode(_ frame: FramePayload) throws -> Bool {
        do {
            return try decodeSlice(frame)
        } catch {
            open = false
            hold = false
            reference = nil
            width = 0
            height = 0
            samples = []
            throw error
        }
    }

    private func decodeSlice(_ frame: FramePayload) throws -> Bool {
        let flags = frame.flags
        guard FrameFlags(rawValue: flags.rawValue & 0x0F) == flags else { throw CodecError("unknown frame flags") }
        if flags.contains(.full) && !flags.contains(.start) { throw CodecError("full frame without start") }
        if flags.contains(.copies) && !flags.contains(.start) { throw CodecError("copies without start") }
        let w = Int(frame.width), h = Int(frame.height)
        if flags.contains(.start) {
            guard w > 0, h > 0 else { throw CodecError("frame has zero size") }
            let grid = tileGrid(width: w, height: h)
            guard grid.cols * grid.rows <= maxTiles, w * h <= maxPixels else { throw CodecError("frame too large") }
            if flags.contains(.full) {
                inflate.reset()
                mode = frame.mode
                bps = frame.mode.bytesPerSample
                width = w
                height = h
                samples = [UInt8](repeating: 0, count: w * h * bps)
                hold = shown
            } else {
                guard !open else { throw CodecError("frame started while another is open") }
                guard width > 0 else { throw CodecError("update frame before any full frame") }
                guard frame.mode == mode else { throw CodecError("update frame mode does not match canvas") }
                let dx = Int(frame.dx), dy = Int(frame.dy)
                hold = w != width || h != height || dx != 0 || dy != 0
                if hold { moveCanvas(width: w, height: h, dx: dx, dy: dy) }
            }
            open = true
            reference = flags.contains(.copies) ? samples : nil
        } else {
            guard open else { throw CodecError("slice without an open frame") }
            guard w == width, h == height else { throw CodecError("update frame size does not match canvas") }
            guard frame.mode == mode else { throw CodecError("update frame mode does not match canvas") }
        }
        let display = !hold || flags.contains(.end)
        if flags.contains(.end) {
            open = false
            shown = true
        }
        defer { if flags.contains(.end) { reference = nil } }

        let (cols, rows) = tileGrid(width: width, height: height)
        // Count, then per tile its header and at most every sample raw.
        let largestBody = 2 + cols * rows * (3 + tileSize * tileSize * bps)
        let body = try inflate.decompress(frame.data, limit: largestBody)
        let rowBytes = width * bps
        var pos = 0

        func need(_ n: Int) throws {
            if n < 0 || pos + n > body.count { throw CodecError("frame data is truncated") }
        }
        func readSample() throws -> UInt16 {
            try need(bps)
            defer { pos += bps }
            return bps == 1 ? UInt16(body[pos]) : UInt16(body[pos]) | UInt16(body[pos + 1]) << 8
        }

        try need(2)
        let count = Int(body[0]) | Int(body[1]) << 8
        pos = 2

        for _ in 0..<count {
            try need(3)
            let index = Int(body[pos]) | Int(body[pos + 1]) << 8
            let kind = body[pos + 2]
            pos += 3
            guard index < cols * rows else { throw CodecError("tile index out of range") }
            let x0 = (index % cols) * tileSize, y0 = (index / cols) * tileSize
            let tw = min(tileSize, width - x0), th = min(tileSize, height - y0)

            switch kind {
            case kindRaw:
                try need(tw * th * bps)
                for y in 0..<th {
                    let dst = (y0 + y) * rowBytes + x0 * bps
                    samples.replaceSubrange(dst..<(dst + tw * bps), with: body[pos..<(pos + tw * bps)])
                    pos += tw * bps
                }
            case kindSolid:
                let v = try readSample()
                for y in 0..<th {
                    var dst = (y0 + y) * rowBytes + x0 * bps
                    for _ in 0..<tw {
                        samples[dst] = UInt8(v & 0xFF)
                        if bps == 2 { samples[dst + 1] = UInt8(v >> 8) }
                        dst += bps
                    }
                }
            case 1, 2, 4:
                let bits = Int(kind)
                try need(1)
                let n = Int(body[pos])
                pos += 1
                guard n >= 1, n <= 1 << bits else { throw CodecError("bad palette size") }
                var palette = [UInt16]()
                palette.reserveCapacity(n)
                for _ in 0..<n { palette.append(try readSample()) }
                let bytesPerTileRow = (tw * bits + 7) / 8
                try need(bytesPerTileRow * th)
                let mask = UInt8((1 << bits) - 1)
                for y in 0..<th {
                    var dst = (y0 + y) * rowBytes + x0 * bps
                    for x in 0..<tw {
                        let bitPos = x * bits
                        let i = Int((body[pos + bitPos / 8] >> UInt8(8 - bits - bitPos % 8)) & mask)
                        guard i < n else { throw CodecError("palette index out of range") }
                        let v = palette[i]
                        samples[dst] = UInt8(v & 0xFF)
                        if bps == 2 { samples[dst + 1] = UInt8(v >> 8) }
                        dst += bps
                    }
                    pos += bytesPerTileRow
                }
            case kindDuo:
                for sy in stride(from: y0, to: y0 + th, by: subBlock) {
                    let sh = min(subBlock, y0 + th - sy)
                    for sx in stride(from: x0, to: x0 + tw, by: subBlock) {
                        let sw = min(subBlock, x0 + tw - sx)
                        try need(1)
                        let n = Int(body[pos])
                        pos += 1
                        guard n == 1 || n == 2 else { throw CodecError("bad two-tone sub-block") }
                        let lo = try readSample()
                        let hi = n == 2 ? try readSample() : lo
                        let bytesPerRow = n == 2 ? (sw + 7) / 8 : 0
                        try need(bytesPerRow * sh)
                        for y in 0..<sh {
                            var dst = (sy + y) * rowBytes + sx * bps
                            for x in 0..<sw {
                                let v = n == 2 && body[pos + x / 8] & (0x80 >> UInt8(x % 8)) != 0 ? hi : lo
                                samples[dst] = UInt8(v & 0xFF)
                                if bps == 2 { samples[dst + 1] = UInt8(v >> 8) }
                                dst += bps
                            }
                            pos += bytesPerRow
                        }
                    }
                }
            case kindCopy:
                try need(4)
                let sx = Int(body[pos]) | Int(body[pos + 1]) << 8
                let sy = Int(body[pos + 2]) | Int(body[pos + 3]) << 8
                pos += 4
                guard let ref = reference else { throw CodecError("copy tile without copies flag") }
                guard sx + tw <= width, sy + th <= height else { throw CodecError("copy source outside canvas") }
                for y in 0..<th {
                    let src = ((sy + y) * width + sx) * bps
                    let dst = (y0 + y) * rowBytes + x0 * bps
                    samples.replaceSubrange(dst..<(dst + tw * bps), with: ref[src..<(src + tw * bps)])
                }
            default:
                throw CodecError("unknown tile kind \(kind)")
            }
        }
        guard pos == body.count else { throw CodecError("unexpected data after last tile") }
        return display
    }

    /// New canvas of `w` x `h` with new(x, y) = old(x + dx, y + dy); the rest is 0.
    private func moveCanvas(width w: Int, height h: Int, dx: Int, dy: Int) {
        samples = movedCanvas(samples, width: width, height: height, bytesPerPixel: bps, to: w, h, dx: dx, dy: dy)
        width = w
        height = h
    }
}
