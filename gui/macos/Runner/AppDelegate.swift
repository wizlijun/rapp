import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    // Closing the window only hides it; quitting goes through the tray menu.
    return false
  }

  // Clicking the Dock icon (or opening rapp.app again) brings the main window back.
  override func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    showMainWindow()
    return true
  }

  override func applicationWillFinishLaunching(_ notification: Notification) {
    super.applicationWillFinishLaunching(notification)
    if !SingleInstance.isConnectionManager {
      DistributedNotificationCenter.default().addObserver(
        forName: SingleInstance.showMain, object: nil, queue: .main
      ) { [weak self] _ in self?.showMainWindow() }
    }
  }

  func showMainWindow() {
    for window in NSApp.windows where window is MainFlutterWindow {
      window.makeKeyAndOrderFront(nil)
    }
    NSApp.activate(ignoringOtherApps: true)
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}

/// One main rapp window per user. `rapp --cm` (A's connection manager) is the same
/// binary and is exempt. A second launch tells the first to show its main window, then exits.
enum SingleInstance {
  static let showMain = Notification.Name("com.rapp.rapp.showMain")
  static let isConnectionManager = CommandLine.arguments.contains("--cm")
  private static var lockFD: Int32 = -1
  private static var lockPath: String {
    (NSTemporaryDirectory() as NSString).appendingPathComponent("com.rapp.rapp.gui.lock")
  }

  /// True when this process now holds the lock (kept until exit; the kernel drops it on crash).
  static func claim() -> Bool {
    let fd = open(lockPath, O_RDWR | O_CREAT, 0o600)
    if fd < 0 { return true }  // cannot lock: never block startup over it
    if flock(fd, LOCK_EX | LOCK_NB) != 0 {
      close(fd)
      return false
    }
    ftruncate(fd, 0)
    let pid = "\(getpid())"
    _ = pid.withCString { write(fd, $0, strlen($0)) }
    lockFD = fd
    return true
  }

  /// Ask the running instance (pid in the lock file) to show its main window and give it focus.
  static func handOff() {
    DistributedNotificationCenter.default().postNotificationName(
      showMain, object: nil, userInfo: nil, deliverImmediately: true)
    let text = (try? String(contentsOfFile: lockPath, encoding: .utf8)) ?? ""
    guard let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)),
          let other = NSRunningApplication(processIdentifier: pid) else { return }
    if #available(macOS 14.0, *) { NSApp.yieldActivation(to: other) }
    other.activate(options: [])
  }
}
