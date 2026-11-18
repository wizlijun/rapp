import Foundation

/// The language speech recognition listens in: the first entry of the system's preferred languages.
///
/// `Locale.current` follows the app bundle's localizations, and the bundle only declares English, so a
/// Chinese system reports `en_CN` and the recogniser hears Chinese as English words. The system's own
/// language list (`Locale.preferredLanguages`) is used instead, first entry only; no fallback to Chinese.
public func speechLocale(preferred: [String]) -> Locale {
  Locale(identifier: normaliseSpeechLocale(preferred.first ?? "en-US"))
}

/// `zh-Hans-CN` → `zh-CN`, `zh-Hant` → `zh-TW`: the language-region form both recognisers know.
public func normaliseSpeechLocale(_ id: String) -> String {
  let language = Locale(identifier: id).language
  guard let code = language.languageCode?.identifier else { return id }
  var region = language.region?.identifier
  if region == nil, code == "zh" { region = language.script?.identifier == "Hant" ? "TW" : "CN" }
  return region.map { "\(code)-\($0)" } ?? code
}
