import Foundation
import RappCore

/// One key message for A: a Mac key code, its modifiers (wire bits) and press or release.
public struct KeyOut: Equatable {
    public var code: UInt16
    public var flags: UInt64
    public var down: Bool

    public init(_ code: UInt16, _ flags: UInt64, _ down: Bool) {
        self.code = code
        self.flags = flags
        self.down = down
    }
}

/// What to do with one hardware-keyboard press on iOS.
public enum PressAction: Equatable {
    /// rApp's own: let it go on to Flutter.
    case local
    /// A type-to-compose letter: open `sid`'s writing panel and hold the press for it.
    case compose(sid: Int64)
    /// Send these to A and swallow the press; `latchUsed`: the latched modifiers went with it.
    case send([KeyOut], latchUsed: Bool)
    /// A reserved chord (⌃⌘…, ⌘Q, ⌃↩): send A these releases first, then let the press go on to Flutter.
    case localAfterRelease([KeyOut])
}

/// The iPad hardware keyboard's rules, without UIKit: which presses go to A (as Mac key codes), which open
/// the writing panel, and which stay with rapp. A modifier press is a key of its own here (UIKit has no
/// flagsChanged). `focusedSid` is the picture with keyboard focus; the caller calls `blur()` before changing it.
public struct PressRouter {
    private var keys = KeyTracker()
    /// Modifiers (wire bits) the key row latched: they go with the next non-modifier key-down, once.
    public var latched: UInt64 = 0
    public var focusedSid: Int64?

    public init() {}

    public mutating func press(hidUsage: Int, uiModifiers: Int, down: Bool, characters: String?, composeOn: Bool,
                               remoteSecure: Bool) -> PressAction {
        guard let sid = focusedSid, let code = macKeyCode(hidUsage: hidUsage) else { return .local }
        let flags = keyFlags(uiModifiers: uiModifiers) | latched
        if composeStart(keyDown: down, composeOn: composeOn, targetSid: sid, characters: characters,
                        flags: KeyFlags(rawValue: flags), isRepeat: false, remoteSecure: remoteSecure) != nil {
            return .compose(sid: sid)
        }
        let decision = keys.route(keyCode: code, down: down, flags: KeyFlags(rawValue: flags), pictureFocused: true)
        let releases = decision.release.map { KeyOut($0, 0, false) }
        guard decision.route == .remote else { return releases.isEmpty ? .local : .localAfterRelease(releases) }
        let latchUsed = down && latched != 0 && !Self.isModifier(code)
        if latchUsed { latched = 0 }
        return .send(releases + [KeyOut(code, flags, down)], latchUsed: latchUsed)
    }

    /// Focus left the picture, or the app is no longer active: a release for every key A holds, ascending.
    public mutating func blur() -> [KeyOut] {
        keys.releaseAll().map { KeyOut($0, 0, false) }
    }

    /// Mac key codes 54–63: ⌘ ⇧ ⌥ ⌃ (both sides), caps lock and fn.
    private static func isModifier(_ code: UInt16) -> Bool { (54...63).contains(code) }
}
