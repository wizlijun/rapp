// Pure key translation; must not import UIKit (modifier flags are UIKeyModifierFlags raw values).

public struct RimeKey: Equatable {
  public let keysym: Int32
  public let mask: Int32
  public init(keysym: Int32, mask: Int32) { self.keysym = keysym; self.mask = mask }
}

public enum RimeKeyMap {
  public static let shift: Int32 = 1 << 0, lock: Int32 = 1 << 1, control: Int32 = 1 << 2, alt: Int32 = 1 << 3
  public static let superMask: Int32 = 1 << 26, release: Int32 = 1 << 30

  // UIKeyModifierFlags raw values.
  static let flagAlphaShift = 0x10000, flagShift = 0x20000, flagControl = 0x40000
  static let flagAlternate = 0x80000, flagCommand = 0x100000

  static let modifierKeys: [Int: Int32] = [
    0xE1: 0xffe1, 0xE5: 0xffe2, 0xE0: 0xffe3, 0xE4: 0xffe4, 0x39: 0xffe5,
    0xE2: 0xffe9, 0xE6: 0xffea, 0xE3: 0xffeb, 0xE7: 0xffec,
  ]

  static let specials: [Int: Int32] = [
    0x2A: 0xff08, 0x2B: 0xff09, 0x28: 0xff0d, 0x58: 0xff8d, 0x29: 0xff1b, 0x4C: 0xffff,
    0x4A: 0xff50, 0x50: 0xff51, 0x52: 0xff52, 0x4F: 0xff53, 0x51: 0xff54,
    0x4B: 0xff55, 0x4E: 0xff56, 0x4D: 0xff57, 0x2C: 0x20,
  ]

  static func mask(_ m: Int) -> Int32 {
    var r: Int32 = 0
    if m & flagShift != 0 { r |= shift }
    if m & flagAlphaShift != 0 { r |= lock }
    if m & flagControl != 0 { r |= control }
    if m & flagAlternate != 0 { r |= alt }
    if m & flagCommand != 0 { r |= superMask }
    return r
  }

  /// Single printable ASCII scalar (0x20...0x7E), else nil.
  static func ascii(_ s: String) -> Int32? {
    let u = Array(s.unicodeScalars)
    guard u.count == 1, (0x20...0x7E).contains(u[0].value) else { return nil }
    return Int32(u[0].value)
  }

  public static func map(hid: Int, characters: String, ignoringModifiers: String, modifiers: Int) -> RimeKey? {
    let mk = mask(modifiers)
    if let sym = modifierKeys[hid] ?? specials[hid] { return RimeKey(keysym: sym, mask: mk) }
    let useRaw = modifiers & (flagControl | flagAlternate | flagCommand) != 0
    guard let sym = ascii(useRaw ? ignoringModifiers : characters) else { return nil }
    return RimeKey(keysym: sym, mask: mk)
  }

  public static func isModifier(hid: Int) -> Bool { modifierKeys[hid] != nil }

  /// The HID usage of ⌫ (Keyboard Delete/Backspace).
  public static let backspaceHid = 0x2A

  public static func typedText(characters: String, modifiers: Int) -> String? {
    if modifiers & (flagControl | flagAlternate | flagCommand) != 0 { return nil }
    return ascii(characters) != nil ? characters : nil
  }
}
