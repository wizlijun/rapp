import XCTest
@testable import RappCore

final class SendPacerTests: XCTestCase {
    /// Sends one frame at `at` and acks it `rtt` later (processing 0).
    private func exchange(_ p: inout SendPacer, at: TimeInterval, rtt: TimeInterval) {
        p.sent(at: at, captured: at)
        _ = p.acked(at: at + rtt, processingMs: 0)
    }

    func testCapIsOneBeforeAnySample() { XCTAssertEqual(SendPacer(fps: 30).cap(now: 0), 1) }

    func testLanCapIsTwo() {
        var p = SendPacer(fps: 30)
        for i in 0..<5 { exchange(&p, at: Double(i) * 0.1, rtt: 0.002) }
        XCTAssertEqual(p.cap(now: 0.5), 2)
    }

    func testCapAt80msAnd30fpsIsFour() {
        var p = SendPacer(fps: 30)
        for i in 0..<5 { exchange(&p, at: Double(i) * 0.1, rtt: 0.08) }
        XCTAssertEqual(p.cap(now: 0.6), 4)
    }

    func testCapClampedToOneSecondOfFrames() {
        var p = SendPacer(fps: 5)
        for i in 0..<5 { exchange(&p, at: Double(i), rtt: 3) }
        XCTAssertEqual(p.cap(now: 20), 5)
    }

    func testProcessingTimeIsSubtracted() {
        var p = SendPacer(fps: 30)
        p.sent(at: 0, captured: 0)
        let r = p.acked(at: 0.25, processingMs: 50)
        XCTAssertEqual(r?.rtt ?? -1, 0.2, accuracy: 1e-9)
    }

    func testLatencyIsAckMinusCapture() {
        var p = SendPacer(fps: 30)
        p.sent(at: 0.1, captured: 0)
        let r = p.acked(at: 0.4, processingMs: 0)
        XCTAssertEqual(r?.latency ?? -1, 0.4, accuracy: 1e-9)
    }

    func testQueueingWhenRttRisesOver100ms() {
        var p = SendPacer(fps: 30)
        exchange(&p, at: 0, rtt: 0.3)
        exchange(&p, at: 1, rtt: 0.45)
        XCTAssertTrue(p.queueing(now: 1.45))
        XCTAssertEqual(p.cap(now: 1.45), 1)
        exchange(&p, at: 2, rtt: 0.35)
        XCTAssertFalse(p.queueing(now: 2.35))
        XCTAssertGreaterThan(p.cap(now: 2.35), 1)
    }

    func testQueueingWhileOldestUnackedWaitsTooLong() {
        var p = SendPacer(fps: 30)
        exchange(&p, at: -1, rtt: 0.3)
        p.sent(at: 0, captured: 0)
        XCTAssertFalse(p.queueing(now: 0.3))
        XCTAssertTrue(p.queueing(now: 0.5))
    }

    func testBaseWindowIs10Seconds() {
        var p = SendPacer(fps: 30)
        exchange(&p, at: 0, rtt: 0.1)
        for i in 5...12 { exchange(&p, at: Double(i), rtt: 0.3) }
        XCTAssertEqual(p.baseRtt(now: 9)!, 0.1, accuracy: 1e-9)
        XCTAssertEqual(p.baseRtt(now: 11)!, 0.3, accuracy: 1e-9)
    }

    func testPostOutageAckDoesNotBecomeBase() {
        var p = SendPacer(fps: 30)
        for i in 0...200 { exchange(&p, at: Double(i) * 0.1, rtt: 0.3) }
        p.sent(at: 20, captured: 20)
        _ = p.acked(at: 31, processingMs: 0)
        XCTAssertEqual(p.baseRtt(now: 31)!, 0.3, accuracy: 1e-9)
        XCTAssertEqual(p.cap(now: 31), 1)
        exchange(&p, at: 31, rtt: 0.3)
        XCTAssertEqual(p.cap(now: 31.3), 10)
    }

    func testExtraAckIgnored() {
        var p = SendPacer(fps: 30)
        XCTAssertNil(p.acked(at: 1, processingMs: 0))
        XCTAssertEqual(p.inFlight, 0)
        XCTAssertNil(p.lastRtt)
    }

    func testAcksMatchOldestFirstAndResetClears() {
        var p = SendPacer(fps: 30)
        p.sent(at: 0, captured: 0)
        p.sent(at: 1, captured: 1)
        XCTAssertEqual(p.inFlight, 2)
        XCTAssertEqual(p.acked(at: 1.2, processingMs: 0)?.rtt ?? -1, 1.2, accuracy: 1e-9)
        XCTAssertEqual(p.inFlight, 1)
        p.reset()
        XCTAssertEqual(p.inFlight, 0)
        XCTAssertNil(p.baseRtt(now: 2))
    }
}
