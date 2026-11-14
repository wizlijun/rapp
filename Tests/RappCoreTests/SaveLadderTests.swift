import XCTest
@testable import RappCore

final class SaveLadderTests: XCTestCase {
    private let best = StreamSpec(mode: .color16, fps: 30, density: 2)

    func testLevelsGoDownFromTheCeiling() {
        XCTAssertEqual(SaveLadder.stream(level: 0, ceiling: best), best)
        XCTAssertEqual(SaveLadder.stream(level: 1, ceiling: best), StreamSpec(mode: .color16, fps: 5, density: 2))
        XCTAssertEqual(SaveLadder.stream(level: 2, ceiling: best), StreamSpec(mode: .duogray, fps: 5, density: 1))
        XCTAssertEqual(SaveLadder.steps(ceiling: best), [1, 2])
    }

    func testALevelThatSavesNothingIsSkipped() {
        let slow = StreamSpec(mode: .gray4, fps: 5, density: 2)
        XCTAssertEqual(SaveLadder.steps(ceiling: slow), [2])
        let floor = StreamSpec(mode: .duogray, fps: 1, density: 0.5)
        XCTAssertEqual(SaveLadder.steps(ceiling: floor), [])
        // Never above the ceiling: a low ceiling fps or density stays.
        XCTAssertEqual(SaveLadder.stream(level: 2, ceiling: floor), floor)
    }
}
