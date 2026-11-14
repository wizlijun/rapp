import XCTest
@testable import RappCore

/// Canvas moves on region changes, the raw key plane and the full-frame rules.
final class ScrollCopyTests: XCTestCase {
    /// The variants every test runs: a mode and whether raw pixels go with the
    /// samples. Without raw nothing is skipped unless its samples match, so the
    /// canvas must equal the quantized frame exactly.
    private let variants: [(mode: Mode, raw: Bool)] = [(.gray4, false), (.color16, false), (.duogray, true), (.duogray, false)]

    private struct Run {
        let enc: FrameEncoder
        let dec: FrameDecoder
        let raw: Bool
        var exact: Bool { !raw }
    }

    private func run(_ v: (mode: Mode, raw: Bool)) -> Run {
        Run(enc: FrameEncoder(mode: v.mode), dec: FrameDecoder(mode: v.mode), raw: v.raw)
    }

    /// Encodes `frame` into real-size slices, decodes them all and checks the
    /// canvas against the encoder model (and the quantized frame when `exact`).
    /// `samples` is the frame already quantized for the run's mode, if at hand.
    @discardableResult
    private func step(_ r: Run, _ frame: SceneFrame, _ what: String, samples: [UInt8]? = nil,
                      file: StaticString = #filePath, line: UInt = #line) throws -> [FramePayload] {
        let samples = samples ?? ScrollScenes.samples(frame, mode: r.dec.mode)
        let slices = r.enc.encodeSlices(samples: samples, raw: r.raw ? frame.bgra : nil, width: frame.width,
                                        height: frame.height, region: frame.region, limit: 32768, firstLimit: 8192)
        for s in slices { try r.dec.decode(s) }
        XCTAssertEqual(r.dec.width, frame.width, what, file: file, line: line)
        XCTAssertEqual(r.dec.height, frame.height, what, file: file, line: line)
        XCTAssertTrue(r.dec.samples == r.enc.model, "decoder canvas differs from model: \(what)", file: file, line: line)
        if r.exact {
            XCTAssertTrue(r.dec.samples == samples, "canvas differs from quantized frame: \(what)", file: file, line: line)
        }
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
                                  .regionMove, .localChange]
        var moves = 0, diverged = 0
        for seed in UInt64(1)...20 {
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
            }
        }
        // The scenes really moved the canvas, and raw matches really left samples behind.
        XCTAssertGreaterThan(moves, 100)
        XCTAssertGreaterThan(diverged, 20)
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
