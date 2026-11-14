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

    private func write() throws {
        let kinds: [SceneKind] = [.terminalScroll, .webScroll(topBar: 30, sideBar: 50), .scrollWhileMoving, .scrollWhileMoving,
                                  .scrollWhileMoving, .regionMove, .localChange, .resize(edge: .top)]
        let frames = ScrollScenes.frames(seed: 7, count: 30, kinds: kinds, size: (160, 120))
        var out = [UInt8]()
        var moves = 0, copyFrames = 0, settles = 0, canvases = 0
        var copyModes = Set<UInt8>(), multiSliceCopies = 0, copiesWithMove = 0
        for (segment, v) in [(Mode.gray4, false), (.color16, false), (.duogray, true)].enumerated() {
            // A new encoder: each segment opens with a full frame in its own mode.
            let enc = FrameEncoder(mode: v.0)
            let dec = FrameDecoder(mode: v.0)
            func emit(_ slices: [FramePayload]) throws {
                for s in slices {
                    out += [1, s.mode.rawValue] + le(UInt64(s.width), 2) + le(UInt64(s.height), 2) + [s.flags.rawValue]
                    out += le(UInt64(UInt32(bitPattern: s.dx)), 4) + le(UInt64(UInt32(bitPattern: s.dy)), 4)
                    out += le(UInt64(s.data.count), 4) + s.data
                    try dec.decode(s)
                    if s.flags.contains(.end) {
                        out += [2] + le(UInt64(dec.width), 2) + le(UInt64(dec.height), 2)
                        out += le(UInt64(dec.samples.count), 4) + dec.samples
                        canvases += 1
                    }
                }
            }
            for f in frames[(segment * 10)..<((segment + 1) * 10)] {
                let samples = ScrollScenes.samples(f, mode: v.0)
                let slices = enc.encodeSlices(samples: samples, raw: v.1 ? f.bgra : nil, width: f.width, height: f.height,
                                              region: f.region, limit: 500, firstLimit: 250)
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
                if enc.needsSettle {
                    let settle = enc.encodeSettle(limit: 500)
                    settles += settle.isEmpty ? 0 : 1
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
        print("fixture: moves \(moves) copyFrames \(copyFrames) modes \(copyModes.sorted()) multiSlice \(multiSliceCopies) copiesWithMove \(copiesWithMove) settles \(settles) canvases \(canvases)")
        out += [3] + le(UInt64(canvases), 4)
        try FileManager.default.createDirectory(at: fixture.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(out).write(to: fixture)
    }
}
