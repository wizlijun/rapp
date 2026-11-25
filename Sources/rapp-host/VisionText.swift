import CoreGraphics
import Foundation
import RappCore
import Vision

/// On-device text recognition for the state rules' text signals (R6). Nothing leaves the machine and
/// nothing recognised is logged or stored: the lines go straight back to the engine's matcher.
///
/// Cost bound: the rect is clamped to the image, tiny rects are skipped, and a rect over `maxPixels`
/// is shrunk by an integer nearest-neighbour step while it is copied out, so Vision never sees more
/// than about 1600 x 1600 pixels.
final class VisionText: TextReader {
    static let minSide = 8
    static let maxPixels = 1600 * 1600

    func lines(in image: RuleImage, rect: RuleRect) -> [String] {
        guard let cg = Self.makeImage(image, rect: rect) else { return [] }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.usesLanguageCorrection = false
        do { try VNImageRequestHandler(cgImage: cg, options: [:]).perform([request]) } catch { return [] }
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    }

    /// The BGRA block under `rect` (clamped to `image`) as a CGImage, or nil when it is degenerate.
    static func makeImage(_ image: RuleImage, rect: RuleRect) -> CGImage? {
        let x0 = max(0, rect.x), y0 = max(0, rect.y)
        let x1 = min(image.width, rect.maxX), y1 = min(image.height, rect.maxY)
        let w = x1 - x0, h = y1 - y0
        guard w >= minSide, h >= minSide, image.pixels.count >= image.width * image.height * 4 else { return nil }
        var step = 1
        while (w / step) * (h / step) > maxPixels { step += 1 }
        let ow = w / step, oh = h / step
        guard ow >= 1, oh >= 1 else { return nil }
        var out = [UInt8](repeating: 0, count: ow * oh * 4)
        image.pixels.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                for y in 0..<oh {
                    let srow = ((y0 + y * step) * image.width + x0) * 4
                    let drow = y * ow * 4
                    if step == 1 {
                        for i in 0..<(ow * 4) { dst[drow + i] = src[srow + i] }
                    } else {
                        for x in 0..<ow {
                            let s = srow + x * step * 4, d = drow + x * 4
                            dst[d] = src[s]; dst[d + 1] = src[s + 1]; dst[d + 2] = src[s + 2]; dst[d + 3] = src[s + 3]
                        }
                    }
                }
            }
        }
        guard let provider = CGDataProvider(data: Data(out) as CFData) else { return nil }
        let info = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        return CGImage(width: ow, height: oh, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: ow * 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: info),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
