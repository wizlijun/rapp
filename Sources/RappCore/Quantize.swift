/// A colour depth. Every pixel is reduced to one "sample" of this mode.
public enum Mode: UInt8, CaseIterable {
    /// 16 grey levels, one byte per sample holding 0...15.
    case gray4 = 0
    /// Fixed 256-colour palette (6x6x6 colour cube + 40 greys), one byte per sample.
    case color8 = 1
    /// RGB565, two bytes per sample, little-endian.
    case color16 = 2
    /// Two tones per 16x16 block, as 16 grey levels (samples like gray4).
    case duogray = 3
    /// Two tones per 16x16 block, as RGB565 (samples like color16).
    case duocolor = 4

    public var bytesPerSample: Int {
        self == .color16 || self == .duocolor ? 2 : 1
    }

    public var name: String {
        switch self {
        case .gray4: return "gray4"
        case .color8: return "color8"
        case .color16: return "color16"
        case .duogray: return "duogray"
        case .duocolor: return "duocolor"
        }
    }

    public init?(name: String) {
        guard let mode = Mode.allCases.first(where: { $0.name == name }) else { return nil }
        self = mode
    }
}

public enum Quantizer {
    @inline(__always)
    private static func luma(_ r: Int, _ g: Int, _ b: Int) -> Int {
        (77 * r + 150 * g + 29 * b) >> 8
    }

    /// Writes the sample for one pixel at `dst[o]` (two bytes for color16).
    @inline(__always)
    private static func store(_ r: Int, _ g: Int, _ b: Int, mode: Mode, into dst: UnsafeMutableBufferPointer<UInt8>, at o: Int) {
        switch mode {
        case .gray4, .duogray:
            dst[o] = UInt8((luma(r, g, b) * 15 + 127) / 255)
        case .color8:
            let mx = max(r, max(g, b)), mn = min(r, min(g, b))
            if mx - mn < 16 {
                dst[o] = UInt8(216 + (luma(r, g, b) * 39 + 127) / 255)
            } else {
                let ri = (r * 5 + 127) / 255, gi = (g * 5 + 127) / 255, bi = (b * 5 + 127) / 255
                dst[o] = UInt8(ri * 36 + gi * 6 + bi)
            }
        case .color16, .duocolor:
            let s = (r >> 3) << 11 | (g >> 2) << 5 | (b >> 3)
            dst[o] = UInt8(s & 0xFF)
            dst[o + 1] = UInt8(s >> 8)
        }
    }

    /// Side of the square blocks the two-tone modes work on.
    public static let duoBlock = 16

    /// Reduces a BGRA image to samples. `bgra` holds B, G, R, A bytes with
    /// `bytesPerRow` bytes per row (rows may be padded). The result has
    /// `width * height * mode.bytesPerSample` bytes, row by row.
    ///
    /// Rounded window corners: fully transparent pixels (alpha 0) before a
    /// row's first visible pixel take that pixel's sample, and likewise after
    /// the last visible one. A row with no visible pixel copies the row above
    /// (white for the first row). Partly transparent pixels (vibrancy
    /// sidebars, anti-aliased corner edges) are kept, un-premultiplied.
    ///
    /// Two-tone modes apply the same corner rule to the colours first, then
    /// split every 16x16 block (aligned to the image origin; edge blocks keep
    /// their real size) into at most two brightness groups, each painted with
    /// its mean colour.
    public static func quantize(bgra: UnsafeRawBufferPointer, width: Int, height: Int,
                                bytesPerRow: Int, mode: Mode) -> [UInt8] {
        precondition(bytesPerRow >= width * 4 && bgra.count >= (height - 1) * bytesPerRow + width * 4,
                     "pixel buffer too small")
        guard width > 0 && height > 0 else { return [UInt8](repeating: 0, count: width * height * mode.bytesPerSample) }
        switch mode {
        case .gray4, .color8, .color16:
            return cornerFilled(bgra: bgra, width: width, height: height, bytesPerRow: bytesPerRow,
                                bps: mode.bytesPerSample) { r, g, b, dst, o in store(r, g, b, mode: mode, into: dst, at: o) }
        case .duogray, .duocolor:
            let rgb = cornerFilled(bgra: bgra, width: width, height: height, bytesPerRow: bytesPerRow, bps: 3) { r, g, b, dst, o in
                dst[o] = UInt8(r); dst[o + 1] = UInt8(g); dst[o + 2] = UInt8(b)
            }
            return twoTone(rgb: rgb, width: width, height: height, mode: mode)
        }
    }

    /// The per-row corner rule, writing `bps` bytes per pixel through `put`.
    @inline(__always)
    private static func cornerFilled(bgra: UnsafeRawBufferPointer, width: Int, height: Int, bytesPerRow: Int, bps: Int,
                                     put: (Int, Int, Int, UnsafeMutableBufferPointer<UInt8>, Int) -> Void) -> [UInt8] {
        let rowSamples = width * bps
        var out = [UInt8](repeating: 0, count: width * height * bps)
        out.withUnsafeMutableBufferPointer { dst in
            for y in 0..<height {
                let row = y * bytesPerRow
                let rowOut = y * rowSamples
                // Only the transparent runs at the ends are scanned twice.
                var first = 0
                while first < width && bgra[row + first * 4 + 3] == 0 { first += 1 }
                if first == width {
                    if y == 0 {
                        put(255, 255, 255, dst, 0)
                        for x in 1..<width { for k in 0..<bps { dst[x * bps + k] = dst[k] } }
                    } else {
                        for k in 0..<rowSamples { dst[rowOut + k] = dst[rowOut - rowSamples + k] }
                    }
                    continue
                }
                var last = width - 1
                while bgra[row + last * 4 + 3] == 0 { last -= 1 }
                var i = row + first * 4
                for x in first...last {
                    let a = Int(bgra[i + 3])
                    if a == 255 || a == 0 {
                        put(Int(bgra[i + 2]), Int(bgra[i + 1]), Int(bgra[i]), dst, rowOut + x * bps)
                    } else {
                        // Capture pixels are premultiplied: recover the colour itself.
                        put(min(255, (Int(bgra[i + 2]) * 255 + a / 2) / a),
                            min(255, (Int(bgra[i + 1]) * 255 + a / 2) / a),
                            min(255, (Int(bgra[i]) * 255 + a / 2) / a), dst, rowOut + x * bps)
                    }
                    i += 4
                }
                for x in 0..<first { for k in 0..<bps { dst[rowOut + x * bps + k] = dst[rowOut + first * bps + k] } }
                if last + 1 < width {
                    for x in (last + 1)..<width { for k in 0..<bps { dst[rowOut + x * bps + k] = dst[rowOut + last * bps + k] } }
                }
            }
        }
        return out
    }

    /// Two brightness groups per block from packed RGB (3 bytes per pixel).
    private static func twoTone(rgb: [UInt8], width: Int, height: Int, mode: Mode) -> [UInt8] {
        let bps = mode.bytesPerSample
        let n = duoBlock
        var out = [UInt8](repeating: 0, count: width * height * bps)
        var lum = [Int](repeating: 0, count: n * n)
        out.withUnsafeMutableBufferPointer { dst in
            rgb.withUnsafeBufferPointer { src in
                for by in stride(from: 0, to: height, by: n) {
                    let bh = min(n, height - by)
                    for bx in stride(from: 0, to: width, by: n) {
                        let bw = min(n, width - bx)
                        var lo = 255, hi = 0
                        for y in 0..<bh {
                            var i = ((by + y) * width + bx) * 3
                            for x in 0..<bw {
                                let l = luma(Int(src[i]), Int(src[i + 1]), Int(src[i + 2]))
                                lum[y * n + x] = l
                                lo = min(lo, l); hi = max(hi, l)
                                i += 3
                            }
                        }
                        // Pixels with brightness >= t are the light group; t above hi means one group.
                        var t = hi + 1
                        if hi - lo >= 24 {
                            t = (lo + hi) / 2
                            for _ in 0..<4 {
                                var s0 = 0, c0 = 0, s1 = 0, c1 = 0
                                for y in 0..<bh { for x in 0..<bw {
                                    let l = lum[y * n + x]
                                    if l >= t { s1 += l; c1 += 1 } else { s0 += l; c0 += 1 }
                                } }
                                if c0 == 0 || c1 == 0 { break }
                                t = (s0 / c0 + s1 / c1 + 1) / 2
                            }
                        }
                        var sum = [0, 0, 0, 0, 0, 0], cnt = [0, 0]
                        for y in 0..<bh {
                            var i = ((by + y) * width + bx) * 3
                            for x in 0..<bw {
                                let g = lum[y * n + x] >= t ? 1 : 0
                                sum[g * 3] += Int(src[i]); sum[g * 3 + 1] += Int(src[i + 1]); sum[g * 3 + 2] += Int(src[i + 2])
                                cnt[g] += 1
                                i += 3
                            }
                        }
                        var tone = [UInt8](repeating: 0, count: 4)
                        tone.withUnsafeMutableBufferPointer { tb in
                            for g in 0..<2 where cnt[g] > 0 {
                                store(sum[g * 3] / cnt[g], sum[g * 3 + 1] / cnt[g], sum[g * 3 + 2] / cnt[g],
                                      mode: mode, into: tb, at: g * bps)
                            }
                        }
                        for y in 0..<bh {
                            for x in 0..<bw {
                                let g = lum[y * n + x] >= t ? 1 : 0
                                let o = ((by + y) * width + bx + x) * bps
                                for k in 0..<bps { dst[o + k] = tone[g * bps + k] }
                            }
                        }
                    }
                }
            }
        }
        return out
    }

    /// Turns samples back into a displayable BGRA image (alpha 255, `width * 4` bytes per row).
    public static func expand(samples: [UInt8], width: Int, height: Int, mode: Mode) -> [UInt8] {
        let count = width * height
        precondition(samples.count >= count * mode.bytesPerSample, "sample buffer too small")
        var out = [UInt8](repeating: 255, count: count * 4)
        out.withUnsafeMutableBufferPointer { dst in
            samples.withUnsafeBufferPointer { src in
                for p in 0..<count {
                    let r: Int, g: Int, b: Int
                    switch mode {
                    case .gray4, .duogray:
                        let v = Int(src[p] & 0x0F) * 17
                        r = v; g = v; b = v
                    case .color8:
                        let s = Int(src[p])
                        if s >= 216 {
                            let v = ((s - 216) * 255 + 19) / 39
                            r = v; g = v; b = v
                        } else {
                            r = (s / 36) * 51; g = (s / 6 % 6) * 51; b = (s % 6) * 51
                        }
                    case .color16, .duocolor:
                        let s = Int(src[p * 2]) | Int(src[p * 2 + 1]) << 8
                        let r5 = s >> 11, g6 = (s >> 5) & 0x3F, b5 = s & 0x1F
                        r = (r5 << 3) | (r5 >> 2); g = (g6 << 2) | (g6 >> 4); b = (b5 << 3) | (b5 >> 2)
                    }
                    dst[p * 4] = UInt8(b)
                    dst[p * 4 + 1] = UInt8(g)
                    dst[p * 4 + 2] = UInt8(r)
                }
            }
        }
        return out
    }
}
