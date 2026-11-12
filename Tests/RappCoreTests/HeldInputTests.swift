import XCTest
@testable import RappCore

final class HeldInputTests: XCTestCase {
    func testPairsLeaveNothingHeld() {
        var held = HeldInput()
        held.pressKey(55); held.releaseKey(55)
        held.pressButton(.left); held.releaseButton(.left)
        let (keys, buttons) = held.drain()
        XCTAssertTrue(keys.isEmpty)
        XCTAssertTrue(buttons.isEmpty)
    }

    func testHeldKeyAndButtonComeBackOnce() {
        var held = HeldInput()
        held.pressKey(55); held.pressButton(.right)
        let (keys, buttons) = held.drain()
        XCTAssertEqual(keys, [55])
        XCTAssertEqual(buttons, [.right])
        let again = held.drain()
        XCTAssertTrue(again.keys.isEmpty)
        XCTAssertTrue(again.buttons.isEmpty)
    }

    func testRepeatedDownCountsOnce() {
        var held = HeldInput()
        held.pressKey(0); held.pressKey(0); held.pressKey(0)
        XCTAssertEqual(held.drain().keys, [0])
        held.pressKey(0); held.releaseKey(0)
        XCTAssertTrue(held.drain().keys.isEmpty)
    }

    func testDrainIsSortedAndComplete() {
        var held = HeldInput()
        held.pressKey(55); held.pressKey(3); held.pressKey(12)
        XCTAssertEqual(held.drain().keys, [3, 12, 55])
    }

    func testDroppedButtonIsNotTracked() {
        // The injector only calls pressButton for a down it actually posted;
        // a dropped down, its drags and its up never reach HeldInput.
        var held = HeldInput()
        held.releaseButton(.left)
        XCTAssertTrue(held.drain().buttons.isEmpty)
    }
}
