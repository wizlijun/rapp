import XCTest
@testable import RappCore

final class FocusPaneTests: XCTestCase {
    let win = CGSize(width: 1000, height: 800)
    func r(_ w: CGFloat, _ h: CGFloat) -> CGRect { CGRect(x: 0, y: 0, width: w, height: h) }

    func testPicksLargestUnderMax() {
        let p = try! FocusPane.panel(chain: [r(100, 50), r(600, 800), r(1000, 800)], window: win).get()
        XCTAssertEqual(p.depth, 1)
        XCTAssertEqual(p.share, 0.6, accuracy: 1e-9)
    }
    func testAllSmall() {
        XCTAssertEqual(FocusPane.panel(chain: [r(100, 50), r(200, 100)], window: win), .failure(.small))
        XCTAssertEqual(FocusPane.panel(chain: [], window: win), .failure(.small))
    }
    func testOnlyHuge() {
        XCTAssertEqual(FocusPane.panel(chain: [r(950, 800), r(1000, 800)], window: win), .failure(.large))
    }
    func testTallContainerIntersectedFirst() {
        let p = try! FocusPane.panel(chain: [CGRect(x: 0, y: -2000, width: 600, height: 5000)], window: win).get()
        XCTAssertEqual(p.rect, CGRect(x: 0, y: 0, width: 600, height: 800))
        XCTAssertEqual(p.share, 0.6, accuracy: 1e-9)
    }
    func testTieTakesOuter() {
        let p = try! FocusPane.panel(chain: [r(600, 800), r(600, 800)], window: win).get()
        XCTAssertEqual(p.depth, 1)
    }
    func testMinWidthHeight() {
        XCTAssertEqual(FocusPane.panel(chain: [r(230, 800)], window: win), .failure(.small))
        XCTAssertEqual(FocusPane.panel(chain: [r(1000, 150)], window: win), .failure(.small))
    }
    func testDepthCappedAt40() {
        var chain = [CGRect](repeating: r(10, 10), count: 40)
        chain.append(r(600, 800))
        XCTAssertEqual(FocusPane.panel(chain: chain, window: win), .failure(.small))
    }
    func testWindowRect() {
        let out = FocusPane.windowRect(global: CGRect(x: 110, y: 85, width: 10, height: 10),
                                       display: CGRect(x: 0, y: 25, width: 1440, height: 875),
                                       window: CanvasRect(x: 100, y: 50, w: 400, h: 300))
        XCTAssertEqual(out, CGRect(x: 10, y: 10, width: 10, height: 10))
    }
    func testWindowTilesRetina() {
        // 1600x1200 px over 800x600 canvas points: scale 2; cols 25, rows 19.
        let rep = EncodeReport(region: CanvasRect(x: 0, y: 0, w: 800, h: 600), width: 1600, height: 1200,
                               full: false, changed: [0, 24, 25 * 5 + 20],
                               copyBounds: CGRect(x: 0, y: 0, width: 2000, height: 128))
        let w = FocusPane.windowTiles(rep, window: CanvasRect(x: 0, y: 0, w: 400, h: 300))
        // tile 24 centre x = 24*32+16 = 784 pt: outside; tile 145 (tx 20, ty 5): x 656 outside.
        XCTAssertEqual(w.changed, [CGRect(x: 0, y: 0, width: 32, height: 32)])
        // tiles with centre inside 400x300: tx 0..12 (centre 16+32tx<400 -> tx<=11 => 12), ty 0..9 (centre<300 -> ty<=8 => 9)
        XCTAssertEqual(w.total, 12 * 9)
        XCTAssertEqual(w.copyBounds, CGRect(x: 0, y: 0, width: 400, height: 64))
        XCTAssertFalse(w.full)
    }
    func testCopyBoundsOutsideIsNil() {
        let rep = EncodeReport(region: CanvasRect(x: 0, y: 0, w: 100, h: 100), width: 100, height: 100,
                               full: true, changed: [], copyBounds: CGRect(x: 90, y: 90, width: 10, height: 10))
        let w = FocusPane.windowTiles(rep, window: CanvasRect(x: 0, y: 0, w: 50, h: 50))
        XCTAssertNil(w.copyBounds)
        XCTAssertTrue(w.full)
    }
}
