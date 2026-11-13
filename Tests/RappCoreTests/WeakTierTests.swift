import XCTest
@testable import RappCore

final class WeakTierTests: XCTestCase {
    func testEntersAfterThreeSecondsOfQueueing() {
        var t = WeakTier()
        XCTAssertNil(t.observe(now: 0, queueing: true, onAck: true))
        XCTAssertNil(t.observe(now: 1, queueing: true, onAck: true))
        XCTAssertNil(t.observe(now: 2, queueing: true, onAck: true))
        XCTAssertEqual(t.observe(now: 3.0, queueing: true, onAck: true), true)
        XCTAssertTrue(t.weak)
        XCTAssertNil(t.observe(now: 4, queueing: true, onAck: true))
    }

    func testShortQueueingDoesNotEnter() {
        var t = WeakTier()
        XCTAssertNil(t.observe(now: 0, queueing: true, onAck: true))
        XCTAssertNil(t.observe(now: 2.9, queueing: true, onAck: true))
        XCTAssertNil(t.observe(now: 3.0, queueing: false, onAck: true))
        XCTAssertNil(t.observe(now: 4, queueing: true, onAck: true))
        XCTAssertNil(t.observe(now: 6.9, queueing: true, onAck: true))
        XCTAssertFalse(t.weak)
    }

    func testLeavesOnAckAfter30sWithoutQueueing() {
        var t = WeakTier()
        _ = t.observe(now: 7, queueing: true, onAck: true)
        XCTAssertEqual(t.observe(now: 10, queueing: true, onAck: true), true)
        XCTAssertNil(t.observe(now: 39.9, queueing: false, onAck: true))
        XCTAssertEqual(t.observe(now: 40, queueing: false, onAck: true), false)
        XCTAssertFalse(t.weak)
    }

    func testIdleDoesNotLeave() {
        var t = WeakTier()
        _ = t.observe(now: 7, queueing: true, onAck: true)
        _ = t.observe(now: 10, queueing: true, onAck: true)
        for s in stride(from: 11.0, through: 70.0, by: 1.0) {
            XCTAssertNil(t.observe(now: s, queueing: false, onAck: false))
        }
        XCTAssertTrue(t.weak)
    }

    func testPinnedNeverEntersAndLeavesAtOnce() {
        var t = WeakTier()
        _ = t.observe(now: 0, queueing: true, onAck: true)
        _ = t.observe(now: 3, queueing: true, onAck: true)
        XCTAssertTrue(t.weak)
        t.pinned = true
        XCTAssertFalse(t.weak)
        for s in 4...14 { XCTAssertNil(t.observe(now: Double(s), queueing: true, onAck: true)) }
        XCTAssertFalse(t.weak)
        XCTAssertNil(t.probe(firstAckDelay: 2.0))
    }

    func testProbe() {
        var a = WeakTier()
        XCTAssertEqual(a.probe(firstAckDelay: 1.01), true)
        XCTAssertTrue(a.weak)
        var t = WeakTier()
        XCTAssertNil(t.probe(firstAckDelay: 0.9))
        XCTAssertFalse(t.weak)
    }
}
