import Carbon
import Cocoa
import FlutterMacOS

/// Password fields: Flutter's `obscureText` keeps the input method on, so pinyin candidates pop up
/// over a password. While one has focus this does what NSSecureTextField does: secure event input
/// on and an ASCII keyboard layout selected; the previous input source comes back afterwards.
final class SecureInputPlugin {
  /// One main window, one engine: kept for the app's lifetime.
  private static var shared: SecureInputPlugin?

  /// Fields that asked to begin and have not ended; nested or overlapping fields share one engage.
  private var depth = 0
  /// Engaged = secure input on (and the layout switched); only while rapp's window has the keys.
  private var engaged = false
  /// The input source to put back on disengage; nil when it already was the ASCII layout.
  private var previous: TISInputSource?
  private weak var window: NSWindow?
  private var observers: [NSObjectProtocol] = []
  private var channel: FlutterMethodChannel?

  static func register(with registrar: FlutterPluginRegistrar, window: NSWindow) {
    let plugin = SecureInputPlugin(window: window)
    let channel = FlutterMethodChannel(name: "rapp/secure-input", binaryMessenger: registrar.messenger)
    channel.setMethodCallHandler { call, result in plugin.handle(call, result: result) }
    plugin.channel = channel
    shared = plugin
    LocalImePlugin.register(with: registrar)
  }

  /// True while secure input is engaged (a password field has focus): the local IME channel then does nothing.
  static var isEngaged: Bool { shared?.engaged ?? false }

  private init(window: NSWindow) {
    self.window = window
    // Switching apps or to another rapp window must not keep the keyboard locked to ASCII
    // (secure input also blocks other apps' key monitoring); coming back restores it.
    let center = NotificationCenter.default
    let names: [(Notification.Name, AnyObject?)] = [
      (NSApplication.didBecomeActiveNotification, nil),
      (NSApplication.didResignActiveNotification, nil),
      (NSWindow.didBecomeKeyNotification, window),
      (NSWindow.didResignKeyNotification, window),
    ]
    for (name, object) in names {
      observers.append(center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
        self?.refresh()
      })
    }
    observers.append(center.addObserver(
      forName: NSApplication.willTerminateNotification, object: nil, queue: .main
    ) { [weak self] _ in self?.disengage() })
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "begin": depth += 1
    case "end": depth = max(depth - 1, 0)  // an unmatched end (e.g. after a hot restart) is harmless
    default:
      result(FlutterMethodNotImplemented)
      return
    }
    refresh()
    result(nil)
  }

  private func refresh() {
    if depth > 0 && NSApp.isActive && window?.isKeyWindow == true {
      engage()
    } else {
      disengage()
    }
  }

  private func engage() {
    guard !engaged else { return }
    engaged = true
    EnableSecureEventInput()
    guard let ascii = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
          let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return }
    if sourceID(current) != sourceID(ascii) {
      previous = current
      TISSelectInputSource(ascii)
    }
  }

  private func disengage() {
    guard engaged else { return }
    engaged = false
    DisableSecureEventInput()
    if let previous {
      TISSelectInputSource(previous)
      self.previous = nil
    }
  }

  private func sourceID(_ source: TISInputSource) -> String? {
    guard let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
    return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
  }
}

/// Switches the local input source for the writing panel: Chinese when it gets the caret, the ASCII
/// layout when the user returns to the streamed picture. Ignored while secure input is engaged.
final class LocalImePlugin {
  static func register(with registrar: FlutterPluginRegistrar) {
    let plugin = LocalImePlugin()
    let channel = FlutterMethodChannel(name: "rapp/local-ime", binaryMessenger: registrar.messenger)
    channel.setMethodCallHandler { call, result in plugin.handle(call, result: result) }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    if SecureInputPlugin.isEngaged {
      result(nil)
      return
    }
    switch call.method {
    case "toChinese":
      let preferred = (call.arguments as? [String: Any])?["preferred"] as? String
      result(toChinese(preferred: preferred))
    case "toEnglish":
      if let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(), !isASCII(current),
         let ascii = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue() {
        TISSelectInputSource(ascii)
      }
      result(nil)
    case "current":
      guard let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(), let id = id(current) else {
        result(nil)
        return
      }
      result(["id": id, "ascii": isASCII(current)])
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func toChinese(preferred: String?) -> String? {
    var target: TISInputSource?
    if let preferred, !preferred.isEmpty {
      let filter = [kTISPropertyInputSourceID as String: preferred] as CFDictionary
      let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource]
      target = list?.first(where: usable)
    }
    if target == nil {
      let list = TISCreateInputSourceList(nil, false)?.takeRetainedValue() as? [TISInputSource]
      target = list?.first { usable($0) && !isASCII($0) && languages($0).contains { $0.hasPrefix("zh") } }
    }
    guard let target, let targetID = id(target) else { return nil }
    if let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(), id(current) == targetID {
      return targetID
    }
    return TISSelectInputSource(target) == noErr ? targetID : nil
  }

  /// Enabled and selectable.
  private func usable(_ source: TISInputSource) -> Bool {
    bool(source, kTISPropertyInputSourceIsEnabled) && bool(source, kTISPropertyInputSourceIsSelectCapable)
  }

  private func bool(_ source: TISInputSource, _ key: CFString) -> Bool {
    guard let raw = TISGetInputSourceProperty(source, key) else { return false }
    return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(raw).takeUnretainedValue())
  }

  private func isASCII(_ source: TISInputSource) -> Bool {
    guard let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceType) else { return false }
    let type = Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue()
    return CFEqual(type, kTISTypeKeyboardLayout)
  }

  private func languages(_ source: TISInputSource) -> [String] {
    guard let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages) else { return [] }
    return (Unmanaged<CFArray>.fromOpaque(raw).takeUnretainedValue() as? [String]) ?? []
  }

  private func id(_ source: TISInputSource) -> String? {
    guard let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
    return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
  }
}
