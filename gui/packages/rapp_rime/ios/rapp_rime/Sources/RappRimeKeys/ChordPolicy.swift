/// librime's ascii_composer toggles 中/英 when a Shift (or Control) goes down and up with no other key in between.
/// A key it never sees (unmapped, or a repeat Flutter holds) or a mouse or trackpad click while the modifier is held
/// would leave it thinking the modifier was alone, and its release would toggle. Such a press is answered with
/// a VoidSymbol press and release, so the engine sees that something came between.
public enum ChordPolicy {
  /// X11 `XK_VoidSymbol`: a key no processor binds.
  public static let voidSymbol: Int32 = 0xffffff

  /// `hid` was pressed with `modifiers` (UIKeyModifierFlags raw) and did not reach the engine.
  public static func interrupts(hid: Int, modifiers: Int, reachedEngine: Bool) -> Bool {
    !reachedEngine && !RimeKeyMap.isModifier(hid: hid)
      && modifiers & (RimeKeyMap.flagShift | RimeKeyMap.flagControl) != 0
  }
}
