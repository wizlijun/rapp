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
}
