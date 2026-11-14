import XCTest
@testable import RappCore

final class PathProbeTests: XCTestCase {
    func testPingsAtOnceThenEveryTenSeconds() {
        var p = PathProbe()
        XCTAssertEqual(p.tick(now: 0).ping, 1)
        XCTAssertEqual(p.pong(seq: 1, now: 0.08), 80)
        for s in 1...9 { XCTAssertNil(p.tick(now: Double(s)).ping) }
        XCTAssertEqual(p.tick(now: 10).ping, 2)
    }

    func testInputPingsEveryTwoSeconds() {
        var p = PathProbe()
        _ = p.tick(now: 0)
        _ = p.pong(seq: 1, now: 0.05)
        p.input(now: 1)
        XCTAssertEqual(p.tick(now: 2).ping, 2)
        _ = p.pong(seq: 2, now: 2.05)
        XCTAssertNil(p.tick(now: 3).ping)
        XCTAssertEqual(p.tick(now: 4).ping, 3)
        // Five seconds after the last input it is idle again.
        _ = p.pong(seq: 3, now: 4.05)
        XCTAssertNil(p.tick(now: 6).ping)
        XCTAssertNil(p.tick(now: 13).ping)
        XCTAssertEqual(p.tick(now: 14).ping, 4)
    }

    func testTwoUnansweredPingsAreStalledAndAnythingFromAEndsIt() {
        var p = PathProbe()
        _ = p.tick(now: 0)
        _ = p.pong(seq: 1, now: 0.05)
        XCTAssertEqual(p.tick(now: 10).ping, 2)
        XCTAssertNil(p.tick(now: 11).stalled)
        let a = p.tick(now: 12)
        XCTAssertEqual(a.ping, 3)
        XCTAssertNil(a.stalled)
        XCTAssertEqual(p.tick(now: 14).stalled, true)
        XCTAssertNil(p.tick(now: 16).stalled)
        XCTAssertEqual(p.received(now: 16.5), false)
        XCTAssertNil(p.received(now: 16.6))
    }

    func testFramesArrivingMeanTheLinkIsUp() {
        var p = PathProbe()
        _ = p.tick(now: 0)
        for s in 1...20 {
            XCTAssertNil(p.received(now: Double(s) - 0.5))
            XCTAssertNil(p.tick(now: Double(s)).stalled)
        }
    }

    func testAnOldPongGivesNoRoundTrip() {
        var p = PathProbe()
        _ = p.tick(now: 0)
        _ = p.tick(now: 2)
        _ = p.tick(now: 4)
        XCTAssertNil(p.pong(seq: 1, now: 4.5))
        XCTAssertEqual(p.pong(seq: 3, now: 4.6), 600)
    }
}
