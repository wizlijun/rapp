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
  /// Every key stopped being down without its own release (deactivated, app resigned active): forget them all,
  /// or the next press of a key whose release was lost would look like a system repeat.
  public mutating func endAll() { down.removeAll() }
  public var ownRepeat: Bool { !systemSeen }

  /// Our repeat of `repeating` ends when another key goes down, as the system's does, so a release that never
  /// came cannot leave it running. A press of the repeating key itself is for `began` to judge.
  public static func stopsOwnRepeat(repeating: Int?, pressed: Int) -> Bool {
    repeating.map { $0 != pressed } ?? false
  }
}
