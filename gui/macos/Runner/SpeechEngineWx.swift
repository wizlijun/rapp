#if RAPP_SPEECH_WX
import AVFoundation

func makeSpeechEngine() -> SpeechEngine { SpeechEngineWx() }

/// WeChat IME's offline model through rust/speech-wx (wx offline ASR design §5.3). The microphone is converted
/// to 16 kHz mono 16-bit and handed to one serial queue, which pushes it, asks for partials after each push
/// (the library paces them, §5.2) and decodes the final; nothing is recognised on the audio thread. The model
/// lives in `<data root>/local/wx-asr` on this machine only and is loaded once, in the background, when Dart
/// first asks `engine`. No model: starts reply `unavailable`; there is no fallback to the system recognisers.
/// Hotwords are taken and not used: the model is plain CTC.
final class SpeechEngineWx: SpeechEngine {
  weak var plugin: SpeechPlugin?
  let name = "wx"
  /// The final can take longer than the system's, more so on a phone (design §5.4).
  let finalGrace: TimeInterval = 5
  let dartWait: TimeInterval = 5.1
  let deniedText = "需要麦克风权限"
  var unavailableText: String { "没有找到离线语音模型，要放在 \(dir ?? "数据目录的 local/wx-asr")" }

  /// Everything that touches the library: loading, pushing, partials, finals and frees, in order.
  private let queue = DispatchQueue(label: "rapp.speech.wx", qos: .userInitiated)
  /// The model directory, once Dart has said where the data lives.
  private var dir: String?
  private var model: OpaquePointer?
  /// Starts waiting for a load under way (main thread); nil = no load running.
  private var waiting: [(OpaquePointer?) -> Void]?

  func prepare(localDir: String?) {
    guard let localDir, dir == nil else { return }
    dir = (localDir as NSString).appendingPathComponent("wx-asr")
    withModel { _ in }
  }

  /// The microphone is the plugin's; this engine needs nothing else.
  func access() -> SpeechAccess { .granted }
  func askAccess(then: @escaping () -> Void) { then() }

  func start(_ gen: Int, hotwords: [String], pressedAt: TimeInterval, reply result: @escaping (String) -> Void) {
    withModel { [weak self] model in
      guard let self, let model else { return result("unavailable") }
      guard gen == self.plugin?.generation else { return result("cancelled") }
      result(self.record(model, pressedAt: pressedAt))
    }
  }

  /// Calls `use` on the main thread with the model, loading it first if needed (again after a failed load, so
  /// files copied in later are found at the next press); nil when there is none.
  private func withModel(_ use: @escaping (OpaquePointer?) -> Void) {
    if let model { return use(model) }
    if waiting != nil {
      waiting?.append(use)
      return
    }
    guard let dir else { return use(nil) }
    waiting = [use]
    queue.async { [weak self] in
      let t0 = ProcessInfo.processInfo.systemUptime
      var err: UnsafeMutablePointer<CChar>?
      let loaded = wx_load(dir, &err)
      let ms = Int(((ProcessInfo.processInfo.systemUptime - t0) * 1000).rounded())
      let why = err.map { String(cString: $0) } ?? ""
      wx_string_free(err)
      DispatchQueue.main.async {
        guard let self else { return wx_model_free(loaded) }
        if let loaded {
          self.model = loaded
          self.plugin?.log("voice wx: model loaded in \(ms)ms from \(dir)")
        } else {
          self.plugin?.log("voice wx: no model in \(dir) (\(ms)ms): \(why)")
        }
        let waiters = self.waiting ?? []
        self.waiting = nil
        for use in waiters { use(loaded) }
      }
    }
  }

  /// Starts the microphone into a new recording; `start`'s reply.
  private func record(_ model: OpaquePointer, pressedAt: TimeInterval) -> String {
    guard let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true),
          let handle = wx_stream_new(model) else { return "unavailable" }
    let stream = WxRecording(handle)
    let run = SpeechRun(startedAt: pressedAt)
    let queue = self.queue
    let started = plugin?.startAudio { mic in
      guard let converter = AVAudioConverter(from: mic, to: target) else { return nil }
      return { [weak self, weak run] buffer in
        guard let out = SpeechAudio.convert(buffer, with: converter), let samples = out.int16ChannelData?[0] else {
          return
        }
        let pcm = Array(UnsafeBufferPointer(start: samples, count: Int(out.frameLength)))
        queue.async {
          guard let handle = stream.handle else { return }
          stream.samples += pcm.count
          pcm.withUnsafeBufferPointer { wx_push(handle, $0.baseAddress, $0.count) }
          guard let text = Self.take(wx_partial(handle)) else { return }
          DispatchQueue.main.async {
            guard let self, let run else { return }
            self.plugin?.partial(run, text)
          }
        }
      }
    } ?? false
    guard started else {
      queue.async { stream.free() }
      return "unavailable"
    }
    run.recognizer = stream
    run.finish = { [weak self, weak run] in
      queue.async {
        guard let handle = stream.handle else { return }
        stream.handle = nil
        let seconds = Double(stream.samples) / 16000
        let t0 = ProcessInfo.processInfo.systemUptime
        let text = Self.take(wx_finish(handle))
        let ms = Int(((ProcessInfo.processInfo.systemUptime - t0) * 1000).rounded())
        DispatchQueue.main.async {
          guard let self, let run, let plugin = self.plugin else { return }
          plugin.log(String(format: "voice wx: %.1fs of audio, final decoded in %dms", seconds, ms))
          if let text { plugin.final(run, text) } else { plugin.failed(run) }
        }
      }
    }
    run.abort = { queue.async { stream.free() } }
    plugin?.run = run
    return "ok"
  }

  /// The library's string as a Swift one, freeing it; nil for NULL.
  private static func take(_ s: UnsafeMutablePointer<CChar>?) -> String? {
    guard let s else { return nil }
    defer { wx_string_free(s) }
    return String(cString: s)
  }
}

/// One recording's library handle; touched on the engine's queue only. Nil once finished or freed.
private final class WxRecording {
  var handle: OpaquePointer?
  /// 16 kHz samples pushed so far, for the log.
  var samples = 0
  init(_ handle: OpaquePointer) { self.handle = handle }

  func free() {
    guard let handle else { return }
    self.handle = nil
    wx_stream_free(handle)
  }
}
#endif
