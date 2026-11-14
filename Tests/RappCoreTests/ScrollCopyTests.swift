import XCTest
@testable import RappCore

/// Canvas moves on region changes, the raw key plane and the full-frame rules.
final class ScrollCopyTests: XCTestCase {
    /// The variants every test runs: a mode and whether raw pixels go with the
    /// samples. Without raw nothing is skipped unless its samples match, so the
    /// canvas must equal the quantized frame exactly.
    private let variants: [(mode: Mode, raw: Bool)] = [(.gray4, false), (.color16, false), (.duogray, true), (.duogray, false)]

    private final class Run {
        let enc: FrameEncoder
        let dec: FrameDecoder
        let raw: Bool
        /// Mirrors the decoder's stream so the test can read the tiles on the wire.
        let inflate = InflateStream()
        /// The last frame, when it went with raw pixels: the source the oracle in `step` checks against.
        var previous: SceneFrame?
        /// Copy tiles sent so far, and the frames that carried any.
        var copies = 0, copyFrames = 0
        init(_ v: (mode: Mode, raw: Bool)) {
            enc = FrameEncoder(mode: v.mode)
            dec = FrameDecoder(mode: v.mode)
            raw = v.raw
        }
    }

    private func run(_ v: (mode: Mode, raw: Bool)) -> Run { Run(v) }

    /// One tile on the wire: its index, kind and, for a copy tile, the source.
    private struct WireTile { var index: Int, kind: UInt8, sx = 0, sy = 0 }

    /// Walks a decompressed slice body (format at the top of TileCodec.swift);
    /// nil when it does not parse.
    private func wireTiles(_ body: [UInt8], width: Int, height: Int, bps: Int) -> [WireTile]? {
        guard body.count >= 2 else { return nil }
        let cols = (width + 63) / 64
        var pos = 2, out = [WireTile]()
        for _ in 0..<(Int(body[0]) | Int(body[1]) << 8) {
            guard pos + 3 <= body.count else { return nil }
            let index = Int(body[pos]) | Int(body[pos + 1]) << 8, kind = body[pos + 2]
            pos += 3
            let x0 = index % cols * 64, y0 = index / cols * 64
            let tw = min(64, width - x0), th = min(64, height - y0)
            var tile = WireTile(index: index, kind: kind)
            switch kind {
            case 0: pos += bps
            case 1, 2, 4:
                guard pos < body.count else { return nil }
                pos += 1 + Int(body[pos]) * bps + (tw * Int(kind) + 7) / 8 * th
            case 3:
                for sy in stride(from: 0, to: th, by: 16) {
                    for sx in stride(from: 0, to: tw, by: 16) {
                        guard pos < body.count else { return nil }
                        let n = Int(body[pos])
                        pos += 1 + n * bps + (n == 2 ? (min(16, tw - sx) + 7) / 8 * min(16, th - sy) : 0)
                    }
                }
            case 5:
                guard pos + 4 <= body.count else { return nil }
                tile.sx = Int(body[pos]) | Int(body[pos + 1]) << 8
                tile.sy = Int(body[pos + 2]) | Int(body[pos + 3]) << 8
                pos += 4
            case 255: pos += tw * th * bps
            default: return nil
            }
            out.append(tile)
        }
        return pos == body.count ? out : nil
    }

    /// Whether `n` bytes of `a` from `ai` equal those of `b` from `bi`.
    private func same(_ a: [UInt8], _ ai: Int, _ b: [UInt8], _ bi: Int, _ n: Int) -> Bool {
        a.withUnsafeBufferPointer { a in b.withUnsafeBufferPointer { b in
            memcmp(a.baseAddress! + ai, b.baseAddress! + bi, n) == 0 } }
    }

    /// Encodes `frame` into real-size slices, decodes them all and checks the
    /// canvas against the encoder model, and against the quantized frame unless
    /// the frame went with raw in a two-tone mode. `samples` is the frame
    /// already quantized for the run's mode, if at hand; `raw` overrides the
    /// run's choice for this one frame.
    ///
    /// Copy tiles are read off the wire and checked on their own: same column,
    /// source wholly inside the part of the canvas the old picture covers, and
    /// `.copies` on the first slice only. With raw in a two-tone mode, every tile
    /// where the canvas differs from this frame's samples must be one whose BGRA
    /// equals its source's BGRA in the previous frame (through the canvas move):
    /// the same place for a kept tile, the copy source for a copy tile.
    @discardableResult
    private func step(_ r: Run, _ frame: SceneFrame, _ what: String, samples: [UInt8]? = nil, raw: Bool? = nil,
                      file: StaticString = #filePath, line: UInt = #line) throws -> [FramePayload] {
        let samples = samples ?? ScrollScenes.samples(frame, mode: r.dec.mode)
        let useRaw = raw ?? r.raw
        let twoTone = useRaw && (r.dec.mode == .duogray || r.dec.mode == .duocolor)
        let (pw, ph) = (r.dec.width, r.dec.height)
        let slices = r.enc.encodeSlices(samples: samples, raw: useRaw ? frame.bgra : nil, width: frame.width,
                                        height: frame.height, region: frame.region, limit: 32768, firstLimit: 8192)
        let bps = r.dec.mode.bytesPerSample
        var sent = [Int: WireTile]()
        for (i, s) in slices.enumerated() {
            if s.isFull { r.inflate.reset() }
            let tiles = wireTiles(try r.inflate.decompress(s.data), width: frame.width, height: frame.height, bps: bps)
            XCTAssertNotNil(tiles, "unreadable slice: \(what)", file: file, line: line)
            for t in tiles ?? [] { sent[t.index] = t }
            if i > 0 { XCTAssertFalse(s.flags.contains(.copies), "copies on a later slice: \(what)", file: file, line: line) }
            try r.dec.decode(s)
        }
        XCTAssertEqual(r.dec.width, frame.width, what, file: file, line: line)
        XCTAssertEqual(r.dec.height, frame.height, what, file: file, line: line)
        XCTAssertTrue(r.dec.samples == r.enc.model, "decoder canvas differs from model: \(what)", file: file, line: line)
        if !twoTone {
            XCTAssertTrue(r.dec.samples == samples, "canvas differs from quantized frame: \(what)", file: file, line: line)
        }

        let dx = Int(slices.first?.dx ?? 0), dy = Int(slices.first?.dy ?? 0)
        let cols = (frame.width + 63) / 64, rows = (frame.height + 63) / 64
        func tileRect(_ index: Int) -> (x0: Int, y0: Int, tw: Int, th: Int) {
            let x0 = index % cols * 64, y0 = index / cols * 64
            return (x0, y0, min(64, frame.width - x0), min(64, frame.height - y0))
        }
        let copies = sent.values.filter { $0.kind == 5 }
        if !copies.isEmpty {
            XCTAssertTrue(slices[0].flags.contains(.copies), "copy tiles without .copies: \(what)", file: file, line: line)
            XCTAssertFalse(slices[0].isFull, "copy tiles in a full frame: \(what)", file: file, line: line)
            r.copyFrames += 1
            r.copies += copies.count
        }
        for t in copies {
            let (x0, _, tw, th) = tileRect(t.index)
            XCTAssertEqual(t.sx, x0, "copy is not vertical: \(what)", file: file, line: line)
            // In old canvas coordinates the source must lie wholly inside the old canvas.
            let inside = t.sx + dx >= 0 && t.sx + tw + dx <= pw && t.sy + dy >= 0 && t.sy + th + dy <= ph
            XCTAssertTrue(inside, "copy source \(t.sx),\(t.sy) not in the old picture: \(what)", file: file, line: line)
        }

        if twoTone {
            let rowBytes = frame.width * bps
            for index in 0..<(cols * rows) {
                let (x0, y0, tw, th) = tileRect(index)
                let exact = (y0..<(y0 + th)).allSatisfy {
                    let o = $0 * rowBytes + x0 * bps
                    return same(r.dec.samples, o, samples, o, tw * bps)
                }
                if exact { continue }
                let tile = sent[index]
                guard tile == nil || tile?.kind == 5, let prev = r.previous else {
                    XCTFail("tile \(index) differs from the quantized frame with no raw source: \(what)",
                            file: file, line: line)
                    continue
                }
                // The source in previous-frame coordinates: the copy source (or the same place) through the move.
                let sx = (tile?.sx ?? x0) + dx, sy = (tile?.sy ?? y0) + dy
                guard sx >= 0, sy >= 0, sx + tw <= prev.width, sy + th <= prev.height else {
                    XCTFail("tile \(index) taken from outside the previous frame: \(what)", file: file, line: line)
                    continue
                }
                let equal = (0..<th).allSatisfy { y in
                    let a = ((y0 + y) * frame.width + x0) * 4, b = ((sy + y) * prev.width + sx) * 4
                    return same(frame.bgra, a, prev.bgra, b, tw * 4)
                }
                XCTAssertTrue(equal, "tile \(index) differs from the quantized frame and from its source's BGRA: \(what)",
                              file: file, line: line)
            }
        }
        r.previous = useRaw ? frame : nil
        return slices
    }

    /// The move the encoder must send between two regions at `scale` px/pt.
    private func expectedMove(_ a: CanvasRect, _ b: CanvasRect, scale: Double) -> (Int32, Int32) {
        func px(_ v: Float) -> Double { (Double(v) * scale).rounded() }
        return (Int32(px(b.x) - px(a.x)), Int32(px(b.y) - px(a.y)))
    }

    func testResizeEveryEdgeIsNotFull() throws {
        for v in variants {
            for edge in SceneKind.Edge.allCases {
                let r = run(v)
                let frames = ScrollScenes.frames(seed: 7, count: 12, kinds: [.resize(edge: edge)])
                var sizes = Set<Int>(), moves = 0
                for (i, f) in frames.enumerated() {
                    let what = "\(v) \(edge) frame \(i)"
                    let slices = try step(r, f, what)
                    sizes.insert(edge == .left || edge == .right ? f.width : f.height)
                    if i == 0 { XCTAssertTrue(slices.first?.isFull ?? false, what); continue }
                    XCTAssertFalse(slices.contains { $0.isFull }, what)
                    let prev = frames[i - 1]
                    guard prev.width != f.width || prev.height != f.height else { continue }
                    let first = try XCTUnwrap(slices.first, what)
                    XCTAssertTrue(first.flags.contains(.start), what)
                    let (dx, dy) = expectedMove(prev.region, f.region, scale: 1)
                    XCTAssertEqual(first.dx, dx, what)
                    XCTAssertEqual(first.dy, dy, what)
                    if dx != 0 || dy != 0 { moves += 1 }
                }
                // The scene really grew and shrank, and left/top edges really moved the origin.
                XCTAssertGreaterThanOrEqual(sizes.count, 4, "\(v) \(edge)")
                if edge == .left || edge == .top { XCTAssertGreaterThan(moves, 3, "\(v) \(edge)") }
            }
        }
    }

    /// Opaque blocky pixels in screen space: point (sx, sy) at `scale` px/pt.
    private func screen(x: Double, y: Double, w: Int, h: Int, scale: Int) -> SceneFrame {
        var bgra = [UInt8](repeating: 255, count: w * h * 4 * scale * scale)
        let pw = w * scale, ph = h * scale
        let ox = Int((x * Double(scale)).rounded()), oy = Int((y * Double(scale)).rounded())
        for py in 0..<ph {
            for px in 0..<pw {
                let gx = ox + px, gy = oy + py
                let o = (py * pw + px) * 4
                let v = UInt32(truncatingIfNeeded: (gx / 3) &* 2_654_435_761 ^ (gy / 2) &* 40503)
                bgra[o] = UInt8(v & 0xFF)
                bgra[o + 1] = UInt8(v >> 8 & 0xFF)
                bgra[o + 2] = UInt8(v >> 16 & 0xFF)
            }
        }
        return SceneFrame(bgra: bgra, width: pw, height: ph,
                          region: CanvasRect(x: Float(x), y: Float(y), w: Float(w), h: Float(h)))
    }

    func testDensityOnlyChangeSendsFull() throws {
        for v in variants {
            let r = run(v)
            try step(r, screen(x: 10, y: 20, w: 100, h: 80, scale: 1), "\(v) 1x")
            let twice = try step(r, screen(x: 10, y: 20, w: 100, h: 80, scale: 2), "\(v) 2x")
            XCTAssertTrue(twice.first?.isFull ?? false, "\(v) 2x")
            let back = try step(r, screen(x: 10, y: 20, w: 100, h: 80, scale: 1), "\(v) back to 1x")
            XCTAssertTrue(back.first?.isFull ?? false, "\(v) back to 1x")
            // Within 1 %: 200 px for 199 points is a resize, not a density change.
            var near = screen(x: 10, y: 20, w: 200, h: 80, scale: 1)
            near.region.w = 199
            try step(r, screen(x: 10, y: 20, w: 199, h: 80, scale: 1), "\(v) 199")
            let resized = try step(r, near, "\(v) 200 px for 199 pt")
            XCTAssertFalse(resized.contains { $0.isFull }, "\(v) 200 px for 199 pt")
        }
    }

    func testFractionalAndHugeRegionMoves() throws {
        for v in variants {
            for scale in [1, 2] {
                let r = run(v)
                let what = "\(v) scale \(scale)"
                try step(r, screen(x: 100, y: 50, w: 150, h: 90, scale: scale), what)
                let half = try step(r, screen(x: 100.5, y: 50, w: 150, h: 90, scale: scale), "\(what) +0.5")
                XCTAssertFalse(half.contains { $0.isFull }, "\(what) +0.5")
                if scale == 2 {
                    XCTAssertEqual(half.first?.dx, 1, what)
                    XCTAssertEqual(half.first?.dy, 0, what)
                }
                // Far past the canvas: nothing of the old picture is left, every tile is sent.
                for x in [1_000_000.0, -3_000_000.0, 100] {
                    let f = screen(x: x, y: 50, w: 150, h: 90, scale: scale)
                    let far = try step(r, f, "\(what) x \(x)")
                    XCTAssertFalse(far.contains { $0.isFull }, "\(what) x \(x)")
                    let tiles = ((f.width + 63) / 64) * ((f.height + 63) / 64)
                    XCTAssertEqual(r.enc.lastTileCount, tiles, "\(what) x \(x)")
                }
            }
        }
    }

    func testModelMatchesDecoderRandomized() throws {
        let kinds: [SceneKind] = [.terminalScroll, .webScroll(topBar: 30, sideBar: 50), .resize(edge: .left),
                                  .resize(edge: .right), .resize(edge: .top), .resize(edge: .bottom),
                                  .regionMove, .localChange, .scrollWhileMoving]
        var moves = 0, diverged = 0, copyFrames = 0, copies = 0
        // Kept short: in a debug build quantizing and encoding these takes most of the time.
        for seed in UInt64(1)...6 {
            let frames = ScrollScenes.frames(seed: seed, count: 40, kinds: kinds)
            var quantized = [Mode: [[UInt8]]]()       // both duogray variants share one quantization
            for v in variants where quantized[v.mode] == nil {
                quantized[v.mode] = frames.map { ScrollScenes.samples($0, mode: v.mode) }
            }
            for v in variants {
                let r = run(v)
                for (i, f) in frames.enumerated() {
                    let slices = try step(r, f, "seed \(seed) \(v) frame \(i)", samples: quantized[v.mode]![i])
                    if i > 0 { XCTAssertFalse(slices.contains { $0.isFull }, "seed \(seed) \(v) frame \(i)") }
                    if let first = slices.first, first.dx != 0 || first.dy != 0 { moves += 1 }
                    if r.enc.lastEncodeDiverged { diverged += 1 }
                }
                copyFrames += r.copyFrames
                copies += r.copies
            }
        }
        // The scenes really moved the canvas, raw matches really left samples
        // behind, and scrolls really sent copy tiles.
        XCTAssertGreaterThan(moves, 100)
        XCTAssertGreaterThan(diverged, 40)
        XCTAssertGreaterThan(copyFrames, 30)
        XCTAssertGreaterThan(copies, 60)
    }

    /// Two-tone frames alternate with and without raw: frames without raw end
    /// exact, frames with raw pass the source oracle in `step`, and the canvas
    /// always equals the model.
    func testAlternatingRawAndSamplesOnly() throws {
        let kinds: [SceneKind] = [.terminalScroll, .webScroll(topBar: 30, sideBar: 50), .regionMove,
                                  .scrollWhileMoving, .localChange]
        var withRaw = 0, withoutRaw = 0, copyFrames = 0, diverged = 0
        for seed in UInt64(1)...4 {
            let frames = ScrollScenes.frames(seed: seed, count: 30, kinds: kinds, size: (256, 192))
            let r = run((.duogray, true))
            for (i, f) in frames.enumerated() {
                // Runs of two to four frames each way.
                let useRaw = (i / (2 + Int(seed) % 3)) % 2 == 0
                try step(r, f, "seed \(seed) frame \(i) raw \(useRaw)", raw: useRaw)
                if useRaw { withRaw += 1 } else { withoutRaw += 1 }
                if r.enc.lastEncodeDiverged { diverged += 1 }
            }
            copyFrames += r.copyFrames
        }
        XCTAssertGreaterThan(withRaw, 40)
        XCTAssertGreaterThan(withoutRaw, 40)
        XCTAssertGreaterThan(copyFrames, 20)
        XCTAssertGreaterThan(diverged, 5)
    }

    /// Bytes of every frame after the first with copies on and off, and the
    /// frames that carried copies with them on.
    private func compareBytes(_ v: (mode: Mode, raw: Bool), _ frames: [SceneFrame],
                              file: StaticString = #filePath, line: UInt = #line) throws
        -> (on: Int, off: Int, copyFrames: Int) {
        let samples = frames.map { ScrollScenes.samples($0, mode: v.mode) }
        var bytes = [Int]()
        var copyFrames = 0
        for copies in [true, false] {
            let r = run(v)
            r.enc.copiesEnabled = copies
            var total = 0
            for (i, f) in frames.enumerated() {
                let slices = try step(r, f, "\(v) copies \(copies) frame \(i)", samples: samples[i], file: file, line: line)
                if i > 0 { total += slices.reduce(0) { $0 + $1.data.count } }
            }
            bytes.append(total)
            if copies { copyFrames = r.copyFrames } else { XCTAssertEqual(r.copyFrames, 0, "\(v)", file: file, line: line) }
        }
        return (bytes[0], bytes[1], copyFrames)
    }

    func testTerminalScrollSendsCopies() throws {
        let frames = ScrollScenes.frames(seed: 5, count: 6, kinds: [.terminalScroll], size: (640, 480))
        for v in [(Mode.gray4, false), (.color16, false), (.duogray, true)] {
            let b = try compareBytes(v, frames)
            XCTAssertEqual(b.copyFrames, frames.count - 1, "\(v)")
            XCTAssertLessThanOrEqual(Double(b.on), 0.2 * Double(b.off), "\(v) \(b.on) vs \(b.off)")
        }
    }

    func testWebScrollWithFixedBarsSendsCopies() throws {
        let frames = ScrollScenes.frames(seed: 6, count: 6, kinds: [.webScroll(topBar: 60, sideBar: 200)],
                                         size: (832, 640))
        for v in [(Mode.gray4, false), (.color16, false), (.duogray, true)] {
            let b = try compareBytes(v, frames)
            XCTAssertEqual(b.copyFrames, frames.count - 1, "\(v)")
            XCTAssertLessThanOrEqual(Double(b.on), 0.4 * Double(b.off), "\(v) \(b.on) vs \(b.off)")
        }
    }

    /// A small hash for hand-made pictures.
    private func mix(_ a: Int, _ b: Int) -> UInt64 {
        var z = UInt64(bitPattern: Int64(a &* 31 &+ b)) &* 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 29)) &* 0xBF58_476D_1CE4_E5B9
        return z ^ (z >> 32)
    }

    /// Hand-made BGRA picture of `w` x `h` at region (x, y), the pixel at
    /// region-relative (px, py) given by `pixel`.
    private func picture(x: Float = 0, y: Float, w: Int, h: Int,
                         _ pixel: (Int, Int) -> (UInt8, UInt8, UInt8)) -> SceneFrame {
        var bgra = [UInt8](repeating: 255, count: w * h * 4)
        for py in 0..<h {
            for px in 0..<w {
                let o = (py * w + px) * 4
                (bgra[o], bgra[o + 1], bgra[o + 2]) = pixel(px, py)
            }
        }
        return SceneFrame(bgra: bgra, width: w, height: h, region: CanvasRect(x: x, y: y, w: Float(w), h: Float(h)))
    }

    func testCopiesNeverReadUncovered() throws {
        // Scenes that move the region and scroll in the same frame; `step`
        // checks every copy source against the old picture.
        for v in variants {
            var copyFrames = 0
            for seed in UInt64(1)...4 {
                let r = run(v)
                for (i, f) in ScrollScenes.frames(seed: seed, count: 20, kinds: [.scrollWhileMoving]).enumerated() {
                    try step(r, f, "\(v) seed \(seed) frame \(i)")
                }
                copyFrames += r.copyFrames
            }
            // Samples alone rarely match after a scroll that is not a multiple of 16 in duogray.
            XCTAssertGreaterThan(copyFrames, v == (.duogray, false) ? 1 : 10, "\(v)")
        }
        // A dark page with sparse lines. The region moves up 40 px (the top 40
        // rows of the canvas are uncovered, zero = black) while the page moves
        // down 32 px. Tile row 1 matches 32 px up only by reading 8 uncovered
        // black rows, so it must be sent, not copied; tile row 2 is copied.
        func dark(regionY: Int, scroll: Int) -> SceneFrame {
            picture(y: Float(regionY), w: 256, h: 192) { px, py in
                let doc = regionY + py + scroll
                let on = doc % 50 < 2 && self.mix(doc / 50, px / 8) & 1 == 1
                return on ? (255, 255, 255) : (0, 0, 0)
            }
        }
        for v in variants {
            let r = run(v)
            try step(r, dark(regionY: 100, scroll: 0), "\(v) dark a")
            let slices = try step(r, dark(regionY: 60, scroll: -32), "\(v) dark b")
            XCTAssertEqual(slices.first?.dy, -40, "\(v)")
            XCTAssertEqual(r.copyFrames, 1, "\(v)")
        }
    }

    func testRepetitiveAndBlankContentStaysCorrect() throws {
        let white = { (_: Int, _: Int) in (UInt8(255), UInt8(255), UInt8(255)) }
        // Every row the same, and 16 px lines that repeat down the page.
        let stripes = { (px: Int, _: Int) -> (UInt8, UInt8, UInt8) in
            self.mix(px / 3, 0) & 1 == 0 ? (20, 20, 20) : (240, 240, 240) }
        let lines = { (s: Int) in { (px: Int, py: Int) -> (UInt8, UInt8, UInt8) in
            let row = (py + s) & 15
            return row > 2 && row < 13 && self.mix(px / 4, row) & 3 == 0 ? (0, 0, 0) : (255, 255, 255) } }
        for v in variants {
            let r = run(v)
            for (i, y) in [0, 70, 50, -20, 0].enumerated() {
                try step(r, picture(y: Float(y), w: 320, h: 240, white), "\(v) white \(i)")
            }
            XCTAssertEqual(r.copyFrames, 0, "\(v) white")
            try step(r, picture(y: 0, w: 320, h: 240, stripes), "\(v) stripes")
            for s in [0, 5, 16, 21, 37, 38, 1000] {
                try step(r, picture(y: 0, w: 320, h: 240, lines(s)), "\(v) lines \(s)")
            }
        }
    }

    /// Blocky content whose page is scrolled by `scroll` px inside a fixed region.
    private func scrolled(_ scroll: Int) -> SceneFrame {
        var f = screen(x: 100, y: 50 + Double(scroll), w: 256, h: 192, scale: 1)
        f.region = CanvasRect(x: 100, y: 50, w: 256, h: 192)
        return f
    }

    func testSettleRestoresExactQuantization() throws {
        // A 5 px scroll (copies matched on raw only) and a 5 px region move
        // (tiles kept on raw only) both leave two-tone samples behind.
        let cases: [(String, SceneFrame, SceneFrame)] = [
            ("scroll", scrolled(0), scrolled(5)),
            ("move", screen(x: 100, y: 50, w: 256, h: 128, scale: 1), screen(x: 95, y: 50, w: 261, h: 128, scale: 1)),
        ]
        for (name, a, b) in cases {
            let r = run((.duogray, true))
            try step(r, a, "\(name) a")
            XCTAssertFalse(r.enc.needsSettle, name)
            XCTAssertEqual(r.enc.encodeSettle(limit: 32768), [], name)
            try step(r, b, "\(name) b")
            if name == "scroll" { XCTAssertEqual(r.copies, 8, name) }   // the two upper tile rows
            let quantized = ScrollScenes.samples(b, mode: .duogray)
            XCTAssertTrue(r.enc.lastEncodeDiverged, name)
            XCTAssertTrue(r.enc.needsSettle, name)
            XCTAssertNotEqual(r.dec.samples, quantized, name)

            let settle = r.enc.encodeSettle(limit: 32768)
            XCTAssertFalse(settle.isEmpty, name)
            for (i, s) in settle.enumerated() {
                XCTAssertFalse(s.isFull, name)
                XCTAssertFalse(s.flags.contains(.copies), name)
                XCTAssertEqual(s.flags.contains(.start), i == 0, name)
                XCTAssertEqual(s.flags.contains(.end), i == settle.count - 1, name)
                XCTAssertEqual(s.dx, 0, name)
                XCTAssertEqual(s.dy, 0, name)
                let body = try r.inflate.decompress(s.data)
                let tiles = wireTiles(body, width: b.width, height: b.height, bps: 1)
                XCTAssertNotNil(tiles, name)
                XCTAssertFalse(tiles?.contains { $0.kind == 5 } ?? true, name)
                try r.dec.decode(s)
            }
            XCTAssertEqual(r.dec.samples, quantized, name)
            XCTAssertEqual(r.enc.model, quantized, name)
            XCTAssertFalse(r.enc.needsSettle, name)
            XCTAssertFalse(r.enc.lastEncodeDiverged, name)
            XCTAssertEqual(r.enc.encodeSettle(limit: 32768), [], name)
            // The stream goes on from the settled canvas.
            try step(r, b, "\(name) b again")
            XCTAssertEqual(r.dec.samples, quantized, name)
        }
    }

    func testScenesAreDeterministic() {
        let kinds: [SceneKind] = [.terminalScroll, .regionMove, .resize(edge: .top), .localChange]
        let a = ScrollScenes.frames(seed: 3, count: 10, kinds: kinds)
        let b = ScrollScenes.frames(seed: 3, count: 10, kinds: kinds)
        XCTAssertEqual(a.map(\.bgra), b.map(\.bgra))
        XCTAssertEqual(a.map(\.region), b.map(\.region))
        XCTAssertNotEqual(a.map(\.bgra), ScrollScenes.frames(seed: 4, count: 10, kinds: kinds).map(\.bgra))
    }

    /// Duogray quantizes 16x16 blocks aligned to the frame origin, so moving
    /// the origin by 5 px changes samples of unchanged pixels. With raw the
    /// encoder skips those tiles and keeps the moved samples; the canvas then
    /// differs from the quantized frame and the encoder says so.
    func testRawMatchSkipsTilesAndMarksDivergence() throws {
        let a = screen(x: 100, y: 50, w: 256, h: 128, scale: 1)
        let b = screen(x: 95, y: 50, w: 261, h: 128, scale: 1)
        let withRaw = run((.duogray, true)), samplesOnly = run((.duogray, false))
        for r in [withRaw, samplesOnly] { try step(r, a, "a raw \(r.raw)") }
        XCTAssertFalse(withRaw.enc.needsSettle)
        try step(withRaw, b, "b with raw")
        try step(samplesOnly, b, "b samples only")
        XCTAssertTrue(withRaw.enc.lastEncodeDiverged)
        XCTAssertTrue(withRaw.enc.needsSettle)
        XCTAssertFalse(samplesOnly.enc.lastEncodeDiverged)
        XCTAssertFalse(samplesOnly.enc.needsSettle)
        XCTAssertLessThan(withRaw.enc.lastTileCount, samplesOnly.enc.lastTileCount)
        XCTAssertNotEqual(withRaw.dec.samples, ScrollScenes.samples(b, mode: .duogray))
        // The same frame again: nothing new is sent, and the divergence stays recorded.
        let again = withRaw.enc.encodeSlices(samples: ScrollScenes.samples(b, mode: .duogray), raw: b.bgra,
                                             width: b.width, height: b.height, region: b.region, limit: 32768)
        XCTAssertEqual(again, [])
        XCTAssertTrue(withRaw.enc.needsSettle)
        // A full frame (reset) brings back exact samples and clears it.
        withRaw.enc.reset()
        try step(withRaw, b, "b after reset")
        XCTAssertEqual(withRaw.dec.samples, ScrollScenes.samples(b, mode: .duogray))
        XCTAssertFalse(withRaw.enc.needsSettle)
        XCTAssertFalse(withRaw.enc.lastEncodeDiverged)
    }

    /// A move sends the exposed tiles even when they look like the zero fill
    /// (here all black); a resize with no changed tile still sends one empty slice.
    func testMoveSendsExposedTilesAndEmptySliceForPureResize() throws {
        let enc = FrameEncoder(mode: .gray4), dec = FrameDecoder(mode: .gray4)
        let a = [UInt8](repeating: 0, count: 128 * 64)
        try dec.decode(try XCTUnwrap(enc.encode(samples: a, width: 128, height: 64,
                                                region: CanvasRect(x: 0, y: 0, w: 128, h: 64))))
        let p = try XCTUnwrap(enc.encode(samples: a, width: 128, height: 64,
                                         region: CanvasRect(x: 64, y: 0, w: 128, h: 64)))
        XCTAssertEqual(p.flags, [.start, .end])
        XCTAssertEqual(p.dx, 64)
        XCTAssertEqual(enc.lastTileCount, 1)          // only the newly exposed right column
        try dec.decode(p)
        XCTAssertEqual(dec.samples, a)
        // Narrower, same origin: every tile is covered and matches; the slice only carries the resize.
        let b = [UInt8](repeating: 0, count: 64 * 64)
        let q = try XCTUnwrap(enc.encode(samples: b, width: 64, height: 64,
                                         region: CanvasRect(x: 64, y: 0, w: 64, h: 64)))
        XCTAssertEqual(q.flags, [.start, .end])
        XCTAssertEqual(enc.lastTileCount, 0)
        try dec.decode(q)
        XCTAssertEqual(dec.samples, b)
        XCTAssertNil(enc.encode(samples: b, width: 64, height: 64, region: CanvasRect(x: 64, y: 0, w: 64, h: 64)))
    }
}
