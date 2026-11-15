import CoreGraphics
import RappCore
import XCTest

final class DesktopTests: XCTestCase {
    func testDesktopTarget() {
        XCTAssertEqual(desktopTarget("desktop:"), .main)
        XCTAssertEqual(desktopTarget("desktop:69733382"), .display(69_733_382))
        XCTAssertNil(desktopTarget("desktop:x"))
        XCTAssertNil(desktopTarget("desktop:-1"))
        XCTAssertNil(desktopTarget("desktop:99999999999"))
        XCTAssertNil(desktopTarget("desktop:１"))
        XCTAssertNil(desktopTarget("com.apple.Safari"))
        XCTAssertNil(desktopTarget("term:abc"))
        XCTAssertTrue(isDesktopApp("desktop:3"))
        XCTAssertFalse(isDesktopApp("desktop"))
    }

    func testOrderedDisplaysMainFirstThenLeftToRight() {
        func d(_ id: UInt32, _ x: CGFloat, _ y: CGFloat = 0, main: Bool = false) -> DesktopDisplay {
            DesktopDisplay(id: id, name: "d\(id)", main: main, frame: CGRect(x: x, y: y, width: 100, height: 100))
        }
        let ordered = orderedDisplays([d(3, 200), d(2, -100), d(1, 0, main: true), d(4, 200, -100)])
        XCTAssertEqual(ordered.map(\.id), [1, 2, 4, 3])
    }

    func testDesktopTitleAndTable() {
        XCTAssertEqual(desktopTitle(computer: "Mac mini", number: 2), "Mac mini · 屏幕 2")
        XCTAssertEqual(desktopTitle(computer: " ", number: 1), "屏幕 1")
        XCTAssertEqual(desktopTable(width: 1512, height: 982, title: "屏幕 1"),
                       [WindowInfo(id: 1, parent: 0, kind: .normal, resizable: false, focused: true,
                                   rect: CanvasRect(x: 0, y: 0, w: 1512, h: 982), titleBar: 0, title: "屏幕 1")])
    }
}
