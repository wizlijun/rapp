import XCTest
@testable import RappSession

final class SpeechLanguageTests: XCTestCase {
  func testFirstPreferredLanguageOnly() {
    XCTAssertEqual(speechLocale(preferred: ["en-US", "zh-Hans-CN"]).identifier, "en-US")
  }
  func testChineseNormalised() {
    XCTAssertEqual(speechLocale(preferred: ["zh-Hans-CN"]).identifier, "zh-CN")
    XCTAssertEqual(normaliseSpeechLocale("zh-Hant-TW"), "zh-TW")
  }
  func testEmptyListFallsBackToEnglish() {
    XCTAssertEqual(speechLocale(preferred: []).identifier, "en-US")
  }
  func testNoChineseFallback() {
    XCTAssertEqual(speechLocale(preferred: ["ja-JP"]).identifier, "ja-JP")
  }
}
