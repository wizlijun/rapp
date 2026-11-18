import Foundation

/// The language speech recognition listens in: the first entry of the system's preferred languages, or,
/// with `chineseFirst` (iOS), the first Chinese entry when the list has one.
///
/// `Locale.current` follows the app bundle's localizations, and the bundle only declares English, so a
/// Chinese system reports `en_CN` and the recogniser hears Chinese as English words. The system's own
/// language list (`Locale.preferredLanguages`) is used instead. On iOS an English UI with a Chinese keyboard
/// is common, so a Chinese entry anywhere in the list wins there; macOS follows the first entry only.
public func speechLocale(preferred: [String], chineseFirst: Bool = false) -> Locale {
  let chinese = chineseFirst ? preferred.first { Locale(identifier: $0).language.languageCode?.identifier == "zh" } : nil
  return Locale(identifier: normaliseSpeechLocale(chinese ?? preferred.first ?? "en-US"))
}

/// `zh-Hans-CN` → `zh-CN`, `zh-Hant` → `zh-TW`: the language-region form both recognisers know.
public func normaliseSpeechLocale(_ id: String) -> String {
  let language = Locale(identifier: id).language
  guard let code = language.languageCode?.identifier else { return id }
  var region = language.region?.identifier
  if region == nil, code == "zh" { region = language.script?.identifier == "Hant" ? "TW" : "CN" }
  return region.map { "\(code)-\($0)" } ?? code
}
