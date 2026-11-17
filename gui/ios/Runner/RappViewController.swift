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

  /// Where hardware-keyboard presses go first (`SessionPlugin.handlePresses`): true when the press was taken,
  /// false or nil to let Flutter have it. Called one press at a time, so a set is never half taken.
  var pressHandler: ((Set<UIPress>, Bool) -> Bool)? = { presses, began in
    SessionPlugin.shared?.handlePresses(presses, began: began) ?? false
  }

  override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge {
    sessionActive ? .all : []
  }

  override var prefersHomeIndicatorAutoHidden: Bool { sessionActive }

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
