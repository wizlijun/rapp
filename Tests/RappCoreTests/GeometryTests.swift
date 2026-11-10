import XCTest
import CoreGraphics
import Foundation
@testable import RappCore

final class GeometryTests: XCTestCase {
    private let image = CGSize(width: 200, height: 100), view = CGSize(width: 400, height: 400)

    func testAspectFit() {
        XCTAssertEqual(aspectFitRect(imageSize: image, in: view), CGRect(x: 0, y: 100, width: 400, height: 200))
        XCTAssertEqual(aspectFitRect(imageSize: CGSize(width: 100, height: 200), in: view),
                       CGRect(x: 100, y: 0, width: 200, height: 400))
        XCTAssertEqual(aspectFitRect(imageSize: .zero, in: view), .zero)
    }

    func testNormalizedPoint() throws {
        let p = try XCTUnwrap(normalizedPoint(CGPoint(x: 200, y: 200), imageSize: image, viewSize: view))
        XCTAssertEqual(p.x, 0.5)
        XCTAssertEqual(p.y, 0.5)
        let corner = try XCTUnwrap(normalizedPoint(CGPoint(x: 0, y: 100), imageSize: image, viewSize: view))
        XCTAssertEqual(corner.x, 0)
        XCTAssertEqual(corner.y, 0)
    }

    func testPointOutsideImageIsNil() {
        XCTAssertNil(normalizedPoint(CGPoint(x: 200, y: 50), imageSize: image, viewSize: view))
        XCTAssertNil(normalizedPoint(CGPoint(x: 200, y: 301), imageSize: image, viewSize: view))
        XCTAssertNil(normalizedPoint(CGPoint(x: 10, y: 10), imageSize: .zero, viewSize: view))
    }

    func testGlobalPoint() {
        XCTAssertEqual(globalPoint(x: 0.5, y: 0.5, windowFrame: CGRect(x: 100, y: 200, width: 800, height: 600)),
                       CGPoint(x: 500, y: 500))
    }

    func testGlobalPointIsClampedToWindow() {
        let frame = CGRect(x: 100, y: 200, width: 800, height: 600)
        XCTAssertEqual(globalPoint(x: -1, y: 2, windowFrame: frame), CGPoint(x: 100, y: 799))
    }

    func testClampSize() {
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080), o = CGPoint(x: 100, y: 100)
        XCTAssertEqual(clampSize(requested: CGSize(width: 3000, height: 2000), origin: o, screen: screen),
                       CGSize(width: 1820, height: 980))
        XCTAssertEqual(clampSize(requested: CGSize(width: 10, height: 10), origin: o, screen: screen),
                       CGSize(width: 100, height: 100))
        XCTAssertEqual(clampSize(requested: CGSize(width: 640, height: 480), origin: o, screen: screen),
                       CGSize(width: 640, height: 480))
    }

    func testChunkDoesNotSplitSurrogatePair() {
        let chunks = chunkUTF16(String(repeating: "a", count: 19) + "😀b")
        XCTAssertEqual(chunks.map(\.count), [19, 3])
        XCTAssertEqual(chunkUTF16(""), [])
        XCTAssertEqual(chunkUTF16("你好").map(\.count), [2])
        XCTAssertEqual(chunkUTF16(String(repeating: "a", count: 40)).map(\.count), [20, 20])
    }

    private let win = CGRect(x: 100, y: 50, width: 800, height: 600)

    func testTitleRowHeightFromCloseButton() {
        XCTAssertEqual(titleRowHeight(closeButtonFrame: CGRect(x: 107, y: 59, width: 14, height: 14), windowFrame: win), 32)  // TextEdit
        XCTAssertEqual(titleRowHeight(closeButtonFrame: CGRect(x: 120, y: 69, width: 14, height: 14), windowFrame: win), 52)  // Calculator
        XCTAssertEqual(titleRowHeight(closeButtonFrame: nil, windowFrame: win), 0)
        XCTAssertEqual(titleRowHeight(closeButtonFrame: CGRect(x: 107, y: 30, width: 14, height: 14), windowFrame: win), 0)  // above the window
        XCTAssertEqual(titleRowHeight(closeButtonFrame: CGRect(x: 107, y: 80, width: 14, height: 14),
                                      windowFrame: CGRect(x: 100, y: 50, width: 800, height: 60)), 0)                        // > half height
    }

    func testContentRectAndItsPoints() {
        XCTAssertEqual(contentRect(windowFrame: win, titleRow: 32), CGRect(x: 100, y: 82, width: 800, height: 568))
        XCTAssertEqual(globalPoint(x: 0, y: 0, windowFrame: contentRect(windowFrame: win, titleRow: 32)), CGPoint(x: 100, y: 82))
    }

    func testWindowSizeForContentAddsTitleRowThenClamps() {
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        XCTAssertEqual(windowSize(forContent: CGSize(width: 800, height: 568), titleRow: 32, origin: win.origin, screen: screen),
                       CGSize(width: 800, height: 600))
        XCTAssertEqual(windowSize(forContent: CGSize(width: 800, height: 1100), titleRow: 32, origin: win.origin, screen: screen).height, 1030)
    }

    // MARK: Client zoom (revision 2)

    private let resizeFrame = CGRect(x: 100, y: 200, width: 800, height: 500)

    func testResizeHandleCorners() {
        for p in [CGPoint(x: 100, y: 200), CGPoint(x: 900, y: 700), CGPoint(x: 116, y: 684),
                  CGPoint(x: 884, y: 216), CGPoint(x: 903, y: 197)] {
            XCTAssertEqual(resizeHandle(mouse: p, windowFrame: resizeFrame, buttonsDown: true), .corner, "\(p)")
        }
        XCTAssertNotEqual(resizeHandle(mouse: CGPoint(x: 883, y: 200), windowFrame: resizeFrame, buttonsDown: true), .corner)   // 17 pt from the right edge
        XCTAssertNotEqual(resizeHandle(mouse: CGPoint(x: 900, y: 683), windowFrame: resizeFrame, buttonsDown: true), .corner)
    }

    func testResizeHandleEdges() {
        XCTAssertEqual(resizeHandle(mouse: CGPoint(x: 900, y: 450), windowFrame: resizeFrame, buttonsDown: true), .horizontal)
        XCTAssertEqual(resizeHandle(mouse: CGPoint(x: 98, y: 450), windowFrame: resizeFrame, buttonsDown: true), .horizontal)
        XCTAssertEqual(resizeHandle(mouse: CGPoint(x: 500, y: 700), windowFrame: resizeFrame, buttonsDown: true), .vertical)
        XCTAssertEqual(resizeHandle(mouse: CGPoint(x: 500, y: 199), windowFrame: resizeFrame, buttonsDown: true), .vertical)
        // Near a corner but outside the corner square: the closer edge wins.
        XCTAssertEqual(resizeHandle(mouse: CGPoint(x: 898, y: 230), windowFrame: resizeFrame, buttonsDown: true), .horizontal)
        XCTAssertEqual(resizeHandle(mouse: CGPoint(x: 870, y: 699), windowFrame: resizeFrame, buttonsDown: true), .vertical)
    }

    func testLockedAspectSize() {
        let aspect = CGSize(width: 1600, height: 1000), cur = CGSize(width: 800, height: 500)
        // Width changed more: height follows the width.
        XCTAssertEqual(lockedAspectSize(proposed: CGSize(width: 960, height: 510), current: cur, aspect: aspect),
                       CGSize(width: 960, height: 600))
        // Height changed more: width follows the height.
        XCTAssertEqual(lockedAspectSize(proposed: CGSize(width: 790, height: 250), current: cur, aspect: aspect),
                       CGSize(width: 400, height: 250))
        // Rounded to whole points.
        XCTAssertEqual(lockedAspectSize(proposed: CGSize(width: 801, height: 500), current: cur, aspect: aspect),
                       CGSize(width: 801, height: 501))
    }

    func testRemoteResize() {
        let remote = CGSize(width: 1600, height: 1000), view = CGSize(width: 600, height: 450)
        XCTAssertEqual(remoteResize(view: view, zoom: 0.5, remote: remote, handle: .horizontal), CGSize(width: 1200, height: 1000))
        XCTAssertEqual(remoteResize(view: view, zoom: 0.5, remote: remote, handle: .vertical), CGSize(width: 1600, height: 900))
        XCTAssertEqual(remoteResize(view: view, zoom: 0.5, remote: remote, handle: .both), CGSize(width: 1200, height: 900))
        XCTAssertEqual(remoteResize(view: view, zoom: 0.5, remote: remote, handle: .corner), remote)
        XCTAssertEqual(remoteResize(view: CGSize(width: 333, height: 450), zoom: 0.4, remote: remote, handle: .horizontal),
                       CGSize(width: 833, height: 1000))
    }

    func testCaptureDensity() {
        XCTAssertEqual(captureDensity(zoom: 0.5, backingScale: 2, saver1x: false), 1.0)
        XCTAssertEqual(captureDensity(zoom: 0.5, backingScale: 2, saver1x: true), 0.5)
        XCTAssertEqual(captureDensity(zoom: 1, backingScale: 1, saver1x: false), 1.0)
        // Always inside what the protocol accepts, (0, 8].
        XCTAssertEqual(captureDensity(zoom: 6, backingScale: 2, saver1x: false), 8)
        XCTAssertGreaterThan(captureDensity(zoom: 0, backingScale: 2, saver1x: false), 0)
    }

    func testStreamChangeIgnoresTinyDensityDrift() {
        let sent = (mode: Mode.duogray, fps: UInt8(5), density: Float(0.24))
        XCTAssertTrue(streamChanged(from: nil, to: sent))
        XCTAssertFalse(streamChanged(from: sent, to: sent))
        XCTAssertFalse(streamChanged(from: sent, to: (.duogray, 5, 0.2415)))   // < 1 %
        XCTAssertTrue(streamChanged(from: sent, to: (.duogray, 5, 0.2430)))    // > 1 %
        XCTAssertTrue(streamChanged(from: sent, to: (.duogray, 5, 0.2370)))
        XCTAssertTrue(streamChanged(from: sent, to: (.gray4, 5, 0.24)))
        XCTAssertTrue(streamChanged(from: sent, to: (.duogray, 15, 0.24)))
    }

    func testResizeWithoutMouseButtonIsBoth() {
        // Zoom button release, ⌃⌘F, a menu command: the mouse position means nothing.
        for p in [CGPoint(x: 100, y: 200), CGPoint(x: 900, y: 450), CGPoint(x: 500, y: 700)] {
            XCTAssertEqual(resizeHandle(mouse: p, windowFrame: resizeFrame, buttonsDown: false), .both, "\(p)")
        }
    }
}
