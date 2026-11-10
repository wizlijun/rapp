/// Frames are cut into square tiles of this many pixels per side.
public let tileSize = 64

/// One encoded frame: the sample mode, the canvas size, whether it replaces
/// the whole canvas, and the deflate-compressed tile data.
public struct FramePayload: Equatable {
    public var mode: Mode
    public var width: UInt16
    public var height: UInt16
    public var isFull: Bool
    public var data: [UInt8]

    public init(mode: Mode = .gray4, width: UInt16, height: UInt16, isFull: Bool, data: [UInt8]) {
        self.mode = mode
        self.width = width
        self.height = height
        self.isFull = isFull
        self.data = data
    }
}

// Tile kinds on the wire. Palette kinds are named by their bits per pixel.
private let kindSolid: UInt8 = 0
private let kindDuo: UInt8 = 3
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

/// Encodes a stream of frames. Each frame is compared with the last frame
/// this encoder returned, and only tiles that differ are sent.
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
    private var previous = [UInt8]()
    private var previousWidth = 0
    private var previousHeight = 0
    private var forceFull = true

    /// Number of tiles in the frame most recently returned by `encode`.
    public private(set) var lastTileCount = 0

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

    /// Returns nil when nothing changed. The first frame, the frame after a
    /// size change and the frame after `reset()` are full frames (`isFull`),
    /// which also restart the compression stream.
    public func encode(samples: [UInt8], width: Int, height: Int) -> FramePayload? {
        precondition(width > 0 && height > 0 && width <= 0xFFFF && height <= 0xFFFF, "bad frame size")
        precondition(samples.count == width * height * bps, "sample count does not match frame size")
        let (cols, rows) = tileGrid(width: width, height: height)
        precondition(cols * rows <= maxTiles, "frame too large")

        let full = forceFull || width != previousWidth || height != previousHeight
        var body: [UInt8] = [0, 0]
        var count = 0
        let rowBytes = width * bps

        samples.withUnsafeBufferPointer { cur in
            previous.withUnsafeBufferPointer { old in
                for ty in 0..<rows {
                    let y0 = ty * tileSize, th = min(tileSize, height - y0)
                    for tx in 0..<cols {
                        let x0 = tx * tileSize, tw = min(tileSize, width - x0)
                        if !full {
                            var same = true
                            for y in y0..<(y0 + th) {
                                let start = y * rowBytes + x0 * bps
                                if !cur[start..<(start + tw * bps)].elementsEqual(old[start..<(start + tw * bps)]) {
                                    same = false
                                    break
                                }
                            }
                            if same { continue }
                        }
                        let index = ty * cols + tx
                        body.append(UInt8(index & 0xFF))
                        body.append(UInt8(index >> 8))
                        encodeTile(cur, rowBytes: rowBytes, x0: x0, y0: y0, tw: tw, th: th, into: &body)
                        count += 1
                    }
                }
            }
        }

        if !full && count == 0 { return nil }
        body[0] = UInt8(count & 0xFF)
        body[1] = UInt8(count >> 8)
        if full { deflate.reset() }
        previous = samples
        previousWidth = width
        previousHeight = height
        forceFull = false
        lastTileCount = count
        return FramePayload(mode: mode, width: UInt16(width), height: UInt16(height), isFull: full,
                            data: deflate.compress(body))
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

    /// A full frame rebuilds the canvas at the frame's mode and size and restarts the
    /// decompression stream. Any other frame must match the current canvas.
    public func decode(_ frame: FramePayload) throws {
        let w = Int(frame.width), h = Int(frame.height)
        if frame.isFull {
            guard w > 0, h > 0 else { throw CodecError("frame has zero size") }
            let grid = tileGrid(width: w, height: h)
            guard grid.cols * grid.rows <= maxTiles, w * h <= maxPixels else { throw CodecError("frame too large") }
            inflate.reset()
            mode = frame.mode
            bps = frame.mode.bytesPerSample
            width = w
            height = h
            samples = [UInt8](repeating: 0, count: w * h * bps)
        } else {
            guard width > 0 else { throw CodecError("update frame before any full frame") }
            guard w == width, h == height else { throw CodecError("update frame size does not match canvas") }
            guard frame.mode == mode else { throw CodecError("update frame mode does not match canvas") }
        }

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
            default:
                throw CodecError("unknown tile kind \(kind)")
            }
        }
        guard pos == body.count else { throw CodecError("unexpected data after last tile") }
    }
}
