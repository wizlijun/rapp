import XCTest
@testable import RappCore

final class QueryCoalescerTests: XCTestCase {
    typealias C = QueryCoalescer<String>

    func testIdleRunsAtOnce() {
        var c = C()
        XCTAssertEqual(c.submit(.keyboard, "k1"), "k1")
        XCTAssertNil(c.finish())
    }

    func testNewerPointerReplacesPendingPointer() {
        var c = C()
        XCTAssertEqual(c.submit(.pointer, "p1"), "p1")
        XCTAssertNil(c.submit(.pointer, "p2"))
        XCTAssertNil(c.submit(.pointer, "p3"))
        XCTAssertEqual(c.finish(), "p3")
        XCTAssertNil(c.finish())
    }

    func testPointerDoesNotReplaceKeyboard() {
        var c = C()
        XCTAssertEqual(c.submit(.pointer, "p1"), "p1")
        XCTAssertNil(c.submit(.keyboard, "k1"))
        XCTAssertNil(c.submit(.pointer, "p2"))
        XCTAssertNil(c.submit(.follow, "f1"))
        var order: [String] = []
        while let next = c.finish() { order.append(next) }
        XCTAssertEqual(order, ["k1", "p2", "f1"])
    }

    func testIdleAgainAfterDrain() {
        var c = C()
        _ = c.submit(.keyboard, "k1")
        XCTAssertNil(c.submit(.keyboard, "k2"))
        XCTAssertEqual(c.finish(), "k2")
        XCTAssertNil(c.finish())
        XCTAssertEqual(c.submit(.follow, "f1"), "f1")
    }

    func testQueryKinds() {
        XCTAssertEqual(FocusTracker.Query.keyboard.kind, .keyboard)
        XCTAssertEqual(FocusTracker.Query.pointer(.zero).kind, .pointer)
        XCTAssertEqual(FocusTracker.Query.follow(.zero).kind, .follow)
    }
}
