import XCTest
@testable import RappCore

final class QueryDeadlineTests: XCTestCase {
    func testRemainingShrinksWithTheClock() {
        let d = QueryDeadline(start: 10, budget: 0.05)
        XCTAssertEqual(d.remaining(now: 10)!, 0.05, accuracy: 1e-9)
        XCTAssertEqual(d.remaining(now: 10.02)!, 0.03, accuracy: 1e-9)
    }

    func testNothingRemainsAtOrAfterTheEnd() {
        let d = QueryDeadline(start: 10, budget: 0.05)
        XCTAssertNil(d.remaining(now: 10.05))
        XCTAssertNil(d.remaining(now: 10.0495))  // under 1 ms is not worth a call
        XCTAssertNil(d.remaining(now: 11))
        XCTAssertTrue(d.expired(now: 10.06))
        XCTAssertFalse(d.expired(now: 10.01))
    }
}
