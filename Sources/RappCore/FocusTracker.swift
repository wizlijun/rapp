import CoreGraphics
import Foundation

/// Focus pane rules 3-8 as a pure state machine (spec 2026-11-16-rapp-focus-pane-rules §4).
///
/// The host feeds it input, window-table changes, AX query results and per-frame tiles, ticks it every
/// 0.1 s, and carries out the actions it returns. All time comes in as `now`; there are no clocks here.
/// Rects are window points. An output of `[]` means the whole window is the focus.
public final class FocusTracker {
    public enum Cause: String { case on, key, click, scroll, hover, follow, notify, resize, window, lock }
    public enum Query: Equatable { case keyboard; case pointer(CGPoint); case follow(CGPoint) }
    public struct Output: Equatable {
        public let window: UInt32
        public let rects: [CGRect]   // [] = whole window
        public let cause: Cause
        public init(window: UInt32, rects: [CGRect], cause: Cause) {
            self.window = window; self.rects = rects; self.cause = cause
        }
    }
    public enum Action: Equatable { case query(Query, generation: Int); case send(Output) }
    public enum Pointer { case click, drag, scroll, move }

    public static let hoverDelay: TimeInterval = 0.5
    public static let keyRecheck: TimeInterval = 0.2
    public static let followWindow: TimeInterval = 1
    public static let followShare = 0.15
    public static let sendInterval: TimeInterval = 0.3
    public static let settle: TimeInterval = 2
    public static let minWindow = CGSize(width: 480, height: 320)
    /// Slack for comparing elapsed times built from decimal steps (1.2 - 1 < 0.2 in doubles).
    static let epsilon: TimeInterval = 1e-6

    /// Bumped when the focused window or its size changes; results from an older generation are dropped.
    public private(set) var generation = 0
    public private(set) var keyboardPanel: CGRect?
    public private(set) var keyboardMiss: PanelMiss?
    public private(set) var pointerPanel: CGRect?
    /// Reason of the last pointer query when it failed; nil after a success or before any query.
    public private(set) var pointerMiss: PanelMiss?
    public private(set) var followPanel: CGRect?

    private var started = false
    private var windowID: UInt32?
    private var size = CGSize.zero
    private var appeared: TimeInterval?
    private var isLocked = false

    private var keyboardCause = Cause.on
    private var pointerCause = Cause.click
    private var recheckAt: TimeInterval?
    private var recheckCause = Cause.key
    private var hover: (point: CGPoint, at: TimeInterval)?
    /// Where the last pointer action of this window happened; a resize asks for the pointer panel there again.
    private var lastPointer: CGPoint?
    private var copyBounds: CGRect?

    /// Rule 5: the click or key that may still trigger a follow query.
    private var actionAt: TimeInterval?
    private var followTiles = Set<TileKey>()
    private var followBox = CGRect.null
    private var followAsked: CGPoint?

    private var lastCause = Cause.on
    private var sent: Output?
    private var sentAt: TimeInterval?

    public init() {}

    // MARK: inputs

    public func start(now: TimeInterval) -> [Action] {
        started = true
        return queryKeyboard(.on) + update(.on, now: now)
    }

    public func window(id: UInt32?, size: CGSize, appeared: TimeInterval?, now: TimeInterval) -> [Action] {
        self.appeared = appeared
        if id == windowID && size == self.size { return started ? update(lastCause, now: now) : [] }
        let resized = id != nil && id == windowID
        windowID = id
        self.size = size
        generation += 1
        // Any resize makes every panel rect stale: drop them all, show the whole window, and ask the
        // keyboard and the last pointer point again (rules 3, 4). Positions and timers stay; a new
        // window starts from nothing.
        if resized { dropPanels() } else { resetWindowState() }
        let cause: Cause = resized ? .resize : .window
        guard started else { return [] }
        var actions = queryKeyboard(cause)
        if resized {
            if let p = lastPointer, CGRect(origin: .zero, size: size).contains(p) {
                actions += queryPointer(p, .resize)
            }
            // B clears on the size change; send the whole window now, past the throttle, so A's
            // last-sent output never claims old rects are showing.
            sent = nil; sentAt = nil
        }
        return actions + update(cause, now: now)
    }

    public func locked(_ on: Bool, now: TimeInterval) -> [Action] {
        isLocked = on
        return started ? update(.lock, now: now) : []
    }

    public func pointer(_ kind: Pointer, at p: CGPoint, now: TimeInterval) -> [Action] {
        guard active else { return [] }
        lastPointer = p
        if kind == .move {
            hover = (p, now)
            return []
        }
        hover = nil
        let cause: Cause = kind == .scroll ? .scroll : .click
        var actions = inPointerPanel(p) ? [] : queryPointer(p, cause)
        if kind == .click { actions += armAction(.click, now: now) }
        return actions
    }

    public func key(now: TimeInterval) -> [Action] {
        guard active else { return [] }
        return armAction(.key, now: now)
    }

    public func keyboardChanged(now: TimeInterval) -> [Action] {
        guard active else { return [] }
        return queryKeyboard(.notify)
    }

    public func result(_ q: Query, generation: Int, _ r: Result<PanelPick, PanelMiss>, now: TimeInterval) -> [Action] {
        guard started, generation == self.generation, windowID != nil else { return [] }
        switch q {
        case .keyboard:
            switch r {
            case .success(let p): keyboardPanel = p.rect; keyboardMiss = nil
            case .failure(let m): keyboardPanel = nil; keyboardMiss = m
            }
            return update(keyboardCause, now: now)
        case .pointer:
            switch r {
            case .success(let p): pointerPanel = p.rect; pointerMiss = nil
            case .failure(let m): pointerMiss = m
            }
            return update(pointerCause, now: now)
        case .follow(let p):
            guard p == followAsked else { return [] }
            followAsked = nil
            guard case .success(let pick) = r else { return [] }
            followPanel = pick.rect
            return update(.follow, now: now)
        }
    }

    public func frame(_ t: WindowTiles, now: TimeInterval) -> [Action] {
        guard active else { return [] }
        var actions: [Action] = []
        if let c = t.copyBounds, !c.isEmpty {
            copyBounds = c
            if copyFallbackApplies { actions += update(.scroll, now: now) }
        }
        return actions + follow(t, now: now)
    }

    public func tick(now: TimeInterval) -> [Action] {
        guard started else { return [] }
        var actions: [Action] = []
        if let at = recheckAt, reached(at, now) {
            recheckAt = nil
            actions += queryKeyboard(recheckCause)
        }
        if let h = hover, reached(h.at + Self.hoverDelay, now) {
            hover = nil
            if !inPointerPanel(h.point) { actions += queryPointer(h.point, .hover) }
        }
        if let a = actionAt, !within(a, Self.followWindow, now) { actionAt = nil }
        return actions + flush(now: now)
    }

    // MARK: state

    private var active: Bool { started && windowID != nil }

    private func resetWindowState() {
        dropPanels()
        actionAt = nil; hover = nil; recheckAt = nil; lastPointer = nil
    }

    /// Forgets every rect that belongs to the old window geometry.
    private func dropPanels() {
        keyboardPanel = nil; keyboardMiss = nil
        pointerPanel = nil; pointerMiss = nil
        followPanel = nil; followAsked = nil; followTiles = []; followBox = .null
        copyBounds = nil
    }

    private func queryKeyboard(_ cause: Cause) -> [Action] {
        guard windowID != nil else { return [] }
        keyboardCause = cause
        return [.query(.keyboard, generation: generation)]
    }

    private func queryPointer(_ p: CGPoint, _ cause: Cause) -> [Action] {
        pointerCause = cause
        return [.query(.pointer(p), generation: generation)]
    }

    private func inPointerPanel(_ p: CGPoint) -> Bool { pointerPanel?.contains(p) ?? false }

    /// A click or key: recheck the keyboard in 0.2 s, clear the follow panel and watch the next second.
    private func armAction(_ cause: Cause, now: TimeInterval) -> [Action] {
        if recheckAt == nil { recheckAt = now + Self.keyRecheck; recheckCause = cause }
        actionAt = now
        followTiles = []; followBox = .null
        followPanel = nil; followAsked = nil
        return update(cause, now: now)
    }

    private func reached(_ deadline: TimeInterval, _ now: TimeInterval) -> Bool { now >= deadline - Self.epsilon }
    private func within(_ start: TimeInterval, _ span: TimeInterval, _ now: TimeInterval) -> Bool {
        now - start <= span + Self.epsilon
    }

    // MARK: rule 5

    private func follow(_ t: WindowTiles, now: TimeInterval) -> [Action] {
        guard let a = actionAt, followAsked == nil else { return [] }
        guard within(a, Self.followWindow, now) else { actionAt = nil; return [] }
        let focus = rects(now: now)
        guard !t.full, !focus.isEmpty, t.total > 0 else { return [] }
        for tile in t.changed {
            let c = CGPoint(x: tile.midX, y: tile.midY)
            if focus.contains(where: { $0.contains(c) }) { continue }
            if followTiles.insert(TileKey(tile)).inserted { followBox = followBox.union(tile) }
        }
        guard Double(followTiles.count) > Double(t.total) * Self.followShare else { return [] }
        actionAt = nil
        let c = CGPoint(x: followBox.midX, y: followBox.midY)
        followAsked = c
        return [.query(.follow(c), generation: generation)]
    }

    // MARK: rule 6

    private var copyFallbackApplies: Bool {
        keyboardMiss == .blocked && pointerPanel == nil && (pointerMiss == nil || pointerMiss == .blocked)
    }

    private var copyPanel: CGRect? {
        guard copyFallbackApplies, let c = copyBounds,
              case .success(let p) = FocusPane.panel(chain: [c], window: size) else { return nil }
        return p.rect
    }

    // MARK: output (rules 7, 8)

    /// The focus rects now; [] = whole window.
    private func rects(now: TimeInterval) -> [CGRect] {
        guard windowID != nil, !isLocked,
              size.width >= Self.minWindow.width, size.height >= Self.minWindow.height else { return [] }
        if let a = appeared, !reached(a + Self.settle, now) { return [] }
        // At most 3: the copy panel only stands in when keyboard and pointer panels are both empty.
        let raw = [keyboardPanel, pointerPanel, followPanel, copyPanel].compactMap { $0 }
        let bounds = CGRect(origin: .zero, size: size)
        let out = Self.dropContained(raw).compactMap { r -> CGRect? in
            let i = Self.roundOut(r).intersection(bounds)
            return i.isNull || i.isEmpty ? nil : i
        }
        guard let box = out.dropFirst().reduce(out.first, { $0?.union($1) }) else { return [] }
        if Double(box.width * box.height) >= FocusPane.maxShare * Double(size.width * size.height) { return [] }
        return out
    }

    private func update(_ cause: Cause, now: TimeInterval) -> [Action] {
        lastCause = cause
        return flush(now: now)
    }

    /// Sends the current output when it differs from the last one sent and 0.3 s have passed.
    private func flush(now: TimeInterval) -> [Action] {
        let out = Output(window: windowID ?? 0, rects: rects(now: now), cause: lastCause)
        if let s = sent, s.window == out.window, s.rects == out.rects { return [] }
        if let at = sentAt, !reached(at + Self.sendInterval, now) { return [] }
        sent = out; sentAt = now
        return [.send(out)]
    }

    /// Drops rects inside another one (of two equal rects the first stays).
    static func dropContained(_ rs: [CGRect]) -> [CGRect] {
        rs.enumerated().filter { i, r in
            !rs.enumerated().contains { j, o in j != i && o.contains(r) && (o != r || j < i) }
        }.map(\.element)
    }

    static func roundOut(_ r: CGRect) -> CGRect {
        let x = r.minX.rounded(.down), y = r.minY.rounded(.down)
        return CGRect(x: x, y: y, width: r.maxX.rounded(.up) - x, height: r.maxY.rounded(.up) - y)
    }
}

private struct TileKey: Hashable {
    let x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat
    init(_ r: CGRect) { x = r.minX; y = r.minY; w = r.width; h = r.height }
}
