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
  }

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
