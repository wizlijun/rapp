import Flutter
import UIKit

/// The root view controller (the storyboard's initial one). While a session window is on screen it takes the
/// screen-edge gestures and the home indicator away from the system, and it is where hardware-keyboard presses arrive.
final class RappViewController: FlutterViewController {
  var sessionActive = false {
    didSet {
      guard sessionActive != oldValue else { return }
      setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
      setNeedsUpdateOfHomeIndicatorAutoHidden()
    }
  }

  /// Hook for the shared SessionPlugin (Task 6): return true when the presses were consumed. Nil means not handled.
  var pressHandler: ((Set<UIPress>, Bool) -> Bool)?

  override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge {
    sessionActive ? .all : []
  }

  override var prefersHomeIndicatorAutoHidden: Bool { sessionActive }

  override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
    if pressHandler?(presses, true) != true { super.pressesBegan(presses, with: event) }
  }

  override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
    if pressHandler?(presses, false) != true { super.pressesEnded(presses, with: event) }
  }

  override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
    if pressHandler?(presses, false) != true { super.pressesCancelled(presses, with: event) }
  }
}
