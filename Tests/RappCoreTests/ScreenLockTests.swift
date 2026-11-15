import XCTest
@testable import RappCore

final class ScreenLockTests: XCTestCase {
    func testAlreadyLockedCallsNothing() {
        var calls = 0
        XCTAssertEqual(lockScreen(isLocked: { true }, call: { calls += 1; return nil }, sleep: { _ in }), .already)
        XCTAssertEqual(calls, 0)
    }

    func testLockedOnceStateFlips() {
        var n = 0
        XCTAssertEqual(lockScreen(isLocked: { n += 1; return n > 3 }, call: { nil }, sleep: { _ in }), .locked)
    }

    func testNeverLockedFailsAfterTimeout() {
        var slept = 0.0
        let r = lockScreen(isLocked: { false }, call: { nil }, sleep: { slept += $0 })
        XCTAssertEqual(r, .failed("调用后 2 秒内没有锁上"))
        XCTAssertGreaterThanOrEqual(slept, 2)
    }

    func testMissingSymbolFails() {
        XCTAssertEqual(lockScreen(isLocked: { false }, call: { "找不到 SACLockScreenImmediate" }, sleep: { _ in }),
                       .failed("找不到 SACLockScreenImmediate"))
    }

    func testWaitUntilUnlockedReturnsAtOnceWhenNotLocked() {
        var slept = 0.0
        waitUntilUnlocked(isLocked: { false }, sleep: { slept += $0 })
        XCTAssertEqual(slept, 0)
    }

    func testWaitUntilUnlockedPollsUntilStateFlips() {
        var n = 0
        var slept = 0.0
        waitUntilUnlocked(isLocked: { n += 1; return n <= 5 }, sleep: { slept += $0 })
        XCTAssertEqual(n, 6)
        XCTAssertEqual(slept, 0.5, accuracy: 0.001)
    }

    func testWaitUntilUnlockedGivesUpAfterTimeout() {
        var slept = 0.0
        waitUntilUnlocked(isLocked: { true }, sleep: { slept += $0 })
        XCTAssertGreaterThanOrEqual(slept, 8)
        XCTAssertLessThan(slept, 8.5)
    }

    // A locked app start announces the display the app's largest window is on (spec §6.4).
    private let mainDisplay = CGRect(x: 0, y: 0, width: 1512, height: 982)
    private let sideDisplay = CGRect(x: 1512, y: -200, width: 2560, height: 1440)

    func testLockedStartDisplayFollowsTheLargestWindow() {
        let small = CGRect(x: 100, y: 100, width: 400, height: 300)
        let large = CGRect(x: 1700, y: 0, width: 1200, height: 900)
        XCTAssertEqual(lockedStartDisplay(windows: [small, large], displays: [mainDisplay, sideDisplay]), sideDisplay)
        XCTAssertEqual(lockedStartDisplay(windows: [large.offsetBy(dx: -1600, dy: 0), small.offsetBy(dx: 1600, dy: 0)],
                                          displays: [mainDisplay, sideDisplay]), mainDisplay)
    }

    func testLockedStartDisplayUsesTheWindowCentre() {
        // Mostly on the side display: its centre decides, like the capture's own lookup.
        let straddling = CGRect(x: 1300, y: 100, width: 800, height: 600)
        XCTAssertEqual(lockedStartDisplay(windows: [straddling], displays: [mainDisplay, sideDisplay]), sideDisplay)
    }

    func testLockedStartDisplayIgnoresTinyWindowsAndFallsBack() {
        XCTAssertNil(lockedStartDisplay(windows: [], displays: [mainDisplay, sideDisplay]))
        XCTAssertNil(lockedStartDisplay(windows: [CGRect(x: 1700, y: 0, width: 40, height: 900)],
                                        displays: [mainDisplay, sideDisplay]))
        XCTAssertNil(lockedStartDisplay(windows: [CGRect(x: 9000, y: 9000, width: 400, height: 400)],
                                        displays: [mainDisplay, sideDisplay]))
        XCTAssertEqual(lockedStartDisplay(windows: [CGRect(x: 1700, y: 0, width: 40, height: 900),
                                                    CGRect(x: 1800, y: 100, width: 300, height: 200)],
                                          displays: [mainDisplay, sideDisplay]), sideDisplay)
    }
}
