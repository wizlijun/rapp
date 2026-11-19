import Cocoa
import FlutterMacOS

/// The Dock menu and the quit gate over `rapp/dock` (Dart side: lib/dock_channel.dart).
/// `applicationDockMenu` is synchronous, so Dart pushes the menu ahead (`setMenu`) and it is kept here;
/// a click goes back as `click(key)`. A quit with remote windows open is asked about in Dart first.
final class DockMenu: NSObject {
  static private(set) var shared: DockMenu?

  private let channel: FlutterMethodChannel
  private var items: [[String: Any]] = []
  /// Dart has spoken (its first `setMenu`): before that a quit goes straight through.
  private(set) var dartReady = false
  /// Dart confirmed the quit: the next `applicationShouldTerminate` lets it through.
  private(set) var quitConfirmed = false

  private init(channel: FlutterMethodChannel) {
    self.channel = channel
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { return result(nil) }
      switch call.method {
      case "setMenu":
        self.items = call.arguments as? [[String: Any]] ?? []
        self.dartReady = true
        result(nil)
      case "confirmQuit":
        self.quitConfirmed = true
        result(nil)
        // Through NSApp.terminate, so willTerminate observers (key releases to A) still run.
        DispatchQueue.main.async { NSApp.terminate(nil) }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  static func register(messenger: FlutterBinaryMessenger) {
    shared = DockMenu(channel: FlutterMethodChannel(name: "rapp/dock", binaryMessenger: messenger))
  }

  /// The menu Dart last pushed; nil before the first push.
  func menu() -> NSMenu? {
    if items.isEmpty { return nil }
    let menu = NSMenu()
    menu.autoenablesItems = false
    for item in items {
      if item["separator"] as? Bool == true {
        menu.addItem(.separator())
        continue
      }
      let entry = NSMenuItem(title: item["label"] as? String ?? "", action: nil, keyEquivalent: "")
      if let key = item["key"] as? String {
        entry.target = self
        entry.action = #selector(clicked(_:))
        entry.representedObject = key
      }
      entry.isEnabled = item["disabled"] as? Bool != true && entry.action != nil
      menu.addItem(entry)
    }
    return menu
  }

  @objc private func clicked(_ item: NSMenuItem) {
    guard let key = item.representedObject as? String else { return }
    channel.invokeMethod("click", arguments: key)
  }

  /// Asks Dart to confirm a quit (it answers with `confirmQuit`, or not at all when cancelled).
  func requestQuit() {
    channel.invokeMethod("quitRequested", arguments: nil)
  }
}
