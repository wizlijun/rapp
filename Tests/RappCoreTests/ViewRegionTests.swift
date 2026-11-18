import CoreGraphics
import RappCore
import XCTest

private func win(_ id: UInt32, _ kind: WindowKind, _ x: Float, _ y: Float, _ w: Float, _ h: Float,
                 titleBar: Float = 0, parent: UInt32 = 0) -> WindowInfo {
    WindowInfo(id: id, parent: parent, kind: kind, resizable: true, focused: false,
               rect: CanvasRect(x: x, y: y, w: w, h: h), titleBar: titleBar, title: "w\(id)")
}

private func contains(_ outer: CanvasRect, _ inner: CanvasRect) -> Bool {
    outer.x <= inner.x && outer.y <= inner.y
        && outer.x + outer.w >= inner.x + inner.w && outer.y + outer.h >= inner.y + inner.h
}

final class ViewRegionTests: XCTestCase {
    private let display = CGSize(width: 1440, height: 900)
    private let main = win(1, .normal, 100, 50, 800, 600, titleBar: 28)

    func testNoViewIsCaptureRegion() {
        let base = captureRegion(windows: [main], display: display)
        XCTAssertNotNil(base)
        XCTAssertEqual(viewRegion(view: nil, windows: [main], display: display), base)
        XCTAssertEqual(viewRegion(view: (window: 0, rect: CanvasRect(x: 0, y: 0, w: 10, h: 10)),
                                  windows: [main], display: display), base)
    }

    func testUnknownWindowIsCaptureRegion() {
        XCTAssertEqual(viewRegion(view: (window: 99, rect: CanvasRect(x: 0, y: 0, w: 10, h: 10)),
                                  windows: [main], display: display),
                       captureRegion(windows: [main], display: display))
    }

    func testViewIsRectOnCanvas() throws {
        let r = try XCTUnwrap(viewRegion(view: (window: 1, rect: CanvasRect(x: 200, y: 100, w: 160, h: 120)),
                                         windows: [main], display: display))
        let want = CanvasRect(x: 300, y: 178, w: 160, h: 120)
        XCTAssertTrue(contains(r, want))
        for v in [r.x, r.y, r.w, r.h] { XCTAssertEqual(v.truncatingRemainder(dividingBy: 8), 0) }
        XCTAssertLessThanOrEqual(want.x - r.x, 8)
        XCTAssertLessThanOrEqual(want.y - r.y, 8)
        XCTAssertLessThanOrEqual(r.x + r.w - (want.x + want.w), 8)
        XCTAssertLessThanOrEqual(r.y + r.h - (want.y + want.h), 8)
    }

    func testViewTakesChildPopups() throws {
        let menu = win(2, .menu, 700, 400, 200, 300, parent: 1)
        let other = win(3, .menu, 20, 700, 100, 100, parent: 5)
        let r = try XCTUnwrap(viewRegion(view: (window: 1, rect: CanvasRect(x: 200, y: 100, w: 160, h: 120)),
                                         windows: [main, menu, other], display: display))
        XCTAssertTrue(contains(r, menu.rect))
        XCTAssertTrue(contains(r, CanvasRect(x: 300, y: 178, w: 160, h: 120)))
        XCTAssertFalse(contains(r, other.rect))
    }

    func testViewClippedToDisplay() throws {
        let off = win(1, .normal, -200, 50, 800, 600, titleBar: 28)
        // x 20..120 of the content is at canvas -180..-80: off the display.
        XCTAssertEqual(viewRegion(view: (window: 1, rect: CanvasRect(x: 20, y: 0, w: 100, h: 100)),
                                  windows: [off], display: display),
                       captureRegion(windows: [off], display: display))
        // x 150..350 straddles the left edge: canvas -50..150.
        let r = try XCTUnwrap(viewRegion(view: (window: 1, rect: CanvasRect(x: 150, y: 0, w: 200, h: 100)),
                                         windows: [off], display: display))
        XCTAssertGreaterThanOrEqual(r.x, 0)
        XCTAssertGreaterThan(r.w, 0)
        XCTAssertLessThanOrEqual(r.x + r.w, Float(display.width))
    }

    func testDensityAtOneIsUnchanged() {
        let size = CGSize(width: 800, height: 600)
        for choice in [DensityChoice.saver1x, .adaptive, .original] {
            XCTAssertEqual(viewDensity(zoom: 1, backingScale: 2, choice: choice, content: size, range: size),
                           captureDensity(zoom: 1, backingScale: 2, choice: choice))
        }
    }

    func testPixelBudget() {
        let content = CGSize(width: 800, height: 600), native: Float = 2
        for scale in [CGFloat(2), 3] {
            for choice in [DensityChoice.saver1x, .adaptive, .original] {
                for zoom in [CGFloat(1), 1.5, 2, 3, 4] {
                    // The visible range never exceeds the window itself.
                    let f = min(1.5 / zoom, 1)
                    let range = CGSize(width: content.width * f, height: content.height * f)
                    let d = viewDensity(zoom: zoom, backingScale: scale, choice: choice, content: content, range: range)
                    let d1 = captureDensity(zoom: 1, backingScale: scale, choice: choice)
                    let used = Float(range.width * range.height) * min(d, native) * min(d, native)
                    let budget = Float(content.width * content.height) * min(d1, native) * min(d1, native)
                    XCTAssertLessThanOrEqual(used, budget * 1.0001, "scale \(scale) \(choice) zoom \(zoom)")
                }
            }
        }
    }

    // MARK: what the host does with setView and table changes

    private let rect = CanvasRect(x: 100, y: 100, w: 200, h: 150)

    func testSetViewChangesRegionToViewRegion() {
        let base = captureRegion(windows: [main], display: display)
        let view = viewFor(window: 1, rect: rect)
        XCTAssertEqual(view?.window, 1)
        let new = regionChange(view: view, windows: [main], display: display, current: base)
        XCTAssertEqual(new, viewRegion(view: view, windows: [main], display: display))
        XCTAssertNotEqual(new, base)
    }

    func testTableChangeRecomputesWithSameView() {
        let view = viewFor(window: 1, rect: rect)
        let current = viewRegion(view: view, windows: [main], display: display)
        let popup = win(2, .menu, 400, 120, 300, 200, parent: 1)
        let table = [main, popup]
        let new = regionChange(view: view, windows: table, display: display, current: current)
        XCTAssertEqual(new, viewRegion(view: view, windows: table, display: display))
        XCTAssertNotNil(new)
        XCTAssertTrue(contains(new!, CanvasRect(x: 400, y: 120, w: 300, h: 200)))
        // Nothing changed: no new region to apply.
        XCTAssertNil(regionChange(view: view, windows: table, display: display, current: new))
    }

    func testWindowZeroReturnsToCaptureRegion() {
        let view = viewFor(window: 1, rect: rect)
        let zoomed = viewRegion(view: view, windows: [main], display: display)
        let cleared = viewFor(window: 0, rect: rect)
        XCTAssertNil(cleared)
        XCTAssertEqual(regionChange(view: cleared, windows: [main], display: display, current: zoomed),
                       captureRegion(windows: [main], display: display))
    }

    func testDesktopSessionHonoursSetView() {
        let table = desktopTable(width: 1440, height: 900, title: "Desktop")
        let full = CanvasRect(x: 0, y: 0, w: 1440, h: 900)
        let view = viewFor(window: 1, rect: rect)
        let new = regionChange(view: view, windows: table, display: display, current: full)
        XCTAssertNotNil(new)
        XCTAssertNotEqual(new, full)
        XCTAssertTrue(contains(new!, rect))
    }
}
