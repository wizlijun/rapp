import CoreVideo
import IOSurface
import XCTest
import RappCore
@testable import RappSession

final class WindowSurfacesTests: XCTestCase {
    private func win(_ id: UInt32, x: Float, y: Float, w: Float, h: Float) -> WindowInfo {
        WindowInfo(id: id, parent: 0, kind: .normal, resizable: true, focused: false,
                   rect: CanvasRect(x: x, y: y, w: w, h: h), titleBar: 0, title: "w\(id)")
    }

    /// A decoder that has seen one full 64x32 color16 frame.
    private func decoder() throws -> FrameDecoder {
        let enc = FrameEncoder(mode: .color16), dec = FrameDecoder(mode: .color16)
        let samples = [UInt8](repeating: 0x55, count: 64 * 32 * 2)
        try dec.decode(try XCTUnwrap(enc.encode(samples: samples, width: 64, height: 32)))
        return dec
    }

    private let region = CanvasRect(x: 0, y: 0, w: 64, h: 32)

    func testDrawMakesOnePoolPerWindowSizedToCrop() throws {
        let dec = try decoder()
        let a = win(1, x: 0, y: 0, w: 32, h: 32), b = win(2, x: 32, y: 0, w: 16, h: 16)
        let s = WindowSurfaces()
        let updated = try s.draw(table: [a, b], decoder: dec, region: region)
        XCTAssertEqual(Set(updated), [1, 2])
        let ca = try XCTUnwrap(cropRect(window: a, region: region, pixelWidth: 64, pixelHeight: 32))
        let bufA = try XCTUnwrap(s.latest(1))
        XCTAssertEqual(CVPixelBufferGetWidth(bufA), Int(ca.width))
        XCTAssertEqual(CVPixelBufferGetHeight(bufA), Int(ca.height))
        XCTAssertEqual(s.poolsCreated, 2)
        _ = try s.draw(table: [a, b], decoder: dec, region: region)
        XCTAssertEqual(s.poolsCreated, 2)
        XCTAssertNotNil(s.visible(1))
    }

    func testDrawRebuildsPoolWhenWindowSizeChanges() throws {
        let dec = try decoder()
        let s = WindowSurfaces()
        _ = try s.draw(table: [win(1, x: 0, y: 0, w: 32, h: 32), win(2, x: 32, y: 0, w: 16, h: 16)], decoder: dec, region: region)
        XCTAssertEqual(s.poolsCreated, 2)
        _ = try s.draw(table: [win(1, x: 0, y: 0, w: 40, h: 32), win(2, x: 32, y: 0, w: 16, h: 16)], decoder: dec, region: region)
        XCTAssertEqual(s.poolsCreated, 3)
        XCTAssertEqual(CVPixelBufferGetWidth(try XCTUnwrap(s.latest(1))), 40)
    }

    func testKeepOnlyDropsGoneWindows() throws {
        let dec = try decoder()
        let s = WindowSurfaces()
        _ = try s.draw(table: [win(1, x: 0, y: 0, w: 32, h: 32), win(2, x: 32, y: 0, w: 16, h: 16)], decoder: dec, region: region)
        XCTAssertEqual(s.keep(only: [1]), [2])
        XCTAssertNil(s.latest(2))
        XCTAssertNil(s.visible(2))
        XCTAssertNotNil(s.latest(1))
    }

    func testPixelBuffersAreIOSurfaceBacked() throws {
        let s = WindowSurfaces()
        _ = try s.draw(table: [win(1, x: 0, y: 0, w: 32, h: 32)], decoder: try decoder(), region: region)
        XCTAssertNotNil(CVPixelBufferGetIOSurface(try XCTUnwrap(s.latest(1))))
    }

    func testDrawBeforeAnyFrameUpdatesNothing() throws {
        let s = WindowSurfaces()
        let updated = try s.draw(table: [win(1, x: 0, y: 0, w: 8, h: 8)], decoder: FrameDecoder(mode: .color16), region: region)
        XCTAssertEqual(updated, [])
        XCTAssertNil(s.latest(1))
    }
}
