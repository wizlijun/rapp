import XCTest
@testable import RappCore

final class HIDKeysTests: XCTestCase {
    func testMacKeyCodes() {
        XCTAssertEqual(macKeyCode(hidUsage: 0x04), 0)    // a
        XCTAssertEqual(macKeyCode(hidUsage: 0x1D), 6)    // z
        XCTAssertEqual(macKeyCode(hidUsage: 0x28), 36)   // return
        XCTAssertEqual(macKeyCode(hidUsage: 0x29), 53)   // esc
        XCTAssertEqual(macKeyCode(hidUsage: 0x2A), 51)   // delete
        XCTAssertEqual(macKeyCode(hidUsage: 0x2B), 48)   // tab
        XCTAssertEqual(macKeyCode(hidUsage: 0x4F), 124)  // right
        XCTAssertEqual(macKeyCode(hidUsage: 0x50), 123)  // left
        XCTAssertEqual(macKeyCode(hidUsage: 0xE3), 55)   // left command
        XCTAssertEqual(macKeyCode(hidUsage: 0xE7), 54)   // right command
        XCTAssertNil(macKeyCode(hidUsage: 0xFFFF))
    }

    func testMoreKeys() {
        XCTAssertEqual(macKeyCode(hidUsage: 0x1E), 18)   // 1
        XCTAssertEqual(macKeyCode(hidUsage: 0x27), 29)   // 0
        XCTAssertEqual(macKeyCode(hidUsage: 0x2C), 49)   // space
        XCTAssertEqual(macKeyCode(hidUsage: 0x3A), 122)  // F1
        XCTAssertEqual(macKeyCode(hidUsage: 0x45), 111)  // F12
        XCTAssertEqual(macKeyCode(hidUsage: 0x4C), 117)  // forward delete
        XCTAssertEqual(macKeyCode(hidUsage: 0x39), 57)   // caps lock
    }

    func testUIModifiersKeepOnlyTheFiveBits() {
        // command | shift | numericPad -> command and shift only
        XCTAssertEqual(keyFlags(uiModifiers: 1 << 20 | 1 << 17 | 1 << 21), 0x120000)
    }
}
