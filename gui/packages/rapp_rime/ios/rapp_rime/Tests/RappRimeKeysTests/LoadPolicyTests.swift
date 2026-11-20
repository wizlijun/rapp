import XCTest
@testable import RappRimeKeys

final class LoadPolicyTests: XCTestCase {
  /// Switch on with a keyboard: wanted at once, with no focus involved (the first replay after a launch).
  func testLoadsAtConfigureWithAKeyboard() {
    XCTAssertTrue(LoadPolicy.wanted(was: false, enabled: true, keyboard: true))
  }

  func testNoKeyboardNoLoad() {
    XCTAssertFalse(LoadPolicy.wanted(was: false, enabled: true, keyboard: false))
  }

  func testSwitchOffReleases() {
    XCTAssertFalse(LoadPolicy.wanted(was: true, enabled: false, keyboard: true))
    XCTAssertFalse(LoadPolicy.wanted(was: false, enabled: false, keyboard: true))
  }

  /// A keyboard going away leaves a loaded engine loaded.
  func testKeyboardDisconnectKeepsIt() {
    XCTAssertTrue(LoadPolicy.wanted(was: true, enabled: true, keyboard: false))
  }

  /// Switch on with no keyboard, then one connects.
  func testKeyboardConnectLoads() {
    var w = LoadPolicy.wanted(was: false, enabled: true, keyboard: false)
    w = LoadPolicy.wanted(was: w, enabled: true, keyboard: true)
    XCTAssertTrue(w)
  }
}
