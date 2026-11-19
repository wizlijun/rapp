import CRime
import Flutter
import GameController
import RappRimeKeys
import UIKit

/// The built-in Rime input method for hardware keyboards, on the `rapp/rime` channel. Dart says when it is wanted
/// (`configure`, `active`); presses `SessionPlugin` keeps local come here first, and the composition and the
/// candidate menu go back to Dart as `update`. Main thread only.
public final class RappRimePlugin: NSObject, FlutterPlugin {
  public static private(set) var shared: RappRimePlugin?

  private let channel: FlutterMethodChannel
  private let engine = RimeEngine()

  // What Dart wants.
  private var enabled = false
  private var dictionary = RimeEngine.Dictionary.bundled
  /// The editor has focus, the switch is on and set to 「内」.
  private var active = false
  /// The engine should be loaded: latched once the switch is on with a hardware keyboard attached (at
  /// `configure` or when one connects, not on first focus), then kept until the switch goes off (`LoadPolicy`).
  private var wanted = false
  private var redeployPending = false

  // Keys.
  private var ledger = PressLedger()
  /// Swallowed presses still down when Dart deactivated: their releases are still swallowed (Flutter never saw
  /// them go down), unless the key is pressed again first.
  private var orphans = Set<Int>()
  private var repeats = RepeatPolicy()
  private var repeatTimer: Timer?
  private var repeatHid: Int?
  private var lastAscii: Bool?

  init(channel: FlutterMethodChannel) {
    self.channel = channel
    super.init()
    engine.onState = { [weak self] state in
      guard let self else { return }
      if state != .ready { self.stopRepeat() }
      self.pushStatus()
      // The composition went away with the session (released, reloaded, failed): Dart drops its copy.
      if state != .starting { self.push() }
    }
    let nc = NotificationCenter.default
    nc.addObserver(self, selector: #selector(keyboardChanged), name: .GCKeyboardDidConnect, object: nil)
    nc.addObserver(self, selector: #selector(keyboardChanged), name: .GCKeyboardDidDisconnect, object: nil)
    nc.addObserver(self, selector: #selector(willResignActive), name: UIApplication.willResignActiveNotification,
                   object: nil)
  }

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "rapp/rime", binaryMessenger: registrar.messenger())
    let instance = RappRimePlugin(channel: channel)
    shared = instance
    registrar.addMethodCallDelegate(instance, channel: channel)
    NSLog("rapp_rime: librime %@", instance.version)
  }

  private var version: String {
    rime_get_api().pointee.get_version().map { String(cString: $0) } ?? "unknown"
  }

  private var keyboard: Bool { GCKeyboard.coalesced != nil }

  // MARK: channel

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "version":
      result(version)
    case "configure":
      enabled = args["enabled"] as? Bool ?? false
      dictionary = (args["dictionary"] as? String).flatMap(RimeEngine.Dictionary.init(rawValue:)) ?? .bundled
      if !enabled { deactivate() }
      latch()
      reconcile()
      pushStatus()
      result(nil)
    case "active":
      let on = args["on"] as? Bool ?? false
      if on != active {
        active = on
        if !on { deactivate() }
      }
      reconcile()
      result(nil)
    case "select":
      if let index = args["index"] as? Int, engine.ready { engine.select(index); push() }
      result(nil)
    case "page":
      if engine.ready { engine.page(next: args["next"] as? Bool ?? true); push() }
      result(nil)
    case "flush":
      // Always answers with an update, even with no engine: Dart holds edits back until it comes.
      flush()
      result(nil)
    case "clear":
      engine.clear()
      push()
      result(nil)
    case "redeploy":
      redeployPending = true
      reconcile()
      result(nil)
    case "userFolder":
      result(["path": RimeEngine.userFolder.path, "ready": RimeEngine.userFolderReady])
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func latch() {
    wanted = LoadPolicy.wanted(was: wanted, enabled: enabled, keyboard: keyboard)
  }

  /// Brings the engine in line with what Dart wants. A load in progress finishes first, then this runs again.
  private func reconcile() {
    guard !engine.loading else { return }
    guard enabled, wanted else {
      if engine.loaded != nil { engine.stop() }
      if redeployPending { redeployPending = false; RimeEngine.removeBuild(dictionary) }
      return
    }
    guard redeployPending || engine.loaded != dictionary else { return }
    if redeployPending { redeployPending = false; engine.stop(); RimeEngine.removeBuild(dictionary) }
    engine.start(dictionary) { [weak self] in self?.reconcile() }
  }

  private func pushStatus() {
    let (state, message): (String, String) = switch engine.state {
    case .off: ("off", "")
    case .starting: ("starting", "")
    case .ready: ("ready", "")
    case let .error(m): ("error", m)
    }
    channel.invokeMethod("status", arguments: ["state": state, "message": message, "keyboard": keyboard])
  }

  /// `delete`: how many ⌫ Dart applies at the caret after the commit (a declined replayed ⌫).
  private func push(extra: String = "", delete: Int = 0) {
    var update = engine.update(extra: extra)
    if delete > 0 { update["delete"] = delete }
    lastAscii = update["ascii"] as? Bool
    channel.invokeMethod("update", arguments: update)
  }

  /// Commits the raw input as typed and clears the composition.
  private func flush() {
    let raw = engine.input
    engine.clear()
    push(extra: raw)
  }

  // MARK: events

  @objc private func keyboardChanged() {
    if !keyboard { stopRepeat(); repeats.endAll() } // a key held while the keyboard went away never comes up
    latch()
    reconcile()
    pushStatus()
  }

  @objc private func willResignActive() {
    stopRepeat()
    repeats.endAll()
    if !engine.input.isEmpty { flush() }
  }

  /// Dart's editor lost the engine (focus, 「系」, switch off): forget the keys in flight.
  private func deactivate() {
    stopRepeat()
    repeats.endAll()
    orphans.formUnion(ledger.forgetAll())
  }

  // MARK: keys

  /// A press or release `SessionPlugin` kept local (began=false is a release or a cancel). True when it was
  /// swallowed and must not go on to Flutter. A release goes wherever its press went.
  public func handlePress(_ press: UIPress, began: Bool) -> Bool {
    guard let key = press.key else { return false }
    let hid = key.keyCode.rawValue
    if !began {
      repeats.ended(hid: hid)
      if repeatHid == hid { stopRepeat() }
      // Shift's release reaches the engine too: that is how Rime toggles 中/英.
      if active, engine.ready, let k = rimeKey(key) {
        if engine.process(k.keysym, k.mask | RimeKeyMap.release) || engine.ascii != lastAscii { push() }
      }
      let swallowedPress = ledger.release(hid: hid)
      return orphans.remove(hid) != nil || swallowedPress
    }
    orphans.remove(hid)
    // A repeat of a key Flutter holds stays with Flutter, whatever changed since its first press.
    guard active, engine.ready, !ledger.flutterHolds(hid: hid) else { return pass(hid) }
    if repeats.began(hid: hid) { stopRepeat() } // the system repeats on its own: never on top of it
    if RimeKeyMap.isModifier(hid: hid) {
      // To the engine, and on to Flutter, whose modifier state must stay right.
      if let k = rimeKey(key), engine.process(k.keysym, k.mask) || engine.ascii != lastAscii { push() }
      return pass(hid)
    }
    guard let k = rimeKey(key) else { return pass(hid) }
    let text = RimeKeyMap.typedText(characters: key.characters, modifiers: key.modifierFlags.rawValue)
    guard send(k, text: text) else { return pass(hid) }
    ledger.took(hid: hid)
    if repeats.ownRepeat { startRepeat(hid, k, text) }
    return true
  }

  /// A press type-to-compose held back, played into the editor once it has focus. True when it was taken (the
  /// engine processed it; or it declined it and it is printable text, committed through Dart like a live press;
  /// or a declined ⌫, which Dart applies at the caret), so the caller must not insertText or deleteBackward it.
  /// False (other non-text keys, engine not active or not ready, modifiers, unmapped keys): the caller handles it
  /// as before. Text edits must not take the caller's way once any edit went through Dart: the iOS text-input
  /// copy learns of a Dart-side edit only through the async setEditingState, so a synchronous insertText or
  /// deleteBackward right after one ("ni␣1": 你, then 1) edits the stale copy, and its full-state update
  /// overwrites what Dart did (`ReplayPolicy`). No repeat, no ledger.
  public func replay(hid: Int, characters: String, modifiers: Int) -> Bool {
    guard active, engine.ready, !RimeKeyMap.isModifier(hid: hid),
          let k = RimeKeyMap.map(hid: hid, characters: characters, ignoringModifiers: characters, modifiers: modifiers)
    else { return false }
    let processed = engine.process(k.keysym, k.mask)
    switch ReplayPolicy.decide(processed: processed,
                               typedText: RimeKeyMap.typedText(characters: characters, modifiers: modifiers),
                               isBackspace: hid == RimeKeyMap.backspaceHid) {
    case .engine: push()
    case let .dart(text): push(extra: text)
    case .delete: push(delete: 1)
    case .pass: return false
    }
    return true
  }

  private func pass(_ hid: Int) -> Bool {
    ledger.passed(hid: hid)
    return false
  }

  private func rimeKey(_ key: UIKey) -> RimeKey? {
    RimeKeyMap.map(hid: key.keyCode.rawValue, characters: key.characters,
                   ignoringModifiers: key.charactersIgnoringModifiers, modifiers: key.modifierFlags.rawValue)
  }

  /// One key into the engine. Printable text the engine leaves is committed through Dart, so the system input
  /// method never sees it either. True when taken either way.
  private func send(_ k: RimeKey, text: String?) -> Bool {
    if engine.process(k.keysym, k.mask) { push(); return true }
    guard let text else { return false }
    push(extra: text)
    return true
  }

  private func startRepeat(_ hid: Int, _ k: RimeKey, _ text: String?) {
    stopRepeat()
    repeatHid = hid
    let first = Timer(timeInterval: RepeatPolicy.delay, repeats: false) { [weak self] _ in
      guard let self, self.repeatHid == hid else { return }
      let every = Timer(timeInterval: RepeatPolicy.interval, repeats: true) { [weak self] _ in
        guard let self, self.repeatHid == hid, self.active, self.engine.ready else { self?.stopRepeat(); return }
        _ = self.send(k, text: text)
      }
      self.repeatTimer = every
      RunLoop.main.add(every, forMode: .common)
    }
    repeatTimer = first
    RunLoop.main.add(first, forMode: .common)
  }

  private func stopRepeat() {
    repeatTimer?.invalidate()
    repeatTimer = nil
    repeatHid = nil
  }
}
