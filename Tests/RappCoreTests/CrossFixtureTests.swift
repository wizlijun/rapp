import XCTest
@testable import RappCore

/// A stream of encoded slices and the canvas expected after each frame, shared
/// with the Rust client (`rust/client-core/tests/client.rs`): both decoders must
/// rebuild exactly these canvases.
///
/// File format, little-endian, records one after another:
///   tag 1 (slice): u8 mode, u16 w, u16 h, u8 flags, i32 dx, i32 dy, u32 n, n bytes of data
///   tag 2 (canvas, after every slice with `end`): u16 w, u16 h, u32 n, n bytes of samples
///   tag 3 (last record): u32 number of tag 2 records
final class CrossFixtureTests: XCTestCase {
    private let fixture = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("rust/client-core/tests/fixtures/scroll-copy.bin")

    private func le(_ v: UInt64, _ bytes: Int) -> [UInt8] { (0..<bytes).map { UInt8(truncatingIfNeeded: v >> (8 * UInt64($0))) } }

    func testFixtureDecodesInSwift() throws {
        if ProcessInfo.processInfo.environment["RAPP_WRITE_FIXTURES"] == "1" { try write() }
        let bytes = [UInt8](try Data(contentsOf: fixture))
        XCTAssertLessThan(bytes.count, 1_000_000)
        var pos = 0
        func take(_ n: Int) -> [UInt8] { defer { pos += n }; return Array(bytes[pos..<(pos + n)]) }
        func int(_ n: Int) -> UInt64 { take(n).enumerated().reduce(0) { $0 | UInt64($1.element) << (8 * UInt64($1.offset)) } }

        let dec = FrameDecoder(mode: .gray4)
        var canvases = 0
        var sawCount = false
        while pos < bytes.count {
            switch int(1) {
            case 1:
                let mode = try XCTUnwrap(Mode(rawValue: UInt8(int(1))))
                let w = UInt16(int(2)), h = UInt16(int(2))
                let flags = FrameFlags(rawValue: UInt8(int(1)))
                let dx = Int32(truncatingIfNeeded: int(4)), dy = Int32(truncatingIfNeeded: int(4))
                let data = take(Int(int(4)))
                try dec.decode(FramePayload(mode: mode, width: w, height: h, flags: flags, dx: dx, dy: dy, data: data))
            case 2:
                let w = Int(int(2)), h = Int(int(2))
                let want = take(Int(int(4)))
                XCTAssertEqual(dec.width, w)
                XCTAssertEqual(dec.height, h)
                XCTAssertTrue(dec.samples == want, "canvas #\(canvases) differs")
                canvases += 1
            case 3:
                XCTAssertEqual(Int(int(4)), canvases, "canvas count record")
                sawCount = true
            default: XCTFail("bad record at \(pos)"); return
            }
        }
        XCTAssertTrue(sawCount)
        XCTAssertEqual(pos, bytes.count)
        XCTAssertGreaterThan(canvases, 15)
    }

    private struct WireTile { var kind: UInt8, x: Int, y: Int, w: Int, h: Int, sx = 0, sy = 0 }

    /// Walks a decompressed slice body (format at the top of TileCodec.swift).
    private func wireTiles(_ body: [UInt8], width: Int, height: Int, bps: Int) throws -> [WireTile] {
        var pos = 2, out = [WireTile]()
        let cols = (width + 63) / 64
        for _ in 0..<(Int(body[0]) | Int(body[1]) << 8) {
            let index = Int(body[pos]) | Int(body[pos + 1]) << 8, kind = body[pos + 2]
            pos += 3
            let x0 = index % cols * 64, y0 = index / cols * 64
            let tw = min(64, width - x0), th = min(64, height - y0)
            var tile = WireTile(kind: kind, x: x0, y: y0, w: tw, h: th)
            switch kind {
            case 0: pos += bps
            case 1, 2, 4: pos += 1 + Int(body[pos]) * bps + (tw * Int(kind) + 7) / 8 * th
            case 3:
                for sy in stride(from: 0, to: th, by: 16) {
                    for sx in stride(from: 0, to: tw, by: 16) {
                        let n = Int(body[pos])
                        pos += 1 + n * bps + (n == 2 ? (min(16, tw - sx) + 7) / 8 * min(16, th - sy) : 0)
                    }
                }
            case 5:
                tile.sx = Int(body[pos]) | Int(body[pos + 1]) << 8
                tile.sy = Int(body[pos + 2]) | Int(body[pos + 3]) << 8
                pos += 4
            case 255: pos += tw * th * bps
            default: XCTFail("unknown tile kind \(kind)")
            }
            out.append(tile)
        }
        return out
    }

    private func write() throws {
        let kinds: [SceneKind] = [.terminalScroll, .webScroll(topBar: 30, sideBar: 50), .scrollWhileMoving, .scrollWhileMoving,
                                  .scrollWhileMoving, .regionMove, .localChange, .resize(edge: .top)]
        let frames = ScrollScenes.frames(seed: 7, count: 15, kinds: kinds, size: (160, 120))
        var out = [UInt8]()
        var laterCopies = 0, copiesOverRewritten = 0
        var moves = 0, copyFrames = 0, settles = 0, canvases = 0
        var copyModes = Set<UInt8>(), multiSliceCopies = 0, copiesWithMove = 0
        for (segment, v) in [(Mode.gray4, false), (.color16, false), (.duogray, true)].enumerated() {
            // A new encoder: each segment opens with a full frame in its own mode.
            let enc = FrameEncoder(mode: v.0)
            let dec = FrameDecoder(mode: v.0)
            let mirror = InflateStream()          // reads the tiles off the wire
            var sliceNo = 0
            var written = [(x: Int, y: Int, w: Int, h: Int)]()   // tiles of the earlier slices of this frame
            func emit(_ slices: [FramePayload]) throws {
                for s in slices {
                    out += [1, s.mode.rawValue] + le(UInt64(s.width), 2) + le(UInt64(s.height), 2) + [s.flags.rawValue]
                    out += le(UInt64(UInt32(bitPattern: s.dx)), 4) + le(UInt64(UInt32(bitPattern: s.dy)), 4)
                    out += le(UInt64(s.data.count), 4) + s.data
                    try dec.decode(s)
                    if s.flags.contains(.start) { sliceNo = 0; written = [] }
                    if s.isFull { mirror.reset() }
                    var thisSlice = [(x: Int, y: Int, w: Int, h: Int)]()
                    for t in try wireTiles(try mirror.decompress(s.data), width: Int(s.width), height: Int(s.height), bps: s.mode.bytesPerSample) {
                        thisSlice.append((t.x, t.y, t.w, t.h))
                        guard t.kind == 5 else { continue }
                        if sliceNo > 0 {
                            laterCopies += 1
                            let overlaps = written.contains { $0.x < t.sx + t.w && t.sx < $0.x + $0.w && $0.y < t.sy + t.h && t.sy < $0.y + $0.h }
                            if overlaps { copiesOverRewritten += 1 }
                        }
                    }
                    written += thisSlice
                    sliceNo += 1
                    if s.flags.contains(.end) {
                        out += [2] + le(UInt64(dec.width), 2) + le(UInt64(dec.height), 2)
                        out += le(UInt64(dec.samples.count), 4) + dec.samples
                        canvases += 1
                    }
                }
            }
            // Five mixed frames, then a terminal scroll played backwards (the content moves down, so a
            // later slice copies from rows an earlier slice of the same frame already rewrote).
            let reverse = ScrollScenes.frames(seed: UInt64(3 + segment), count: 5, kinds: [.terminalScroll], size: (160, 120)).reversed()
            for f in Array(frames[(segment * 5)..<((segment + 1) * 5)]) + reverse {
                let samples = ScrollScenes.samples(f, mode: v.0)
                let slices = enc.encodeSlices(samples: samples, raw: v.1 ? f.bgra : nil, width: f.width, height: f.height,
                                              region: f.region, limit: 500, firstLimit: 100)
                if let first = slices.first {
                    if first.dx != 0 || first.dy != 0 { moves += 1 }
                    if first.flags.contains(.copies) {
                        copyFrames += 1
                        copyModes.insert(first.mode.rawValue)
                        if slices.count > 1 { multiSliceCopies += 1 }
                        if first.dx != 0 || first.dy != 0 { copiesWithMove += 1 }
                    }
                }
                try emit(slices)
                while enc.needsSettle {
                    let settle = enc.encodeSettle(limit: 500)
                    if settle.isEmpty { break }
                    settles += 1
                    try emit(settle)
                }
            }
        }
        XCTAssertGreaterThan(moves, 0, "fixture has no canvas move")
        XCTAssertGreaterThan(copyFrames, 0, "fixture has no copy tiles")
        XCTAssertGreaterThan(settles, 0, "fixture has no settle frame")
        XCTAssertGreaterThanOrEqual(copyModes.count, 2, "copy tiles in fewer than two modes")
        XCTAssertGreaterThan(multiSliceCopies, 0, "no copies frame spans several slices")
        XCTAssertGreaterThan(copiesWithMove, 0, "no copies frame also moves the canvas")
        XCTAssertGreaterThan(laterCopies, 0, "no copy tile in a non-first slice")
        XCTAssertGreaterThan(copiesOverRewritten, 0, "no later copy reads rows an earlier slice rewrote")
        print("fixture: moves \(moves) copyFrames \(copyFrames) modes \(copyModes.sorted()) multiSlice \(multiSliceCopies) copiesWithMove \(copiesWithMove) settles \(settles) canvases \(canvases) laterCopies \(laterCopies) overRewritten \(copiesOverRewritten)")
        out += [3] + le(UInt64(canvases), 4)
        try FileManager.default.createDirectory(at: fixture.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(out).write(to: fixture)
    }
}
