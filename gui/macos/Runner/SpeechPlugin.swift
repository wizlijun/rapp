import AVFoundation
#if os(iOS)
import Flutter
import UIKit
#else
import AppKit
import FlutterMacOS
#endif

/// The `rapp/speech` channel: hold-to-talk speech recognition for the voice button.
/// Dart calls `engine` {local_dir} (replies {name, final_wait_ms, denied, unavailable}: the compiled-in engine,
/// how long Dart waits for a final, and the hints for those two starts), `start` (replies `ok` / `asked` /
/// `denied` / `unavailable` / `preparing`, or `cancelled` when a cancel, another start or an interruption overtook
/// it while it set up), `stop` and `cancel`; this side sends `partial` / `final` {text} and `error` {code},
/// `timing` {first_partial_ms, final_ms} (milliseconds, or null) just before each `final`, and `log` {line}.
/// Everything runs on the main thread except the audio tap, which only hands buffers to the recogniser. On iOS
/// this plugin owns the app's AVAudioSession; macOS has no shared session, so it only owns its audio engine.
/// The recogniser is the one `SpeechEngine` compiled in (SpeechEngine.swift); this file knows none by name.
final class SpeechPlugin: NSObject, FlutterPlugin {
  private let channel: FlutterMethodChannel
  private let recognizer: SpeechEngine
  /// The recording in progress: live, or stopped and waiting for its final text. Engines set it once they record.
  var run: SpeechRun?
  /// Bumped by every start, stop, cancel and interruption, so a start still awaiting its setup knows it was overtaken.
  private(set) var generation = 0
  private var engine: AVAudioEngine?
  private var sessionActive = false

  init(channel: FlutterMethodChannel) {
    self.channel = channel
    recognizer = makeSpeechEngine()
    super.init()
    recognizer.plugin = self
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
    case "engine":
      recognizer.prepare(localDir: (call.arguments as? [String: Any])?["local_dir"] as? String)
      result([
        "name": recognizer.name,
        "final_wait_ms": Int((recognizer.dartWait * 1000).rounded()),
        "denied": recognizer.deniedText,
        "unavailable": recognizer.unavailableText,
      ])
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
    switch access() {
    case .denied:
      return result("denied")
    case .ask:
      askAccess()
      return result("asked")  // This hold does not record.
    case .granted:
      break
    }
    recognizer.start(gen, hotwords: hotwords, pressedAt: pressedAt, reply: result)
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
    let grace = recognizer.finalGrace
    DispatchQueue.main.asyncAfter(deadline: .now() + grace) { [weak self, weak run] in
      guard let self, let run else { return }
      if run === self.run {
        self.log("voice: no final \(Int((grace * 1000).rounded()))ms after release, sent the last partial")
      }
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

  func partial(_ run: SpeechRun, _ text: String) {
    guard run === self.run else { return }
    run.text = text
    if run.firstPartialAt == nil, !text.isEmpty { run.firstPartialAt = Self.now() }
    channel.invokeMethod("partial", arguments: ["text": text])
  }

  func final(_ run: SpeechRun, _ text: String) {
    guard run === self.run else { return }
    let at = Self.now()
    end()
    channel.invokeMethod("timing", arguments: [
      "first_partial_ms": Self.ms(from: run.startedAt, to: run.firstPartialAt),
      "final_ms": Self.ms(from: run.stoppedAt, to: at),
    ])
    channel.invokeMethod("final", arguments: ["text": text])
  }

  /// A line for the app's log.
  func log(_ line: String) {
    channel.invokeMethod("log", arguments: ["line": line])
  }

  /// Monotonic seconds, for the timing event.
  private static func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

  /// Whole milliseconds from `start` to `end`, or NSNull (null in Dart) when either is missing.
  private static func ms(from start: TimeInterval?, to end: TimeInterval?) -> Any {
    guard let start, let end else { return NSNull() }
    return max(0, Int(((end - start) * 1000).rounded()))
  }

  /// A recogniser error. After `stop` it only means no more text is coming (for example, no speech).
  func failed(_ run: SpeechRun) {
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

  // MARK: - Permissions: the microphone here, the rest the engine's

  private func access() -> SpeechAccess {
    let own = recognizer.access()
    #if os(iOS)
    let mic = AVAudioApplication.shared.recordPermission
    let micDenied = mic == .denied
    let micUndecided = mic == .undetermined
    #else
    let mic = AVCaptureDevice.authorizationStatus(for: .audio)
    let micDenied = mic == .denied || mic == .restricted
    let micUndecided = mic == .notDetermined
    #endif
    if own == .denied || micDenied { return .denied }
    if own == .ask || micUndecided { return .ask }
    return .granted
  }

  /// Asks for whatever is not yet decided: the engine's own permissions first, then the microphone.
  private func askAccess() {
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
    recognizer.askAccess(then: askMic)
  }

  // MARK: - Audio

  /// Activates the session and starts the engine. `makeFeed` gets the microphone's format and returns what
  /// each tapped buffer is handed to (on the audio thread), or nil to give up.
  func startAudio(_ makeFeed: (AVAudioFormat) -> ((AVAudioPCMBuffer) -> Void)?) -> Bool {
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
}
