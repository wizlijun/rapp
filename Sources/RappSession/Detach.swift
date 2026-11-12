import AppKit
import CoreGraphics
import RappCore

/// Pure parts of detaching a session from the GUI's stage into native windows (R20, R21): where
/// the windows go, when a user resize goes to A, and which session a key event belongs to. The
/// runner's `DetachedSession` is the AppKit glue around these.

/// Gap between the cascaded windows, and the fallback offset from the main window.
private let detachStep: CGFloat = 24

/// The frames for windows of sizes `contents` (AppKit coordinates, y up), beside the main window
/// `main` on `screen` (its visible frame). Each size is first clamped into `screen`. The first
/// window decides where they all go: right of `main`, top-aligned with it; if it does not fit
/// there, left of `main`; if not there either, at main's top-left moved by (24, -24). That is the
/// anchor (window 0's top-left); window `i` goes at the anchor moved by (24i, -24i), and each is
/// pulled back onto `screen`.
public func detachedFrames(contents: [CGSize], screen: CGRect, beside main: CGRect) -> [CGRect] {
    let sizes = contents.map {
        CGSize(width: min(max($0.width, 0), screen.width), height: min(max($0.height, 0), screen.height))
    }
    guard let first = sizes.first else { return [] }
    let anchorX: CGFloat, anchorTop: CGFloat
    if main.maxX + first.width <= screen.maxX {
        (anchorX, anchorTop) = (main.maxX, main.maxY)
    } else if main.minX - first.width >= screen.minX {
        (anchorX, anchorTop) = (main.minX - first.width, main.maxY)
    } else {
        (anchorX, anchorTop) = (main.minX + detachStep, main.maxY - detachStep)
    }
    return sizes.enumerated().map { i, size in
        let x = anchorX + detachStep * CGFloat(i), top = anchorTop - detachStep * CGFloat(i)
        return CGRect(x: min(max(x, screen.minX), screen.maxX - size.width),
                      y: min(max(top - size.height, screen.minY), screen.maxY - size.height),
                      width: size.width, height: size.height)
    }
}

/// The content size a detached window must take when A's window changes from `old` to `new`: a
/// non-resizable window has no handle, so it follows A's content size (title row excluded; e.g.
/// Calculator going Basic → Scientific). A resizable one keeps the size the user gave it (nil): A's
/// answer shows letterboxed, and no resize is ever answered with another.
public func detachedFollowSize(old: WindowInfo, new: WindowInfo) -> CGSize? {
    guard !new.resizable else { return nil }
    let content = { (i: WindowInfo) in CGSize(width: CGFloat(i.rect.w), height: CGFloat(i.rect.h - i.titleBar)) }
    let size = content(new)
    guard size != content(old), size.width > 0, size.height > 0 else { return nil }
    return size
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
