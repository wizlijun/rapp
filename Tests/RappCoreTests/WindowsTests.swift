import CoreGraphics
import RappCore
import XCTest

private func win(_ id: UInt32, _ kind: WindowKind, _ x: Float, _ y: Float, _ w: Float, _ h: Float,
                 titleBar: Float = 0, parent: UInt32 = 0) -> WindowInfo {
    WindowInfo(id: id, parent: parent, kind: kind, resizable: true, focused: false,
               rect: CanvasRect(x: x, y: y, w: w, h: h), titleBar: titleBar, title: "w\(id)")
}

final class WindowsTests: XCTestCase {
    // MARK: classifyWindow (spec §3.3)

    func testClassifyNormalLevelUsesAccessibility() {
        let normal = Int(CGWindowLevelForKey(.normalWindow))
        XCTAssertEqual(classifyWindow(level: normal, role: "AXSheet", subrole: nil), .sheet)
        XCTAssertEqual(classifyWindow(level: normal, role: "AXPopover", subrole: nil), .popover)
        XCTAssertEqual(classifyWindow(level: normal, role: "AXWindow", subrole: "AXDialog"), .dialog)
        XCTAssertEqual(classifyWindow(level: normal, role: "AXWindow", subrole: "AXSystemDialog"), .dialog)
        XCTAssertEqual(classifyWindow(level: normal, role: "AXWindow", subrole: "AXFloatingWindow"), .floating)
        XCTAssertEqual(classifyWindow(level: normal, role: "AXWindow", subrole: "AXSystemFloatingWindow"), .floating)
        XCTAssertEqual(classifyWindow(level: normal, role: "AXWindow", subrole: "AXStandardWindow"), .normal)
        XCTAssertEqual(classifyWindow(level: normal, role: nil, subrole: nil), .normal)
    }

    func testClassifyByLevel() {
        func level(_ key: CGWindowLevelKey) -> Int { Int(CGWindowLevelForKey(key)) }
        XCTAssertEqual(classifyWindow(level: level(.floatingWindow), role: "AXWindow", subrole: "AXFloatingWindow"), .floating)
        XCTAssertEqual(classifyWindow(level: level(.utilityWindow), role: nil, subrole: nil), .floating)
        XCTAssertEqual(classifyWindow(level: level(.modalPanelWindow), role: nil, subrole: nil), .dialog)
        XCTAssertEqual(classifyWindow(level: level(.popUpMenuWindow), role: nil, subrole: nil), .menu)
        XCTAssertEqual(classifyWindow(level: level(.popUpMenuWindow) + 1, role: nil, subrole: nil), .tooltip)
        XCTAssertEqual(classifyWindow(level: level(.helpWindow), role: nil, subrole: nil), .tooltip)
    }

    // MARK: assignParents (spec §3.2)

    func testDecoratedWindowsHaveNoParent() {
        let out = assignParents([win(1, .normal, 0, 0, 100, 100, parent: 9), win(2, .dialog, 10, 10, 50, 50, parent: 9)])
        XCTAssertEqual(out.map(\.parent), [0, 0])
    }

    func testPopupTakesLargestOverlap() {
        let out = assignParents([
            win(1, .menu, 90, 0, 40, 40),
            win(2, .normal, 0, 0, 100, 100),   // overlaps 10 x 40
            win(3, .normal, 100, 0, 100, 100), // overlaps 30 x 40
        ])
        XCTAssertEqual(out[0].parent, 3)
        XCTAssertEqual(out[1].parent, 0)
    }

    func testPopupTieTakesFrontmost() {
        let out = assignParents([
            win(1, .menu, 80, 0, 40, 40),
            win(2, .normal, 0, 0, 100, 100),   // 20 x 40
            win(3, .normal, 100, 0, 100, 100), // 20 x 40
        ])
        XCTAssertEqual(out[0].parent, 2)
    }

    func testTooltipOverlappingNothingTakesFrontmostDecorated() {
        let out = assignParents([
            win(1, .tooltip, 500, 500, 40, 20),
            win(2, .sheet, 0, 0, 50, 50),
            win(3, .floating, 0, 0, 100, 100),
            win(4, .normal, 200, 0, 100, 100),
        ])
        XCTAssertEqual(out[0].parent, 3)
        XCTAssertEqual(out[1].parent, 3)
    }

    func testPopupWithoutDecoratedWindowHasNoParent() {
        XCTAssertEqual(assignParents([win(1, .menu, 0, 0, 10, 10, parent: 5)]).map(\.parent), [0])
        XCTAssertEqual(assignParents([]), [])
    }

    // MARK: dropTitleBarAccessories (spec §3.2)

    func testDropsWindowInsideTitleBar() {
        let out = dropTitleBarAccessories([
            win(1, .normal, 100, 100, 400, 300, titleBar: 28),
            win(2, .dialog, 106, 106, 66, 20),
        ])
        XCTAssertEqual(out.map(\.id), [1])
    }

    func testTitleBarZeroCountsAs28() {
        let out = dropTitleBarAccessories([
            win(1, .normal, 100, 100, 400, 300),
            win(2, .dialog, 106, 106, 66, 20),
            win(3, .menu, 106, 106, 66, 30), // reaches below the band
        ])
        XCTAssertEqual(out.map(\.id), [1, 3])
    }

    func testKeepsWindowInsidePopupTop() {
        // Only decorated windows have a title bar.
        let out = dropTitleBarAccessories([win(1, .menu, 100, 100, 400, 300), win(2, .tooltip, 106, 106, 66, 20)])
        XCTAssertEqual(out.map(\.id), [1, 2])
        XCTAssertEqual(dropTitleBarAccessories([]), [])
    }

    // MARK: captureRegion (spec §1.1)

    func testRegionIsUnionRoundedOutTo8() {
        let region = captureRegion(windows: [win(1, .normal, 10, 20, 100, 50), win(2, .menu, 105, 60, 30, 30)],
                                   display: CGSize(width: 1000, height: 800))
        // Union (10, 20) - (135, 90) -> (8, 16) - (136, 96).
        XCTAssertEqual(region, CanvasRect(x: 8, y: 16, w: 128, h: 80))
    }

    func testRegionAlreadyOn8IsUnchanged() {
        let region = captureRegion(windows: [win(1, .normal, 16, 24, 80, 40)], display: CGSize(width: 1000, height: 800))
        XCTAssertEqual(region, CanvasRect(x: 16, y: 24, w: 80, h: 40))
    }

    func testRegionClippedToScreen() {
        let region = captureRegion(windows: [win(1, .normal, -50, 700, 200, 300)], display: CGSize(width: 1001, height: 797))
        XCTAssertEqual(region, CanvasRect(x: 0, y: 696, w: 152, h: 101))
    }

    func testRegionNilWhenEmptyOrOffScreen() {
        XCTAssertNil(captureRegion(windows: [], display: CGSize(width: 100, height: 100)))
        XCTAssertNil(captureRegion(windows: [win(1, .normal, 200, 0, 50, 50)], display: CGSize(width: 100, height: 100)))
    }

    // MARK: cropRect (spec §4.4)

    func testCropRemovesTitleBarAndScales() {
        let w = win(1, .normal, 108, 116, 100, 60, titleBar: 28)
        let crop = cropRect(window: w, region: CanvasRect(x: 100, y: 100, w: 200, h: 100), pixelWidth: 400, pixelHeight: 200)
        // Content (108, 144) 100 x 32 -> minus origin (8, 44) -> x2.
        XCTAssertEqual(crop, CGRect(x: 16, y: 88, width: 200, height: 64))
    }

    func testCropIsClippedToRegionAndRounded() {
        let w = win(1, .menu, 90.3, 100, 30, 10)
        let crop = cropRect(window: w, region: CanvasRect(x: 100, y: 96, w: 40, h: 40), pixelWidth: 60, pixelHeight: 60)
        // (100, 100) - (120.3, 110) in the region, minus (100, 96), x1.5: (0, 6) - (30.45, 21) -> (0, 6) - (30, 21).
        XCTAssertEqual(crop, CGRect(x: 0, y: 6, width: 30, height: 15))
    }

    func testCropNilOutsideRegion() {
        let w = win(1, .normal, 0, 0, 50, 50)
        XCTAssertNil(cropRect(window: w, region: CanvasRect(x: 100, y: 100, w: 40, h: 40), pixelWidth: 80, pixelHeight: 80))
        XCTAssertNil(cropRect(window: w, region: CanvasRect(x: 0, y: 0, w: 0, h: 40), pixelWidth: 80, pixelHeight: 80))
    }

    // MARK: WindowPlacement (spec §1.3, §4.2)

    func testPlacementRoundTrip() {
        let p = WindowPlacement(origin: CGPoint(x: 13.5, y: -7.25), zoom: 1.25)
        for c in [CGPoint(x: 0, y: 0), CGPoint(x: 333.3, y: 1234.5), CGPoint(x: -20, y: 7)] {
            let back = p.toCanvas(p.toB(c))
            XCTAssertEqual(back.x, c.x, accuracy: 0.001)
            XCTAssertEqual(back.y, c.y, accuracy: 0.001)
        }
        XCTAssertEqual(p.toB(CGPoint(x: 10, y: 10)), CGPoint(x: 26, y: 5.25))
    }

    func testCenteringPutsContentCenterOnScreenCenter() {
        let p = WindowPlacement.centering(content: CGRect(x: 100, y: 50, width: 200, height: 100),
                                          on: CGRect(x: 0, y: 25, width: 1000, height: 800), zoom: 2)
        let center = p.toB(CGPoint(x: 200, y: 100))
        XCTAssertEqual(center.x, 500, accuracy: 0.001)
        XCTAssertEqual(center.y, 425, accuracy: 0.001)
        XCTAssertEqual(p.zoom, 2)
    }

    func testPopupOriginFollowsParentInB() {
        let p = WindowPlacement(origin: .zero, zoom: 1.5)
        let origin = p.popupOrigin(popup: CanvasRect(x: 130, y: 90, w: 50, h: 80),
                                   parentContent: CanvasRect(x: 100, y: 50, w: 400, h: 300),
                                   parentContentInB: CGPoint(x: 700, y: 20))
        XCTAssertEqual(origin, CGPoint(x: 745, y: 80))
    }

    func testRezoomKeepsCanvasPoint() {
        let p = WindowPlacement(origin: CGPoint(x: 40, y: 60), zoom: 1)
        let kept = CGPoint(x: 120, y: 80)
        let q = p.rezoomed(to: 2, keeping: kept)
        XCTAssertEqual(q.zoom, 2)
        XCTAssertEqual(q.toB(kept).x, p.toB(kept).x, accuracy: 0.001)
        XCTAssertEqual(q.toB(kept).y, p.toB(kept).y, accuracy: 0.001)
    }

    // MARK: menuItem(at:in:) (spec §3.5)

    func testMenuItemPath() {
        let tree = [
            MenuItem(title: "File", children: [MenuItem(title: "New"), MenuItem(title: "Open",
                     children: [MenuItem(title: "Recent")])]),
            MenuItem(title: "Edit"),
        ]
        XCTAssertEqual(menuItem(at: [0, 1, 0], in: tree)?.title, "Recent")
        XCTAssertEqual(menuItem(at: [1], in: tree)?.title, "Edit")
        XCTAssertNil(menuItem(at: [2], in: tree))
        XCTAssertNil(menuItem(at: [1, 0], in: tree))
        XCTAssertNil(menuItem(at: [], in: tree))
        XCTAssertNil(menuItem(at: [0], in: []))
    }
}
