import Foundation

/// A rectangle in image points, y down.
public struct RuleRect: Equatable, Hashable {
    public var x, y, w, h: Int
    public init(x: Int, y: Int, w: Int, h: Int) { self.x = x; self.y = y; self.w = w; self.h = h }
    public var maxX: Int { x + w }
    public var maxY: Int { y + h }
}

/// A frame sampled at one pixel per point. BGRA, `width * 4` bytes per row.
public struct RuleImage {
    public let width: Int, height: Int
    public var pixels: [UInt8]

    public init(width: Int, height: Int, pixels: [UInt8]) {
        self.width = width; self.height = height; self.pixels = pixels
    }

    /// Cap on the sampled image so a hostile or buggy `scale` cannot ask for gigabytes.
    static let maxSamplePixels = 64 * 1024 * 1024

    /// Crops `crop` (pixels of the source) and scales it to one pixel per point by nearest neighbour:
    /// each point takes the top-left pixel of its `scale` x `scale` cell. Returns nil when `crop`
    /// is empty or leaves the source, when `scale` is not a positive finite number, or when the
    /// buffer is too short for the stated geometry.
    public static func sample(bgra: UnsafeRawBufferPointer, width: Int, height: Int, bytesPerRow: Int,
                              crop: RuleRect, scale: Double) -> RuleImage? {
        guard width > 0, height > 0, bytesPerRow >= width * 4, scale.isFinite, scale > 0,
              crop.w > 0, crop.h > 0, crop.x >= 0, crop.y >= 0,
              crop.x <= width - crop.w, crop.y <= height - crop.h,
              bgra.count >= (height - 1) * bytesPerRow + width * 4,
              let base = bgra.baseAddress else { return nil }
        let dw = max(1, Int((Double(crop.w) / scale).rounded(.down)))
        let dh = max(1, Int((Double(crop.h) / scale).rounded(.down)))
        guard dw <= maxSamplePixels / dh else { return nil }
        let src = base.assumingMemoryBound(to: UInt8.self)
        var out = [UInt8](repeating: 0, count: dw * dh * 4)
        // Source columns are the same for every row.
        var cols = [Int](repeating: 0, count: dw)
        for dx in 0..<dw { cols[dx] = crop.x + min(crop.w - 1, Int((Double(dx) * scale).rounded(.down))) }
        for dy in 0..<dh {
            let sy = crop.y + min(crop.h - 1, Int((Double(dy) * scale).rounded(.down)))
            let row = src + sy * bytesPerRow
            var o = dy * dw * 4
            for dx in 0..<dw {
                let p = row + cols[dx] * 4
                out[o] = p[0]; out[o + 1] = p[1]; out[o + 2] = p[2]; out[o + 3] = p[3]
                o += 4
            }
        }
        return RuleImage(width: dw, height: dh, pixels: out)
    }

    /// Caller keeps `x`, `y` inside the image.
    public func rgb(_ x: Int, _ y: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
        let i = (y * width + x) * 4
        return (pixels[i + 2], pixels[i + 1], pixels[i])
    }
}

public struct HSL: Equatable { public var h, s, l: Double }   // h 0..<360, s/l 0...100

public func hsl(r: UInt8, g: UInt8, b: UInt8) -> HSL {
    let rf = Double(r) / 255, gf = Double(g) / 255, bf = Double(b) / 255
    let hi = max(rf, gf, bf), lo = min(rf, gf, bf), d = hi - lo
    let l = (hi + lo) / 2
    if d == 0 { return HSL(h: 0, s: 0, l: l * 100) }
    let s = d / (1 - abs(2 * l - 1))
    var h: Double
    if hi == rf { h = (gf - bf) / d; if h < 0 { h += 6 } }
    else if hi == gf { h = (bf - rf) / d + 2 }
    else { h = (rf - gf) / d + 4 }
    h *= 60
    if h >= 360 { h -= 360 }
    return HSL(h: h, s: min(100, s * 100), l: l * 100)
}

/// Largest per-channel difference.
public func colorDistance(_ a: (r: UInt8, g: UInt8, b: UInt8), _ b: (r: UInt8, g: UInt8, b: UInt8)) -> Int {
    max(abs(Int(a.r) - Int(b.r)), abs(Int(a.g) - Int(b.g)), abs(Int(a.b) - Int(b.b)))
}

public let regionContrast = 16      // edge: a column differs from the reference by this much
public let blobContrast = 24        // blob / shape foreground threshold
