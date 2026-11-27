import XCTest
@testable import RappCore

/// `Quantizer.quantize` on many pictures, in all five modes (read by `rust/host-core/tests/quantize.rs`).
///
/// `quantize.bin` records come in pairs: tag 1 = the input (`u8 mode, u16 width, u16 height,
/// u32 bytesPerRow`, then the BGRA bytes), tag 2 = Swift's output for it.
final class QuantizeFixtures: XCTestCase {
    struct Picture {
        var name: String
        var width: Int
        var height: Int
        var bytesPerRow: Int
        var bgra: [UInt8]
    }

    /// Rows of (R, G, B, A) pixels, tightly packed.
    private static func img(_ name: String, _ rows: [[(UInt8, UInt8, UInt8, UInt8)]]) -> Picture {
        Picture(name: name, width: rows[0].count, height: rows.count, bytesPerRow: rows[0].count * 4,
                bgra: rows.flatMap { $0.flatMap { [$0.2, $0.1, $0.0, $0.3] } })
    }

    /// A w x h opaque picture whose colour comes from `f(x, y)`.
    private static func gen(_ name: String, _ w: Int, _ h: Int, _ f: (Int, Int) -> (UInt8, UInt8, UInt8)) -> Picture {
        var px = [UInt8]()
        for y in 0..<h { for x in 0..<w { let c = f(x, y); px += [c.2, c.1, c.0, 255] } }
        return Picture(name: name, width: w, height: h, bytesPerRow: w * 4, bgra: px)
    }

    /// Random BGRA with `padding` junk bytes per row; `clear` percent of the pixels have
    /// alpha 0 and a quarter are partly transparent (any byte values, as a real capture never is).
    private static func noise(_ name: String, _ w: Int, _ h: Int, padding: Int, seed: UInt64, clear: Int = 15) -> Picture {
        var rng = HostRNG(seed: seed)
        let bpr = w * 4 + padding
        var px = [UInt8](repeating: 0, count: max(0, h * bpr))
        for y in 0..<h {
            for x in 0..<w {
                let o = y * bpr + x * 4
                let a: UInt8
                let roll = rng.int(0...99)
                if roll < clear {
                    a = 0
                } else if roll < clear + 25 {
                    a = UInt8(rng.int(1...254))
                } else {
                    a = 255
                }
                px[o] = UInt8(rng.int(0...255)); px[o + 1] = UInt8(rng.int(0...255)); px[o + 2] = UInt8(rng.int(0...255))
                px[o + 3] = a
            }
            for k in 0..<padding { px[y * bpr + w * 4 + k] = UInt8(rng.int(0...255)) }
        }
        return Picture(name: name, width: w, height: h, bytesPerRow: bpr, bgra: px)
    }

    static func pictures() -> [Picture] {
        var out: [Picture] = []
        // QuantizeTests scenes.
        out.append(img("corner fill left and right",
                       [[(0, 0, 0, 0), (0, 0, 0, 0), (255, 255, 255, 255), (0, 0, 0, 255), (0, 0, 0, 0)]]))
        out.append(img("transparent row copies the row above",
                       [[(0, 0, 0, 255), (255, 255, 255, 255)], [(0, 0, 0, 0), (0, 0, 0, 0)]]))
        out.append(img("first row transparent is white",
                       [[(0, 0, 0, 0), (0, 0, 0, 0)], [(0, 0, 0, 255), (0, 0, 0, 255)]]))
        out.append(img("translucent pixel inside a row", [[(255, 255, 255, 255), (0, 0, 0, 128), (255, 255, 255, 255)]]))
        var sidebar: [(UInt8, UInt8, UInt8, UInt8)] = (0..<20).map { $0 % 2 == 0 ? (0, 0, 0, 128) : (128, 128, 128, 128) }
        sidebar += [(UInt8, UInt8, UInt8, UInt8)](repeating: (128, 128, 128, 255), count: 44)
        out.append(img("vibrancy sidebar", [[(UInt8, UInt8, UInt8, UInt8)]](repeating: sidebar, count: 4)))
        out.append(img("unpremultiplied", [[(255, 255, 255, 255), (64, 64, 64, 128), (255, 255, 255, 255)]]))
        let colours: [(UInt8, UInt8, UInt8)] = [(12, 200, 7), (255, 0, 0), (128, 128, 128), (3, 3, 250), (90, 40, 160), (0, 0, 0)]
        out.append(img("opaque colours", [Array(colours[0..<3]).map { ($0.0, $0.1, $0.2, 255) },
                                          Array(colours[3..<6]).map { ($0.0, $0.1, $0.2, 255) }]))
        out.append(img("row end fill", [[(255, 0, 0, 255), (0, 0, 0, 0), (0, 0, 0, 0)]]))
        out.append(Picture(name: "row padding", width: 2, height: 2, bytesPerRow: 12,
                           bgra: [255, 255, 255, 255, 0, 0, 0, 255, 0x7F, 0x7F, 0x7F, 0x7F,
                                  0, 0, 0, 255, 255, 255, 255, 255, 0x7F, 0x7F, 0x7F, 0x7F]))
        out.append(gen("duo flat block", 16, 16) { x, _ in let v = UInt8(100 + x); return (v, v, v) })
        out.append(gen("duo sharp text", 16, 16) { x, _ in x == 6 ? (0, 0, 0) : (255, 255, 255) })
        out.append(gen("duo anti-aliased edge", 16, 16) { x, _ in x == 6 ? (0, 0, 0) : x == 7 ? (128, 128, 128) : (255, 255, 255) })
        out.append(gen("duo stroke with grey edges", 16, 16) { x, _ in
            x == 6 ? (0, 0, 0) : (x == 5 || x == 7) ? (96, 96, 96) : (255, 255, 255)
        })
        out.append(gen("duo ramp", 16, 16) { x, _ in let v = UInt8(x * 17); return (v, v, v) })
        out.append(gen("duo red text", 16, 16) { x, _ in x == 6 ? (255, 0, 0) : x == 7 ? (255, 128, 128) : (255, 255, 255) })
        out.append(gen("duo edge blocks", 20, 18) { x, y in
            if x >= 16 || y >= 16 { return (0, 0, 255) }
            return x == 3 && y == 3 ? (0, 0, 0) : (255, 255, 255)
        })
        out.append(gen("duo red with white bar", 16, 16) { x, _ in x < 4 ? (255, 255, 255) : (255, 0, 0) })
        var holes = gen("duo transparent corners", 16, 1) { _, _ in (255, 255, 255) }
        holes.bgra[3] = 0; holes.bgra[7] = 0
        out.append(holes)
        // A captured scene.
        let scene = ScrollScenes.frames(seed: 5, count: 1, kinds: [.terminalScroll], size: (160, 120))[0]
        out.append(Picture(name: "scene 160x120", width: scene.width, height: scene.height,
                           bytesPerRow: scene.width * 4, bgra: scene.bgra))
        // Sizes that are not multiples of 16 or 64, with transparency and row padding.
        out.append(noise("noise 1x1", 1, 1, padding: 0, seed: 1))
        out.append(noise("noise 17x33", 17, 33, padding: 0, seed: 2))
        out.append(noise("noise 65x1", 65, 1, padding: 0, seed: 3))
        out.append(noise("noise 300x7 padded", 300, 7, padding: 20, seed: 4))
        out.append(noise("noise 33x17 padded 3", 33, 17, padding: 3, seed: 5))
        out.append(noise("noise 40x40 mostly clear", 40, 40, padding: 8, seed: 6, clear: 70))
        // Flat pictures.
        out.append(gen("black", 33, 20) { _, _ in (0, 0, 0) })
        out.append(gen("white", 33, 20) { _, _ in (255, 255, 255) })
        out.append(gen("every grey", 256, 1) { x, _ in (UInt8(x), UInt8(x), UInt8(x)) })
        out.append(gen("every grey, 16 rows", 16, 256) { _, y in (UInt8(y), UInt8(y), UInt8(y)) })
        out.append(gen("primaries", 7, 3) { x, y in
            let c: [(UInt8, UInt8, UInt8)] = [(255, 0, 0), (0, 255, 0), (0, 0, 255), (255, 255, 0),
                                               (0, 255, 255), (255, 0, 255), (15, 0, 0)]
            return y == 1 ? (c[x].0 / 2, c[x].1 / 2, c[x].2 / 2) : c[x]
        })
        out.append(gen("colour cube edges", 18, 18) { x, y in
            (UInt8(x * 15), UInt8(y * 15), UInt8((x + y) * 7))
        })
        var clear = gen("all transparent", 5, 4) { _, _ in (10, 20, 30) }
        for i in stride(from: 3, to: clear.bgra.count, by: 4) { clear.bgra[i] = 0 }
        out.append(clear)
        // Empty pictures.
        out.append(Picture(name: "width 0", width: 0, height: 4, bytesPerRow: 0, bgra: []))
        out.append(Picture(name: "height 0", width: 4, height: 0, bytesPerRow: 16, bgra: []))
        return out
    }

    func testQuantize() {
        var items: [(tag: UInt8, payload: [UInt8])] = []
        for p in Self.pictures() {
            for mode in Mode.allCases {
                let input = [mode.rawValue] + HostFixture.u16(UInt16(p.width)) + HostFixture.u16(UInt16(p.height))
                    + HostFixture.u32(UInt32(p.bytesPerRow)) + p.bgra
                let output = p.bgra.withUnsafeBytes {
                    Quantizer.quantize(bgra: $0, width: p.width, height: p.height, bytesPerRow: p.bytesPerRow, mode: mode)
                }
                XCTAssertEqual(output.count, p.width * p.height * mode.bytesPerSample, p.name)
                items.append((tag: 1, payload: input))
                items.append((tag: 2, payload: output))
            }
        }
        HostFixture.check("quantize.bin", HostFixture.records(items))
    }
}
