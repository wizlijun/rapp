/// Decides whether we generate key repeat ourselves or the system does.
/// Once the system re-sends a press for a key that is still down, we never repeat on our own again.
public struct RepeatPolicy {
  public static let delay: Double = 0.4, interval: Double = 0.04
  private var down: Set<Int> = []
  private var systemSeen = false
  public init() {}

  /// Returns true when this press is a system auto-repeat.
  public mutating func began(hid: Int) -> Bool {
    if down.contains(hid) { systemSeen = true; return true }
    down.insert(hid)
    return false
  }
  public mutating func ended(hid: Int) { down.remove(hid) }
  public var ownRepeat: Bool { !systemSeen }
}
