import XCTest
@testable import RappCore

final class PauseOutboxTests: XCTestCase {
    private let w1 = Message.windows([]), menu = Message.menuBar([])
    private let focus = Message.focusRegion(window: 7, rects: [])
    private func table(_ id: UInt32) -> Message {
        .windows([WindowInfo(id: id, parent: 0, kind: .normal, resizable: true, focused: true,
                             rect: CanvasRect(x: 0, y: 0, w: 1, h: 1), titleBar: 0, title: "t\(id)")])
    }

    func testStreamingPassesEverything() {
        var o = PauseOutbox()
        for m in [w1, menu, focus, .pong(1), .clip(id: 1, .unsupported("x"))] {
            XCTAssertEqual(o.pass(m, now: 0), m)
        }
        XCTAssertNil(o.changed(now: 0))
        XCTAssertNil(o.due(now: 100))
    }

    func testPausedHoldsMenuAndFocusKeepingTheNewest() {
        var o = PauseOutbox()
        XCTAssertEqual(o.setPaused(true, now: 0), [])
        XCTAssertNil(o.pass(menu, now: 1))
        let newer = Message.focusRegion(window: 9, rects: [])
        XCTAssertNil(o.pass(focus, now: 1))
        XCTAssertNil(o.pass(newer, now: 2))
        XCTAssertEqual(o.pass(.pong(3), now: 2), .pong(3))
        XCTAssertEqual(o.pass(.secureFocus(true), now: 2), .secureFocus(true))
        XCTAssertEqual(o.setPaused(false, now: 3), [menu, newer])
        XCTAssertEqual(o.setPaused(true, now: 4), [])
        XCTAssertEqual(o.setPaused(false, now: 5), [], "nothing held twice")
    }

    func testPausedWindowTableAtMostEveryFiveSeconds() {
        var o = PauseOutbox()
        XCTAssertEqual(o.pass(table(1), now: 0), table(1))
        _ = o.setPaused(true, now: 1)
        XCTAssertNil(o.pass(table(2), now: 2))
        XCTAssertNil(o.pass(table(3), now: 4))
        XCTAssertNil(o.due(now: 4.9))
        XCTAssertEqual(o.due(now: 5), table(3), "the newest, 5 s after the last one sent")
        XCTAssertNil(o.due(now: 20), "sent once")
        XCTAssertEqual(o.pass(table(4), now: 20), table(4), "more than 5 s since the last: at once")
        XCTAssertNil(o.pass(table(5), now: 21))
    }

    func testResumeFlushesWindowsMenuFocusInOrder() {
        var o = PauseOutbox()
        _ = o.pass(table(1), now: 0)
        _ = o.setPaused(true, now: 0)
        XCTAssertNil(o.pass(focus, now: 1))
        XCTAssertNil(o.pass(table(2), now: 1))
        XCTAssertNil(o.pass(menu, now: 2))
        XCTAssertEqual(o.setPaused(false, now: 3), [table(2), menu, focus])
        XCTAssertEqual(o.pass(table(3), now: 3.5), table(3), "streaming again: no throttle")
    }

    func testChangedAtMostOncePerSecondOnlyWhilePaused() {
        var o = PauseOutbox()
        XCTAssertNil(o.changed(now: 0))
        _ = o.setPaused(true, now: 0)
        XCTAssertEqual(o.changed(now: 0), .changed)
        XCTAssertNil(o.changed(now: 0.5))
        XCTAssertNil(o.changed(now: 0.99))
        XCTAssertEqual(o.changed(now: 1), .changed)
        _ = o.setPaused(false, now: 2)
        XCTAssertNil(o.changed(now: 5))
    }
}
