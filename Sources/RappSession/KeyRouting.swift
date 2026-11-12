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

/// For a modifier key's `flagsChanged` event: whether the key is now down. Left and right keys
/// are told apart by the device-dependent bits in `rawValue` (IOKit's NX_DEVICE*KEYMASK), so
/// releasing one of two held shifts reads as a release; fn and caps lock use their own bit. If
/// an event carries no device bits for the pair, the device-independent bit decides. Nil for key
/// codes that are not modifier keys (54–63).
public func modifierKeyIsDown(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool? {
    let bit: NSEvent.ModifierFlags
    let device: (mine: UInt, pair: UInt)?
    switch keyCode {
    case 55: (bit, device) = (.command, (0x8, 0x8 | 0x10))
    case 54: (bit, device) = (.command, (0x10, 0x8 | 0x10))
    case 56: (bit, device) = (.shift, (0x2, 0x2 | 0x4))
    case 60: (bit, device) = (.shift, (0x4, 0x2 | 0x4))
    case 58: (bit, device) = (.option, (0x20, 0x20 | 0x40))
    case 61: (bit, device) = (.option, (0x40, 0x20 | 0x40))
    case 59: (bit, device) = (.control, (0x1, 0x1 | 0x2000))
    case 62: (bit, device) = (.control, (0x2000, 0x1 | 0x2000))
    case 57: (bit, device) = (.capsLock, nil)
    case 63: (bit, device) = (.function, nil)
    default: return nil
    }
    guard flags.contains(bit) else { return false }
    guard let device, flags.rawValue & device.pair != 0 else { return true }
    return flags.rawValue & device.mine != 0
}

/// Caps lock's `flagsChanged` reports the lock toggling, not a key held: it is never tracked.
private let capsLockKey: UInt16 = 57

/// What to do with one key event: where it goes, and the keys A holds that must be released
/// first (sent to A before the event goes on).
public struct KeyDecision: Equatable {
    public var route: KeyRoute
    public var release: [UInt16]

    public init(_ route: KeyRoute, release: [UInt16] = []) {
        self.route = route
        self.release = release
    }
}

/// The keys A has been sent a press for and not yet a release, so none stays stuck on A when
/// the picture loses focus.
public struct KeyTracker {
    private var held = Set<UInt16>()

    public init() {}

    public mutating func down(_ code: UInt16) {
        guard code != capsLockKey else { return }
        held.insert(code)
    }

    public mutating func up(_ code: UInt16) { held.remove(code) }

    public func isDown(_ code: UInt16) -> Bool { held.contains(code) }

    /// The held keys, ascending, and forgets them: the caller sends A a release for each.
    public mutating func releaseAll() -> [UInt16] {
        defer { held.removeAll() }
        return held.sorted()
    }

    /// Routes one press or release and keeps track of what A holds. A release goes to A exactly
    /// when A got the press, so both A and rapp always see matched pairs. A press that stays
    /// local while the picture has focus is a reserved chord (⌃⌘…, ⌘Q): whatever A holds (the
    /// chord's first modifiers) is released on A first, so nothing stays held there.
    public mutating func route(keyCode: UInt16, down isDown: Bool, flags: NSEvent.ModifierFlags,
                               pictureFocused: Bool) -> KeyDecision {
        route(keyCode: keyCode, down: isDown, to: routeKey(keyCode: keyCode, flags: flags, pictureFocused: pictureFocused),
              focused: pictureFocused)
    }

    /// The pairing rule for a press or release that `to` routes; `focused`: A's window has the keys
    /// (a local press then releases what A holds).
    mutating func route(keyCode: UInt16, down isDown: Bool, to: KeyRoute, focused: Bool) -> KeyDecision {
        if keyCode == capsLockKey { return KeyDecision(to) }
        if !isDown {
            guard held.contains(keyCode) else { return KeyDecision(.local) }
            up(keyCode)
            return KeyDecision(.remote)
        }
        guard to == .remote else { return KeyDecision(.local, release: focused ? releaseAll() : []) }
        down(keyCode)
        return KeyDecision(.remote)
    }
}
