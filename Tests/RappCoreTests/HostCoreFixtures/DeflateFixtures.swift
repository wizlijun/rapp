import XCTest
@testable import RappCore

/// One script run against one Swift `DeflateStream` (read by `rust/host-core/tests/deflate.rs`).
///
/// `deflate.bin` records, in order:
/// - tag 1: a `compress` input; the next record is tag 2, its output.
/// - tag 3: a `compress(_:ifAtMost:)` call: `u32 LE limit`, then the input; the next record
///   is tag 4: `u8 fits`, then the data Swift returned (also when it does not fit: only its
///   size matters to the caller, TileCodec.swift:269, but the bytes are compared too).
/// - tag 5: `reset()`, empty payload.
final class DeflateFixtures: XCTestCase {
    /// The pre-deflate tile streams of three scene frames: the encoder's own deflate
    /// output, inflated back (the encoder resets its stream on a full frame, and only the
    /// first slice of a full frame says so, so the inflater resets there too).
    static func tileStreams() -> [[UInt8]] {
        let frames = ScrollScenes.frames(seed: 11, count: 3, kinds: [.terminalScroll, .localChange])
        let encoder = FrameEncoder(mode: .gray4)
        let inflate = InflateStream()
        var out: [[UInt8]] = []
        for f in frames {
            let samples = ScrollScenes.samples(f, mode: .gray4)
            for p in encoder.encodeSlices(samples: samples, width: f.width, height: f.height,
                                          region: f.region, limit: Int.max) {
                if p.isFull { inflate.reset() }
                out.append(try! inflate.decompress(p.data))
            }
        }
        return out
    }

    func testScript() {
        var rng = HostRNG(seed: 3)
        let stream = DeflateStream(level: 6)
        var items: [(tag: UInt8, payload: [UInt8])] = []
        func compress(_ input: [UInt8]) {
            items.append((tag: 1, payload: input))
            items.append((tag: 2, payload: stream.compress(input)))
        }
        func trial(_ input: [UInt8], limit: Int) {
            items.append((tag: 3, payload: HostFixture.u32(UInt32(limit)) + input))
            let r = stream.compress(input, ifAtMost: limit)
            items.append((tag: 4, payload: [r.fits ? 1 : 0] + r.data))
        }
        func reset() {
            stream.reset()
            items.append((tag: 5, payload: []))
        }

        let first: [UInt8] = []
        compress(first)
        compress([0x41])
        compress([UInt8](repeating: 0, count: 64 * 1024))
        compress(rng.bytes(64 * 1024))
        // More than one 64 KiB output buffer: the drain loop runs several times.
        compress(rng.bytes(300_000))
        let tiles = Self.tileStreams()
        XCTAssertGreaterThanOrEqual(tiles.count, 3)
        for t in tiles { compress(t) }
        // A trial that fits, then one that does not followed by a plain compress
        // of the same input (the stream must be as it was before the trial).
        let fitting = rng.bytes(4096)
        trial(fitting, limit: 1 << 20)
        let tooBig = rng.bytes(3000)
        trial(tooBig, limit: 100)
        compress(tooBig)
        // One byte short does not fit; exactly its own size does (the check is `count > limit`).
        // The measuring trial leaves the stream unchanged, so it is not recorded.
        let exact = rng.bytes(500)
        let measured = stream.compress(exact, ifAtMost: 0)
        XCTAssertFalse(measured.fits)
        trial(exact, limit: measured.data.count - 1)
        trial(exact, limit: measured.data.count)
        // A repeated input compresses against the dictionary.
        compress(fitting)
        // reset, then the first inputs again: the outputs equal the first ones.
        reset()
        compress(first)
        compress([0x41])
        reset()
        compress(tiles[0])
        compress(tiles[1])

        HostFixture.check("deflate.bin", HostFixture.records(items))
    }
}
