import AppKit
import CoreGraphics
import RappCore

/// Pure parts of detaching a session from the GUI's stage into native windows (R20, R21): where
/// the windows go, when a user resize goes to A, and which session a key event belongs to. The
/// runner's `DetachedSession` is the AppKit glue around these.

/// Gap between the cascaded windows, and the fallback offset from the main window.
private let detachStep: CGFloat = 24

/// The frames for windows of sizes `contents` (AppKit coordinates, y up), beside the main window
/// `main` on `screen` (its visible frame). Each size is first clamped into `screen`. A window goes
/// right of `main`, top-aligned with it; if it does not fit there, left of `main`; if not there
/// either, at main's top-left moved by (24, -24). Window `i` is further offset by (24i, -24i), and
/// the result is pulled back onto `screen`.
public func detachedFrames(contents: [CGSize], screen: CGRect, beside main: CGRect) -> [CGRect] {
    contents.enumerated().map { i, content in
        let w = min(max(content.width, 0), screen.width), h = min(max(content.height, 0), screen.height)
        var x: CGFloat
        var top = main.maxY
        if main.maxX + w <= screen.maxX {
            x = main.maxX
        } else if main.minX - w >= screen.minX {
            x = main.minX - w
        } else {
            x = main.minX + detachStep
            top -= detachStep
        }
        x += detachStep * CGFloat(i)
        top -= detachStep * CGFloat(i)
        let clampedX = min(max(x, screen.minX), screen.maxX - w)
        let clampedY = min(max(top - h, screen.minY), screen.maxY - h)
        return CGRect(x: clampedX, y: clampedY, width: w, height: h)
    }
}

/// The `.resize` a detached window's new content size (B points) sends to A, by R12: only for a
/// resizable window, and only when the size differs from A's content size (title row excluded).
public func detachedResize(_ info: WindowInfo, content: CGSize) -> Message? {
    guard info.resizable else { return nil }
    let w = content.width.rounded(), h = content.height.rounded()
    guard w.isFinite, h.isFinite else { return nil }
    let aw = CGFloat(info.rect.w).rounded(), ah = CGFloat(info.rect.h - info.titleBar).rounded()
    if w == aw && h == ah { return nil }
    let clamp = { (v: CGFloat) in UInt16(clamping: Int(max(v, 0))) }
    return .resize(window: info.id, width: clamp(w), height: clamp(h))
}

/// The decorated window a popup `id` is drawn over: its parent's, through nested popups (a submenu
/// sits over its menu's window); `fallback` (the current window) when the chain leaves the table
/// (R8). A loop in the chain ends at `fallback` too.
public func popupOwner(_ id: UInt32, table: [WindowInfo], fallback: UInt32?) -> UInt32? {
    let byID = Dictionary(table.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    var seen: Set<UInt32> = [id]
    var at = byID[id]?.parent ?? 0
    while let w = byID[at], seen.insert(at).inserted {
        if w.kind.isDecorated { return at }
        at = w.parent
    }
    return fallback
}

/// Whose keys a window's key events are.
public enum KeyWindowRoute: Equatable {
    /// The main Flutter window: the session whose picture has focus, if any.
    case main
    /// A detached window of session `sid`.
    case detached(Int64)
    /// Any other window (panels, sheets), or none: rapp's own.
    case local
}

/// Maps the window a key event came from (`window`, nil for none) to its route: `main` is the main
/// Flutter window (nil while it is not known yet), `detached` maps each detached window to its sid.
public func keyWindowRoute<W: Hashable>(window: W?, main: W?, detached: [W: Int64]) -> KeyWindowRoute {
    guard let window else { return .local }
    if let main, window == main { return .main }
    if let sid = detached[window] { return .detached(sid) }
    return .local
}

/// What a key in a detached window does.
public enum DetachedKeyRoute: Equatable {
    /// ⌃⌘D: put the session back on the stage.
    case attach
    /// ⌘Q: quit rapp.
    case local
    /// Everything else, ⌃⌘ chords included: the session's.
    case remote
}

/// In a detached window only ⌃⌘D (attach) and ⌘Q (quit) are rapp's; every other key is A's.
public func routeDetachedKey(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> DetachedKeyRoute {
    let mods = flags.intersection([.command, .control, .option, .shift])
    if keyCode == 2 && mods == [.control, .command] { return .attach }
    if keyCode == 12 && mods == [.command] { return .local }
    return .remote
}

extension KeyTracker {
    /// `route` for a key event in a detached window (`routeDetachedKey`), on the same tracker so the
    /// same pairing holds: a release goes to A exactly when A got the press, and a press that stays
    /// local (⌃⌘D, ⌘Q) first releases whatever A holds.
    public mutating func routeDetached(keyCode: UInt16, down isDown: Bool, flags: NSEvent.ModifierFlags) -> KeyDecision {
        let to: KeyRoute = routeDetachedKey(keyCode: keyCode, flags: flags) == .remote ? .remote : .local
        return route(keyCode: keyCode, down: isDown, to: to, focused: true)
    }
}

/// The runner's `detached` call to Dart: the session moved into its own windows (`detached`), or
/// back, with the window that becomes the current tab (`current`, null for none; R21).
public func detachedPayload(sid: Int64, detached: Bool, current: UInt32?) -> (method: String, args: [String: Any]) {
    ("detached", ["sid": sid, "detached": detached, "current": current.map { Int($0) as Any } ?? NSNull()])
}
