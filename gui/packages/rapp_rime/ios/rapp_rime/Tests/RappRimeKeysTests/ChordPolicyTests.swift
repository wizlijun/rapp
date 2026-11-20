import XCTest
@testable import RappRimeKeys

final class ChordPolicyTests: XCTestCase {
  let shift = 0x20000, control = 0x40000, command = 0x100000

  /// Shift+F1: unmapped, so the engine never sees it; without the VoidSymbol, Shift's release toggles 中/英.
  func testShiftWithAKeyTheEngineMissed() {
    XCTAssertTrue(ChordPolicy.interrupts(hid: 0x3A, modifiers: shift, reachedEngine: false))
    XCTAssertTrue(ChordPolicy.interrupts(hid: 0x3A, modifiers: control, reachedEngine: false))
  }

  func testAKeyTheEngineSawNeedsNothing() {
    XCTAssertFalse(ChordPolicy.interrupts(hid: 0x04, modifiers: shift, reachedEngine: true))
  }

  func testNoShiftOrControlNeedsNothing() {
    XCTAssertFalse(ChordPolicy.interrupts(hid: 0x3A, modifiers: 0, reachedEngine: false))
    XCTAssertFalse(ChordPolicy.interrupts(hid: 0x3A, modifiers: command, reachedEngine: false))
  }

  /// The other Shift, or Shift's own system repeat: modifiers are the engine's business already.
  func testModifierKeysNeedNothing() {
    XCTAssertFalse(ChordPolicy.interrupts(hid: 0xE5, modifiers: shift, reachedEngine: false))
    XCTAssertFalse(ChordPolicy.interrupts(hid: 0xE1, modifiers: shift, reachedEngine: false))
  }
}
