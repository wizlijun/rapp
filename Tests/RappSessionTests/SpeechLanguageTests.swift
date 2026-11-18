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
  /// iOS: an English UI with Chinese further down the list still listens in Chinese.
  func testChineseFirstPicksChineseFromLaterInTheList() {
    XCTAssertEqual(speechLocale(preferred: ["en-US", "zh-Hans-CN"], chineseFirst: true).identifier, "zh-CN")
    XCTAssertEqual(speechLocale(preferred: ["en-US", "ja-JP", "zh-Hant-TW"], chineseFirst: true).identifier, "zh-TW")
  }
  func testChineseFirstWithoutChineseKeepsTheFirstLanguage() {
    XCTAssertEqual(speechLocale(preferred: ["en-US", "ja-JP"], chineseFirst: true).identifier, "en-US")
    XCTAssertEqual(speechLocale(preferred: [], chineseFirst: true).identifier, "en-US")
  }
}
