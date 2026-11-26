import Flutter
import Network
import UIKit

/// The `rapp/ios` channel: paths, device facts, network state, background time and the share sheet.
final class IosPlugin: NSObject, FlutterPlugin {
  private let channel: FlutterMethodChannel
  private var background: UIBackgroundTaskIdentifier = .invalid
  private let pathMonitor = NWPathMonitor()
  private var lastPath: NWPath?

  init(channel: FlutterMethodChannel) {
    self.channel = channel
    super.init()
    NotificationCenter.default.addObserver(
      self, selector: #selector(memoryWarning),
      name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
    pathMonitor.pathUpdateHandler = { [weak self] path in
      DispatchQueue.main.async { self?.pathUpdated(path) }
    }
    pathMonitor.start(queue: DispatchQueue(label: "rapp.ios.path"))
  }

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "rapp/ios", binaryMessenger: registrar.messenger())
    let plugin = IosPlugin(channel: channel)
    registrar.addMethodCallDelegate(plugin, channel: channel)
    registrar.addApplicationDelegate(plugin)
  }

  /// The root controller; the storyboard makes it a `RappViewController`.
  private static var root: RappViewController? {
    if let current = RappViewController.current { return current }
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    for scene in scenes {
      let window = scene.keyWindow ?? scene.windows.first
      if let top = window?.rootViewController as? RappViewController { return top }
    }
    return UIApplication.shared.delegate?.window??.rootViewController as? RappViewController
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "paths":
      do { result(try Self.paths()) } catch {
        result(FlutterError(code: "paths", message: "\(error)", details: nil))
      }
    case "deviceName":
      result(UIDevice.current.name)
    case "idiom":
      switch UIDevice.current.userInterfaceIdiom {
      case .pad: result("pad")
      case .phone: result("phone")
      default: result("")  // anything else reads as unknown, not as a phone
      }
    case "version":
      result(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")
    case "net":
      Self.net(result)
    case "openSettings":
      if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
      result(true)
    case "keepAwake":
      UIApplication.shared.isIdleTimerDisabled = args["on"] as? Bool ?? false
      result(true)
    case "sessionActive":
      RappViewController.wantsSessionActive = args["on"] as? Bool ?? false
      result(true)
    case "fullscreen":
      RappViewController.wantsFullscreen = args["on"] as? Bool ?? false
      result(true)
    case "beginBackground":
      beginBackground()
      result(true)
    case "endBackground":
      endBackground()
      result(true)
    case "share":
      guard let path = args["path"] as? String else {
        return result(FlutterError(code: "share", message: "missing path", details: nil))
      }
      if Self.share(path) { result(true) } else {
        result(FlutterError(code: "share", message: "no view controller to present from", details: nil))
      }
    case "openUrl":
      guard let text = args["url"] as? String, let url = URL(string: text) else {
        return result(FlutterError(code: "openUrl", message: "bad url", details: nil))
      }
      UIApplication.shared.open(url)
      result(true)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// `Application Support/rapp` (not backed up, readable after the first unlock) and `Documents/传输`.
  private static func paths() throws -> [String: String] {
    let fm = FileManager.default
    let support = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    let documents = try fm.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    var rapp = support.appendingPathComponent("rapp", isDirectory: true)
    try fm.createDirectory(at: rapp, withIntermediateDirectories: true)
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try rapp.setResourceValues(values)
    try fm.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: rapp.path)
    try fm.createDirectory(at: documents.appendingPathComponent("传输", isDirectory: true), withIntermediateDirectories: true)
    return ["support": support.path, "documents": documents.path]
  }

  /// One system HTTP request plus the current network path. On China-region iPhones an app has no network until the
  /// user answers the "无线数据" prompt, and only system networking (URLSession, Network.framework) brings that prompt
  /// up: the hub's own UDP sockets just time out.
  private static func net(_ result: @escaping FlutterResult) {
    let started = Date()
    let monitor = NWPathMonitor()
    monitor.pathUpdateHandler = { path in
      monitor.cancel()
      var request = URLRequest(url: URL(string: "https://captive.apple.com/hotspot-detect.html")!)
      request.timeoutInterval = 5
      URLSession.shared.dataTask(with: request) { _, response, error in
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let reply: [String: Any] = [
          "ok": error == nil && status == 200,
          "status": status,
          "error": error.map { "\($0)" } ?? "",
          "ms": Int(Date().timeIntervalSince(started) * 1000),
          "wifi": path.usesInterfaceType(.wifi),
          "cellular": path.usesInterfaceType(.cellular),
          "constrained": path.isConstrained,
          "expensive": path.isExpensive,
        ]
        DispatchQueue.main.async { result(reply) }
      }.resume()
    }
    monitor.start(queue: DispatchQueue(label: "rapp.ios.net"))
  }

  private func beginBackground() {
    endBackground()
    background = UIApplication.shared.beginBackgroundTask(withName: "rapp.session") { [weak self] in
      self?.endBackground()
    }
  }

  private func endBackground() {
    guard background != .invalid else { return }
    UIApplication.shared.endBackgroundTask(background)
    background = .invalid
  }

  /// The share sheet for one file (also SessionPlugin's 显示位置 on iOS).
  @discardableResult
  static func share(_ path: String) -> Bool {
    guard let top = root else { return false }
    let sheet = UIActivityViewController(activityItems: [URL(fileURLWithPath: path)], applicationActivities: nil)
    if let popover = sheet.popoverPresentationController {
      popover.sourceView = top.view
      popover.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0, height: 0)
      popover.permittedArrowDirections = []
    }
    (top.presentedViewController ?? top).present(sheet, animated: true)
    return true
  }

  @objc private func memoryWarning() {
    channel.invokeMethod("memoryWarning", arguments: nil)
  }

  /// Tell Dart when the network goes, comes back, or is a different one (Wi-Fi to cellular, one Wi-Fi to
  /// another: a new gateway or interface), not on every path update. Each one makes the hub take a new socket.
  private func pathUpdated(_ path: NWPath) {
    defer { lastPath = path }
    guard let old = lastPath else { return }
    let lost = old.status == .satisfied && path.status != .satisfied
    let regained = old.status != .satisfied && path.status == .satisfied
    let types: [NWInterface.InterfaceType] = [.wifi, .cellular, .wiredEthernet, .other]
    let changed = types.contains { old.usesInterfaceType($0) != path.usesInterfaceType($0) }
    let moved = path.status == .satisfied && Self.place(old) != Self.place(path)
    if lost || regained || changed || moved { channel.invokeMethod("pathChanged", arguments: nil) }
  }

  /// The interfaces in use and their gateways: what tells one Wi-Fi from the next.
  private static func place(_ path: NWPath) -> [String] {
    path.availableInterfaces.map { $0.name } + path.gateways.map { "\($0)" }
  }
}
