import Foundation
import XCTest
@testable import RappCore

/// Fixtures shared with the Rust host core (`rust/host-core/tests/`): the Swift
/// code is the reference, and every generator here ends in `HostFixture.check`.
///
/// `RAPP_WRITE_FIXTURES=1 swift test --filter 'Fixtures/'` writes the files to
/// `rust/host-core/tests/fixtures/`; a plain `swift test` compares and fails on any
/// difference, so a Swift change that moves a fixture cannot go unnoticed.
///
/// Formats:
/// - `.bin`: records one after another, each `u8 tag, u32 LE length, payload`.
/// - `.json`: an array of `{"name", "in", "out"}` objects, sorted keys, pretty-printed,
///   trailing newline. Swift `Float` values are written as the `Double` of the same
///   value (`f(_:)`), so Rust reads them back as exactly the same `f32`.
enum HostFixture {
    /// The repository root: this file is `Tests/RappCoreTests/HostCoreFixtures/HostFixture.swift`.
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    static let directory = root.appendingPathComponent("rust/host-core/tests/fixtures")

    static var writing: Bool { ProcessInfo.processInfo.environment["RAPP_WRITE_FIXTURES"] == "1" }

    /// Writes the fixture (write mode) or compares it with the file on disk.
    static func check(_ name: String, _ bytes: [UInt8], file: StaticString = #filePath, line: UInt = #line) {
        let url = directory.appendingPathComponent(name)
        if writing {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try Data(bytes).write(to: url, options: .atomic)
            } catch {
                XCTFail("cannot write fixture \(name): \(error)", file: file, line: line)
            }
            return
        }
        guard let data = try? Data(contentsOf: url) else {
            XCTFail("fixture \(name) is missing; run with RAPP_WRITE_FIXTURES=1", file: file, line: line)
            return
        }
        let old = [UInt8](data)
        guard old != bytes else { return }
        let common = min(old.count, bytes.count)
        let at = (0..<common).first { old[$0] != bytes[$0] } ?? common
        XCTFail("fixture \(name) differs at byte \(at) (file \(old.count) bytes, now \(bytes.count)); "
            + "if the Swift change is intended, regenerate with RAPP_WRITE_FIXTURES=1", file: file, line: line)
    }

    /// Records, each `u8 tag, u32 LE length, payload`.
    static func records(_ items: [(tag: UInt8, payload: [UInt8])]) -> [UInt8] {
        var out: [UInt8] = []
        for item in items {
            precondition(item.payload.count <= Int(UInt32.max))
            out.append(item.tag)
            out += u32(UInt32(item.payload.count))
            out += item.payload
        }
        return out
    }

    /// A case list: sorted keys, pretty-printed, no escaped slashes, trailing newline.
    static func cases(_ cases: [[String: Any]]) -> [UInt8] {
        let data = try! JSONSerialization.data(
            withJSONObject: cases, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])
        return [UInt8](data) + [0x0A]
    }

    static func hex(_ bytes: [UInt8]) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count * 2)
        for b in bytes {
            out.append(digits[Int(b >> 4)])
            out.append(digits[Int(b & 15)])
        }
        return String(decoding: out, as: UTF8.self)
    }

    // MARK: - Little-endian writers

    static func le(_ v: UInt64, _ n: Int) -> [UInt8] { (0..<n).map { UInt8(truncatingIfNeeded: v >> (8 * UInt64($0))) } }
    static func u16(_ v: UInt16) -> [UInt8] { le(UInt64(v), 2) }
    static func u32(_ v: UInt32) -> [UInt8] { le(UInt64(v), 4) }
    static func u64(_ v: UInt64) -> [UInt8] { le(v, 8) }
    static func i32(_ v: Int32) -> [UInt8] { u32(UInt32(bitPattern: v)) }
    static func f32(_ v: Float) -> [UInt8] { u32(v.bitPattern) }
    static func f64(_ v: Double) -> [UInt8] { u64(v.bitPattern) }
    /// `u32` length, then the bytes.
    static func sized(_ bytes: [UInt8]) -> [UInt8] { u32(UInt32(bytes.count)) + bytes }

    // MARK: - JSON values

    /// A `Float` for JSON: the `Double` of the same value, read back by Rust as the same `f32`.
    static func f(_ v: Float) -> Double { Double(v) }

    static func rect(_ r: CanvasRect) -> [String: Any] { ["x": f(r.x), "y": f(r.y), "w": f(r.w), "h": f(r.h)] }

    /// A `CGRect`-like rect of `Double`s, matching Rust's `geometry::Rect`.
    static func rect(x: Double, y: Double, width: Double, height: Double) -> [String: Any] {
        ["x": x, "y": y, "width": width, "height": height]
    }

    /// JSON `null` for an absent optional.
    static func opt(_ v: Any?) -> Any { v ?? NSNull() }
}

/// A small deterministic generator for fixture inputs, the same on every machine
/// (Swift's `SystemRandomNumberGenerator` is not seedable).
struct HostRNG {
    private var state: UInt64

    init(seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 &+ 1 }

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state >> 33
    }

    /// A value in `range` (inclusive).
    mutating func int(_ range: ClosedRange<Int>) -> Int {
        let span = UInt64(range.upperBound - range.lowerBound) + 1
        return range.lowerBound + Int(next() % span)
    }

    mutating func bytes(_ n: Int) -> [UInt8] { (0..<n).map { _ in UInt8(truncatingIfNeeded: next()) } }

    /// A value in [0, 1).
    mutating func unit() -> Double { Double(next() & ((1 << 31) - 1)) / Double(1 << 31) }
}
