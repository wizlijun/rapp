import AVFoundation
import RappSession
import Speech
#if os(iOS)
import Flutter
import UIKit
#else
import AppKit
import FlutterMacOS
#endif

/// The `rapp/speech` channel: hold-to-talk speech recognition for the voice button.
/// Dart calls `start` (replies `ok` / `asked` / `denied` / `unavailable` / `preparing`, or `cancelled` when a
/// cancel, another start or an interruption overtook it while it set up), `stop` and `cancel`;
/// this side sends `partial` / `final` {text} and `error` {code}, and `timing` {first_partial_ms, final_ms}
/// (milliseconds, or null) just before each `final`. Everything runs on the main thread except
/// the audio tap, which only hands buffers to the recogniser. On iOS this plugin owns the app's AVAudioSession; macOS has no shared session, so it only owns its audio engine.
/// iOS 26+ uses SpeechAnalyzer + SpeechTranscriber; older systems (or no transcriber for the locale) use
/// SFSpeechRecognizer.
final class SpeechPlugin: NSObject, FlutterPlugin {
  /// How long after `stop` this side gives up on the recogniser and sends `final` with what it has.
  /// Dart waits 1 s, so this lands just before.
  private static let finalGrace: TimeInterval = 0.9
  /// The language to recognise: the system's first preferred language (not `Locale.current`, which is English
  /// here); on iOS a Chinese entry anywhere in the list comes first.
  #if os(iOS)
  private static var locale: Locale { speechLocale(preferred: Locale.preferredLanguages, chineseFirst: true) }
  #else
  private static var locale: Locale { speechLocale(preferred: Locale.preferredLanguages) }
  #endif

  private let channel: FlutterMethodChannel
  /// The recording in progress: live, or stopped and waiting for its final text.
  private var run: Run?
  /// Bumped by every start, stop, cancel and interruption, so a start still awaiting its setup knows it was overtaken.
  private var generation = 0
  private var engine: AVAudioEngine?
  private var sessionActive = false
  /// A speech model download is under way (iOS 26+); starts reply `preparing` until it ends.
  private var assetsInstalling = false
  /// What the last analyzer start learned about `key` (a `Self.locale.identifier`), so the next press skips
  /// those lookups (iOS 26+). Replaced when the language changes; dropped when the assets turn out missing.
  private var analyzerCache: AnalyzerCache?

  init(channel: FlutterMethodChannel) {
    self.channel = channel
    super.init()
    #if os(iOS)
    NotificationCenter.default.addObserver(
      self, selector: #selector(audioInterrupted(_:)),
      name: AVAudioSession.interruptionNotification, object: nil)
    NotificationCenter.default.addObserver(
      self, selector: #selector(resignActive),
      name: UIApplication.willResignActiveNotification, object: nil)
    #endif
  }

  #if os(macOS)
  /// The app's main window: losing key status interrupts a live recording.
  private var keyObserver: NSObjectProtocol?

  /// macOS entry point: also watches `window` so that it resigning key ends a live recording.
  static func register(with registrar: FlutterPluginRegistrar, window: NSWindow) {
    let plugin = makePlugin(registrar)
    plugin.keyObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.didResignKeyNotification, object: window, queue: .main
    ) { [weak plugin] _ in plugin?.interrupt() }
  }
  #endif

  static func register(with registrar: FlutterPluginRegistrar) {
    _ = makePlugin(registrar)
  }

  @discardableResult
  private static func makePlugin(_ registrar: FlutterPluginRegistrar) -> SpeechPlugin {
    #if os(iOS)
    let messenger = registrar.messenger()
    #else
    let messenger = registrar.messenger
    #endif
    let channel = FlutterMethodChannel(name: "rapp/speech", binaryMessenger: messenger)
    let plugin = SpeechPlugin(channel: channel)
    registrar.addMethodCallDelegate(plugin, channel: channel)
    return plugin
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "start":
      // Words to expect (the gateway's hotwords): names and products said often and heard wrong.
      let words = ((call.arguments as? [String: Any])?["hotwords"] as? [String])?.filter { !$0.isEmpty } ?? []
      start(result, hotwords: Array(words.prefix(100)))
    case "stop":
      stop()
      result(nil)
    case "cancel":
      generation += 1
      end()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - Start, stop, end

  private func start(_ result: @escaping FlutterResult, hotwords: [String]) {
    let pressedAt = Self.now()
    generation += 1
    let gen = generation
    end()  // A second start cancels the first, silently: Dart has already moved on.
    switch Self.access() {
    case .denied:
      return result("denied")
    case .ask:
      Self.askAccess()
      return result("asked")  // This hold does not record.
    case .granted:
      break
    }
    if #available(iOS 26, macOS 26, *) {
      Task { @MainActor [weak self] in
        guard let self else { return result("cancelled") }
        if let reply = await self.startAnalyzer(gen, hotwords: hotwords, pressedAt: pressedAt) { return result(reply) }
        // No transcriber for this device or locale: the older recogniser may still work.
        result(gen == self.generation ? self.startRecognizer(hotwords: hotwords, pressedAt: pressedAt) : "cancelled")
      }
    } else {
      result(startRecognizer(hotwords: hotwords, pressedAt: pressedAt))
    }
  }

  /// Ends the audio; the recogniser delivers its final text, or `finalGrace` later this side sends what it has.
  private func stop() {
    guard let run, !run.stopped else {
      generation += 1  // Nothing live: just make sure a start still setting up does not begin recording.
      return
    }
    run.stopped = true
    run.stoppedAt = Self.now()
    stopAudio()
    run.finish()
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.finalGrace) { [weak self, weak run] in
      guard let self, let run else { return }
      self.final(run, run.text)
    }
  }

  /// Drops the current recording, if any, without telling Dart.
  private func end() {
    guard let run else { return }
    self.run = nil
    run.abort()
    stopAudio()
  }

  // MARK: - Events to Dart (main thread; events from a recording that is no longer current are dropped)

  private func partial(_ run: Run, _ text: String) {
    guard run === self.run else { return }
    run.text = text
    if run.firstPartialAt == nil, !text.isEmpty { run.firstPartialAt = Self.now() }
    channel.invokeMethod("partial", arguments: ["text": text])
  }

  private func final(_ run: Run, _ text: String) {
    guard run === self.run else { return }
    let at = Self.now()
    end()
    channel.invokeMethod("timing", arguments: [
      "first_partial_ms": Self.ms(from: run.startedAt, to: run.firstPartialAt),
      "final_ms": Self.ms(from: run.stoppedAt, to: at),
    ])
    channel.invokeMethod("final", arguments: ["text": text])
  }

  /// Monotonic seconds, for the timing event.
  private static func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

  /// Whole milliseconds from `start` to `end`, or NSNull (null in Dart) when either is missing.
  private static func ms(from start: TimeInterval?, to end: TimeInterval?) -> Any {
    guard let start, let end else { return NSNull() }
    return max(0, Int(((end - start) * 1000).rounded()))
  }

  /// A recogniser error. After `stop` it only means no more text is coming (for example, no speech).
  private func failed(_ run: Run) {
    guard run === self.run else { return }
    if run.stopped { return final(run, run.text) }
    end()
    channel.invokeMethod("error", arguments: ["code": "failed"])
  }

  // MARK: - Interruptions

  #if os(iOS)
  @objc private func audioInterrupted(_ note: Notification) {
    guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
          AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
    DispatchQueue.main.async { [weak self] in self?.interrupt() }
  }

  @objc private func resignActive() {
    DispatchQueue.main.async { [weak self] in self?.interrupt() }
  }

  #endif

  /// A call, Siri, Control Center or leaving the app: a live recording is cancelled and Dart told so.
  /// A stopped one is only waiting for its text and keeps going.
  private func interrupt() {
    generation += 1
    guard let run, !run.stopped else { return }
    end()
    channel.invokeMethod("error", arguments: ["code": "interrupted"])
  }

  // MARK: - Permissions

  private enum Access { case granted, denied, ask }

  private static func access() -> Access {
    let speech = SFSpeechRecognizer.authorizationStatus()
    #if os(iOS)
    let mic = AVAudioApplication.shared.recordPermission
    let micDenied = mic == .denied
    let micUndecided = mic == .undetermined
    #else
    let mic = AVCaptureDevice.authorizationStatus(for: .audio)
    let micDenied = mic == .denied || mic == .restricted
    let micUndecided = mic == .notDetermined
    #endif
    if speech == .denied || speech == .restricted || micDenied { return .denied }
    if speech == .notDetermined || micUndecided { return .ask }
    return .granted
  }

  /// Asks for whatever is not yet decided: speech recognition first, then the microphone.
  private static func askAccess() {
    let askMic = {
      #if os(iOS)
      if AVAudioApplication.shared.recordPermission == .undetermined {
        AVAudioApplication.requestRecordPermission { _ in }
      }
      #else
      if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
      }
      #endif
    }
    if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
      SFSpeechRecognizer.requestAuthorization { _ in DispatchQueue.main.async(execute: askMic) }
    } else {
      askMic()
    }
  }

  // MARK: - Audio

  /// Activates the session and starts the engine. `makeFeed` gets the microphone's format and returns what
  /// each tapped buffer is handed to (on the audio thread), or nil to give up.
  private func startAudio(_ makeFeed: (AVAudioFormat) -> ((AVAudioPCMBuffer) -> Void)?) -> Bool {
    #if os(iOS)
    let session = AVAudioSession.sharedInstance()
    do {
      try session.setCategory(.record, mode: .measurement, options: [])
      // Else iOS mutes haptics while recording: the press and each pick change are felt (spec §5.1).
      try session.setAllowHapticsAndSystemSoundsDuringRecording(true)
      // Small hardware buffers (~20 ms; iOS otherwise hands the tap ~100 ms at a time): audio reaches the
      // recogniser sooner. A hint; iOS may round it.
      try? session.setPreferredIOBufferDuration(0.02)
      try session.setActive(true)
    } catch {
      return false
    }
    #endif
    sessionActive = true
    let engine = AVAudioEngine()
    self.engine = engine
    let input = engine.inputNode
    let format = input.outputFormat(forBus: 0)
    guard format.sampleRate > 0, format.channelCount > 0, let feed = makeFeed(format) else {
      stopAudio()
      return false
    }
    // The level goes to Dart at most every 50 ms; the tap is the only writer of `lastLevel`.
    var lastLevel = Date.distantPast
    input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
      feed(buffer)
      let now = Date()
      guard now.timeIntervalSince(lastLevel) >= 0.05, let rms = Self.rms(buffer) else { return }
      lastLevel = now
      let value = Self.level(rms: rms)
      DispatchQueue.main.async {
        guard let self, self.engine != nil else { return }
        self.channel.invokeMethod("level", arguments: ["value": value])
      }
    }
    engine.prepare()
    do {
      try engine.start()
    } catch {
      stopAudio()
      return false
    }
    return true
  }

  /// Microphone loudness 0...1: decibels of `rms`, -50 dB (or less) = 0, 0 dB = 1.
  static func level(rms: Float) -> Double {
    let db = 20 * log10(Double(max(rms, 1e-7)))
    return min(max((db + 50) / 50, 0), 1)
  }

  /// RMS of channel 0, or nil when the buffer has no float samples.
  private static func rms(_ buffer: AVAudioPCMBuffer) -> Float? {
    guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return nil }
    var sum: Float = 0
    for i in 0..<Int(buffer.frameLength) { sum += samples[i] * samples[i] }
    return (sum / Float(buffer.frameLength)).squareRoot()
  }

  private func stopAudio() {
    if let engine {
      engine.inputNode.removeTap(onBus: 0)
      engine.stop()
      self.engine = nil
    }
    if sessionActive {
      sessionActive = false
      #if os(iOS)
      try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
      #endif
    }
  }

  // MARK: - iOS 26+: SpeechAnalyzer

  /// The reply for Dart, or nil when the transcriber cannot serve this device or locale.
  @available(iOS 26, macOS 26, *)
  @MainActor
  private func startAnalyzer(_ gen: Int, hotwords: [String], pressedAt: TimeInterval) async -> String? {
    guard SpeechTranscriber.isAvailable else { return nil }
    let key = Self.locale.identifier
    if analyzerCache?.key != key { analyzerCache = nil }
    let supported: Locale?
    if let cache = analyzerCache {
      supported = cache.locale
    } else {
      supported = await SpeechTranscriber.supportedLocale(equivalentTo: Self.locale)
      analyzerCache = AnalyzerCache(key: key, locale: supported)
    }
    guard let locale = supported else { return nil }
    // .fastResults: words show while being said instead of after the transcriber gathers more context (user
    // 2026-11-18: 「实时显示不太即时……确保说完立即显示」); the finalised text still corrects them.
    let transcriber = SpeechTranscriber(
      locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults, .fastResults],
      attributeOptions: [])

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

    let run = Run(startedAt: pressedAt)
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
          self?.partial(run, result.isFinal ? done : done + text)
        }
        self?.final(run, done)
      } catch {
        // A live run failing (not one cancelled or replaced): maybe the cached assets went away, so look
        // them up again next time.
        if let self, run === self.run { self.analyzerCache = nil }
        self?.failed(run)
      }
    }
    // The hotwords as the analysis context: the transcriber leans toward them. Without them it still runs.
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
    guard gen == generation else {
      run.abort()
      return "cancelled"
    }
    let started = startAudio { mic in
      if mic == format { return { input.yield(AnalyzerInput(buffer: $0)) } }
      guard let converter = AVAudioConverter(from: mic, to: format) else { return nil }
      return { buffer in
        if let converted = Self.convert(buffer, with: converter) { input.yield(AnalyzerInput(buffer: converted)) }
      }
    }
    guard started else {
      run.abort()
      return "unavailable"
    }
    self.run = run
    return "ok"
  }

  /// Converts one tapped buffer to the analyzer's format (audio thread; the converter keeps resampling state).
  private static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter) -> AVAudioPCMBuffer? {
    let format = converter.outputFormat
    let frames = (Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate).rounded(.up)
    guard frames > 0, let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else {
      return nil
    }
    var handed = false
    var error: NSError?
    let status = converter.convert(to: out, error: &error) { _, inputStatus in
      if handed {
        inputStatus.pointee = .noDataNow
        return nil
      }
      handed = true
      inputStatus.pointee = .haveData
      return buffer
    }
    return status == .error || out.frameLength == 0 ? nil : out
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
    guard startAudio({ _ in { request.append($0) } }) else { return "unavailable" }

    let run = Run(startedAt: pressedAt)
    let task = recognizer.recognitionTask(with: request) { [weak self, weak run] result, error in
      let text = result?.bestTranscription.formattedString
      let isFinal = result?.isFinal ?? false
      let failed = error != nil
      DispatchQueue.main.async {
        guard let self, let run else { return }
        if let text, isFinal {
          self.final(run, text)
        } else if failed {
          self.failed(run)
        } else if let text {
          self.partial(run, text)
        }
      }
    }
    run.recognizer = recognizer
    run.finish = { request.endAudio() }
    run.abort = {
      request.endAudio()
      task.cancel()
    }
    self.run = run
    return "ok"
  }
}

/// The analyzer lookups for one language (`key`, a `Locale.identifier`); main thread only.
private struct AnalyzerCache {
  let key: String
  /// `SpeechTranscriber.supportedLocale(equivalentTo:)`; nil = no transcriber for this language.
  let locale: Locale?
  /// `assetInstallationRequest` said nothing needs installing.
  var assetsInstalled = false
  /// `SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith:)`.
  var format: AVAudioFormat?
}

/// One recording: how to end its recogniser, and what Dart has seen of it. Main thread only.
private final class Run {
  init(startedAt: TimeInterval) { self.startedAt = startedAt }

  /// When `start` was called (`SpeechPlugin.now()`), and when the first non-empty partial and `stop` came.
  let startedAt: TimeInterval
  var firstPartialAt: TimeInterval?
  var stoppedAt: TimeInterval?

  /// The audio has ended: the recogniser should deliver its final text.
  var finish: () -> Void = {}
  /// Drop the recogniser without a result. Safe to call more than once, and after it finished.
  var abort: () -> Void = {}
  /// Kept alive while the recognition runs.
  var recognizer: AnyObject?
  /// The latest transcript sent as `partial`.
  var text = ""
  /// `stop` came: no more audio, a `final` is due.
  var stopped = false
}
