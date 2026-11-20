import XCTest
@testable import RappRimeKeys

final class PressLedgerTests: XCTestCase {
  func testReleaseOnlyAfterTakenPress() {
    var l = PressLedger()
    XCTAssertFalse(l.release(hid: 4))              // never taken → Flutter gets the up
    l.took(hid: 4); XCTAssertTrue(l.release(hid: 4)); XCTAssertFalse(l.release(hid: 4))
  }

  func testForgetAll() {
    var l = PressLedger(); l.took(hid: 4); l.took(hid: 5)
    XCTAssertEqual(Set(l.forgetAll()), [4, 5]); XCTAssertFalse(l.release(hid: 4))
  }

  func testKeysAreIndependent() {
    var l = PressLedger(); l.took(hid: 4)
    XCTAssertFalse(l.release(hid: 5))
    XCTAssertTrue(l.release(hid: 4))
  }

  func testForgetAllEmptiesTheLedger() {
    var l = PressLedger(); l.took(hid: 4)
    _ = l.forgetAll()
    XCTAssertEqual(l.forgetAll(), [Int]())
  }

  /// A press that went to Flutter owns its release, even when an earlier press of the same key was taken
  /// (its release was lost, or the engine stopped while the key was held).
  func testPassedPressOwnsTheRelease() {
    var l = PressLedger(); l.took(hid: 4)
    l.passed(hid: 4)
    XCTAssertTrue(l.flutterHolds(hid: 4))
    XCTAssertFalse(l.release(hid: 4))
    XCTAssertFalse(l.flutterHolds(hid: 4))
  }

  func testFlutterHoldsSurvivesForgetAll() {
    var l = PressLedger(); l.passed(hid: 4); l.took(hid: 5)
    XCTAssertEqual(l.forgetAll(), [5])
    XCTAssertTrue(l.flutterHolds(hid: 4))
  }
}
