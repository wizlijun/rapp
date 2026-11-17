import Flutter
import UIKit

/// The root view controller (the storyboard's initial one). While a session window is on screen it takes the
/// screen-edge gestures and the home indicator away from the system, and it is where hardware-keyboard presses arrive.
/// In rapp's fullscreen it hides the status bar and lets the home indicator fade (iOS never removes it for good).
final class RappViewController: FlutterViewController {
  /// The wanted state lives in statics so a call that arrives before any controller is reachable (no key window yet,
  /// boot time) still takes effect as soon as one exists.
  static var wantsSessionActive = false {
    didSet { if wantsSessionActive != oldValue { current?.refreshSessionState() } }
  }

  static var wantsFullscreen = false {
    didSet { if wantsFullscreen != oldValue { current?.refreshFullscreenState() } }
  }

  private(set) static weak var current: RappViewController?

  var sessionActive: Bool {
    get { Self.wantsSessionActive }
    set { Self.wantsSessionActive = newValue }
  }

  var fullscreen: Bool {
    get { Self.wantsFullscreen }
    set { Self.wantsFullscreen = newValue }
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    Self.current = self
    refreshSessionState()
    refreshFullscreenState()
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    Self.current = self
    refreshSessionState()
    refreshFullscreenState()
  }

  private func refreshSessionState() {
    setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
    setNeedsUpdateOfHomeIndicatorAutoHidden()
  }

  private func refreshFullscreenState() {
    setNeedsStatusBarAppearanceUpdate()
    setNeedsUpdateOfHomeIndicatorAutoHidden()
  }

  /// Where hardware-keyboard presses go first (`SessionPlugin.handlePresses`): true when the press was taken,
  /// false or nil to let Flutter have it. Called one press at a time, so a set is never half taken.
  var pressHandler: ((Set<UIPress>, Bool) -> Bool)? = { presses, began in
    SessionPlugin.shared?.handlePresses(presses, began: began) ?? false
  }

  override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge {
    sessionActive ? .all : []
  }

  override var prefersHomeIndicatorAutoHidden: Bool { sessionActive || fullscreen }

  override var prefersStatusBarHidden: Bool { fullscreen }

  override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
    for press in presses where pressHandler?([press], true) != true { super.pressesBegan([press], with: event) }
  }

  override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
    for press in presses where pressHandler?([press], false) != true { super.pressesEnded([press], with: event) }
  }

  override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
    for press in presses where pressHandler?([press], false) != true { super.pressesCancelled([press], with: event) }
  }
}
