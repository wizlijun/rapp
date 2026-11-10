import XCTest
@testable import RappCore

/// Deterministic pseudo-random bytes (linear congruential generator), shared by the test files.
func pseudoRandom(count: Int, seed: UInt32) -> [UInt8] {
    var state = seed &* 2_654_435_761 &+ 1
    var out = [UInt8]()
    out.reserveCapacity(count)
    for _ in 0..<count {
        state = state &* 1_664_525 &+ 1_013_904_223
        out.append(UInt8(truncatingIfNeeded: state >> 24))
    }
    return out
}

final class DeflateTests: XCTestCase {
    func testRoundTripAcrossChunks() throws {
        let a = pseudoRandom(count: 4096, seed: 1), b = pseudoRandom(count: 100, seed: 2)
        let d = DeflateStream(), i = InflateStream()
        XCTAssertEqual(try i.decompress(d.compress(a)), a)
        XCTAssertEqual(try i.decompress(d.compress(b)), b)
    }

    func testDecompressStopsAtLimit() {
        let bomb = DeflateStream().compress([UInt8](repeating: 0, count: 200 << 20))
        XCTAssertThrowsError(try InflateStream().decompress(bomb, limit: 1 << 20)) { error in
            XCTAssertEqual(error as? CodecError, CodecError("decompressed data is larger than the frame allows"))
        }
        let small = pseudoRandom(count: 1000, seed: 3)
        XCTAssertEqual(try InflateStream().decompress(DeflateStream().compress(small), limit: 1000), small)
    }

    func testContextIsKeptBetweenCalls() {
        let a = pseudoRandom(count: 4096, seed: 1)
        let d = DeflateStream()
        let first = d.compress(a), second = d.compress(a)
        XCTAssertLessThan(second.count, first.count / 4)
    }

    func testResetStartsFresh() throws {
        let a = pseudoRandom(count: 4096, seed: 1)
        let d = DeflateStream(), i = InflateStream()
        _ = try i.decompress(d.compress(a))
        d.reset()
        i.reset()
        XCTAssertEqual(try i.decompress(d.compress(a)), a)
    }

    func testGarbageThrows() {
        XCTAssertThrowsError(try InflateStream().decompress([1, 2, 3, 4, 5]))
    }

    func testLargeInputRoundTrips() throws {
        // Larger than any single internal output buffer.
        let a = pseudoRandom(count: 300_000, seed: 7)
        let d = DeflateStream(), i = InflateStream()
        XCTAssertEqual(try i.decompress(d.compress(a)), a)
    }

    func testEmptyInputRoundTrips() throws {
        let d = DeflateStream(), i = InflateStream()
        XCTAssertEqual(try i.decompress(d.compress([])), [])
    }
}
