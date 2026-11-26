#if os(macOS)
import Cocoa
import FlutterMacOS
#else
import Flutter
import UIKit
#endif
import CoreVideo
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

#if os(iOS)
/// One A window's full-window base picture (the last frame that showed all of it), which the zoom UI
/// shows around a partial stream.
final class BaseTexture: NSObject, FlutterTexture {
  private let surfaces: WindowSurfaces
  private let window: UInt32

  init(surfaces: WindowSurfaces, window: UInt32) {
    self.surfaces = surfaces
    self.window = window
  }

  func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
    surfaces.base(window).map { Unmanaged.passRetained($0) }
  }
}

/// One hardware-keyboard press held behind a type-to-compose letter (iOS's `ComposeHold` event).
struct HeldPress {
  let hid: Int
  let characters: String
  let modifiers: Int
  let down: Bool
}
#endif

/// The `rapp/session` channel: glue between Dart and the embedded sessions in `RappSession`.
/// Parsing and encoding are `channelCommand` / `eventPayload`; this only owns the sessions,
/// their textures, their detached windows and the main-thread hops. Shared by the macOS and
/// iOS runners: what only exists on the Mac (detached windows, the key monitor, Finder, the
/// open panel) is macOS-only; the iPad's hardware keyboard comes in through `handlePresses`.
///
/// Threading, per entry point: `handle` (Flutter's platform thread, which is main),
/// `deliver` (hopped onto main from each session's queue), the key monitor / `handlePresses`
/// and every observer (main). So all of this object's state is main-only; a session is only
/// reached through its queue-safe `send`/`close`/`setStream`…, or on its queue (`backingScale`).
final class SessionPlugin: NSObject, FlutterPlugin {
  #if os(iOS)
  /// The registered plugin, for the root view controller's presses.
  static weak var shared: SessionPlugin?
  /// Tried first for each replayed press (the built-in input method, set by the iOS runner): true when it took
  /// the press, which then is not typed as text.
  static var replayHook: ((HeldPress) -> Bool)?
  #endif

  private final class Live {
    let session: EmbeddedSession
    /// The session's own queue: its state (`backingScale` included) is only touched there.
    let queue: DispatchQueue
    /// Window id → its registered texture.
    var textures = [UInt32: (id: Int64, texture: SurfaceTexture)]()
    #if os(iOS)
    /// Window id → its registered base-picture texture.
    var bases = [UInt32: (id: Int64, texture: BaseTexture)]()
    #endif
    /// A's latest window table, for a detach.
    var windows = [SessionWindow]()
    init(session: EmbeddedSession, queue: DispatchQueue) {
      self.session = session
      self.queue = queue
    }
  }

  /// Copies of A's clips; they outlive the session they came from.
  private let copies = ClipCopies()
  /// Where downloads go, worked out at each use so a moved data dir applies to new downloads.
  private var downloads: URL { DataPaths.currentTransfers() }
  private let channel: FlutterMethodChannel
  private let registry: FlutterTextureRegistry
  private var live = [Int64: Live]()
  private var ready = false
  private var timer: Timer?
  /// The session whose picture has keyboard focus (Dart's `picture_focus`).
  private var focusedSid: Int64?
  /// The session the held keys were sent to (`keys` on macOS, `router` on iOS), if any.
  private var keysHolder: Int64?
  /// Dart's `picture_focus` compose flag for `focusedSid`: a letter there opens the writing panel.
  private var composeOn = false
  /// Dart's `picture_focus` voice flag for `focusedSid`: holding the voice hotkey there starts voice input (macOS).
  private var voiceOn = false
  /// Sessions whose A focus is in a password field (v13 `secure_focus`): no type-to-compose there,
  /// decided here so the very first key of a password never opens the panel.
  private var secure = Set<Int64>()
  /// Windows the GUI hides per session (set_hidden); detached windows leave them out.
  private var hidden = [Int64: Set<UInt32>]()
  /// The banner each session's detached windows show (Dart's `set_banner`), kept for a later detach.
  private var banners = [Int64: String]()
  private var resignObserver: NSObjectProtocol?
  private var terminateObserver: NSObjectProtocol?
  #if os(macOS)
  private weak var view: NSView?
  private var scaleObserver: NSObjectProtocol?
  /// What A has been sent presses for: released when focus leaves (R15). One tracker for the
  /// stage and the detached windows, so a release always goes where its press went.
  private var keys = KeyTracker()
  /// The compose letter and what followed it, until Dart asks for them back (`compose_replay`).
  private var hold = ComposeHold<NSEvent>()
  /// Re-dispatching held events: they go to rapp's window as they are.
  private var replaying = false
  /// Sessions shown in their own windows instead of on the stage (R20).
  private var detached = [Int64: DetachedSession]()
  private var keyMonitor: Any?
  /// 「附件」's open file picker, one per session.
  private var panels = [Int64: NSOpenPanel]()
  /// Hold-to-talk on the stage picture: decides, in front of the main window's key routing, which
  /// keys are the voice hotkey (and so never reach A) and when voice input starts and ends.
  private var gate = VoiceKeyGate()
  /// The hotkey down the gate swallowed while it waits to see a long press; A gets it on a flush.
  private var gateHeld: NSEvent?
  /// The session the gate's voice input is for (its `voice_key` calls carry it).
  private var gateSid: Int64?
  /// Feeds the gate `.elapsed` once the hotkey has been held `VoiceKeyGate.holdDelay`.
  private var gateTimer: DispatchWorkItem?
  #else
  /// The hardware keyboard: what goes to A, what A holds (released on blur), the latched modifiers.
  private var router = PressRouter()
  /// The compose letter and the presses after it, until Dart asks for them back (`compose_replay`).
  private var hold = ComposeHold<HeldPress>()
  #endif

  #if os(macOS)
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
  #else
  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "rapp/session", binaryMessenger: registrar.messenger())
    let plugin = SessionPlugin(channel: channel, registry: registrar.textures())
    registrar.addMethodCallDelegate(plugin, channel: channel)
    shared = plugin
  }

  private init(channel: FlutterMethodChannel, registry: FlutterTextureRegistry) {
    self.channel = channel
    self.registry = registry
  }
  #endif

  deinit {
    timer?.invalidate()
    if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
    if let terminateObserver { NotificationCenter.default.removeObserver(terminateObserver) }
    #if os(macOS)
    if let scaleObserver { NotificationCenter.default.removeObserver(scaleObserver) }
    if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    #endif
  }

  private var backingScale: CGFloat {
    #if os(macOS)
    view?.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    #else
    UIScreen.main.scale
    #endif
  }

  private var doubleClickMs: Int {
    #if os(macOS)
    Int((NSEvent.doubleClickInterval * 1000).rounded())
    #else
    500
    #endif
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
      result(["doubleClickMs": doubleClickMs])
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
    case let .mouse(sid, message):
      #if os(macOS)
      // A press on the picture: a held hotkey was a modifier for the click, a recording is cancelled.
      if case .mouse(kind: .down, _, _, _, _, _) = message { gateFeed(.pointer, targetSid: mainTargetSid) }
      #endif
      live[sid]?.session.send(message)
      result(nil)
    case let .scroll(sid, message):
      #if os(macOS)
      gateFeed(.scroll, targetSid: mainTargetSid)  // a held hotkey was a modifier for the scroll
      #endif
      live[sid]?.session.send(message)
      result(nil)
    case let .resize(sid, message):
      live[sid]?.session.send(message)
      result(nil)
    case let .key(sid, keyCode, modifiers):
      live[sid]?.session.send(.key(keyCode: keyCode, modifiers: modifiers, down: true))
      live[sid]?.session.send(.key(keyCode: keyCode, modifiers: modifiers, down: false))
      result(nil)
    case let .keyEvent(sid, keyCode, modifiers, down):
      live[sid]?.session.send(.key(keyCode: keyCode, modifiers: modifiers, down: down))
      result(nil)
    #if os(macOS)
    case .latch:
      result(nil)  // external-keyboard latch is iOS only
    #else
    case let .latch(_, modifiers):
      router.latched = modifiers  // the hardware keyboard's next key carries these
      result(nil)
    #endif
    case let .selectWindow(sid, window):
      live[sid]?.session.send(.focus(window))
      result(nil)
    case let .closeWindow(sid, window):
      live[sid]?.session.send(.close(window))
      result(nil)
    case let .autoEnglish(sid, on):
      live[sid]?.session.setAutoEnglish(on)
      result(nil)
    case let .selectInput(sid, id):
      // Queued with the session's other messages: a composer send after it reaches A after the switch.
      live[sid]?.session.send(.selectInput(id: id))
      result(nil)
    case let .setView(sid, window, rect, zoom):
      live[sid]?.session.setView(window: window, rect: rect, zoom: zoom)
      result(nil)
    case let .setStream(sid, mode, fps, density, pinned, focus):
      live[sid]?.session.setStream(mode: mode, fps: fps, choice: density, pinned: pinned, focus: focus)
      result(nil)
    case let .cancelTransfer(sid, id):
      if let id { live[sid]?.session.cancelTransfer(id: id) } else { live[sid]?.session.cancelTransfers() }
      result(nil)
    case let .fetchClip(sid, clip):
      guard let entry = live[sid] else {
        result(["error": "远端已断开"])
        return
      }
      // The reply comes back on main (the session hops it), where `copies` lives.
      entry.session.fetchCopy(clip) { [copies] r in
        result(clipCopyReply(r.map { copies.add($0) }))
      }
    case let .copyLocal(copy):
      result(copies.write(copy, to: LocalPasteboard()))
    case let .pinSave(copy, textDir, fileDir, stem):
      do {
        let url = try copies.save(copy, textDir: URL(fileURLWithPath: textDir), fileDir: URL(fileURLWithPath: fileDir),
                                  stem: stem)
        result(url.map { ["path": $0.path] } ?? ["error": "副本已不在"])
      } catch {
        result(["error": "写不进数据目录"])
      }
    case let .pinLoad(path):
      if let r = copies.load(URL(fileURLWithPath: path)) { result(["copy": r.n, "kind": r.kind]) } else { result(nil) }
    case let .dropCopy(copy):
      copies.drop(copy)
      result(nil)
    case let .reveal(path):
      // Only what rapp itself downloaded: inside the downloads dir in use.
      let root = downloads
      if let url = revealableURL(path, within: [root]) {
        #if os(macOS)
        NSWorkspace.shared.activateFileViewerSelecting([url])
        #else
        IosPlugin.share(url.path)  // no Finder: the share sheet (save to Files, AirDrop…)
        #endif
        result(true)
      } else {
        result(false)  // missing, or not in rapp's downloads dir
      }
    case let .composerPaste(sid):
      // ⌘V on B: the user's own clipboard, read on main by the composer.
      result(pasteResultPayload(live[sid]?.session.composer.paste() ?? .nothing))
    #if os(macOS)
    case let .composerAttach(sid):
      attach(sid: sid, result: result)
    #else
    case .composerAttach:
      result(FlutterMethodNotImplemented)  // no file picker on iOS yet
    #endif
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
    case let .pictureFocus(sid, compose, voice):
      hold.focus(sid, compose: compose)
      if sid != focusedSid {
        releaseKeys()
        focusedSid = sid
      }
      composeOn = compose && sid != nil
      voiceOn = voice && sid != nil
      result(nil)
    #if os(macOS)
    case let .setVoiceHotkey(hotkey):
      // A change mid-hold starts the gate over, as a resign does: the old key's hold timer and
      // held down go, and a recording on it is cancelled (Dart ends the hold).
      if hotkey != gate.hotkey {
        gateTimer?.cancel()
        gateTimer = nil
        gateHeld = nil
        let step = gate.setHotkey(hotkey)
        if let phase = step.voice, let sid = gateSid {
          channel.invokeMethod("voice_key", arguments: ["sid": sid, "phase": phase.rawValue])
        }
      }
      result(nil)
    case let .voiceEnd(sid):
      if sid == gateSid { _ = gate.handle(.ended, at: ProcessInfo.processInfo.systemUptime, ready: false) }
      result(nil)
    #else
    case .setVoiceHotkey, .voiceEnd:
      result(nil)  // hold-to-talk on a hotkey is macOS only
    #endif
    case let .composeReplay(sid):
      // The caret is in the panel and the picture blurred (Dart sent `picture_focus(nil)` first):
      // the held keys now reach Flutter's text input, and B's IME, in the order they were typed.
      let events = hold.take(sid: sid, now: ProcessInfo.processInfo.systemUptime)
      #if os(macOS)
      // On the next runloop turn: the panel's text field must have taken the caret first.
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        self.replaying = true
        for e in events { NSApp.sendEvent(e) }
        self.replaying = false
      }
      #else
      DispatchQueue.main.async { [weak self] in self?.replay(events) }
      #endif
      result(nil)
    #if os(macOS)
    case let .detach(sid):
      detachSession(sid)
      result(nil)
    case let .attach(sid):
      attachSession(sid)
      result(nil)
    case let .raiseDetached(sid):
      detached[sid]?.raise()
      result(nil)
    #else
    case .detach:
      result(FlutterError(code: "detach", message: "not on iOS", details: nil))
    case .attach, .raiseDetached:
      result(nil)  // nothing is ever detached on iOS
    #endif
    case let .unlock(sid, password):
      live[sid]?.session.send(.unlock(password: password))
      result(nil)
    case let .stateRules(sid, json):
      live[sid]?.session.send(.stateRules(json))
      result(nil)
    case let .dismissCover(sid, id):
      live[sid]?.session.send(.dismissCover(id))
      result(nil)
    case let .dropTextures(sid):
      #if os(iOS)
      // A memory warning: Dart sends it only for frozen sessions off the stage. Their pictures go; the
      // reconnect registers new ones.
      if let entry = live[sid] {
        entry.textures.values.forEach { registry.unregisterTexture($0.id) }
        entry.textures = [:]
        entry.bases.values.forEach { registry.unregisterTexture($0.id) }
        entry.bases = [:]
      }
      #endif
      result(nil)
    case let .setBanner(sid, text):
      banners[sid] = text.isEmpty ? nil : text
      #if os(macOS)
      detached[sid]?.banner = banners[sid]
      #endif
      result(nil)
    case let .setHidden(sid, windows):
      hidden[sid] = windows.isEmpty ? nil : Set(windows)
      #if os(macOS)
      if let entry = live[sid] {
        detached[sid]?.update(detachedWindows(entry.windows, hidden: hidden[sid] ?? []))
      }
      #endif
      result(nil)
    }
  }

  #if os(macOS)
  /// On main: the session's windows leave the stage for their own (R20). Nothing to show (no
  /// decorated window), an unknown or an already detached session: nothing happens.
  private func detachSession(_ sid: Int64) {
    guard detached[sid] == nil, let entry = live[sid] else { return }
    let shown = detachedWindows(entry.windows, hidden: hidden[sid] ?? [])
    guard shown.contains(where: { $0.info.kind.isDecorated }) else { return }
    // Keys typed on the stage were the stage's: A gets their releases before the windows move.
    if keysHolder == sid { releaseKeys() }
    let session = DetachedSession(session: entry.session, windows: shown, beside: view?.window,
                                  onAttach: { [weak self] in self?.attachSession(sid) })
    session.banner = banners[sid]
    session.onVisible = { [weak self] visible in
      self?.channel.invokeMethod("window_visible", arguments: ["sid": sid, "visible": visible])
    }
    detached[sid] = session
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
  #endif

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
    #if os(macOS)
    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
      guard let self else { return event }
      return self.route(event)
    }
    // Key focus leaving the main window or a detached one: A gets the releases (R15).
    resignObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.didResignKeyNotification, object: nil, queue: .main
    ) { [weak self] note in
      guard let self, let window = note.object as? NSWindow else { return }
      let main = window === self.view?.window
      guard main || self.detached.values.contains(where: { $0.owns(window) }) else { return }
      if main {
        // The gate forgets what is held (a recording is cancelled); A never saw a swallowed hotkey down.
        self.gateFeed(.resign, targetSid: self.mainTargetSid)
        self.gateHeld = nil
        self.gateTimer?.cancel()
        self.gateTimer = nil
      }
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
    #else
    // Leaving the foreground (app switcher, Control Centre, a call…): A gets the releases.
    resignObserver = NotificationCenter.default.addObserver(
      forName: UIApplication.willResignActiveNotification, object: nil, queue: .main
    ) { [weak self] _ in
      self?.releaseKeys()
    }
    terminateObserver = NotificationCenter.default.addObserver(
      forName: UIApplication.willTerminateNotification, object: nil, queue: .main
    ) { [weak self] _ in
      self?.releaseKeys()
    }
    #endif
  }

  #if os(macOS)
  /// On main, for every key event of the app: a key for A is sent to its session and swallowed
  /// (nil); everything else goes on unchanged. Which session is the event's window's: the main
  /// window's is the one whose picture has focus (`routeKey`), a detached window's is its own
  /// (`routeDetachedKey`), any other window's (panels, sheets) or none is rapp's (finding v).
  private func route(_ event: NSEvent) -> NSEvent? {
    if replaying { return event }
    let down: Bool
    switch event.type {
    case .keyDown: down = true
    case .keyUp: down = false
    case .flagsChanged:
      guard let d = modifierKeyIsDown(keyCode: event.keyCode, flags: KeyFlags(event.modifierFlags)) else { return event }
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
    switch to {
    case .local:
      return event
    case .main:
      let targetSid = mainTargetSid
      // The voice gate first: the hotkey held for voice input never reaches A.
      let input: VoiceGateInput = down
        ? .down(event.keyCode, KeyFlags(event.modifierFlags), isRepeat: event.type == .keyDown && event.isARepeat)
        : .up(event.keyCode)
      let step = gateFeed(input, targetSid: targetSid)
      if step.arm { gateHeld = event }
      return step.pass ? routeMain(event, down: down, targetSid: targetSid) : nil
    case let .detached(sid):
      if sid != keysHolder { releaseKeys() }
      let decision = keys.routeDetached(keyCode: event.keyCode, down: down, flags: event.modifierFlags)
      let attach = down && event.type == .keyDown
        && routeDetachedKey(keyCode: event.keyCode, flags: event.modifierFlags) == .attach
      return sendKey(event, down: down, decision: decision, targetSid: sid, attach: attach)
    }
  }

  /// The session whose stage picture has keyboard focus, if it is live and on the stage.
  private var mainTargetSid: Int64? {
    focusedSid.flatMap { live[$0] != nil && detached[$0] == nil ? $0 : nil }
  }

  /// A main-window key event past the voice gate: the compose hold, type-to-compose, then A or rapp.
  private func routeMain(_ event: NSEvent, down: Bool, targetSid: Int64?) -> NSEvent? {
    let now = ProcessInfo.processInfo.systemUptime
    // Waiting for the panel to take the caret: everything typed meanwhile waits behind the letter.
    switch hold.add(event, now: now) {
    case .held: return nil
    case .dropped: releaseKeys()  // a release that sat in the hold is gone: nothing stays stuck on A
    case .notHolding: break
    }
    if let sid = composeStart(keyDown: down && event.type == .keyDown, composeOn: composeOn,
                              targetSid: targetSid, characters: event.characters,
                              flags: KeyFlags(event.modifierFlags), isRepeat: event.isARepeat,
                              remoteSecure: targetSid.map(secure.contains) ?? false) {
      // Type-to-compose: the letter never reaches A; Dart opens the panel, then asks for it back.
      hold.start(sid: sid, event, now: now)
      channel.invokeMethod("compose_key", arguments: ["sid": sid])
      return nil
    }
    if targetSid != keysHolder { releaseKeys() }
    let decision = keys.route(keyCode: event.keyCode, down: down, flags: KeyFlags(event.modifierFlags),
                              pictureFocused: targetSid != nil)
    return sendKey(event, down: down, decision: decision, targetSid: targetSid, attach: false)
  }

  /// Feeds the voice gate one input and acts on its step, except for the event itself: a flush
  /// sends the held hotkey down to A first, an arm marks the session and starts the hold timer,
  /// a phase goes to Dart as `voice_key`. `targetSid`: the stage picture's session (`mainTargetSid`).
  @discardableResult
  private func gateFeed(_ input: VoiceGateInput, targetSid: Int64?) -> VoiceGateStep {
    let step = gate.handle(input, at: ProcessInfo.processInfo.systemUptime, ready: voiceOn && targetSid != nil)
    if step.flush {
      gateTimer?.cancel()
      gateTimer = nil
      if let held = gateHeld {
        gateHeld = nil
        _ = routeMain(held, down: true, targetSid: targetSid)
      }
    }
    // A hold_combo starts on its key down with no arm before it: the start names the session then.
    if step.arm || (step.voice == .start && input != .elapsed) { gateSid = targetSid }
    if step.arm {
      gateTimer?.cancel()
      let timer = DispatchWorkItem { [weak self] in
        guard let self else { return }
        self.gateTimer = nil
        self.gateFeed(.elapsed, targetSid: self.mainTargetSid)
      }
      gateTimer = timer
      DispatchQueue.main.asyncAfter(deadline: .now() + VoiceKeyGate.holdDelay, execute: timer)
    }
    if let phase = step.voice, let sid = gateSid {
      channel.invokeMethod("voice_key", arguments: ["sid": sid, "phase": phase.rawValue])
    }
    return step
  }

  /// Sends a routed key event's releases and the event itself to the session it is for.
  private func sendKey(_ event: NSEvent, down: Bool, decision: KeyDecision, targetSid: Int64?, attach: Bool) -> NSEvent? {
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
    // The keyboard in use hides the 快捷区 when 打字后自动收起 is on (foldKeyBar); ⌘ shortcuts and modifiers alone do not.
    if down, event.type == .keyDown, !event.isARepeat, !event.modifierFlags.contains(.command) {
      channel.invokeMethod("key_typed", arguments: ["sid": sid])
    }
    return nil
  }
  #endif

  /// A release for every key A still holds, to the session that got the presses (nothing stays stuck on A).
  private func releaseKeys() {
    #if os(macOS)
    let held = keys.releaseAll()
    #else
    let held = router.blur().map(\.code)
    #endif
    defer { keysHolder = nil }
    guard let sid = keysHolder, let entry = live[sid] else { return }
    for code in held {
      entry.session.send(.key(keyCode: code, modifiers: 0, down: false))
    }
  }

  /// `sid`'s link is gone: what A held for it is forgotten, nothing is sent.
  private func forgetKeys(of sid: Int64) {
    guard keysHolder == sid else { return }
    #if os(macOS)
    _ = keys.releaseAll()
    #else
    _ = router.blur()
    #endif
    keysHolder = nil
  }

  #if os(iOS)
  /// On main, for the root view controller's hardware-keyboard presses (`began`: pressesBegan, else
  /// ended or cancelled): true when this took them (sent to A, or held for the writing panel), false to
  /// let them go on to Flutter. Every press sent to A is in `router`, so `releaseKeys` lets go of it.
  func handlePresses(_ presses: Set<UIPress>, began: Bool) -> Bool {
    var took = false
    for press in presses {
      guard let key = press.key else { continue }
      if handle(key, down: began) { took = true }
    }
    return took
  }

  private func handle(_ key: UIKey, down: Bool) -> Bool {
    let press = HeldPress(hid: key.keyCode.rawValue, characters: key.characters, modifiers: key.modifierFlags.rawValue,
                          down: down)
    let now = ProcessInfo.processInfo.systemUptime
    // Waiting for the panel to take the caret: everything typed meanwhile waits behind the letter.
    switch hold.add(press, now: now) {
    case .held: return true
    case .dropped: releaseKeys()  // a release that sat in the hold is gone: nothing stays stuck on A
    case .notHolding: break
    }
    let target = focusedSid.flatMap { live[$0] != nil ? $0 : nil }
    router.focusedSid = target
    let action = router.press(hidUsage: press.hid, uiModifiers: press.modifiers, down: down,
                              characters: press.characters, composeOn: composeOn,
                              remoteSecure: target.map(secure.contains) ?? false)
    switch action {
    case .local:
      return false
    case let .compose(sid):
      // Type-to-compose: the letter never reaches A; Dart opens the panel, then asks for it back.
      hold.start(sid: sid, press, now: now)
      channel.invokeMethod("compose_key", arguments: ["sid": sid])
      return true
    case let .localAfterRelease(outs):
      send(outs, to: keysHolder)
      return false
    case let .send(outs, latchUsed):
      guard let sid = target else { return false }
      keysHolder = sid
      send(outs, to: sid)
      if latchUsed { channel.invokeMethod("latch_used", arguments: ["sid": sid]) }
      return true
    }
  }

  private func send(_ outs: [KeyOut], to sid: Int64?) {
    guard let sid, let entry = live[sid] else { return }
    for o in outs { entry.session.send(.key(keyCode: o.code, modifiers: o.flags, down: o.down)) }
  }

  /// `compose_replay` on iOS: the held presses as text into the first responder (the panel's text input,
  /// which has the caret now). Only typed text and ⌫ replay; ups, chords and special keys are dropped.
  private func replay(_ presses: [HeldPress]) {
    guard !presses.isEmpty else { return }
    firstResponder = nil
    UIApplication.shared.sendAction(#selector(UIResponder.rappFindFirstResponder(_:)), to: nil, from: nil, for: nil)
    guard let input = firstResponder as? UIKeyInput else { return }
    let chords = UIKeyModifierFlags([.command, .control, .alternate]).rawValue
    for p in presses where p.down && p.modifiers & chords == 0 {
      if Self.replayHook?(p) == true { continue }
      if p.hid == UIKeyboardHIDUsage.keyboardDeleteOrBackspace.rawValue {
        input.deleteBackward()
      } else if isTypedText(p.characters) {
        input.insertText(p.characters)
      }
    }
  }
  #endif

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
        #if os(iOS)
        // The base picture changes only with a frame that covers the whole window.
        if let b = entry.bases[id], let v = entry.session.surfaces.visible(id), WindowSurfaces.coversWindow(v) {
          registry.textureFrameAvailable(b.id)
        }
        #endif
      }
      #if os(macOS)
      detached[sid]?.surfacesUpdated(ids)
      #endif
    case let .windows(windows):
      let change = textureChanges(have: Set(entry.textures.keys), windows: windows)
      for id in change.unregister {
        if let t = entry.textures.removeValue(forKey: id) { registry.unregisterTexture(t.id) }
        #if os(iOS)
        if let b = entry.bases.removeValue(forKey: id) { registry.unregisterTexture(b.id) }
        #endif
      }
      for id in change.register {
        let texture = SurfaceTexture(surfaces: entry.session.surfaces, window: id)
        entry.textures[id] = (registry.register(texture), texture)
        #if os(iOS)
        let base = BaseTexture(surfaces: entry.session.surfaces, window: id)
        entry.bases[id] = (registry.register(base), base)
        #endif
      }
      entry.windows = windows
      #if os(macOS)
      // The textures stay registered while detached: attaching shows the picture at once.
      detached[sid]?.update(detachedWindows(windows, hidden: hidden[sid] ?? []))
      #endif
    case .appState:
      break  // Flutter gets it through eventPayload
    case let .secureFocus(on):
      if on { secure.insert(sid) } else { secure.remove(sid) }
    case .disconnected:
      // The link is down but the last pictures stay; Dart decides when the session ends.
      #if os(macOS)
      panels.removeValue(forKey: sid)?.cancel(nil)
      #endif
      forgetKeys(of: sid)
      if focusedSid == sid { focusedSid = nil }
    case .closed:
      // Every texture goes before Dart hears the session ended.
      entry.textures.values.forEach { registry.unregisterTexture($0.id) }
      entry.textures = [:]
      #if os(iOS)
      entry.bases.values.forEach { registry.unregisterTexture($0.id) }
      entry.bases = [:]
      #endif
      live[sid] = nil
      hidden[sid] = nil
      banners[sid] = nil
      secure.remove(sid)
      #if os(macOS)
      panels.removeValue(forKey: sid)?.cancel(nil)
      // Its windows go with it (the close button, 「结束会话」, A quitting): no attach is sent.
      detached.removeValue(forKey: sid)?.close()
      #endif
      forgetKeys(of: sid)
      if focusedSid == sid { focusedSid = nil }
    default:
      break
    }
    #if os(iOS)
    let bases = entry.bases.mapValues(\.id)
    #else
    let bases = [UInt32: Int64]()
    #endif
    if let payload = eventPayload(event, sid: sid, textures: entry.textures.mapValues(\.id), bases: bases) {
      channel.invokeMethod(payload.method, arguments: payload.args)
    }
    #if os(macOS)
    // A detached session that loses its link goes back to the main window (after Dart heard `disconnected`).
    if case .disconnected = event, detached[sid] != nil { attachSession(sid) }
    #endif
  }
}

#if os(iOS)
/// Where `rappFindFirstResponder` leaves the first responder (UIKit has no getter for it).
private weak var firstResponder: UIResponder?

extension UIResponder {
  /// Sent down the responder chain with a nil target: the first responder records itself.
  @objc func rappFindFirstResponder(_ sender: Any?) { firstResponder = self }
}

/// Text a press types: not empty, no control characters (⏎ ⇥ ⎋) and none of UIKit's named keys (arrows…).
private func isTypedText(_ s: String) -> Bool {
  !s.isEmpty && !s.hasPrefix("UIKeyInput") && !s.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
}
#endif
