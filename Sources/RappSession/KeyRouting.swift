import AppKit

/// Where a key event from the embedded picture goes: to rapp itself (Flutter) or to A.
public enum KeyRoute: Equatable {
    case local
    case remote
}

/// While the picture has focus every key goes to A except ⌃⌘ chords (rapp's own shortcuts) and
/// plain ⌘Q (quit rapp); without focus every key stays with rapp.
public func routeKey(keyCode: UInt16, flags: NSEvent.ModifierFlags, pictureFocused: Bool) -> KeyRoute {
    let mods = flags.intersection([.command, .control, .option, .shift])
    if mods.contains([.control, .command]) { return .local }
    if mods == [.command] && keyCode == 12 { return .local }
    return pictureFocused ? .remote : .local
}

/// For a modifier key's `flagsChanged` event: whether the key is now down (its modifier bit is
/// still set). Nil for key codes that are not modifier keys (54–63).
public func modifierKeyIsDown(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool? {
    let bit: NSEvent.ModifierFlags
    switch keyCode {
    case 54, 55: bit = .command
    case 56, 60: bit = .shift
    case 57: bit = .capsLock
    case 58, 61: bit = .option
    case 59, 62: bit = .control
    case 63: bit = .function
    default: return nil
    }
    return flags.contains(bit)
}

/// The keys A has been sent a press for and not yet a release, so none stays stuck on A when
/// the picture loses focus.
public struct KeyTracker {
    private var held = Set<UInt16>()

    public init() {}

    public mutating func down(_ code: UInt16) { held.insert(code) }

    public mutating func up(_ code: UInt16) { held.remove(code) }

    public func isDown(_ code: UInt16) -> Bool { held.contains(code) }

    /// The held keys, ascending, and forgets them: the caller sends A a release for each.
    public mutating func releaseAll() -> [UInt16] {
        defer { held.removeAll() }
        return held.sorted()
    }

    /// Routes one press or release and keeps track of what A holds. A release goes to A exactly
    /// when A got the press, so both A and rapp always see matched pairs.
    public mutating func route(keyCode: UInt16, down isDown: Bool, flags: NSEvent.ModifierFlags,
                               pictureFocused: Bool) -> KeyRoute {
        if !isDown {
            guard held.contains(keyCode) else { return .local }
            up(keyCode)
            return .remote
        }
        guard routeKey(keyCode: keyCode, flags: flags, pictureFocused: pictureFocused) == .remote else { return .local }
        down(keyCode)
        return .remote
    }
}
