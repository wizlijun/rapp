import XCTest
@testable import RappCore

final class WeakTierTests: XCTestCase {
    func testLadderDownEveryThreeSecondsUpEveryThirty() {
        var t = WeakTier()
        t.steps = [1, 2]
        XCTAssertNil(t.observe(now: 0, queueing: true, onAck: true))
        XCTAssertNil(t.observe(now: 2.9, queueing: true, onAck: true))
        XCTAssertEqual(t.observe(now: 3, queueing: true, onAck: true), 1)
        XCTAssertTrue(t.weak)
        XCTAssertNil(t.observe(now: 5.9, queueing: true, onAck: true))
        XCTAssertEqual(t.observe(now: 6, queueing: true, onAck: true), 2)
        XCTAssertNil(t.observe(now: 20, queueing: true, onAck: true))
        XCTAssertNil(t.observe(now: 49.9, queueing: false, onAck: true))
        XCTAssertEqual(t.observe(now: 50, queueing: false, onAck: true), 1)
        XCTAssertNil(t.observe(now: 79.9, queueing: false, onAck: true))
        XCTAssertEqual(t.observe(now: 80, queueing: false, onAck: true), 0)
        XCTAssertFalse(t.weak)
        XCTAssertNil(t.observe(now: 200, queueing: false, onAck: true))
    }

    func testShortQueueingDoesNotEnter() {
        var t = WeakTier()
        XCTAssertNil(t.observe(now: 0, queueing: true, onAck: true))
        XCTAssertNil(t.observe(now: 2.9, queueing: true, onAck: true))
        XCTAssertNil(t.observe(now: 3.0, queueing: false, onAck: true))
        XCTAssertNil(t.observe(now: 4, queueing: true, onAck: true))
        XCTAssertNil(t.observe(now: 6.9, queueing: true, onAck: true))
        XCTAssertEqual(t.level, 0)
    }

    func testIdleDoesNotGoUp() {
        var t = WeakTier()
        t.steps = [2]
        _ = t.observe(now: 7, queueing: true, onAck: true)
        XCTAssertEqual(t.observe(now: 10, queueing: true, onAck: true), 2)
        for s in stride(from: 11.0, through: 70.0, by: 1.0) {
            XCTAssertNil(t.observe(now: s, queueing: false, onAck: false))
        }
        XCTAssertEqual(t.level, 2)
    }

    func testPinnedGoesBackToZeroAndStays() {
        var t = WeakTier()
        _ = t.observe(now: 0, queueing: true, onAck: true)
        _ = t.observe(now: 3, queueing: true, onAck: true)
        XCTAssertEqual(t.level, 1)
        t.pinned = true
        XCTAssertEqual(t.level, 0)
        for s in 4...14 { XCTAssertNil(t.observe(now: Double(s), queueing: true, onAck: true)) }
        XCTAssertNil(t.probe(firstAckDelay: 2.0))
        XCTAssertEqual(t.level, 0)
    }

    func testSlowFirstSliceStartsAtTheLastStep() {
        var a = WeakTier()
        a.steps = [1, 2]
        XCTAssertEqual(a.probe(firstAckDelay: 1.01), 2)
        var t = WeakTier()
        XCTAssertNil(t.probe(firstAckDelay: 0.9))
        XCTAssertEqual(t.level, 0)
        var none = WeakTier()
        none.steps = []
        XCTAssertNil(none.probe(firstAckDelay: 3))
    }

    func testProbeEnteredGoesUpAfter30sWithoutQueueing() {
        var t = WeakTier()
        t.steps = [2]
        XCTAssertEqual(t.probe(firstAckDelay: 1.5), 2)
        XCTAssertNil(t.observe(now: 0, queueing: false, onAck: true))
        XCTAssertNil(t.observe(now: 29.9, queueing: false, onAck: true))
        XCTAssertEqual(t.observe(now: 30, queueing: false, onAck: true), 0)
    }

    func testNewStepsKeepTheLevelUnlessItIsGone() {
        var t = WeakTier()
        t.steps = [1, 2]
        _ = t.probe(firstAckDelay: 2)
        XCTAssertNil(t.setSteps([1, 2]))
        XCTAssertEqual(t.setSteps([1]), 1)
        var u = WeakTier()
        _ = u.observe(now: 0, queueing: true, onAck: true)
        _ = u.observe(now: 3, queueing: true, onAck: true)
        XCTAssertEqual(u.level, 1)
        // A ceiling at 5 fps or less: level 1 saves nothing, so it is the ceiling itself.
        XCTAssertEqual(u.setSteps([2]), 0)
    }
}
