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
        // Borderless: no standard AX window (Chrome's address-bar list, custom right-click menus).
        XCTAssertEqual(classifyWindow(level: normal, role: nil, subrole: nil), .popover)
        XCTAssertEqual(classifyWindow(level: normal, role: "AXWindow", subrole: nil), .popover)
        XCTAssertEqual(classifyWindow(level: normal, role: "AXWindow", subrole: "AXUnknown"), .popover)
    }

    func testClassifyByLevel() {
        func level(_ key: CGWindowLevelKey) -> Int { Int(CGWindowLevelForKey(key)) }
        XCTAssertEqual(classifyWindow(level: level(.floatingWindow), role: "AXWindow", subrole: "AXFloatingWindow"), .floating)
        XCTAssertEqual(classifyWindow(level: level(.utilityWindow), role: "AXWindow", subrole: "AXStandardWindow"), .floating)
        XCTAssertEqual(classifyWindow(level: level(.utilityWindow), role: nil, subrole: nil), .popover)
        XCTAssertEqual(classifyWindow(level: level(.floatingWindow), role: "AXWindow", subrole: "AXUnknown"), .popover)
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

    // MARK: dropStrayIndicators / promoteMainWindow (spec §3.2)

    func testDropsSmallWindowsExceptMenus() {
        // The screen-recording pill macOS 27 adds is 66x20 and reports itself as a dialog.
        let out = dropStrayIndicators([
            win(1, .normal, 0, 0, 400, 300),
            win(2, .dialog, 6, 6, 66, 20),
            win(3, .popover, 50, 50, 120, 48),
            win(4, .menu, 60, 60, 100, 30),
            win(5, .popover, 70, 70, 121, 30),
            win(6, .tooltip, 80, 80, 40, 49),
        ])
        XCTAssertEqual(out.map(\.id), [1, 4, 5, 6])
    }

    func testPromotesLargestPopoverWhenNothingIsDecorated() {
        let out = promoteMainWindow([win(1, .popover, 0, 0, 100, 100), win(2, .popover, 0, 0, 300, 200),
                                     win(3, .menu, 0, 0, 500, 500)])
        XCTAssertEqual(out.map(\.kind), [.popover, .normal, .menu])
    }

    func testPromotesNothingWhenADecoratedWindowExists() {
        let table = [win(1, .popover, 0, 0, 900, 900), win(2, .dialog, 0, 0, 100, 100)]
        XCTAssertEqual(promoteMainWindow(table), table)
        XCTAssertEqual(promoteMainWindow([win(1, .menu, 0, 0, 10, 10)]).map(\.kind), [.menu])
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

    func testVisiblePartIsTheContentInsideTheRegion() {
        // Content 100,78 400x272; region stops at x 400 and y 214.
        let w = WindowInfo(id: 1, parent: 0, kind: .normal, resizable: true, focused: false,
                           rect: CanvasRect(x: 100, y: 50, w: 400, h: 300), titleBar: 28, title: "")
        let part = visiblePart(window: w, region: CanvasRect(x: 0, y: 0, w: 400, h: 214))
        XCTAssertEqual(part, CGRect(x: 0, y: 0, width: 0.75, height: 0.5))
        let whole = visiblePart(window: w, region: CanvasRect(x: 0, y: 0, w: 800, h: 600))
        XCTAssertEqual(whole, CGRect(x: 0, y: 0, width: 1, height: 1))
        XCTAssertNil(visiblePart(window: w, region: CanvasRect(x: 0, y: 0, w: 50, h: 50)))
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

    func testPopupFrameFollowsParentPicture() {
        // Parent content 400x300 drawn 600x450 at (700, 20) in B: scale 1.5.
        let frame = popupFrame(popup: CanvasRect(x: 130, y: 90, w: 50, h: 80),
                               parentContent: CanvasRect(x: 100, y: 50, w: 400, h: 300),
                               parentPicture: CGRect(x: 700, y: 20, width: 600, height: 450))
        XCTAssertEqual(frame, CGRect(x: 745, y: 80, width: 75, height: 120))
    }

    func testPopupFrameUsesThePictureScaleNotZoom() {
        // A refused a resize, so the parent's picture is aspect-fitted at half size.
        let frame = popupFrame(popup: CanvasRect(x: 30, y: 40, w: 20, h: 10),
                               parentContent: CanvasRect(x: 10, y: 20, w: 100, h: 50),
                               parentPicture: CGRect(x: 200, y: 300, width: 50, height: 25))
        XCTAssertEqual(frame, CGRect(x: 210, y: 310, width: 10, height: 5))
    }

    // MARK: clampedWindowOrigin (a move must leave the title row on A's display)

    func testClampedWindowOriginKeepsTheTitleRowOnTheCanvas() {
        let canvas = CGSize(width: 1000, height: 800), size = CGSize(width: 400, height: 300)
        XCTAssertEqual(clampedWindowOrigin(CGPoint(x: -500, y: 900), size: size, titleBar: 28, canvas: canvas),
                       CGPoint(x: -360, y: 772))
        XCTAssertEqual(clampedWindowOrigin(CGPoint(x: 2000, y: -50), size: size, titleBar: 28, canvas: canvas),
                       CGPoint(x: 960, y: 0))
        XCTAssertEqual(clampedWindowOrigin(CGPoint(x: 100, y: 100), size: size, titleBar: 28, canvas: canvas),
                       CGPoint(x: 100, y: 100))
    }

    func testClampedWindowOriginWithoutTitleRowKeeps20Points() {
        let origin = clampedWindowOrigin(CGPoint(x: 0, y: 5000), size: CGSize(width: 30, height: 30), titleBar: 0,
                                         canvas: CGSize(width: 1000, height: 800))
        XCTAssertEqual(origin, CGPoint(x: 0, y: 780))
    }

    // MARK: classificationIsFinal (a window without its AX window yet is classified again)

    func testClassificationWithoutAccessibilityIsRetried() {
        XCTAssertFalse(classificationIsFinal(foundAccessibility: false, belowPopUp: true, attempts: 1))
        XCTAssertFalse(classificationIsFinal(foundAccessibility: false, belowPopUp: true, attempts: classificationAttempts - 1))
        XCTAssertTrue(classificationIsFinal(foundAccessibility: false, belowPopUp: true, attempts: classificationAttempts))
        XCTAssertTrue(classificationIsFinal(foundAccessibility: true, belowPopUp: true, attempts: 1))
        // Menus and tooltips never have one, so nothing is gained by asking again.
        XCTAssertTrue(classificationIsFinal(foundAccessibility: false, belowPopUp: false, attempts: 1))
    }

    func testRezoomKeepsCanvasPoint() {
        let p = WindowPlacement(origin: CGPoint(x: 40, y: 60), zoom: 1)
        let kept = CGPoint(x: 120, y: 80)
        let q = p.rezoomed(to: 2, keeping: kept)
        XCTAssertEqual(q.zoom, 2)
        XCTAssertEqual(q.toB(kept).x, p.toB(kept).x, accuracy: 0.001)
        XCTAssertEqual(q.toB(kept).y, p.toB(kept).y, accuracy: 0.001)
    }

    func testContentTopLeftSkipsTheATitleRow() {
        let p = WindowPlacement(origin: CGPoint(x: 10, y: 20), zoom: 2)
        let w = WindowInfo(id: 1, parent: 0, kind: .normal, resizable: true, focused: true,
                           rect: CanvasRect(x: 100, y: 50, w: 400, h: 300), titleBar: 28, title: "")
        XCTAssertEqual(p.contentTopLeftInB(w), CGPoint(x: 210, y: 176))
    }

    func testWindowOriginFromBContentUndoesContentTopLeft() {
        let p = WindowPlacement(origin: CGPoint(x: 10, y: 20), zoom: 2)
        // B content moved 40 right, 10 down from where (100, 50) with a 28-point row would be.
        let origin = p.windowOrigin(contentTopLeftInB: CGPoint(x: 250, y: 186), titleBar: 28)
        XCTAssertEqual(origin.x, 120, accuracy: 0.001)
        XCTAssertEqual(origin.y, 55, accuracy: 0.001)
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

    // MARK: Move to A's top-left (B's window menu)

    func testMoveToTopLeftMovesThenRaises() {
        XCTAssertEqual(moveToTopLeftMessages(window: 7, table: [win(7, .normal, 500, 400, 300, 200)]),
                       [.move(window: 7, x: 0, y: 0), .focus(7)])
    }

    func testMoveToTopLeftStacksBelowRightOfWindowsAlreadyThere() {
        // Window 1 sits in the first slot (macOS pushed it below a 30-point menu bar), 2 in the second.
        let table = [win(1, .normal, 0, 30, 300, 200), win(2, .normal, 28, 30, 300, 200),
                     win(7, .normal, 500, 400, 300, 200)]
        XCTAssertEqual(moveToTopLeftMessages(window: 7, table: table), [.move(window: 7, x: 56, y: 56), .focus(7)])
    }

    func testMoveToTopLeftIgnoresItselfPopupsAndWindowsElsewhere() {
        let table = [win(7, .normal, 0, 30, 300, 200),            // itself, already there
                     win(8, .menu, 0, 30, 100, 100),              // a popup is not a stacked window
                     win(9, .normal, 0, 400, 300, 200),           // same x, far below the top
                     win(10, .normal, 300, 30, 300, 200)]         // at the top, far to the right
        XCTAssertEqual(moveToTopLeftMessages(window: 7, table: table), [.move(window: 7, x: 0, y: 0), .focus(7)])
    }
}
