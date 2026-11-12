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
/// their textures, their detached windows and the main-thread hops.
///
/// Threading, per entry point: `handle` (Flutter's platform thread, which is main on macOS),
/// `deliver` (hopped onto main from each session's queue), the key monitor and every observer
/// (main). So all of this object's state is main-only; a session is only reached through its
/// queue-safe `send`/`close`/`setStream`…, or on its queue (`backingScale`).
final class SessionPlugin: NSObject, FlutterPlugin {
  private final class Live {
    let session: EmbeddedSession
    /// The session's own queue: its state (`backingScale` included) is only touched there.
    let queue: DispatchQueue
    /// Window id → its registered texture.
    var textures = [UInt32: (id: Int64, texture: SurfaceTexture)]()
    /// A's latest window table, for a detach.
    var windows = [SessionWindow]()
    init(session: EmbeddedSession, queue: DispatchQueue) {
      self.session = session
      self.queue = queue
    }
  }

  /// Copies of A's clips; they outlive the session they came from.
  private let copies = ClipCopies()
  /// Where downloads go: `RAPP_DOWNLOADS` when set and non-empty, else the session's default.
  private let downloads: URL? = {
    guard let p = ProcessInfo.processInfo.environment["RAPP_DOWNLOADS"], !p.isEmpty else { return nil }
    return URL(fileURLWithPath: p, isDirectory: true)
  }()
  private let channel: FlutterMethodChannel
  private let registry: FlutterTextureRegistry
  private weak var view: NSView?
  private var live = [Int64: Live]()
  private var ready = false
  private var timer: Timer?
  private var scaleObserver: NSObjectProtocol?
  /// The session whose picture has keyboard focus (Dart's `picture_focus`).
  private var focusedSid: Int64?
  /// What A has been sent presses for: released when focus leaves (R15). One tracker for the
  /// stage and the detached windows, so a release always goes where its press went.
  private var keys = KeyTracker()
  /// The session `keys` holds presses for (the one they were sent to), if any.
  private var keysHolder: Int64?
  /// Sessions shown in their own windows instead of on the stage (R20).
  private var detached = [Int64: DetachedSession]()
  private var keyMonitor: Any?
  private var resignObserver: NSObjectProtocol?
  private var terminateObserver: NSObjectProtocol?
  /// 「附件」's open file picker, one per session.
  private var panels = [Int64: NSOpenPanel]()

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
    case let .cancelTransfer(sid, id):
      if let id { live[sid]?.session.cancelTransfer(id: id) } else { live[sid]?.session.cancelTransfers() }
      result(nil)
    case let .fetchClip(sid, clip):
      guard let entry = live[sid] else {
        result(["error": "A 已断开"])
        return
      }
      // The reply comes back on main (the session hops it), where `copies` lives.
      entry.session.fetchCopy(clip) { [copies] r in
        result(clipCopyReply(r.map { copies.add($0) }))
      }
    case let .copyLocal(copy):
      result(copies.write(copy, to: LocalPasteboard()))
    case let .dropCopy(copy):
      copies.drop(copy)
      result(nil)
    case let .reveal(path):
      let url = URL(fileURLWithPath: path)
      if FileManager.default.fileExists(atPath: path) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
        result(true)
      } else {
        result(false)
      }
    case let .composerPaste(sid):
      // ⌘V on B: the user's own clipboard, read on main by the composer.
      result(pasteResultPayload(live[sid]?.session.composer.paste() ?? .nothing))
    case let .composerAttach(sid):
      attach(sid: sid, result: result)
    case let .composerSend(sid, pieces):
      live[sid]?.session.composer.send(pieces)
      result(nil)
    case let .composerDropBlock(sid, block):
      live[sid]?.session.composer.drop(block)
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
    case let .detach(sid):
      detachSession(sid)
      result(nil)
    case let .attach(sid):
      attachSession(sid)
      result(nil)
    case let .raiseDetached(sid):
      detached[sid]?.raise()
      result(nil)
    }
  }

  /// On main: the session's windows leave the stage for their own (R20). Nothing to show (no
  /// decorated window), an unknown or an already detached session: nothing happens.
  private func detachSession(_ sid: Int64) {
    guard detached[sid] == nil, let entry = live[sid],
          entry.windows.contains(where: { $0.info.kind.isDecorated }) else { return }
    // Keys typed on the stage were the stage's: A gets their releases before the windows move.
    if keysHolder == sid { releaseKeys() }
    detached[sid] = DetachedSession(session: entry.session, windows: entry.windows, beside: view?.window,
                                    onAttach: { [weak self] in self?.attachSession(sid) })
    let payload = detachedPayload(sid: sid, detached: true, current: nil)
    channel.invokeMethod(payload.method, arguments: payload.args)
  }

  /// On main: back on the stage (Dart's `attach`, ⌃⌘D in one of its windows, or no window left,
  /// R7); the last key window becomes the current tab (R21).
  private func attachSession(_ sid: Int64) {
    guard let session = detached.removeValue(forKey: sid) else { return }
    let wasKey = session.owns(NSApp.keyWindow)
    let current = session.lastKey
    if keysHolder == sid { releaseKeys() }
    session.close()
    // Focus stays within rapp: only when one of these windows had it does the main window take it.
    if wasKey { view?.window?.makeKeyAndOrderFront(nil) }
    let payload = detachedPayload(sid: sid, detached: false, current: current)
    channel.invokeMethod(payload.method, arguments: payload.args)
  }

  /// On main: 「附件」's file picker; the picked files go to the composer's (tested) `attach`.
  /// One per session: a second 「附件」 brings it to the front; the session's end cancels it.
  private func attach(sid: Int64, result: @escaping FlutterResult) {
    if let open = panels[sid] {
      open.makeKeyAndOrderFront(nil)
      result([String: Any]())
      return
    }
    guard live[sid] != nil else {
      result([String: Any]())
      return
    }
    let panel = NSOpenPanel()
    panels[sid] = panel
    panel.canChooseFiles = true
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = true
    panel.begin { [weak self] response in
      if self?.panels[sid] === panel { self?.panels[sid] = nil }
      guard response == .OK, let composer = self?.live[sid]?.session.composer else {
        result([String: Any]())
        return
      }
      result(pasteResultPayload(composer.attach(panel.urls)))
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
    // Key focus leaving the main window or a detached one: A gets the releases (R15).
    resignObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.didResignKeyNotification, object: nil, queue: .main
    ) { [weak self] note in
      guard let self, let window = note.object as? NSWindow else { return }
      guard window === self.view?.window || self.detached.values.contains(where: { $0.owns(window) }) else { return }
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

  /// On main, for every key event of the app: a key for A is sent to its session and swallowed
  /// (nil); everything else goes on unchanged. Which session is the event's window's: the main
  /// window's is the one whose picture has focus (`routeKey`), a detached window's is its own
  /// (`routeDetachedKey`), any other window's (panels, sheets) or none is rapp's (finding v).
  private func route(_ event: NSEvent) -> NSEvent? {
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
    var owners = [ObjectIdentifier: Int64]()
    for (sid, session) in detached {
      for window in session.allWindows { owners[ObjectIdentifier(window)] = sid }
    }
    let to = keyWindowRoute(window: event.window.map(ObjectIdentifier.init),
                            main: view?.window.map(ObjectIdentifier.init), detached: owners)
    let targetSid: Int64?
    let decision: KeyDecision
    var attach = false
    switch to {
    case .local:
      return event
    case .main:
      targetSid = focusedSid.flatMap { live[$0] != nil && detached[$0] == nil ? $0 : nil }
      if targetSid != keysHolder { releaseKeys() }
      decision = keys.route(keyCode: event.keyCode, down: down, flags: event.modifierFlags,
                            pictureFocused: targetSid != nil)
    case let .detached(sid):
      targetSid = sid
      if targetSid != keysHolder { releaseKeys() }
      decision = keys.routeDetached(keyCode: event.keyCode, down: down, flags: event.modifierFlags)
      attach = down && event.type == .keyDown
        && routeDetachedKey(keyCode: event.keyCode, flags: event.modifierFlags) == .attach
    }
    // A held ⌃⌘D repeats: swallowed, and only its first press toggles.
    if attach, event.isARepeat { return nil }
    let target = targetSid.flatMap { live[$0] }
    for code in decision.release {
      target?.session.send(.key(keyCode: code, modifiers: 0, down: false))
    }
    if attach, let sid = targetSid {
      // ⌃⌘D in a detached window: back on the stage, once this event is done with its window.
      DispatchQueue.main.async { [weak self] in self?.attachSession(sid) }
      return nil
    }
    guard decision.route == .remote, let target, let sid = targetSid else { return event }
    keysHolder = sid
    target.session.send(.key(keyCode: event.keyCode, modifiers: UInt64(event.modifierFlags.rawValue), down: down))
    return nil
  }

  /// A release for every key A still holds, to the session that got the presses (nothing stays stuck on A).
  private func releaseKeys() {
    let held = keys.releaseAll()
    defer { keysHolder = nil }
    guard let sid = keysHolder, let entry = live[sid] else { return }
    for code in held {
      entry.session.send(.key(keyCode: code, modifiers: 0, down: false))
    }
  }

  private func start(sid: Int64, port: UInt16, token: String, mode: Mode, fps: UInt8, density: DensityChoice) {
    let address = RemoteAddress(host: "127.0.0.1", port: port, bundleID: "", token: token, mode: mode, fps: fps)
    let queue = DispatchQueue(label: "rapp.session.\(sid)")
    let session = EmbeddedSession(address: address, choice: density, backingScale: backingScale,
                                  link: Connection(address: address, queue: queue),
                                  pasteboard: LocalPasteboard(), queue: queue, downloads: downloads)
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
      detached[sid]?.surfacesUpdated(ids)
    case let .windows(windows):
      let change = textureChanges(have: Set(entry.textures.keys), windows: windows)
      for id in change.unregister {
        if let t = entry.textures.removeValue(forKey: id) { registry.unregisterTexture(t.id) }
      }
      for id in change.register {
        let texture = SurfaceTexture(surfaces: entry.session.surfaces, window: id)
        entry.textures[id] = (registry.register(texture), texture)
      }
      entry.windows = windows
      // The textures stay registered while detached: attaching shows the picture at once.
      detached[sid]?.update(windows)
    case .disconnected:
      // The link is down but the last pictures stay; Dart decides when the session ends.
      panels.removeValue(forKey: sid)?.cancel(nil)
      if keysHolder == sid {
        _ = keys.releaseAll()
        keysHolder = nil
      }
      if focusedSid == sid { focusedSid = nil }
    case .closed:
      // Every texture goes before Dart hears the session ended.
      entry.textures.values.forEach { registry.unregisterTexture($0.id) }
      entry.textures = [:]
      live[sid] = nil
      panels.removeValue(forKey: sid)?.cancel(nil)
      // Its windows go with it (the close button, 「结束会话」, A quitting): no attach is sent.
      detached.removeValue(forKey: sid)?.close()
      if keysHolder == sid {
        _ = keys.releaseAll()
        keysHolder = nil
      }
      if focusedSid == sid { focusedSid = nil }
    default:
      break
    }
    if let payload = eventPayload(event, sid: sid, textures: entry.textures.mapValues(\.id)) {
      channel.invokeMethod(payload.method, arguments: payload.args)
    }
    // A detached session that loses its link goes back to the main window (after Dart heard `disconnected`).
    if case .disconnected = event, detached[sid] != nil { attachSession(sid) }
  }
}
