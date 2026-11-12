import XCTest
@testable import RappCore

final class StayAwakeTests: XCTestCase {
    private var holds = 0
    private var released: [UInt32] = []

    private func make(granted: Bool = true) -> StayAwake {
        StayAwake(hold: { [unowned self] in
            holds += 1
            return granted ? UInt32(holds) : nil
        }, release: { [unowned self] in released.append($0) })
    }

    func testBeginHoldsOnceAndEndReleasesThatHold() {
        let awake = make()
        awake.begin(); awake.begin()
        XCTAssertEqual(holds, 1)
        awake.end(); awake.end()
        XCTAssertEqual(released, [1])
    }

    func testEndWithoutBeginReleasesNothing() {
        make().end()
        XCTAssertEqual(holds, 0)
        XCTAssertTrue(released.isEmpty)
    }

    func testRefusedHoldReleasesNothing() {
        let awake = make(granted: false)
        awake.begin()
        awake.end()
        XCTAssertEqual(holds, 1)
        XCTAssertTrue(released.isEmpty)
    }

    func testANewSessionHoldsAgain() {
        let awake = make()
        awake.begin(); awake.end()
        awake.begin(); awake.end()
        XCTAssertEqual(released, [1, 2])
    }
}
