import CoreGraphics
import RappCore
import XCTest

final class HitTestTests: XCTestCase {
    private let app: Int32 = 100, dock: Int32 = 50, other: Int32 = 70
    private let point = CGPoint(x: 400, y: 300)
    private func win(_ pid: Int32, _ name: String, layer: Int = 0, frame: CGRect = CGRect(x: 0, y: 0, width: 800, height: 600),
                     alpha: Double = 1) -> ScreenWindow {
        ScreenWindow(pid: pid, name: name, layer: layer, alpha: alpha, frame: frame)
    }
    private var fullScreenDock: ScreenWindow { win(dock, "Dock", layer: 20, frame: CGRect(x: 0, y: 0, width: 1920, height: 1080)) }

    // macOS 27: the Dock keeps a transparent full-screen window above every app window.
    func testTransparentDockOverlayIsLookedThrough() {
        let owner = topWindowOwner(at: point, windows: [fullScreenDock, win(app, "TextEdit")], dockPID: dock) { self.app }
        XCTAssertEqual(owner.pid, app)
    }

    func testDockBarAtThePointStillCovers() {
        let owner = topWindowOwner(at: point, windows: [fullScreenDock, win(app, "TextEdit")], dockPID: dock) { self.dock }
        XCTAssertEqual(owner.pid, dock)
    }

    func testFailedHitTestLooksThroughTheDock() {
        let owner = topWindowOwner(at: point, windows: [fullScreenDock, win(app, "TextEdit")], dockPID: dock) { nil }
        XCTAssertEqual(owner.pid, app)
    }

    func testOtherAppWindowCovers() {
        let owner = topWindowOwner(at: point, windows: [fullScreenDock, win(other, "Notes"), win(app, "TextEdit")],
                                   dockPID: dock) { self.app }
        XCTAssertEqual(owner.pid, other)
    }

    func testInvisibleHighLayerAndMissedWindowsAreSkipped() {
        let windows = [win(other, "Clear", alpha: 0), win(other, "Cursor", layer: 2000),
                       win(other, "Elsewhere", frame: CGRect(x: 900, y: 0, width: 100, height: 100)), win(app, "TextEdit")]
        XCTAssertEqual(topWindowOwner(at: point, windows: windows, dockPID: dock) { nil }.pid, app)
        XCTAssertEqual(topWindowOwner(at: point, windows: [], dockPID: dock) { nil }.name, "nothing")
    }
}
