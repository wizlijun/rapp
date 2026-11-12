import AppKit
import RappCore
import XCTest
@testable import RappSession

final class DetachTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 2000, height: 1200)

    func testDetachedFramesGoRightOfMainWhenRoom() {
        let main = CGRect(x: 100, y: 200, width: 800, height: 800)
        let f = detachedFrames(contents: [CGSize(width: 600, height: 400)], screen: screen, beside: main)
        XCTAssertEqual(f.count, 1)
        XCTAssertEqual(f[0].minX, 900)
        XCTAssertEqual(f[0].maxY, 1000)
        XCTAssertEqual(f[0].size, CGSize(width: 600, height: 400))
    }

    func testDetachedFramesFallBackLeftThenOffset() {
        // Main against the right edge: the window goes to its left, top-aligned.
        let right = CGRect(x: 1300, y: 200, width: 700, height: 800)
        let left = detachedFrames(contents: [CGSize(width: 600, height: 400)], screen: screen, beside: right)
        XCTAssertEqual(left[0], CGRect(x: 700, y: 600, width: 600, height: 400))
        // Room on neither side: main's top-left moved by (24, -24).
        let wide = CGRect(x: 300, y: 200, width: 1400, height: 800)
        let offset = detachedFrames(contents: [CGSize(width: 600, height: 400)], screen: screen, beside: wide)
        XCTAssertEqual(offset[0], CGRect(x: 324, y: 1000 - 24 - 400, width: 600, height: 400))
    }

    func testDetachedFramesClampToScreenAndCascade() {
        let main = CGRect(x: 100, y: 200, width: 800, height: 800)
        let f = detachedFrames(contents: [CGSize(width: 3000, height: 2000), CGSize(width: 600, height: 400)],
                               screen: screen, beside: main)
        XCTAssertEqual(f[0], screen)
        // The first one decides the side (here: neither, so main's top-left +(24, -24)); the second
        // cascades 24 right and 24 down from that anchor.
        XCTAssertEqual(f[1], CGRect(x: 124 + 24, y: 976 - 24 - 400, width: 600, height: 400))
        // Cascading never leaves the screen.
        let crowded = detachedFrames(contents: Array(repeating: CGSize(width: 1000, height: 1100), count: 4),
                                     screen: screen, beside: main)
        for r in crowded { XCTAssertTrue(screen.contains(r), "\(r)") }
    }

    func testDetachedFramesCascadeFromOneAnchorWhateverTheSizes() {
        // Right of main, decided by the first window; a wider second one cascades from there and is
        // pulled back onto the screen, instead of choosing a side of its own.
        let main = CGRect(x: 100, y: 200, width: 800, height: 800)
        let f = detachedFrames(contents: [CGSize(width: 600, height: 400), CGSize(width: 1200, height: 300)],
                               screen: screen, beside: main)
        XCTAssertEqual(f[0], CGRect(x: 900, y: 600, width: 600, height: 400))
        XCTAssertEqual(f[1], CGRect(x: 800, y: 1000 - 24 - 300, width: 1200, height: 300))
        // Left of main: a small second window stays on the left too.
        let right = CGRect(x: 1300, y: 200, width: 700, height: 800)
        let g = detachedFrames(contents: [CGSize(width: 600, height: 400), CGSize(width: 200, height: 100)],
                               screen: screen, beside: right)
        XCTAssertEqual(g[0], CGRect(x: 700, y: 600, width: 600, height: 400))
        XCTAssertEqual(g[1], CGRect(x: 724, y: 1000 - 24 - 100, width: 200, height: 100))
    }

    func testDetachedFramesOnAnOffsetScreen() {
        let s = CGRect(x: -1440, y: 100, width: 1440, height: 900)
        let main = CGRect(x: -1400, y: 300, width: 600, height: 600)
        let f = detachedFrames(contents: [CGSize(width: 500, height: 300)], screen: s, beside: main)
        XCTAssertEqual(f[0], CGRect(x: -800, y: 600, width: 500, height: 300))
    }

    private func info(_ id: UInt32, w: Float = 400, h: Float = 328, resizable: Bool = true) -> WindowInfo {
        WindowInfo(id: id, parent: 0, kind: .normal, resizable: resizable, focused: false,
                   rect: CanvasRect(x: 0, y: 0, w: w, h: h), titleBar: 28, title: "w\(id)")
    }

    func testDetachedResizeFollowsR12() {
        // Content 400×300 (title row excluded): a different size is sent, the same one is not.
        XCTAssertEqual(detachedResize(info(5), content: CGSize(width: 500.4, height: 250.6)),
                       .resize(window: 5, width: 500, height: 251))
        XCTAssertNil(detachedResize(info(5), content: CGSize(width: 400, height: 300)))
        XCTAssertNil(detachedResize(info(5, resizable: false), content: CGSize(width: 500, height: 250)))
    }

    func testDetachedFollowSize() {
        // A non-resizable window has no handle: it takes A's new content size (title row excluded).
        let basic = info(5, w: 230, h: 328, resizable: false), scientific = info(5, w: 560, h: 328, resizable: false)
        XCTAssertEqual(detachedFollowSize(old: basic, new: scientific), CGSize(width: 560, height: 300))
        XCTAssertNil(detachedFollowSize(old: basic, new: basic))
        // The title row alone changing is a content change too.
        var taller = basic
        taller.titleBar = 0
        XCTAssertEqual(detachedFollowSize(old: basic, new: taller), CGSize(width: 230, height: 328))
        // A resizable one keeps the size the user gave it (A's answer shows letterboxed).
        XCTAssertNil(detachedFollowSize(old: info(5), new: info(5, w: 800, h: 600)))
        // Becoming non-resizable with another size: follow it.
        XCTAssertEqual(detachedFollowSize(old: info(5), new: info(5, w: 300, h: 228, resizable: false)),
                       CGSize(width: 300, height: 200))
    }

    func testPopupOwner() {
        let table = [info(5), info(6),
                     WindowInfo(id: 20, parent: 6, kind: .menu, resizable: false, focused: false,
                                rect: CanvasRect(x: 0, y: 0, w: 10, h: 10), titleBar: 0, title: ""),
                     WindowInfo(id: 21, parent: 20, kind: .menu, resizable: false, focused: false,
                                rect: CanvasRect(x: 0, y: 0, w: 10, h: 10), titleBar: 0, title: ""),
                     WindowInfo(id: 22, parent: 0, kind: .tooltip, resizable: false, focused: false,
                                rect: CanvasRect(x: 0, y: 0, w: 10, h: 10), titleBar: 0, title: ""),
                     WindowInfo(id: 23, parent: 23, kind: .menu, resizable: false, focused: false,
                                rect: CanvasRect(x: 0, y: 0, w: 10, h: 10), titleBar: 0, title: "")]
        XCTAssertEqual(popupOwner(20, table: table, fallback: 5), 6)
        XCTAssertEqual(popupOwner(21, table: table, fallback: 5), 6)   // a submenu: its menu's window
        XCTAssertEqual(popupOwner(22, table: table, fallback: 5), 5)   // no parent: the current one (R8)
        XCTAssertEqual(popupOwner(23, table: table, fallback: nil), nil) // a loop ends
    }

    func testKeyWindowRoute() {
        let main = 1, a = 2, b = 3, other = 4
        let detached = [a: Int64(7), b: Int64(8)]
        XCTAssertEqual(keyWindowRoute(window: main, main: main, detached: detached), .main)
        XCTAssertEqual(keyWindowRoute(window: a, main: main, detached: detached), .detached(7))
        XCTAssertEqual(keyWindowRoute(window: b, main: main, detached: detached), .detached(8))
        XCTAssertEqual(keyWindowRoute(window: other, main: main, detached: detached), .local)
        // No window, or the main window not known yet: nothing is A's.
        XCTAssertEqual(keyWindowRoute(window: nil, main: main, detached: detached), .local)
        XCTAssertEqual(keyWindowRoute(window: main, main: nil, detached: [:]), .local)
        XCTAssertEqual(keyWindowRoute(window: Optional<Int>.none, main: nil, detached: [:]), .local)
    }

    func testRouteDetachedKey() {
        XCTAssertEqual(routeDetachedKey(keyCode: 2, flags: [.control, .command]), .attach)           // ⌃⌘D
        XCTAssertEqual(routeDetachedKey(keyCode: 2, flags: [.control, .command, .capsLock]), .attach)
        XCTAssertEqual(routeDetachedKey(keyCode: 12, flags: [.command]), .local)                     // ⌘Q
        XCTAssertEqual(routeDetachedKey(keyCode: 3, flags: [.control, .command]), .remote)           // ⌃⌘F is A's here
        XCTAssertEqual(routeDetachedKey(keyCode: 2, flags: [.command]), .remote)                     // ⌘D
        XCTAssertEqual(routeDetachedKey(keyCode: 53, flags: []), .remote)                            // Esc
        XCTAssertEqual(routeDetachedKey(keyCode: 13, flags: [.command]), .remote)                    // ⌘W
    }

    func testKeyTrackerInDetachedWindow() {
        var k = KeyTracker()
        // ⌃ and ⌘ go down on A, then D makes the chord: A gets their releases, D stays local.
        XCTAssertEqual(k.routeDetached(keyCode: 59, down: true, flags: [.control]), KeyDecision(.remote))
        XCTAssertEqual(k.routeDetached(keyCode: 55, down: true, flags: [.control, .command]), KeyDecision(.remote))
        XCTAssertEqual(k.routeDetached(keyCode: 2, down: true, flags: [.control, .command]),
                       KeyDecision(.local, release: [55, 59]))
        XCTAssertEqual(k.routeDetached(keyCode: 2, down: false, flags: [.control, .command]), KeyDecision(.local))
        XCTAssertEqual(k.routeDetached(keyCode: 55, down: false, flags: [.control]), KeyDecision(.local))
        // An ordinary key pairs up on A.
        XCTAssertEqual(k.routeDetached(keyCode: 0, down: true, flags: []), KeyDecision(.remote))
        XCTAssertTrue(k.isDown(0))
        XCTAssertEqual(k.routeDetached(keyCode: 0, down: false, flags: []), KeyDecision(.remote))
        // ⌘Q stays local; the ⌘ A holds is released first.
        XCTAssertEqual(k.routeDetached(keyCode: 55, down: true, flags: [.command]), KeyDecision(.remote))
        XCTAssertEqual(k.routeDetached(keyCode: 12, down: true, flags: [.command]), KeyDecision(.local, release: [55]))
    }

    func testDetachedPayload() {
        let on = detachedPayload(sid: 3, detached: true, current: nil)
        XCTAssertEqual(on.method, "detached")
        XCTAssertEqual(on.args["sid"] as? Int64, 3)
        XCTAssertEqual(on.args["detached"] as? Bool, true)
        XCTAssertTrue(on.args["current"] is NSNull)
        let off = detachedPayload(sid: 3, detached: false, current: 7)
        XCTAssertEqual(off.args["detached"] as? Bool, false)
        XCTAssertEqual(off.args["current"] as? Int, 7)
    }

    func testDetachChannelCommands() throws {
        XCTAssertEqual(try channelCommand("detach", ["sid": 4]), .detach(sid: 4))
        XCTAssertEqual(try channelCommand("attach", ["sid": 4]), .attach(sid: 4))
        XCTAssertEqual(try channelCommand("raise_detached", ["sid": 4]), .raiseDetached(sid: 4))
        XCTAssertThrowsError(try channelCommand("detach", ["sid": "x"]))
    }
}
