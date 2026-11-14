import XCTest
@testable import RappCore

/// Valid samples for a mode (gray4 bytes stay in 0...15).
func randomSamples(width: Int, height: Int, mode: Mode, seed: UInt32) -> [UInt8] {
    var s = pseudoRandom(count: width * height * mode.bytesPerSample, seed: seed)
    if mode == .gray4 { for i in s.indices { s[i] &= 0x0F } }
    return s
}

final class TileCodecTests: XCTestCase {
    private func roundTrip(width: Int, height: Int, file: StaticString = #filePath, line: UInt = #line) throws {
        for mode in Mode.allCases {
            let s = randomSamples(width: width, height: height, mode: mode, seed: 3)
            let enc = FrameEncoder(mode: mode), dec = FrameDecoder(mode: mode)
            let p = try XCTUnwrap(enc.encode(samples: s, width: width, height: height), file: file, line: line)
            XCTAssertTrue(p.isFull, file: file, line: line)
            XCTAssertEqual(Int(p.width), width, file: file, line: line)
            XCTAssertEqual(Int(p.height), height, file: file, line: line)
            try dec.decode(p)
            XCTAssertEqual(dec.samples, s, "\(mode)", file: file, line: line)
        }
    }

    func testFirstFrameIsFullAndRoundTrips() throws {
        try roundTrip(width: 128, height: 64)
    }

    func testOddSizeRoundTrips() throws {
        try roundTrip(width: 130, height: 70)
        // A later change in the bottom-right corner (a 2x6 edge tile) also survives.
        for mode in Mode.allCases {
            var s = randomSamples(width: 130, height: 70, mode: mode, seed: 4)
            let enc = FrameEncoder(mode: mode), dec = FrameDecoder(mode: mode)
            try dec.decode(try XCTUnwrap(enc.encode(samples: s, width: 130, height: 70)))
            s[s.count - 1] ^= 0x01
            let p = try XCTUnwrap(enc.encode(samples: s, width: 130, height: 70))
            XCTAssertFalse(p.isFull)
            XCTAssertEqual(enc.lastTileCount, 1)
            try dec.decode(p)
            XCTAssertEqual(dec.samples, s, "\(mode)")
        }
    }

    func testUnchangedFrameReturnsNil() {
        let s = randomSamples(width: 130, height: 70, mode: .color8, seed: 5)
        let enc = FrameEncoder(mode: .color8)
        XCTAssertNotNil(enc.encode(samples: s, width: 130, height: 70))
        XCTAssertNil(enc.encode(samples: s, width: 130, height: 70))
    }

    func testSinglePixelChangeEncodesOneTile() throws {
        var s = randomSamples(width: 130, height: 70, mode: .gray4, seed: 6)
        let enc = FrameEncoder(mode: .gray4), dec = FrameDecoder(mode: .gray4)
        try dec.decode(try XCTUnwrap(enc.encode(samples: s, width: 130, height: 70)))
        XCTAssertEqual(enc.lastTileCount, 6)          // 3 columns x 2 rows
        s[10 * 130 + 70] ^= 0x01                      // pixel (70, 10)
        let p = try XCTUnwrap(enc.encode(samples: s, width: 130, height: 70))
        XCTAssertFalse(p.isFull)
        XCTAssertEqual(enc.lastTileCount, 1)
        try dec.decode(p)
        XCTAssertEqual(dec.samples, s)
    }

    func testSizeChangeForcesFull() throws {
        let enc = FrameEncoder(mode: .color16), dec = FrameDecoder(mode: .color16)
        let a = randomSamples(width: 130, height: 70, mode: .color16, seed: 7)
        try dec.decode(try XCTUnwrap(enc.encode(samples: a, width: 130, height: 70)))
        let b = randomSamples(width: 64, height: 64, mode: .color16, seed: 8)
        let p = try XCTUnwrap(enc.encode(samples: b, width: 64, height: 64))
        XCTAssertTrue(p.isFull)
        try dec.decode(p)
        XCTAssertEqual(dec.width, 64)
        XCTAssertEqual(dec.height, 64)
        XCTAssertEqual(dec.samples, b)
    }

    func testResetForcesFull() throws {
        let s = randomSamples(width: 64, height: 64, mode: .gray4, seed: 9)
        let enc = FrameEncoder(mode: .gray4), dec = FrameDecoder(mode: .gray4)
        try dec.decode(try XCTUnwrap(enc.encode(samples: s, width: 64, height: 64)))
        enc.reset()
        let p = try XCTUnwrap(enc.encode(samples: s, width: 64, height: 64))
        XCTAssertTrue(p.isFull)
        try dec.decode(p)
        XCTAssertEqual(dec.samples, s)
    }

    func testKindSelection() {
        XCTAssertEqual([1, 2, 3, 4, 5, 16, 17].map(FrameEncoder.kind(forDistinctCount:)), [0, 1, 2, 2, 4, 4, 255])
    }

    func testEveryPaletteKindRoundTrips() throws {
        // One 64x64 tile per palette size: 1, 2, 4, 16 and 17 distinct samples.
        for distinct in [1, 2, 3, 4, 5, 16, 17] {
            var s = [UInt8](repeating: 0, count: 64 * 64 * 2)
            for p in 0..<(64 * 64) {
                let v = (p * 7 + p / 64) % distinct
                s[p * 2] = UInt8(v * 13)
                s[p * 2 + 1] = UInt8(v)
            }
            let enc = FrameEncoder(mode: .color16), dec = FrameDecoder(mode: .color16)
            try dec.decode(try XCTUnwrap(enc.encode(samples: s, width: 64, height: 64)))
            XCTAssertEqual(dec.samples, s, "\(distinct) distinct samples")
        }
    }

    func testLowColorTileIsSmallerThanRaw() throws {
        var s = [UInt8](repeating: 0, count: 64 * 64 * 2)
        for y in 0..<64 { for x in 0..<64 where (x + y) % 2 == 1 {
            s[(y * 64 + x) * 2] = 0xFF
            s[(y * 64 + x) * 2 + 1] = 0xFF
        } }
        let p = try XCTUnwrap(FrameEncoder(mode: .color16).encode(samples: s, width: 64, height: 64))
        XCTAssertLessThan(p.data.count, 64 * 64 * 2 / 8)
    }

    func testDeltaBeforeFullThrows() throws {
        var s = randomSamples(width: 64, height: 64, mode: .gray4, seed: 10)
        let enc = FrameEncoder(mode: .gray4)
        _ = enc.encode(samples: s, width: 64, height: 64)
        s[0] ^= 0x01
        let delta = try XCTUnwrap(enc.encode(samples: s, width: 64, height: 64))
        XCTAssertFalse(delta.isFull)
        XCTAssertThrowsError(try FrameDecoder(mode: .gray4).decode(delta))
    }

    func testCorruptDataThrows() {
        let bad = FramePayload(width: 64, height: 64, flags: [.full, .start, .end], data: [1, 2, 3])
        XCTAssertThrowsError(try FrameDecoder(mode: .gray4).decode(bad))
    }

    func testTruncatedBodyThrows() throws {
        // A well-formed zlib stream whose contents stop in the middle of a tile.
        let body: [UInt8] = [1, 0, 0, 0, 255, 9, 9, 9]     // 1 tile, index 0, raw, only 3 samples
        let p = FramePayload(width: 64, height: 64, flags: [.full, .start, .end], data: DeflateStream().compress(body))
        XCTAssertThrowsError(try FrameDecoder(mode: .gray4).decode(p))
    }

    func testBadTileIndexOrKindThrows() {
        for body: [UInt8] in [[1, 0, 9, 0, 0, 5], [1, 0, 0, 0, 77, 5], [1, 0, 0, 0, 1, 3, 1, 2, 3]] {
            let p = FramePayload(width: 64, height: 64, flags: [.full, .start, .end], data: DeflateStream().compress(body))
            XCTAssertThrowsError(try FrameDecoder(mode: .gray4).decode(p), "\(body)")
        }
    }

    func testOversizedFrameIsRejectedBeforeDecoding() {
        let p = FramePayload(width: 8193, height: 8192, flags: [.full, .start, .end], data: DeflateStream().compress([0, 0]))
        XCTAssertThrowsError(try FrameDecoder(mode: .gray4).decode(p)) { error in
            XCTAssertEqual(error as? CodecError, CodecError("frame too large"))
        }
    }

    func testDecompressionBombFrameThrows() {
        let bomb = DeflateStream().compress([UInt8](repeating: 0, count: 200 << 20))
        let p = FramePayload(width: 64, height: 64, flags: [.full, .start, .end], data: bomb)
        XCTAssertThrowsError(try FrameDecoder(mode: .gray4).decode(p)) { error in
            XCTAssertEqual(error as? CodecError, CodecError("decompressed data is larger than the frame allows"))
        }
    }

    func testZeroSizeFrameThrows() {
        let p = FramePayload(width: 0, height: 0, flags: [.full, .start, .end], data: DeflateStream().compress([0, 0]))
        XCTAssertThrowsError(try FrameDecoder(mode: .gray4).decode(p))
    }

    func testDecoderFollowsModeOfFullFrames() throws {
        let dec = FrameDecoder()
        let g = [UInt8](repeating: 7, count: 64 * 64)
        try dec.decode(FrameEncoder(mode: .gray4).encode(samples: g, width: 64, height: 64)!)
        XCTAssertEqual(dec.mode, .gray4)
        let c = [UInt8](repeating: 9, count: 64 * 64 * 2)
        try dec.decode(FrameEncoder(mode: .color16).encode(samples: c, width: 64, height: 64)!)
        XCTAssertEqual(dec.mode, .color16)
        XCTAssertEqual(dec.samples, c)
    }

    func testUpdateFrameWithOtherModeIsRejected() throws {
        let enc = FrameEncoder(mode: .gray4), dec = FrameDecoder()
        var s = [UInt8](repeating: 1, count: 64 * 64)
        try dec.decode(enc.encode(samples: s, width: 64, height: 64)!)
        s[0] = 2
        var update = enc.encode(samples: s, width: 64, height: 64)!
        update.mode = .color8
        XCTAssertThrowsError(try dec.decode(update))
    }

    // MARK: Two-tone sub-blocks (kind 3)

    /// The uncompressed body of a frame from a fresh encoder.
    private func body(of p: FramePayload) throws -> [UInt8] {
        try InflateStream().decompress(p.data)
    }

    /// RGB565 samples where every 16x16 sub-block has its own two colours.
    private func duoSamples(width: Int, height: Int, breakSubBlock: Bool = false) -> [UInt8] {
        var s = [UInt8](repeating: 0, count: width * height * 2)
        let bits = pseudoRandom(count: width * height, seed: 21)
        for y in 0..<height { for x in 0..<width {
            let block = (y / 16) * 100 + x / 16
            var v = UInt16(block * 2 + Int(bits[y * width + x] & 1)) * 37
            if breakSubBlock && x == 20 && y == 20 { v = 0xFFFF }      // a third colour in sub-block (1, 1)
            s[(y * width + x) * 2] = UInt8(v & 0xFF)
            s[(y * width + x) * 2 + 1] = UInt8(v >> 8)
        } }
        return s
    }

    func testDuoSubBlocksRoundTripAndAreSmaller() throws {
        let s = duoSamples(width: 64, height: 64)
        let p = try XCTUnwrap(FrameEncoder(mode: .duocolor).encode(samples: s, width: 64, height: 64))
        XCTAssertEqual(try body(of: p)[4], 3, "kind 3")
        let dec = FrameDecoder()
        try dec.decode(p)
        XCTAssertEqual(dec.samples, s)
        let raw: [UInt8] = [1, 0, 0, 0, 255] + s
        XCTAssertLessThan(p.data.count, DeflateStream().compress(raw).count)
        // Random bits do not compress: the kind 3 body itself (597 bytes) plus zlib framing.
        XCTAssertLessThan(p.data.count, 5 + 16 * 5 + 64 * 64 / 8 + 32)
    }

    func testDuoKindChosenOnlyWhenEverySubBlockFits() throws {
        let s = duoSamples(width: 64, height: 64, breakSubBlock: true)
        let p = try XCTUnwrap(FrameEncoder(mode: .duocolor).encode(samples: s, width: 64, height: 64))
        XCTAssertNotEqual(try body(of: p)[4], 3)
        let dec = FrameDecoder()
        try dec.decode(p)
        XCTAssertEqual(dec.samples, s)
        // Three samples, each sub-block with at most two: kind 3 even though a 2-bit palette would fit.
        var t = [UInt8](repeating: 1, count: 64 * 64)
        for x in 0..<16 { t[x] = 2 }
        for x in 16..<32 { t[64 + x] = 3 }
        let q = try XCTUnwrap(FrameEncoder(mode: .duogray).encode(samples: t, width: 64, height: 64))
        XCTAssertEqual(try body(of: q)[4], 3)
        try dec.decode(q)
        XCTAssertEqual(dec.samples, t)
    }

    func testDuoEdgeTileRoundTrip() throws {
        // Real two-tone output at a size that is not a multiple of 16 or 64.
        var px = [UInt8]()
        let noise = pseudoRandom(count: 100 * 70 * 3, seed: 22)
        for i in 0..<(100 * 70) { px += [noise[i * 3], noise[i * 3 + 1], noise[i * 3 + 2], 255] }
        for mode in [Mode.duocolor, .duogray] {
            let s = px.withUnsafeBytes { Quantizer.quantize(bgra: $0, width: 100, height: 70, bytesPerRow: 400, mode: mode) }
            let enc = FrameEncoder(mode: mode), dec = FrameDecoder()
            try dec.decode(try XCTUnwrap(enc.encode(samples: s, width: 100, height: 70)))
            XCTAssertEqual(dec.samples, s, mode.name)
            var u = s
            u[u.count - 1] ^= 0x01                         // bottom-right corner, a 36x6 edge tile
            let d = try XCTUnwrap(enc.encode(samples: u, width: 100, height: 70))
            try dec.decode(d)
            XCTAssertEqual(dec.samples, u, mode.name)
        }
    }

    func testDecoderRejectsBadDuoSubBlock() {
        // One 16x16 frame, kind 3, sub-block with n = 3; then n = 0; then truncated bits.
        for body: [UInt8] in [[1, 0, 0, 0, 3, 3, 1, 2, 3], [1, 0, 0, 0, 3, 0], [1, 0, 0, 0, 3, 2, 1, 2, 0xFF]] {
            let p = FramePayload(mode: .gray4, width: 16, height: 16, flags: [.full, .start, .end], data: DeflateStream().compress(body))
            XCTAssertThrowsError(try FrameDecoder().decode(p), "\(body)")
        }
        // The same frame with a valid sub-block decodes.
        let ok: [UInt8] = [1, 0, 0, 0, 3, 2, 1, 2] + [UInt8](repeating: 0x80, count: 32)
        let dec = FrameDecoder()
        XCTAssertNoThrow(try dec.decode(FramePayload(mode: .gray4, width: 16, height: 16, flags: [.full, .start, .end],
                                                     data: DeflateStream().compress(ok))))
        XCTAssertEqual(dec.samples[0], 2)
        XCTAssertEqual(dec.samples[1], 1)
    }
}

final class TileSliceTests: XCTestCase {
    /// Feeds the slice to the decoder and returns the tile rows whose pixels changed.
    private func decodeAndChangedRows(_ dec: FrameDecoder, _ slice: FramePayload) throws -> [Int] {
        // A full slice starts from a blank canvas.
        var before = dec.samples
        try dec.decode(slice)
        if slice.isFull { before = [UInt8](repeating: 0, count: dec.samples.count) }
        let w = dec.width, bps = dec.mode.bytesPerSample
        var rows = Set<Int>()
        for (i, v) in dec.samples.enumerated() where before[i] != v {
            rows.insert(i / (w * bps) / tileSize)
        }
        return rows.sorted()
    }

    func testSmallFrameIsOneSliceSameAsEncode() {
        let a = FrameEncoder(mode: .gray4), b = FrameEncoder(mode: .gray4)
        var s = randomSamples(width: 200, height: 150, mode: .gray4, seed: 5)
        for step in 0..<3 {
            let one = a.encode(samples: s, width: 200, height: 150)
            let many = b.encodeSlices(samples: s, width: 200, height: 150, limit: 32768)
            XCTAssertEqual(many.count, 1)
            XCTAssertEqual(many.first, one)
            s[step * 70 + 3] ^= 1
        }
        _ = b.encodeSlices(samples: s, width: 200, height: 150, limit: 32768)
        XCTAssertEqual(b.encodeSlices(samples: s, width: 200, height: 150, limit: 32768), [])
    }

    func testLargeFrameSlicesTopToBottomAndDecodesIdentically() throws {
        let w = 1920, h = 1080
        let s = randomSamples(width: w, height: h, mode: .gray4, seed: 9)
        let slices = FrameEncoder(mode: .gray4).encodeSlices(samples: s, width: w, height: h, limit: 32768)
        XCTAssertGreaterThanOrEqual(slices.count, 2)
        XCTAssertEqual(slices.map(\.isFull), [true] + [Bool](repeating: false, count: slices.count - 1))
        let dec = FrameDecoder()
        var last = -1
        for slice in slices {
            let rows = try decodeAndChangedRows(dec, slice)
            XCTAssertGreaterThan(try XCTUnwrap(rows.first), last)
            last = try XCTUnwrap(rows.last)
        }
        XCTAssertEqual(dec.samples, s)
    }

    func testFirstLimitCapsFirstSlice() {
        // One tile column, 7 tile rows (28672 raw samples): the whole frame compresses to between 8192 and 32768 bytes,
        // so it is one slice under the plain limit and several once the first slice is capped at 8192.
        let w = 64, h = 448
        let s = randomSamples(width: w, height: h, mode: .gray4, seed: 11)
        let plain = FrameEncoder(mode: .gray4).encodeSlices(samples: s, width: w, height: h, limit: 32768,
                                                             firstLimit: nil)
        XCTAssertEqual(plain.count, 1)
        let total = plain[0].data.count
        XCTAssertGreaterThan(total, 8192)
        XCTAssertLessThan(total, 32768)
        let capped = FrameEncoder(mode: .gray4).encodeSlices(samples: s, width: w, height: h, limit: 32768,
                                                              firstLimit: 8192)
        XCTAssertGreaterThanOrEqual(capped.count, 2)
        // One tile row (64 x 64 samples, ratio 1) is the soft floor over the limit.
        XCTAssertLessThanOrEqual(capped[0].data.count, 8192 + 64 * 64 / 2)
    }

    func testDeltaSlicesCarryOnlyChangedTiles() throws {
        let w = 128, h = 64 * 50
        let a = randomSamples(width: w, height: h, mode: .gray4, seed: 1)
        let enc = FrameEncoder(mode: .gray4), dec = FrameDecoder()
        for p in enc.encodeSlices(samples: a, width: w, height: h, limit: 1 << 20) { try dec.decode(p) }
        var b = a
        for row in [3, 40] { b[(row * 64 + 5) * w + 7] ^= 1 }
        let slices = enc.encodeSlices(samples: b, width: w, height: h, limit: 1)
        XCTAssertEqual(slices.count, 2)
        XCTAssertEqual(slices.map(\.isFull), [false, false])
        XCTAssertEqual(enc.lastTileCount, 2)
        XCTAssertEqual(try decodeAndChangedRows(dec, slices[0]), [3])
        XCTAssertEqual(try decodeAndChangedRows(dec, slices[1]), [40])
        XCTAssertEqual(dec.samples, b)
    }

    func testForceFullAfterDroppedSlicesRestoresPicture() throws {
        let w = 1920, h = 1080
        let one = randomSamples(width: w, height: h, mode: .gray4, seed: 2)
        let two = randomSamples(width: w, height: h, mode: .gray4, seed: 3)
        let enc = FrameEncoder(mode: .gray4), dec = FrameDecoder()
        let first = enc.encodeSlices(samples: one, width: w, height: h, limit: 400_000)
        XCTAssertGreaterThanOrEqual(first.count, 3)
        try dec.decode(first[0])
        enc.forceFull = true
        let second = enc.encodeSlices(samples: two, width: w, height: h, limit: 400_000)
        XCTAssertTrue(second[0].isFull)
        for p in second { try dec.decode(p) }
        XCTAssertEqual(dec.samples, two)
    }
}
