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

/// Other apps' see-through overlays (a full-screen global prompt layer, a translucent HUD): they count
/// only where the Accessibility hit test finds them, or when it cannot say.
final class OverlayHitTestTests: XCTestCase {
    private let app: Int32 = 100, dock: Int32 = 50, other: Int32 = 70
    private let point = CGPoint(x: 400, y: 300)
    private let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    private func win(_ pid: Int32, _ name: String, layer: Int = 0, frame: CGRect = CGRect(x: 0, y: 0, width: 800, height: 600),
                     alpha: Double = 1) -> ScreenWindow {
        ScreenWindow(pid: pid, name: name, layer: layer, alpha: alpha, frame: frame)
    }
    private func owner(_ windows: [ScreenWindow], hit: @escaping () -> Int32?) -> Int32 {
        topWindowOwner(at: point, windows: windows, dockPID: dock, displays: [screen], hitTestPID: hit).pid
    }

    func testFullScreenOverlayIsLookedThroughWhereTheAppIsHit() {
        XCTAssertEqual(owner([win(other, "Prompt", layer: 25, frame: screen), win(app, "TextEdit")]) { self.app }, app)
    }

    func testFullScreenOverlayCoversWhereItIsHit() {
        XCTAssertEqual(owner([win(other, "Prompt", layer: 25, frame: screen), win(app, "TextEdit")]) { self.other }, other)
    }

    func testFullScreenOverlayCoversWhenTheHitTestFails() {
        XCTAssertEqual(owner([win(other, "Prompt", layer: 25, frame: screen), win(app, "TextEdit")]) { nil }, other)
    }

    func testNearlyFullScreenCountsAsOverlay() {
        let big = CGRect(x: 0, y: 25, width: 1920, height: 1000)
        XCTAssertEqual(owner([win(other, "Prompt", frame: big), win(app, "TextEdit")]) { self.app }, app)
    }

    func testTranslucentWindowIsLookedThroughWhereTheAppIsHit() {
        let hud = CGRect(x: 300, y: 200, width: 300, height: 200)
        XCTAssertEqual(owner([win(other, "HUD", layer: 8, frame: hud, alpha: 0.4), win(app, "TextEdit")]) { self.app }, app)
    }

    func testSmallOpaqueWindowCoversWithoutAskingAccessibility() {
        let sheet = CGRect(x: 300, y: 200, width: 300, height: 200)
        XCTAssertEqual(owner([win(other, "Notes", frame: sheet), win(app, "TextEdit")]) {
            XCTFail("no hit test for an ordinary window"); return nil
        }, other)
    }

    func testHitTestRunsOncePerPress() {
        var calls = 0
        let windows = [win(dock, "Dock", layer: 20, frame: screen), win(other, "Prompt", layer: 25, frame: screen),
                       win(app, "TextEdit")]
        XCTAssertEqual(owner(windows) { calls += 1; return self.app }, app)
        XCTAssertEqual(calls, 1)
    }

    func testOverlayOfAThirdProcessIsLookedThroughToTheNextWindow() {
        let windows = [win(other, "Prompt", layer: 25, frame: screen), win(71, "Notes"), win(app, "TextEdit")]
        XCTAssertEqual(owner(windows) { 71 }, 71)
    }

    func testDisplayIsTheOneHoldingThePoint() {
        // The display holding the point decides: all of it is an overlay, half of it an ordinary window.
        let second = CGRect(x: 1920, y: 0, width: 1920, height: 1080)
        let wide = CGRect(x: 0, y: 0, width: 3840, height: 1080)
        let windows = [win(other, "Wide", frame: wide), win(app, "TextEdit")]
        XCTAssertEqual(topWindowOwner(at: point, windows: windows, dockPID: dock, displays: [screen, second]) { self.app }.pid, app)
        let small = CGRect(x: 0, y: 0, width: 960, height: 1080)
        XCTAssertEqual(topWindowOwner(at: point, windows: [win(other, "Half", frame: small), win(app, "TextEdit")],
                                      dockPID: dock, displays: [screen, second]) { self.app }.pid, other)
    }
}
