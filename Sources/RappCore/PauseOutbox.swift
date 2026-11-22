import Foundation

/// What a host sends besides pictures while B has paused the session (v15 `setStream` fps 0):
/// the window table at most every `windowsEvery` seconds, the menu bar and focus region held
/// until resume, `changed` at most every `changedEvery` seconds, everything else at once.
public struct PauseOutbox {
    public static let windowsEvery: TimeInterval = 5
    public static let changedEvery: TimeInterval = 1

    public private(set) var paused = false
    private var windows: Message?
    private var menuBar: Message?
    private var focusRegion: Message?
    private var windowsSent = -TimeInterval.infinity
    private var changedSent = -TimeInterval.infinity

    public init() {}

    /// `m` to send now, or nil when it is held for later.
    public mutating func pass(_ m: Message, now: TimeInterval) -> Message? {
        switch m {
        case .windows:
            guard paused, now - windowsSent < Self.windowsEvery else {
                windows = nil
                windowsSent = now
                return m
            }
            windows = m
            return nil
        case .menuBar where paused:
            menuBar = m
            return nil
        case .focusRegion where paused:
            focusRegion = m
            return nil
        default:
            return m
        }
    }

    /// The held window table once its turn has come (call about once a second).
    public mutating func due(now: TimeInterval) -> Message? {
        guard paused, let w = windows, now - windowsSent >= Self.windowsEvery else { return nil }
        windows = nil
        windowsSent = now
        return w
    }

    /// `changed` for a picture change seen while paused, unless one went out less than a second ago.
    public mutating func changed(now: TimeInterval) -> Message? {
        guard paused, now - changedSent >= Self.changedEvery else { return nil }
        changedSent = now
        return .changed
    }

    /// Pausing holds from now on; resuming returns what was held, to send before the next picture.
    public mutating func setPaused(_ on: Bool, now: TimeInterval) -> [Message] {
        defer { paused = on }
        guard paused, !on else { return [] }
        let held = [windows, menuBar, focusRegion].compactMap { $0 }
        if windows != nil { windowsSent = now }
        windows = nil; menuBar = nil; focusRegion = nil
        return held
    }
}
