/// Keeps presses and releases paired: a key's release goes wherever its latest press went, so Flutter never
/// sees half a key. A press Flutter got and a release it never gets leaves the key stuck (⌘ held forever, and
/// ⌘+letter stops working); a release on its own Flutter's embedder just drops.
public struct PressLedger {
  private var taken: Set<Int> = []
  private var flutter: Set<Int> = []
  public init() {}

  /// The press of `hid` was swallowed.
  public mutating func took(hid: Int) { taken.insert(hid) }

  /// The press of `hid` went on to Flutter, so its release must too: forgets an earlier swallowed press of the
  /// key whose release never came.
  public mutating func passed(hid: Int) {
    taken.remove(hid)
    flutter.insert(hid)
  }

  /// Flutter has seen this key go down and not up yet; a repeat of it must go to Flutter as well.
  public func flutterHolds(hid: Int) -> Bool { flutter.contains(hid) }

  /// Whether to swallow this key's release: only when its press was swallowed; it is forgotten after one release.
  public mutating func release(hid: Int) -> Bool {
    flutter.remove(hid)
    return taken.remove(hid) != nil
  }

  /// On deactivation: the keys whose press was swallowed and that have not been released yet.
  public mutating func forgetAll() -> [Int] {
    defer { taken.removeAll() }
    return Array(taken)
  }
}
