import XCTest
@testable import RappCore

final class FrameMarkTests: XCTestCase {
    func testSyncCellsAndBitOrder() {
        let c = FrameMark.cells(0b1000_0000_0000_0001)
        XCTAssertEqual(c.count, 18); XCTAssertTrue(c[0]); XCTAssertFalse(c[1])
        XCTAssertTrue(c[2]); XCTAssertTrue(c[17]); XCTAssertFalse(c[3])
    }
    func testRoundTripAllEdges() {
        for n: UInt16 in [0, 1, 255, 256, 65535, 12345] {
            let c = FrameMark.cells(n)
            XCTAssertEqual(FrameMark.read { c[$0] ? 20 : 235 }, n)
        }
    }
    func testReadRejectsWithoutSync() {
        XCTAssertNil(FrameMark.read { _ in 20 })
        XCTAssertNil(FrameMark.read { _ in 235 })
    }
    func testThresholdIs128() {
        let c = FrameMark.cells(0)
        XCTAssertEqual(FrameMark.read { c[$0] ? 127 : 128 }, 0)
        // bit 0 (cell 17) at 127 reads black = 1; at 128 reads white = 0.
        XCTAssertEqual(FrameMark.read { $0 == 17 ? 127 : (c[$0] ? 0 : 255) }, 1)
        XCTAssertEqual(FrameMark.read { $0 == 17 ? 128 : (c[$0] ? 0 : 255) }, 0)
    }
}
