import Cocoa
import CoreVideo
import FlutterMacOS
import RappCore
import RappSession

/// One A window's picture as a Flutter texture: the raster thread takes the latest buffer.
final class SurfaceTexture: NSObject, FlutterTexture {
  private let surfaces: WindowSurfaces
  private let window: UInt32

  init(surfaces: WindowSurfaces, window: UInt32) {
    self.surfaces = surfaces
    self.window = window
  }

  func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
    surfaces.latest(window).map { Unmanaged.passRetained($0) }
  }
}

/// The `rapp/session` channel: glue between Dart and the embedded sessions in `RappSession`.
/// Parsing and encoding are `channelCommand` / `eventPayload`; this only owns the sessions,
/// their textures and the main-thread hops.
final class SessionPlugin: NSObject, FlutterPlugin {
  private final class Live {
    let session: EmbeddedSession
    /// The session's own queue: its state (`backingScale` included) is only touched there.
    let queue: DispatchQueue
    /// Window id → its registered texture.
    var textures = [UInt32: (id: Int64, texture: SurfaceTexture)]()
    init(session: EmbeddedSession, queue: DispatchQueue) {
      self.session = session
      self.queue = queue
    }
  }

  private let channel: FlutterMethodChannel
  private let registry: FlutterTextureRegistry
  private weak var view: NSView?
  private var live = [Int64: Live]()
  private var ready = false
  private var timer: Timer?
  private var scaleObserver: NSObjectProtocol?
  /// The session whose picture has keyboard focus (Dart's `picture_focus`).
  private var focusedSid: Int64?
  /// What A has been sent presses for: released when focus leaves (R15).
  private var keys = KeyTracker()
  private var keyMonitor: Any?
  private var resignObserver: NSObjectProtocol?
  private var terminateObserver: NSObjectProtocol?

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "rapp/session", binaryMessenger: registrar.messenger)
    let plugin = SessionPlugin(channel: channel, registry: registrar.textures, view: registrar.view)
    registrar.addMethodCallDelegate(plugin, channel: channel)
  }

  private init(channel: FlutterMethodChannel, registry: FlutterTextureRegistry, view: NSView?) {
    self.channel = channel
    self.registry = registry
    self.view = view
  }

  deinit {
    timer?.invalidate()
    if let scaleObserver { NotificationCenter.default.removeObserver(scaleObserver) }
    if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
    if let terminateObserver { NotificationCenter.default.removeObserver(terminateObserver) }
    if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
  }

  private var backingScale: CGFloat {
    view?.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let command: ChannelCommand
    do {
      command = try channelCommand(call.method, call.arguments)
    } catch ChannelError.unknown {
      result(FlutterMethodNotImplemented)
      return
    } catch {
      result(FlutterError(code: "bad_args", message: "\(call.method): bad arguments", details: nil))
      return
    }
    switch command {
    case .initialize:
      begin()
      result(["doubleClickMs": Int((NSEvent.doubleClickInterval * 1000).rounded())])
    case let .start(sid, port, token, mode, fps, density):
      guard ready else {
        result(FlutterError(code: "not_ready", message: "init first", details: nil))
        return
      }
      guard live[sid] == nil else {
        result(FlutterError(code: "exists", message: "session \(sid) already started", details: nil))
        return
      }
      start(sid: sid, port: port, token: token, mode: mode, fps: fps, density: density)
      result(nil)
    case let .close(sid):
      live[sid]?.session.close(reason: "quit")
      result(nil)
    case let .mouse(sid, message), let .scroll(sid, message), let .resize(sid, message):
      live[sid]?.session.send(message)
      result(nil)
    case let .key(sid, keyCode, modifiers):
      live[sid]?.session.send(.key(keyCode: keyCode, modifiers: modifiers, down: true))
      live[sid]?.session.send(.key(keyCode: keyCode, modifiers: modifiers, down: false))
      result(nil)
    case let .selectWindow(sid, window):
      live[sid]?.session.send(.focus(window))
      result(nil)
    case let .setStream(sid, mode, fps, density):
      live[sid]?.session.setStream(mode: mode, fps: fps, choice: density)
      result(nil)
    case .cancelTransfer:
      // Nothing to cancel until the composer's transfers land (Task 11).
      result(nil)
    case let .clipPick(sid, clip, insert):
      live[sid]?.session.pickClip(clip, insert: insert)
      result(nil)
    case let .menuPick(sid, path):
      live[sid]?.session.menuPick(path)
      result(nil)
    case let .moveTopLeft(sid, window):
      live[sid]?.session.moveToTopLeft(window: window)
      result(nil)
    case let .pictureFocus(sid):
      if sid != focusedSid {
        releaseKeys()
        focusedSid = sid
      }
      result(nil)
    }
  }

  /// After Dart's `init`: the engine is up, so textures may be registered from now on.
  private func begin() {
    guard !ready else { return }
    ready = true
    // Common modes, so traffic keeps ticking during window resizes and menu tracking.
    let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
      self?.live.values.forEach { $0.session.tickTraffic() }
    }
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
      guard let self else { return event }
      return self.route(event)
    }
    resignObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.didResignKeyNotification, object: nil, queue: .main
    ) { [weak self] note in
      guard let self, let main = self.view?.window, note.object as? NSWindow === main else { return }
      self.releaseKeys()
    }
    // Quitting (⌘Q included): A gets the releases before the connections go.
    terminateObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.willTerminateNotification, object: nil, queue: .main
    ) { [weak self] _ in
      self?.releaseKeys()
    }
    scaleObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.didChangeBackingPropertiesNotification, object: nil, queue: .main
    ) { [weak self] _ in
      guard let self else { return }
      let scale = self.backingScale
      for entry in self.live.values {
        entry.queue.async { entry.session.backingScale = scale }
      }
    }
  }

  /// On main, for every key event of the app: a key for A is sent to the focused session and
  /// swallowed (nil); everything else goes on to Flutter unchanged. `routeKey` decides.
  private func route(_ event: NSEvent) -> NSEvent? {
    // Only the main window's keys (detached windows route their own, Task 12).
    if let main = view?.window, event.window !== main { return event }
    let down: Bool
    switch event.type {
    case .keyDown: down = true
    case .keyUp: down = false
    case .flagsChanged:
      guard let d = modifierKeyIsDown(keyCode: event.keyCode, flags: event.modifierFlags) else { return event }
      down = d
    default:
      return event
    }
    let target = focusedSid.flatMap { live[$0] }
    let decision = keys.route(keyCode: event.keyCode, down: down, flags: event.modifierFlags,
                              pictureFocused: target != nil)
    for code in decision.release {
      target?.session.send(.key(keyCode: code, modifiers: 0, down: false))
    }
    guard decision.route == .remote, let target else { return event }
    target.session.send(.key(keyCode: event.keyCode, modifiers: UInt64(event.modifierFlags.rawValue), down: down))
    return nil
  }

  /// A release for every key A still holds, to the focused session (nothing stays stuck on A).
  private func releaseKeys() {
    let held = keys.releaseAll()
    guard let sid = focusedSid, let entry = live[sid] else { return }
    for code in held {
      entry.session.send(.key(keyCode: code, modifiers: 0, down: false))
    }
  }

  private func start(sid: Int64, port: UInt16, token: String, mode: Mode, fps: UInt8, density: DensityChoice) {
    let address = RemoteAddress(host: "127.0.0.1", port: port, bundleID: "", token: token, mode: mode, fps: fps)
    let queue = DispatchQueue(label: "rapp.session.\(sid)")
    let session = EmbeddedSession(address: address, choice: density, backingScale: backingScale,
                                  link: Connection(address: address, queue: queue),
                                  pasteboard: LocalPasteboard(), queue: queue)
    session.onEvent = { [weak self] event in
      DispatchQueue.main.async { self?.deliver(event, sid: sid) }
    }
    live[sid] = Live(session: session, queue: queue)
    session.start()
  }

  /// On main: keeps the session's textures in step with its windows, then tells Dart.
  private func deliver(_ event: SessionEvent, sid: Int64) {
    guard let entry = live[sid] else { return }
    switch event {
    case let .surfaces(ids):
      for id in ids {
        if let t = entry.textures[id] { registry.textureFrameAvailable(t.id) }
      }
    case let .windows(windows):
      let change = textureChanges(have: Set(entry.textures.keys), windows: windows)
      for id in change.unregister {
        if let t = entry.textures.removeValue(forKey: id) { registry.unregisterTexture(t.id) }
      }
      for id in change.register {
        let texture = SurfaceTexture(surfaces: entry.session.surfaces, window: id)
        entry.textures[id] = (registry.register(texture), texture)
      }
    case .closed:
      // Every texture goes before Dart hears the session ended.
      entry.textures.values.forEach { registry.unregisterTexture($0.id) }
      entry.textures = [:]
      live[sid] = nil
      if focusedSid == sid {
        _ = keys.releaseAll()
        focusedSid = nil
      }
    default:
      break
    }
    if let payload = eventPayload(event, sid: sid, textures: entry.textures.mapValues(\.id)) {
      channel.invokeMethod(payload.method, arguments: payload.args)
    }
  }
}
