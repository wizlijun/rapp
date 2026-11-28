#if !RAPP_SPEECH_WX
import AVFoundation
import RappSession
import Speech

func makeSpeechEngine() -> SpeechEngine { SpeechEngineApple() }

/// The system's recognisers, moved here unchanged from SpeechPlugin.swift (wx offline ASR design §5.3).
/// iOS 26+ uses SpeechAnalyzer + DictationTranscriber; older systems (or no transcriber for the locale) use
/// SFSpeechRecognizer.
final class SpeechEngineApple: SpeechEngine {
  weak var plugin: SpeechPlugin?
  let name = "apple"
  /// How long after `stop` this side gives up on the recogniser and sends `final` with what it has.
  /// Dart waits 1 s, so this lands just before.
  let finalGrace: TimeInterval = 0.9
  let dartWait: TimeInterval = 1
  let deniedText = "需要麦克风和语音识别权限"
  let unavailableText = "这种系统语言暂不支持语音识别，可以在系统设置里换一种"

  /// The language to recognise, from the system's preferred languages (not `Locale.current`, which is English
  /// here): a Chinese entry anywhere in the list comes first, on iOS and macOS alike (user, 2026-11-25).
  private static var locale: Locale { speechLocale(preferred: Locale.preferredLanguages, chineseFirst: true) }

  /// A speech model download is under way (iOS 26+); starts reply `preparing` until it ends.
  private var assetsInstalling = false
  /// What the last analyzer start learned about `key` (a `Self.locale.identifier`), so the next press skips
  /// those lookups (iOS 26+). Replaced when the language changes; dropped when the assets turn out missing.
  private var analyzerCache: AnalyzerCache?

  func prepare(localDir: String?) {}

  // MARK: - Permissions (the microphone's are SpeechPlugin's)

  func access() -> SpeechAccess {
    let speech = SFSpeechRecognizer.authorizationStatus()
    if speech == .denied || speech == .restricted { return .denied }
    if speech == .notDetermined { return .ask }
    return .granted
  }

  /// Speech recognition first, then (`then`) the microphone.
  func askAccess(then: @escaping () -> Void) {
    if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
      SFSpeechRecognizer.requestAuthorization { _ in DispatchQueue.main.async(execute: then) }
    } else {
      then()
    }
  }

  // MARK: - Start

  func start(_ gen: Int, hotwords: [String], pressedAt: TimeInterval, reply result: @escaping (String) -> Void) {
    if #available(iOS 26, macOS 26, *) {
      Task { @MainActor [weak self] in
        guard let self else { return result("cancelled") }
        if let reply = await self.startAnalyzer(gen, hotwords: hotwords, pressedAt: pressedAt) { return result(reply) }
        // No transcriber for this device or locale: the older recogniser may still work.
        result(gen == self.plugin?.generation ? self.startRecognizer(hotwords: hotwords, pressedAt: pressedAt) : "cancelled")
      }
    } else {
      result(startRecognizer(hotwords: hotwords, pressedAt: pressedAt))
    }
  }

  // MARK: - iOS 26+: SpeechAnalyzer

  /// The reply for Dart, or nil when the transcriber cannot serve this device or locale.
  @available(iOS 26, macOS 26, *)
  @MainActor
  private func startAnalyzer(_ gen: Int, hotwords: [String], pressedAt: TimeInterval) async -> String? {
    let key = Self.locale.identifier
    if analyzerCache?.key != key { analyzerCache = nil }
    let supported: Locale?
    if let cache = analyzerCache {
      supported = cache.locale
    } else {
      supported = await DictationTranscriber.supportedLocale(equivalentTo: Self.locale)
      analyzerCache = AnalyzerCache(key: key, locale: supported)
    }
    guard let locale = supported else { return nil }
    // DictationTranscriber, not SpeechTranscriber: with the hotwords it got the names and products right in
    // 17 of 30 probe clips against 4, at a lower error rate and no later first word (voice local fix spec §8,
    // D13). The progressive preset shows words while they are being said; the finalised text still corrects them.
    let preset = DictationTranscriber.Preset.progressiveLongDictation
    let transcriber = DictationTranscriber(
      locale: locale, contentHints: preset.contentHints, transcriptionOptions: preset.transcriptionOptions,
      reportingOptions: preset.reportingOptions, attributeOptions: preset.attributeOptions)

    if assetsInstalling { return "preparing" }
    if analyzerCache?.key == key, analyzerCache?.assetsInstalled == true {
      // Installed at an earlier press for this language: no need to ask again.
    } else {
      do {
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
          analyzerCache = nil
          assetsInstalling = true
          let download = Task.detached { try? await request.downloadAndInstall() }
          Task { @MainActor [weak self] in
            await download.value
            self?.assetsInstalling = false
          }
          return "preparing"
        }
        if analyzerCache?.key == key { analyzerCache?.assetsInstalled = true }
      } catch {
        analyzerCache = nil
        return nil
      }
    }
    let format: AVAudioFormat
    if analyzerCache?.key == key, let cached = analyzerCache?.format {
      format = cached
    } else {
      guard let found = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
        return nil
      }
      format = found
      if analyzerCache?.key == key { analyzerCache?.format = found }
    }

    let run = SpeechRun(startedAt: pressedAt)
    let analyzer = SpeechAnalyzer(modules: [transcriber])
    let (stream, input) = AsyncStream.makeStream(of: AnalyzerInput.self)
    run.finish = {
      input.finish()
      Task { try? await analyzer.finalizeAndFinishThroughEndOfInput() }
    }
    run.abort = {
      input.finish()
      Task { await analyzer.cancelAndFinishNow() }
    }
    // Volatile results replace each other; finalised ones accumulate. Ends when the analyzer finishes.
    Task { @MainActor [weak self] in
      var done = ""
      do {
        for try await result in transcriber.results {
          let text = String(result.text.characters)
          if result.isFinal { done += text }
          self?.plugin?.partial(run, result.isFinal ? done : done + text)
        }
        self?.plugin?.final(run, done)
      } catch {
        // A live run failing (not one cancelled or replaced): maybe the cached assets went away, so look
        // them up again next time.
        if let self, run === self.plugin?.run { self.analyzerCache = nil }
        self?.plugin?.failed(run)
      }
    }
    // The hotwords as the analysis context: DictationTranscriber leans toward them (probe P1/P2, voice local fix
    // spec §8: SpeechTranscriber ignored them, 4/30 clips right either way). Without them it still runs.
    if !hotwords.isEmpty {
      let context = AnalysisContext()
      context.contextualStrings[.general] = hotwords
      try? await analyzer.setContext(context)
    }
    do {
      try await analyzer.start(inputSequence: stream)
    } catch {
      analyzerCache = nil
      run.abort()
      return nil
    }
    guard gen == plugin?.generation else {
      run.abort()
      return "cancelled"
    }
    let started = plugin?.startAudio { mic in
      if mic == format { return { input.yield(AnalyzerInput(buffer: $0)) } }
      guard let converter = AVAudioConverter(from: mic, to: format) else { return nil }
      return { buffer in
        if let converted = SpeechAudio.convert(buffer, with: converter) { input.yield(AnalyzerInput(buffer: converted)) }
      }
    } ?? false
    guard started else {
      run.abort()
      return "unavailable"
    }
    plugin?.run = run
    return "ok"
  }

  // MARK: - Below iOS 26: SFSpeechRecognizer

  private func startRecognizer(hotwords: [String], pressedAt: TimeInterval) -> String {
    guard let recognizer = SFSpeechRecognizer(locale: Self.locale), recognizer.isAvailable else { return "unavailable" }
    let request = SFSpeechAudioBufferRecognitionRequest()
    request.shouldReportPartialResults = true
    // Dictation: partials come per word, not held for a whole query.
    request.taskHint = .dictation
    request.contextualStrings = hotwords
    request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
    guard plugin?.startAudio({ _ in { request.append($0) } }) == true else { return "unavailable" }

    let run = SpeechRun(startedAt: pressedAt)
    let task = recognizer.recognitionTask(with: request) { [weak self, weak run] result, error in
      let text = result?.bestTranscription.formattedString
      let isFinal = result?.isFinal ?? false
      let failed = error != nil
      DispatchQueue.main.async {
        guard let self, let run, let plugin = self.plugin else { return }
        if let text, isFinal {
          plugin.final(run, text)
        } else if failed {
          plugin.failed(run)
        } else if let text {
          plugin.partial(run, text)
        }
      }
    }
    run.recognizer = recognizer
    run.finish = { request.endAudio() }
    run.abort = {
      request.endAudio()
      task.cancel()
    }
    plugin?.run = run
    return "ok"
  }
}

/// The analyzer lookups for one language (`key`, a `Locale.identifier`); main thread only.
private struct AnalyzerCache {
  let key: String
  /// `DictationTranscriber.supportedLocale(equivalentTo:)`; nil = no transcriber for this language.
  let locale: Locale?
  /// `assetInstallationRequest` said nothing needs installing.
  var assetsInstalled = false
  /// `SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith:)`.
  var format: AVAudioFormat?
}
#endif
