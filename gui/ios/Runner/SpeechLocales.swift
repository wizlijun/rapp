import Foundation

/// Which languages speech recognition tries, best first.
///
/// `Locale.current` follows the app bundle's localizations, and the bundle only declares English, so a
/// Chinese phone reports `en_CN` and the recogniser hears Chinese as English words. The device's own
/// language list (`Locale.preferredLanguages`) is used instead. Chinese entries come first, because the
/// app is Chinese. The other entries follow in the device's order, and zh-CN comes last as the fallback.
enum SpeechLocales {
  static func candidates(_ preferred: [String]) -> [Locale] {
    let ids = preferred.map(normalise)
    let chinese = ids.filter { $0.hasPrefix("zh") }
    var seen = Set<String>()
    return (chinese + ids + ["zh-CN"])
      .filter { seen.insert($0).inserted }
      .map { Locale(identifier: $0) }
  }

  /// `zh-Hans-CN` → `zh-CN`, `zh-Hant` → `zh-TW`: the language-region form both recognisers know.
  static func normalise(_ id: String) -> String {
    let language = Locale(identifier: id).language
    guard let code = language.languageCode?.identifier else { return id }
    var region = language.region?.identifier
    if region == nil, code == "zh" { region = language.script?.identifier == "Hant" ? "TW" : "CN" }
    return region.map { "\(code)-\($0)" } ?? code
  }
}
