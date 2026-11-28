import AVFoundation

/// One speech recogniser behind the `rapp/speech` channel (wx offline ASR design §5.3). Exactly one engine is
/// compiled in, chosen by `RAPP_SPEECH` (gui/Speech.xcconfig): `apple` builds SpeechEngineApple.swift, `wx`
/// builds SpeechEngineWx.swift; each defines `makeSpeechEngine()`. SpeechPlugin owns the channel, the
/// microphone, levels, interruptions, timing and a recording's life; it knows no engine by name.
/// Everything here runs on the main thread unless said otherwise.
protocol SpeechEngine: AnyObject {
  /// The plugin, set right after the engine is made.
  var plugin: SpeechPlugin? { get set }
  /// Reported to Dart by `engine`.
  var name: String { get }
  /// How long after `stop` the plugin gives up on the engine and sends `final` with the last partial.
  var finalGrace: TimeInterval { get }
  /// How long Dart waits for that final: a little longer than `finalGrace`.
  var dartWait: TimeInterval { get }
  /// What Dart shows for a `denied` and an `unavailable` start.
  var deniedText: String { get }
  var unavailableText: String { get }

  /// Dart asked `engine` and gave the data directory's `local` folder: a chance to get ready before the first press.
  func prepare(localDir: String?)
  /// This engine's own permissions; the microphone's are the plugin's.
  func access() -> SpeechAccess
  /// Asks for this engine's undecided permissions, then calls `then` on the main thread.
  func askAccess(then: @escaping () -> Void)
  /// Starts a recording for the start numbered `gen` (`plugin.generation` moves on when it is overtaken).
  /// It starts the microphone with `plugin.startAudio`, makes `plugin.run` its `SpeechRun`, and reports through
  /// `plugin.partial` / `final` / `failed`. `reply` gets `start`'s answer, once. After `run.finish` it reports
  /// exactly one `final` or `failed` (the plugin sends what it has `finalGrace` later); after `run.abort`, nothing.
  func start(_ gen: Int, hotwords: [String], pressedAt: TimeInterval, reply: @escaping (String) -> Void)
}

enum SpeechAccess { case granted, denied, ask }

/// One recording: how to end its recogniser, and what Dart has seen of it. Main thread only.
final class SpeechRun {
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

enum SpeechAudio {
  /// Converts one tapped buffer to the converter's output format (audio thread; the converter keeps resampling state).
  static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter) -> AVAudioPCMBuffer? {
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
}
