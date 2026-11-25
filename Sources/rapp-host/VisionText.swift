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

    private static let readyLock = NSLock()
    private static var isReady = false
    var ready: Bool { Self.readyLock.withLock { Self.isReady } }

    private static let warmed = NSLock()
    private static var warmStarted = false

    /// Loads Vision once per process, off the caller's queue. Later calls do nothing. When the warm-up
    /// recognition fails the reader stays not ready (text signals read nothing) and one line says so.
    static func warmUp(log: @escaping (String) -> Void) {
        let first = warmed.withLock { () -> Bool in defer { warmStarted = true }; return !warmStarted }
        guard first else { return }
        DispatchQueue.global(qos: .utility).async {
            // The first recognition loads the model (seconds); pay for it here, not on the watcher queue.
            var px = [UInt8](repeating: 255, count: 64 * 64 * 4)
            for i in stride(from: 0, to: px.count, by: 4) where (i / 4) % 64 > 20 && (i / 4) % 64 < 40 { px[i] = 0; px[i + 1] = 0; px[i + 2] = 0 }
            let probe = RuleImage(width: 64, height: 64, pixels: px)
            guard VisionText().recognise(in: probe, rect: RuleRect(x: 0, y: 0, w: 64, h: 64)) != nil else {
                log("state rules: text recognition unavailable (warm-up failed), text signals are off")
                return
            }
            readyLock.withLock { isReady = true }
        }
    }

    func lines(in image: RuleImage, rect: RuleRect) -> [String] {
        guard ready else { return [] }
        return recognise(in: image, rect: rect) ?? []
    }

    /// Nil when the image is degenerate or Vision failed; the recognised lines otherwise.
    private func recognise(in image: RuleImage, rect: RuleRect) -> [String]? {
        guard let cg = Self.makeImage(image, rect: rect) else { return nil }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.usesLanguageCorrection = false
        do { try VNImageRequestHandler(cgImage: cg, options: [:]).perform([request]) } catch { return nil }
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
