import XCTest
@testable import RappCore

final class InputYieldTests: XCTestCase {
    private func k(_ code: UInt16, _ down: Bool) -> Message { .key(keyCode: code, modifiers: 0, down: down) }
    private func m(_ kind: MouseKind) -> Message {
        .mouse(kind: kind, button: .left, window: 1, x: 0, y: 0, clickCount: 1)
    }
    private let t = Message.text("a")

    func testOwnInputPassesAndReportsAtMostEveryQuarterSecond() {
        var y = InputYield()
        XCTAssertEqual(y.admit(t, at: 0), .pass(report: true))
        XCTAssertEqual(y.admit(t, at: 0.1), .pass(report: false))
        XCTAssertEqual(y.admit(t, at: 0.3), .pass(report: true))
    }
    func testSteadyInputReportsEveryQuarterSecondAndTheTrailingOne() {
        var y = InputYield()
        _ = y.admit(t, at: 0); _ = y.admit(t, at: 0.1)
        XCTAssertFalse(y.tick(at: 0.2))
        XCTAssertTrue(y.tick(at: 0.25))      // the 0.1 one is reported late
        XCTAssertFalse(y.tick(at: 0.5))      // nothing new
    }
    func testInputWithinOneSecondOfAYieldIsDroppedThenPasses() {
        var y = InputYield()
        y.yielded(to: "Mac mini", at: 10)
        XCTAssertEqual(y.admit(t, at: 10.2), .drop(notify: "Mac mini"))
        XCTAssertEqual(y.admit(t, at: 10.4), .drop(notify: nil))
        XCTAssertEqual(y.admit(t, at: 10.8), .drop(notify: "Mac mini"))
        XCTAssertEqual(y.admit(t, at: 11.0), .pass(report: true))
    }
    func testHoverIsBlockedButNeverReported() {
        var y = InputYield()
        XCTAssertEqual(y.admit(m(.move), at: 0), .pass(report: false))
        y.yielded(to: "x", at: 1)
        XCTAssertEqual(y.admit(m(.move), at: 1.1), .drop(notify: "x"))
    }
    func testReleaseOfAnAdmittedPressPassesWhileBlocked() {
        var y = InputYield()
        _ = y.admit(k(56, true), at: 0); _ = y.admit(m(.down), at: 0)
        y.yielded(to: "x", at: 0.5)
        XCTAssertEqual(y.admit(k(56, false), at: 0.6), .pass(report: true))
        XCTAssertEqual(y.admit(m(.up), at: 0.9), .pass(report: true))
    }
    func testDragOfAnAdmittedButtonIsNeverBlocked() {
        var y = InputYield()
        _ = y.admit(m(.down), at: 0)
        y.yielded(to: "x", at: 0.1)
        XCTAssertEqual(y.admit(m(.drag), at: 0.2), .pass(report: false))
        XCTAssertEqual(y.admit(m(.drag), at: 0.3), .pass(report: true))
    }
    func testDragAndUpOfABlockedPressAreDropped() {
        var y = InputYield()
        y.yielded(to: "x", at: 0)
        XCTAssertEqual(y.admit(m(.down), at: 0.1), .drop(notify: "x"))
        XCTAssertEqual(y.admit(m(.drag), at: 1.5), .drop(notify: nil))
        XCTAssertEqual(y.admit(m(.up), at: 1.6), .drop(notify: nil))
        XCTAssertEqual(y.admit(m(.down), at: 1.7), .pass(report: true))
    }
    func testStrayReleaseIsDroppedOnlyWhileBlocked() {
        var y = InputYield()
        XCTAssertEqual(y.admit(k(0, false), at: 0), .pass(report: false))
        y.yielded(to: "x", at: 1)
        XCTAssertEqual(y.admit(k(0, false), at: 1.1), .drop(notify: "x"))
    }
    func testWindowCommandsAreNeverBlocked() {
        var y = InputYield()
        y.yielded(to: "x", at: 0)
        for msg: Message in [.resize(window: 1, width: 10, height: 10), .move(window: 1, x: 0, y: 0), .close(1),
                             .setStream(mode: .gray4, fps: 5, density: 1)] {
            XCTAssertEqual(y.admit(msg, at: 0.1), .pass(report: false))
        }
    }
    func testPasteMenuPickFocusAndScrollAreInput() {
        var y = InputYield()
        y.yielded(to: "x", at: 0)
        for msg: Message in [.paste(seq: 1, .text("a")), .menuPick([0]), .focus(1), .scroll(window: 1, x: 0, y: 0, dx: 0, dy: 1)] {
            if case .drop = y.admit(msg, at: 0.1) {} else { XCTFail("\(msg)") }
        }
    }
    func testReleasedKeyIsForgottenSoNextPressIsJudgedFresh() {
        var y = InputYield()
        _ = y.admit(k(5, true), at: 0)
        _ = y.admit(k(5, false), at: 0.1)
        y.yielded(to: "x", at: 0.2)
        XCTAssertEqual(y.admit(k(5, true), at: 0.3), .drop(notify: "x"))
    }
}
