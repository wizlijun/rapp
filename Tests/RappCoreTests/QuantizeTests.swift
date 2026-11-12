import XCTest
@testable import RappCore

/// Quantizes one pixel given as R, G, B.
private func q(_ r: UInt8, _ g: UInt8, _ b: UInt8, _ mode: Mode) -> [UInt8] {
    let bgra: [UInt8] = [b, g, r, 255]
    return bgra.withUnsafeBytes {
        Quantizer.quantize(bgra: $0, width: 1, height: 1, bytesPerRow: 4, mode: mode)
    }
}

/// Expands one sample to [B, G, R, A].
private func e(_ s: [UInt8], _ mode: Mode) -> [UInt8] {
    try! Quantizer.expand(samples: s, width: 1, height: 1, mode: mode)
}

/// Builds a BGRA image from rows of (R, G, B, A) pixels.
private func img(_ rows: [[(UInt8, UInt8, UInt8, UInt8)]]) -> [UInt8] {
    rows.flatMap { $0.flatMap { [$0.2, $0.1, $0.0, $0.3] } }
}

private func quant(_ px: [UInt8], w: Int, h: Int, _ mode: Mode = .gray4) -> [UInt8] {
    px.withUnsafeBytes { Quantizer.quantize(bgra: $0, width: w, height: h, bytesPerRow: w * 4, mode: mode) }
}

final class QuantizeTests: XCTestCase {
    func testCornerFillLeftAndRight() {
        // row: transparent, transparent, white, black, transparent
        let px = img([[(0, 0, 0, 0), (0, 0, 0, 0), (255, 255, 255, 255), (0, 0, 0, 255), (0, 0, 0, 0)]])
        XCTAssertEqual(quant(px, w: 5, h: 1), [15, 15, 15, 0, 0])
    }

    func testFullyTransparentRowCopiesRowAbove() {
        let px = img([[(0, 0, 0, 255), (255, 255, 255, 255)], [(0, 0, 0, 0), (0, 0, 0, 0)]])
        XCTAssertEqual(quant(px, w: 2, h: 2), [0, 15, 0, 15])
    }

    func testFirstRowFullyTransparentIsWhite() {
        let px = img([[(0, 0, 0, 0), (0, 0, 0, 0)], [(0, 0, 0, 255), (0, 0, 0, 255)]])
        XCTAssertEqual(quant(px, w: 2, h: 2), [15, 15, 0, 0])
    }

    func testTranslucentPixelInsideRowIsKept() {
        // Only the ends are filled; a non-opaque pixel between opaque ones is quantized as is.
        let px = img([[(255, 255, 255, 255), (0, 0, 0, 128), (255, 255, 255, 255)]])
        XCTAssertEqual(quant(px, w: 3, h: 1), [15, 0, 15])
    }

    func testTranslucentPixelsAtRowStartAreNotSmeared() {
        // A vibrancy sidebar: 20 px at alpha 128 (premultiplied) alternating true
        // black and true white, then opaque mid gray. The sidebar must survive.
        var row: [(UInt8, UInt8, UInt8, UInt8)] = (0..<20).map { $0 % 2 == 0 ? (0, 0, 0, 128) : (128, 128, 128, 128) }
        row += [(UInt8, UInt8, UInt8, UInt8)](repeating: (128, 128, 128, 255), count: 44)
        let rows = [[(UInt8, UInt8, UInt8, UInt8)]](repeating: row, count: 4)
        let out = quant(img(rows), w: 64, h: 4)
        for y in 0..<4 {
            XCTAssertEqual(Array(out[(y * 64)..<(y * 64 + 20)]), (0..<20).map { $0 % 2 == 0 ? 0 : 15 }, "row \(y)")
        }
    }

    func testPartlyTransparentPixelIsUnpremultiplied() {
        // (64, 64, 64) at alpha 128 premultiplied is gray 128 -> 8 of 15 (4 if left premultiplied).
        let px = img([[(255, 255, 255, 255), (64, 64, 64, 128), (255, 255, 255, 255)]])
        XCTAssertEqual(quant(px, w: 3, h: 1), [15, 8, 15])
    }

    func testOpaqueImageUnchanged() {
        let colours: [(UInt8, UInt8, UInt8)] = [(12, 200, 7), (255, 0, 0), (128, 128, 128), (3, 3, 250), (90, 40, 160), (0, 0, 0)]
        let px = img([Array(colours[0..<3]).map { ($0.0, $0.1, $0.2, 255) }, Array(colours[3..<6]).map { ($0.0, $0.1, $0.2, 255) }])
        // Per-pixel modes only: the two-tone modes merge colours within a block by design.
        for mode in [Mode.gray4, .color8, .color16] {
            XCTAssertEqual(quant(px, w: 3, h: 2, mode), colours.flatMap { q($0.0, $0.1, $0.2, mode) }, mode.name)
        }
    }

    func testColor16RowEndFillCopiesWholeSample() {
        let px = img([[(255, 0, 0, 255), (0, 0, 0, 0), (0, 0, 0, 0)]])
        XCTAssertEqual(quant(px, w: 3, h: 1, .color16), [0x00, 0xF8, 0x00, 0xF8, 0x00, 0xF8])
    }

    func testGray4() {
        XCTAssertEqual(q(255, 255, 255, .gray4), [15])
        XCTAssertEqual(q(0, 0, 0, .gray4), [0])
        XCTAssertEqual(q(128, 128, 128, .gray4), [8])
        XCTAssertEqual(e([8], .gray4), [136, 136, 136, 255])
    }

    func testColor8() {
        XCTAssertEqual(q(255, 0, 0, .color8), [180])
        XCTAssertEqual(e([180], .color8), [0, 0, 255, 255])
        XCTAssertEqual(q(128, 128, 128, .color8), [236])
        XCTAssertEqual(e([236], .color8), [131, 131, 131, 255])
        XCTAssertEqual(q(255, 255, 255, .color8), [255])
        XCTAssertEqual(q(0, 0, 0, .color8), [216])
    }

    func testColor16() {
        XCTAssertEqual(q(255, 0, 0, .color16), [0x00, 0xF8])
        XCTAssertEqual(e([0x00, 0xF8], .color16), [0, 0, 255, 255])
        XCTAssertEqual(q(8, 4, 8, .color16), [0x21, 0x08])
        XCTAssertEqual(e([0x21, 0x08], .color16), [8, 4, 8, 255])
    }

    func testRowPaddingIsSkipped() {
        // 2x2 image, 12 bytes per row: two pixels then 4 bytes of padding.
        let white: [UInt8] = [255, 255, 255, 255], black: [UInt8] = [0, 0, 0, 255]
        let pad: [UInt8] = [0x7F, 0x7F, 0x7F, 0x7F]
        let bgra = white + black + pad + black + white + pad
        let samples = bgra.withUnsafeBytes {
            Quantizer.quantize(bgra: $0, width: 2, height: 2, bytesPerRow: 12, mode: .gray4)
        }
        XCTAssertEqual(samples, [15, 0, 0, 15])
    }

    func testExpandedSamplesQuantizeBackToThemselves() {
        // Every sample value must survive expand -> quantize, otherwise a
        // decoded frame would not be a fixed point of the mode.
        for s in 0...15 { let v = e([UInt8(s)], .gray4); XCTAssertEqual(q(v[2], v[1], v[0], .gray4), [UInt8(s)]) }
        for s in 0...255 {
            // The six grey corners of the colour cube are never produced:
            // grey pixels always go to the grey ramp (216...255).
            if s < 216 && s % 43 == 0 { continue }
            let v = e([UInt8(s)], .color8)
            XCTAssertEqual(q(v[2], v[1], v[0], .color8), [UInt8(s)], "sample \(s)")
        }
        for s in stride(from: 0, through: 0xFFFF, by: 257) {
            let bytes = [UInt8(s & 0xFF), UInt8(s >> 8)]
            let v = e(bytes, .color16)
            XCTAssertEqual(q(v[2], v[1], v[0], .color16), bytes)
        }
    }

    func testModeNames() {
        XCTAssertEqual(Mode(name: "color8"), .color8)
        XCTAssertNil(Mode(name: "x"))
        XCTAssertEqual(Mode.gray4.name, "gray4")
        XCTAssertEqual(Mode.allCases.map(\.bytesPerSample), [1, 1, 2, 1, 2])
    }

    // MARK: Two-tone (duogray / duocolor)

    /// A w x h opaque image whose pixel colour comes from `f(x, y)`.
    private func gen(_ w: Int, _ h: Int, _ f: (Int, Int) -> (UInt8, UInt8, UInt8)) -> [UInt8] {
        var px = [UInt8]()
        for y in 0..<h { for x in 0..<w { let c = f(x, y); px += [c.2, c.1, c.0, 255] } }
        return px
    }

    /// Distinct samples (1 or 2 bytes each) inside the block x0..<x1, y0..<y1.
    private func distinct(_ s: [UInt8], w: Int, bps: Int, _ x0: Int, _ x1: Int, _ y0: Int, _ y1: Int) -> Set<Int> {
        var set = Set<Int>()
        for y in y0..<y1 { for x in x0..<x1 {
            let o = (y * w + x) * bps
            set.insert(bps == 1 ? Int(s[o]) : Int(s[o]) | Int(s[o + 1]) << 8)
        } }
        return set
    }

    func testDuoModesHaveNamesAndSampleSizes() {
        XCTAssertEqual(Mode.duogray.rawValue, 3)
        XCTAssertEqual(Mode.duocolor.rawValue, 4)
        XCTAssertEqual(Mode(name: "duogray"), .duogray)
        XCTAssertEqual(Mode(name: "duocolor"), .duocolor)
        XCTAssertEqual(Mode.duogray.bytesPerSample, 1)
        XCTAssertEqual(Mode.duocolor.bytesPerSample, 2)
    }

    func testDuoFlatBlockIsOneSample() {
        // Brightness 100...115 across the block: less than 24 apart.
        let px = gen(16, 16) { x, _ in let v = UInt8(100 + x); return (v, v, v) }
        let s = quant(px, w: 16, h: 16, .duogray)
        XCTAssertEqual(distinct(s, w: 16, bps: 1, 0, 16, 0, 16).count, 1)
    }

    func testDuoSharpBlackTextOnWhiteIsTwoSamples() {
        let px = gen(16, 16) { x, _ in x == 6 ? (0, 0, 0) : (255, 255, 255) }
        let s = quant(px, w: 16, h: 16, .duogray)
        XCTAssertEqual(distinct(s, w: 16, bps: 1, 0, 16, 0, 16), [0, 15])
    }

    func testDuoAntialiasedEdgeKeepsAnIntermediateLevel() {
        // White, with a black column 6 and a 50 % grey anti-aliasing column 7.
        let px = gen(16, 16) { x, _ in x == 6 ? (0, 0, 0) : x == 7 ? (128, 128, 128) : (255, 255, 255) }
        let s = quant(px, w: 16, h: 16, .duogray)
        XCTAssertEqual(s[6], 0, "stroke keeps full black")
        XCTAssertEqual(s[0], 15, "background keeps full white")
        XCTAssertTrue(s[7] > 0 && s[7] < 15, "edge pixel is a blend, got \(s[7])")
    }

    func testDuoDarkToneIsTheStrokeNotTheEdgeAverage() {
        // A black stroke flanked by dark-grey anti-aliasing: the stroke must stay black,
        // not be averaged with its edges into a washed-out grey.
        let px = gen(16, 16) { x, _ in
            x == 6 ? (0, 0, 0) : (x == 5 || x == 7) ? (96, 96, 96) : (255, 255, 255)
        }
        let s = quant(px, w: 16, h: 16, .duogray)
        XCTAssertEqual(s[6], 0)
        XCTAssertEqual(s[0], 15)
    }

    func testDuoBlockHasAtMostFourSamples() {
        // A full black-to-white ramp across the block.
        let px = gen(16, 16) { x, _ in let v = UInt8(x * 17); return (v, v, v) }
        for mode in [Mode.duogray, .duocolor] {
            let s = quant(px, w: 16, h: 16, mode)
            let set = distinct(s, w: 16, bps: mode.bytesPerSample, 0, 16, 0, 16)
            XCTAssertLessThanOrEqual(set.count, 4, "\(mode)")
            XCTAssertGreaterThanOrEqual(set.count, 3, "\(mode)")
        }
    }

    func testDuoColorEdgeBlendsBetweenTheTwoTones() {
        // Red text on white with a pink anti-aliasing column.
        let px = gen(16, 16) { x, _ in x == 6 ? (255, 0, 0) : x == 7 ? (255, 128, 128) : (255, 255, 255) }
        let s = quant(px, w: 16, h: 16, .duocolor)
        let at = { (x: Int) in Int(s[x * 2]) | Int(s[x * 2 + 1]) << 8 }
        XCTAssertEqual(at(6), 0xF800)
        XCTAssertEqual(at(0), 0xFFFF)
        XCTAssertNotEqual(at(7), 0xF800)
        XCTAssertNotEqual(at(7), 0xFFFF)
        XCTAssertEqual(at(7) >> 11, 31, "blend keeps full red")
    }

    func testDuoEdgeBlocksUseTheirOwnPixels() {
        // 20 x 18: main area white with a black dot, right 4 columns and bottom 2 rows blue.
        let px = gen(20, 18) { x, y in
            if x >= 16 || y >= 16 { return (0, 0, 255) }
            return x == 3 && y == 3 ? (0, 0, 0) : (255, 255, 255)
        }
        let s = quant(px, w: 20, h: 18, .duocolor)
        for (x0, x1, y0, y1) in [(0, 16, 0, 16), (16, 20, 0, 16), (0, 16, 16, 18), (16, 20, 16, 18)] {
            XCTAssertLessThanOrEqual(distinct(s, w: 20, bps: 2, x0, x1, y0, y1).count, 2)
        }
        XCTAssertEqual(distinct(s, w: 20, bps: 2, 16, 20, 0, 16), [0x001F], "right edge block is blue")
        XCTAssertEqual(distinct(s, w: 20, bps: 2, 0, 16, 16, 18), [0x001F], "bottom edge block is blue")
        XCTAssertEqual(distinct(s, w: 20, bps: 2, 0, 16, 0, 16), [0x0000, 0xFFFF])
    }

    func testDuoColorKeepsHue() {
        // Red with a white bar.
        let px = gen(16, 16) { x, _ in x < 4 ? (255, 255, 255) : (255, 0, 0) }
        let s = quant(px, w: 16, h: 16, .duocolor)
        XCTAssertEqual(distinct(s, w: 16, bps: 2, 0, 16, 0, 16), [0xF800, 0xFFFF])
    }

    func testDuoTransparentCornersAreFilledFirst() {
        // Same corner rule as the other modes: a transparent run takes the first opaque pixel.
        var px = gen(16, 1) { _, _ in (255, 255, 255) }
        px[3] = 0; px[7] = 0
        XCTAssertEqual(quant(px, w: 16, h: 1, .duogray), [UInt8](repeating: 15, count: 16))
    }

    func testDuoExpandMatchesBaseModes() {
        let g: [UInt8] = [0, 7, 15]
        XCTAssertEqual(try Quantizer.expand(samples: g, width: 3, height: 1, mode: .duogray),
                       try Quantizer.expand(samples: g, width: 3, height: 1, mode: .gray4))
        let c: [UInt8] = [0x00, 0xF8, 0x1F, 0x00]
        XCTAssertEqual(try Quantizer.expand(samples: c, width: 2, height: 1, mode: .duocolor),
                       try Quantizer.expand(samples: c, width: 2, height: 1, mode: .color16))
    }

    func testExpandShortSamplesThrows() {
        XCTAssertThrowsError(try Quantizer.expand(samples: [0], width: 4, height: 4, mode: .color16)) {
            XCTAssertEqual($0 as? ExpandError, .shortSamples)
        }
    }

    func testExpandRectIntoStridedBuffer() throws {
        // 4x2 color16: pixel i has sample value (i + 1) in the low byte of green.
        var samples = [UInt8]()
        for i in 0..<8 { let s = UInt16(i + 1) << 5; samples += [UInt8(s & 0xFF), UInt8(s >> 8)] }
        var dst = [UInt8](repeating: 7, count: 32)
        try dst.withUnsafeMutableBytes {
            try Quantizer.expand(samples: samples, width: 4, height: 2, mode: .color16,
                                 rect: (x: 1, y: 0, w: 2, h: 2), into: $0.baseAddress!, bytesPerRow: 16)
        }
        let whole = try Quantizer.expand(samples: samples, width: 4, height: 2, mode: .color16)
        XCTAssertEqual(Array(dst[0..<8]), Array(whole[4..<12]))
        XCTAssertEqual(Array(dst[8..<16]), [UInt8](repeating: 7, count: 8))
        XCTAssertEqual(Array(dst[16..<24]), Array(whole[20..<28]))
        XCTAssertEqual(Array(dst[24..<32]), [UInt8](repeating: 7, count: 8))
    }

    func testExpandRectOutsideThrows() {
        var dst = [UInt8](repeating: 0, count: 64)
        let samples = [UInt8](repeating: 0, count: 16)
        for rect in [(x: 3, y: 0, w: 2, h: 1), (x: 0, y: 0, w: 0, h: 1), (x: -1, y: 0, w: 1, h: 1)] {
            var caught: ExpandError?
            dst.withUnsafeMutableBytes { buf in
                do {
                    try Quantizer.expand(samples: samples, width: 4, height: 2, mode: .color16, rect: rect,
                                         into: buf.baseAddress!, bytesPerRow: 16)
                } catch { caught = error as? ExpandError }
            }
            XCTAssertEqual(caught, .badRect)
        }
    }
}
