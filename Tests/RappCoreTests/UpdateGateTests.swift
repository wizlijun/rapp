import Foundation
import XCTest
@testable import RappCore

/// Shared, lock-protected record of what the gate's work saw.
private final class Probe: @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    private(set) var maxActive = 0
    private(set) var runs = 0
    private(set) var lastSeen = -1
    private var state = 0

    func setState(_ value: Int) { lock.withLock { state = value } }

    func work() async {
        let seen: Int = lock.withLock {
            active += 1
            maxActive = max(maxActive, active)
            runs += 1
            return state
        }
        try? await Task.sleep(nanoseconds: 2_000_000)
        lock.withLock {
            lastSeen = seen
            active -= 1
        }
    }

    var snapshot: (maxActive: Int, runs: Int, lastSeen: Int, state: Int) {
        lock.withLock { (maxActive, runs, lastSeen, state) }
    }
}

final class UpdateGateTests: XCTestCase {
    func testRequestBeforeOpenRunsWhenOpened() async {
        let gate = UpdateGate(), probe = Probe()
        probe.setState(7)
        await gate.request()
        XCTAssertEqual(probe.snapshot.runs, 0)
        let opened = await gate.open { await probe.work() }
        XCTAssertTrue(opened)
        XCTAssertEqual(probe.snapshot.runs, 1)
        XCTAssertEqual(probe.snapshot.lastSeen, 7)
    }

    func testOpenWithoutRequestRunsNothing() async {
        let gate = UpdateGate(), probe = Probe()
        _ = await gate.open { await probe.work() }
        XCTAssertEqual(probe.snapshot.runs, 0)
    }

    func testWorkNeverOverlapsAndSeesTheLatestState() async {
        let gate = UpdateGate(), probe = Probe()
        _ = await gate.open { await probe.work() }
        await withTaskGroup(of: Void.self) { group in
            for i in 1...20 {
                group.addTask {
                    probe.setState(i)
                    await gate.request()
                }
            }
        }
        let s = probe.snapshot
        XCTAssertEqual(s.maxActive, 1)
        XCTAssertEqual(s.lastSeen, s.state, "the last run must have read the last state written")
        XCTAssertLessThanOrEqual(s.runs, 20)
    }

    func testClosedGateRefusesToOpenAndRunsNothing() async {
        let gate = UpdateGate(), probe = Probe()
        await gate.request()
        gate.close()
        let opened = await gate.open { await probe.work() }
        XCTAssertFalse(opened)
        await gate.request()
        XCTAssertEqual(probe.snapshot.runs, 0)
    }

    func testCloseStopsLaterRequests() async {
        let gate = UpdateGate(), probe = Probe()
        _ = await gate.open { await probe.work() }
        await gate.request()
        gate.close()
        await gate.request()
        XCTAssertEqual(probe.snapshot.runs, 1)
    }
}
