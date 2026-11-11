import RappCore
import XCTest

final class PendingActionsTests: XCTestCase {
    func testDroppedKeysNeverRunAndAreForgotten() {
        var pending = PendingActions<Int>()
        let kept = expectation(description: "kept key runs")
        let dropped = expectation(description: "dropped key runs")
        dropped.isInverted = true
        pending.schedule(1, after: 0.05) { kept.fulfill() }
        pending.schedule(2, after: 0.05) { dropped.fulfill() }
        pending.keep(only: [1])
        XCTAssertEqual(pending.count, 1)
        wait(for: [kept, dropped], timeout: 0.3)
    }

    func testRescheduleReplacesTheEarlierAction() {
        var pending = PendingActions<Int>()
        let first = expectation(description: "first runs")
        first.isInverted = true
        let second = expectation(description: "second runs")
        pending.schedule(1, after: 0.05) { first.fulfill() }
        pending.schedule(1, after: 0.05) { second.fulfill() }
        XCTAssertEqual(pending.count, 1)
        wait(for: [first, second], timeout: 0.3)
    }

    func testCancelStopsTheAction() {
        var pending = PendingActions<Int>()
        let ran = expectation(description: "cancelled runs")
        ran.isInverted = true
        pending.schedule(1, after: 0.05) { ran.fulfill() }
        pending.cancel(1)
        XCTAssertEqual(pending.count, 0)
        wait(for: [ran], timeout: 0.2)
    }
}
