import XCTest
@testable import RappCore

final class FrameFormatTests: XCTestCase {
    private func raw(_ index: Int, _ samples: [UInt8]) -> [UInt8] { [UInt8(index & 0xFF), UInt8(index >> 8), 255] + samples }
    private func solid(_ index: Int, _ v: UInt8) -> [UInt8] { [UInt8(index & 0xFF), UInt8(index >> 8), 0, v] }
    private func copy(_ index: Int, _ sx: Int, _ sy: Int) -> [UInt8] {
        [UInt8(index & 0xFF), UInt8(index >> 8), 5, UInt8(sx & 0xFF), UInt8(sx >> 8), UInt8(sy & 0xFF), UInt8(sy >> 8)]
    }
    private func slice(_ z: DeflateStream, _ w: Int, _ h: Int, _ flags: FrameFlags, dx: Int32 = 0, dy: Int32 = 0,
                       _ tiles: [[UInt8]] = []) -> FramePayload {
        let body: [UInt8] = [UInt8(tiles.count & 0xFF), UInt8(tiles.count >> 8)] + tiles.flatMap { $0 }
        return FramePayload(width: UInt16(w), height: UInt16(h), flags: flags, dx: dx, dy: dy, data: z.compress(body))
    }
    /// A decoder holding a 128x64 canvas: tile 0 all 3, tile 1 all 5.
    private func twoTiles() throws -> (FrameDecoder, DeflateStream) {
        let z = DeflateStream(), dec = FrameDecoder(mode: .gray4)
        try dec.decode(slice(z, 128, 64, [.full, .start, .end], [solid(0, 3), solid(1, 5)]))
        return (dec, z)
    }

    func testSliceFlagsStartAndEnd() {
        let w = 1920, h = 1080
        let s = randomSamples(width: w, height: h, mode: .gray4, seed: 9)
        let slices = FrameEncoder(mode: .gray4).encodeSlices(samples: s, width: w, height: h, limit: 32768)
        XCTAssertGreaterThanOrEqual(slices.count, 3)
        XCTAssertEqual(slices.first?.flags, [.full, .start])
        XCTAssertEqual(slices.last?.flags, [.end])
        for m in slices.dropFirst().dropLast() { XCTAssertEqual(m.flags, []) }
        let one = FrameEncoder(mode: .gray4).encodeSlices(samples: [UInt8](repeating: 1, count: 64), width: 8, height: 8, limit: 32768)
        XCTAssertEqual(one.map(\.flags), [[.full, .start, .end]])
    }

    func testMoveHeaderShiftsCanvas() throws {
        let z = DeflateStream(), dec = FrameDecoder(mode: .gray4)
        let old = (0..<64).map { UInt8($0 % 16) }
        try dec.decode(slice(z, 8, 8, [.full, .start, .end], [raw(0, old)]))
        XCTAssertEqual(dec.samples, old)
        try dec.decode(slice(z, 10, 6, [.start, .end], dx: 2, dy: -1))
        XCTAssertEqual(dec.width, 10)
        XCTAssertEqual(dec.height, 6)
        for y in 0..<6 {
            for x in 0..<10 {
                let ox = x + 2, oy = y - 1
                let want: UInt8 = ox < 8 && oy >= 0 && oy < 8 ? old[oy * 8 + ox] : 0
                XCTAssertEqual(dec.samples[y * 10 + x], want, "(\(x),\(y))")
            }
        }
    }

    func testCopyTileReadsReferenceNotPartialFrame() throws {
        let (dec, z) = try twoTiles()
        XCTAssertNoThrow(try dec.decode(slice(z, 128, 64, [.start, .copies], [solid(0, 9)])))
        XCTAssertNoThrow(try dec.decode(slice(z, 128, 64, [.end], [copy(1, 0, 0)])))
        XCTAssertEqual(dec.samples[63], 9)           // tile 0 got 9 first, tile 1 copied the old 3
        XCTAssertEqual(dec.samples[64], 3)
        XCTAssertEqual(dec.samples[127], 3)
    }

    func testCopyTileWithoutCopiesFlagThrows() throws {
        let (dec, z) = try twoTiles()
        XCTAssertThrowsError(try dec.decode(slice(z, 128, 64, [.start, .end], [copy(1, 0, 0)])))
    }

    func testCopySourceOutOfCanvasThrows() throws {
        let (dec, z) = try twoTiles()
        XCTAssertThrowsError(try dec.decode(slice(z, 128, 64, [.start, .end, .copies], [copy(1, 65, 0)])))
    }

    func testUnknownFlagBitsThrow() throws {
        let (dec, z) = try twoTiles()
        XCTAssertThrowsError(try dec.decode(slice(z, 128, 64, FrameFlags(rawValue: 0x10 | 6))))
    }

    func testCopiesWithoutStartThrows() throws {
        let (dec, z) = try twoTiles()
        try dec.decode(slice(z, 128, 64, [.start]))
        XCTAssertThrowsError(try dec.decode(slice(z, 128, 64, [.end, .copies])))
    }

    func testSliceWithoutOpenFrameThrows() throws {
        let (dec, z) = try twoTiles()
        XCTAssertThrowsError(try dec.decode(slice(z, 128, 64, [.end])))
    }

    func testDeltaStartWhileFrameOpenThrows() throws {
        let (dec, z) = try twoTiles()
        try dec.decode(slice(z, 128, 64, [.start]))
        XCTAssertThrowsError(try dec.decode(slice(z, 128, 64, [.start, .end])))
    }

    func testFullFrameMayInterruptOpenFrame() throws {
        let (dec, z) = try twoTiles()
        try dec.decode(slice(z, 128, 64, [.start]))
        let z2 = DeflateStream()
        XCTAssertTrue(try dec.decode(slice(z2, 128, 64, [.full, .start, .end], [solid(0, 1), solid(1, 1)])))
        XCTAssertEqual(dec.samples[0], 1)
    }

    func testExtremeOffsetsGiveBlankCanvas() throws {
        for (dx, dy) in [(Int32.max, Int32(0)), (.min, 0), (0, .max), (0, .min), (.min, .min), (.max, .max)] {
            let (dec, z) = try twoTiles()
            XCTAssertNoThrow(try dec.decode(slice(z, 128, 64, [.start, .end], dx: dx, dy: dy)), "\(dx),\(dy)")
            XCTAssertEqual(dec.samples, [UInt8](repeating: 0, count: 128 * 64), "\(dx),\(dy)")
        }
        let (dec, z) = try twoTiles()
        try dec.decode(slice(z, 128, 64, [.start, .end], dx: .max, dy: 0, [solid(1, 7)]))
        XCTAssertEqual(dec.samples[0], 0)
        XCTAssertEqual(dec.samples[64], 7)
    }

    func testThrowLeavesDecoderNeedingFullFrame() throws {
        let (dec, z) = try twoTiles()
        let bad = FramePayload(width: 128, height: 64, flags: [.start, .end], dx: 1, data: [1, 2, 3])
        XCTAssertThrowsError(try dec.decode(bad))
        XCTAssertThrowsError(try dec.decode(slice(z, 128, 64, [.start, .end], [solid(0, 1)])))
        let z2 = DeflateStream()
        XCTAssertNoThrow(try dec.decode(slice(z2, 128, 64, [.full, .start, .end], [solid(0, 2), solid(1, 4)])))
        XCTAssertEqual(dec.samples[0], 2)
        XCTAssertEqual(dec.samples[64], 4)
    }

    func testDisplayTiming() throws {
        let z = DeflateStream(), dec = FrameDecoder(mode: .gray4)
        // The session's first full frame shows slice by slice.
        XCTAssertTrue(try dec.decode(slice(z, 128, 64, [.full, .start], [solid(0, 3)])))
        XCTAssertTrue(try dec.decode(slice(z, 128, 64, [.end], [solid(1, 3)])))
        // Later full frames wait for the last slice.
        let z2 = DeflateStream()
        XCTAssertFalse(try dec.decode(slice(z2, 128, 64, [.full, .start], [solid(0, 4)])))
        XCTAssertTrue(try dec.decode(slice(z2, 128, 64, [.end], [solid(1, 4)])))
        // Plain deltas show every slice.
        XCTAssertTrue(try dec.decode(slice(z2, 128, 64, [.start], [solid(0, 5)])))
        XCTAssertTrue(try dec.decode(slice(z2, 128, 64, [.end], [solid(1, 5)])))
        // Moves (offset or size change) wait for the last slice.
        XCTAssertFalse(try dec.decode(slice(z2, 128, 64, [.start], dy: 3, [solid(0, 6)])))
        XCTAssertTrue(try dec.decode(slice(z2, 128, 64, [.end], [solid(1, 6)])))
        XCTAssertFalse(try dec.decode(slice(z2, 64, 64, [.start], [solid(0, 7)])))
        XCTAssertTrue(try dec.decode(slice(z2, 64, 64, [.end])))
        XCTAssertTrue(try dec.decode(slice(z2, 64, 64, [.start, .end], [solid(0, 8)])))
    }
}
