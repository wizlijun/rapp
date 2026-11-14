import Foundation
import XCTest
@testable import RappCore

/// Encode time of scroll detection at 1080p. Runs only with RAPP_PERF=1, in a
/// release build: `RAPP_PERF=1 swift test -c release --filter RappCoreTests.ScrollCopyPerfTests`.
final class ScrollCopyPerfTests: XCTestCase {
    func testExtraEncodeTimeAt1080p() throws {
        guard ProcessInfo.processInfo.environment["RAPP_PERF"] == "1" else {
            throw XCTSkip("set RAPP_PERF=1 (release build) to measure")
        }
        let scroll = ScrollScenes.frames(seed: 9, count: 61, kinds: [.webScroll(topBar: 60, sideBar: 200)],
                                         size: (1920, 1080))
        // The worst case for the detector: every tile changes and nothing is found anywhere.
        var state: UInt64 = 1
        let noise = (0..<16).map { _ in
            var bgra = [UInt8](repeating: 0, count: 1920 * 1080 * 4)
            bgra.withUnsafeMutableBytes { p in
                for i in 0..<(p.count / 8) {
                    state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                    p.storeBytes(of: state | 0xFF00_0000_FF00_0000, toByteOffset: i * 8, as: UInt64.self)
                }
            }
            return SceneFrame(bgra: bgra, width: 1920, height: 1080, region: CanvasRect(x: 0, y: 0, w: 1920, h: 1080))
        }
        for (name, frames) in [("web scroll", scroll), ("noise", noise)] {
        for (mode, raw) in [(Mode.duogray, true), (.color16, false)] {
            let samples = frames.map { ScrollScenes.samples($0, mode: mode) }
            /// Mean milliseconds per frame over every frame after the first, best of three runs.
            func measure(copies: Bool) -> (ms: Double, bytes: Int) {
                var best = Double.infinity, bytes = 0
                for _ in 0..<3 {
                    let enc = FrameEncoder(mode: mode)
                    enc.copiesEnabled = copies
                    var total = 0.0
                    bytes = 0
                    for (i, f) in frames.enumerated() {
                        let start = DispatchTime.now().uptimeNanoseconds
                        let slices = enc.encodeSlices(samples: samples[i], raw: raw ? f.bgra : nil, width: f.width,
                                                      height: f.height, region: f.region, limit: 32768, firstLimit: 8192)
                        let ns = DispatchTime.now().uptimeNanoseconds - start
                        if i > 0 {
                            total += Double(ns) / 1e6
                            bytes += slices.reduce(0) { $0 + $1.data.count }
                        }
                    }
                    best = min(best, total / Double(frames.count - 1))
                }
                return (best, bytes)
            }
            let on = measure(copies: true), off = measure(copies: false)
            print(String(format: "ScrollCopyPerf %@, %@ raw %@: copies on %.2f ms/frame (%d bytes), off %.2f ms/frame (%d bytes), extra %.2f ms",
                         name, mode.name, raw ? "yes" : "no", on.ms, on.bytes, off.ms, off.bytes, on.ms - off.ms))
            XCTAssertLessThanOrEqual(on.ms - off.ms, 3, "\(name) \(mode)")
        }
        }
    }
}
