import XCTest
@testable import RappRimeKeys

final class RimeKeyMapTests: XCTestCase {
  func testLetters() { XCTAssertEqual(RimeKeyMap.map(hid: 0x04, characters: "a", ignoringModifiers: "a", modifiers: 0), RimeKey(keysym: 0x61, mask: 0)) }
  func testShiftedDigitIsItsSymbol() { XCTAssertEqual(RimeKeyMap.map(hid: 0x1E, characters: "!", ignoringModifiers: "1", modifiers: 0x20000), RimeKey(keysym: 0x21, mask: 1)) }
  func testCommandUsesUnmodified() { XCTAssertEqual(RimeKeyMap.map(hid: 0x04, characters: "å", ignoringModifiers: "a", modifiers: 0x100000), RimeKey(keysym: 0x61, mask: 1 << 26)) }
  func testSpecials() {
    for (hid, sym) in [(0x2A, 0xff08), (0x28, 0xff0d), (0x29, 0xff1b), (0x50, 0xff51), (0x51, 0xff54), (0x4B, 0xff55), (0x4E, 0xff56), (0x2C, 0x20)] {
      XCTAssertEqual(RimeKeyMap.map(hid: hid, characters: "", ignoringModifiers: "", modifiers: 0)?.keysym, Int32(sym))
    }
  }
  func testAllSpecials() {
    let table: [(Int, Int)] = [(0x2A, 0xff08), (0x2B, 0xff09), (0x28, 0xff0d), (0x58, 0xff8d), (0x29, 0xff1b), (0x4C, 0xffff),
      (0x4A, 0xff50), (0x50, 0xff51), (0x52, 0xff52), (0x4F, 0xff53), (0x51, 0xff54), (0x4B, 0xff55), (0x4E, 0xff56), (0x4D, 0xff57),
      (0xE1, 0xffe1), (0xE5, 0xffe2), (0xE0, 0xffe3), (0xE4, 0xffe4), (0x39, 0xffe5), (0xE2, 0xffe9), (0xE6, 0xffea), (0xE3, 0xffeb), (0xE7, 0xffec), (0x2C, 0x20)]
    for (hid, sym) in table {
      XCTAssertEqual(RimeKeyMap.map(hid: hid, characters: "", ignoringModifiers: "", modifiers: 0)?.keysym, Int32(sym), "hid \(hid)")
    }
  }
  func testShiftKeyItself() { XCTAssertEqual(RimeKeyMap.map(hid: 0xE1, characters: "", ignoringModifiers: "", modifiers: 0x20000), RimeKey(keysym: 0xffe1, mask: 1)) }
  func testMasks() {
    XCTAssertEqual(RimeKeyMap.map(hid: 0x04, characters: "a", ignoringModifiers: "a", modifiers: 0x10000)?.mask, 2)
    XCTAssertEqual(RimeKeyMap.map(hid: 0x04, characters: "\u{1}", ignoringModifiers: "a", modifiers: 0x40000), RimeKey(keysym: 0x61, mask: 4))
    XCTAssertEqual(RimeKeyMap.map(hid: 0x04, characters: "å", ignoringModifiers: "a", modifiers: 0x80000), RimeKey(keysym: 0x61, mask: 8))
  }
  func testUnknown() {
    XCTAssertNil(RimeKeyMap.map(hid: 0x3A, characters: "UIKeyInputF1", ignoringModifiers: "UIKeyInputF1", modifiers: 0)) // F1
    XCTAssertNil(RimeKeyMap.map(hid: 0x08, characters: "é", ignoringModifiers: "é", modifiers: 0))
  }
  func testTypedText() {
    XCTAssertEqual(RimeKeyMap.typedText(characters: "A", modifiers: 0x20000), "A")
    XCTAssertNil(RimeKeyMap.typedText(characters: "a", modifiers: 0x100000))
    XCTAssertNil(RimeKeyMap.typedText(characters: "a", modifiers: 0x40000))
    XCTAssertNil(RimeKeyMap.typedText(characters: "a", modifiers: 0x80000))
    XCTAssertNil(RimeKeyMap.typedText(characters: "\r", modifiers: 0))
    XCTAssertNil(RimeKeyMap.typedText(characters: "ab", modifiers: 0))
    XCTAssertEqual(RimeKeyMap.typedText(characters: " ", modifiers: 0), " ")
  }
  /// What a declined replayed key becomes: printable text goes through Dart, ⌫ and other non-text keys do not.
  func testReplayTextDecision() {
    XCTAssertEqual(RimeKeyMap.typedText(characters: "1", modifiers: 0), "1")
    XCTAssertEqual(RimeKeyMap.typedText(characters: ",", modifiers: 0), ",")
    XCTAssertNil(RimeKeyMap.typedText(characters: "\u{8}", modifiers: 0))   // ⌫
    XCTAssertNil(RimeKeyMap.typedText(characters: "\u{7f}", modifiers: 0))  // delete
    XCTAssertNil(RimeKeyMap.typedText(characters: "\u{1b}", modifiers: 0))  // Esc
    XCTAssertNil(RimeKeyMap.typedText(characters: "", modifiers: 0))         // arrows and other keys with no text
  }
  func testModifiers() { XCTAssertTrue(RimeKeyMap.isModifier(hid: 0xE1)); XCTAssertTrue(RimeKeyMap.isModifier(hid: 0x39)); XCTAssertFalse(RimeKeyMap.isModifier(hid: 0x04)) }
  func testRepeatPolicy() {
    var p = RepeatPolicy()
    XCTAssertFalse(p.began(hid: 4)); XCTAssertTrue(p.ownRepeat)
    XCTAssertTrue(p.began(hid: 4)); XCTAssertFalse(p.ownRepeat)
    p.ended(hid: 4); XCTAssertFalse(p.began(hid: 4)); XCTAssertFalse(p.ownRepeat)  // once seen, stays off
  }

  func testRepeatPolicyEndAll() {
    var p = RepeatPolicy()
    XCTAssertFalse(p.began(hid: 4)); XCTAssertFalse(p.began(hid: 5))
    p.endAll()  // both releases were lost
    XCTAssertFalse(p.began(hid: 4)); XCTAssertFalse(p.began(hid: 5)); XCTAssertTrue(p.ownRepeat)
  }
}
