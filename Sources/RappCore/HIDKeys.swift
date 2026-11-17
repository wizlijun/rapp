import Foundation

/// The Mac virtual key code (what A's `.key` messages carry) for a USB HID keyboard usage
/// (usage page 0x07, as UIKey.keyCode gives it). Nil for keys with no Mac counterpart here.
public func macKeyCode(hidUsage: Int) -> UInt16? {
    hidToMac[hidUsage]
}

/// `UIKeyModifierFlags` raw bits as the wire's modifiers: the caps lock, shift, control, alternate
/// and command bits are the same as CGEventFlags'; the rest (numeric pad, alpha shift variants) go.
public func keyFlags(uiModifiers: Int) -> UInt64 {
    UInt64(truncatingIfNeeded: uiModifiers) & 0x1F0000
}

private let hidToMac: [Int: UInt16] = {
    var t = [Int: UInt16]()
    // Letters a-z (0x04-0x1D).
    let letters: [UInt16] = [0, 11, 8, 2, 14, 3, 5, 4, 34, 38, 40, 37, 46, 45, 31, 35, 12, 15, 1, 17, 32, 9, 13, 7, 16, 6]
    for (i, c) in letters.enumerated() { t[0x04 + i] = c }
    // Digits 1-9, 0 (0x1E-0x27).
    let digits: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25, 29]
    for (i, c) in digits.enumerated() { t[0x1E + i] = c }
    let named: [Int: UInt16] = [
        0x28: 36, 0x29: 53, 0x2A: 51, 0x2B: 48, 0x2C: 49,
        0x2D: 27, 0x2E: 24, 0x2F: 33, 0x30: 30, 0x31: 42, 0x33: 41, 0x34: 39, 0x35: 50, 0x36: 43, 0x37: 47, 0x38: 44,
        0x39: 57,
        0x4A: 115, 0x4B: 116, 0x4C: 117, 0x4D: 119, 0x4E: 121, 0x4F: 124, 0x50: 123, 0x51: 125, 0x52: 126,
        0xE0: 59, 0xE1: 56, 0xE2: 58, 0xE3: 55, 0xE4: 62, 0xE5: 60, 0xE6: 61, 0xE7: 54,
    ]
    t.merge(named) { a, _ in a }
    // F1-F12 (0x3A-0x45).
    let fkeys: [UInt16] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
    for (i, c) in fkeys.enumerated() { t[0x3A + i] = c }
    return t
}()
