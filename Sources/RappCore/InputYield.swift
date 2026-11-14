import Foundation

/// How long a remote input waits after another B device operated A (R8).
public let yieldWindow: TimeInterval = 1.0
/// The worker tells the host about input at most this often.
public let inputReportEvery: TimeInterval = 0.25
/// A blocked B hears about it at most this often.
public let blockedNoticeEvery: TimeInterval = 0.5

public enum YieldDecision: Equatable {
    /// Let it through; `report`: tell stdout about this input now.
    case pass(report: Bool)
    /// Hold it back; `notify`: the device name to tell B (empty string allowed), or nil.
    case drop(notify: String?)
}

/// Decides which remote input on A waits because another B device is operating A (R7).
/// Pure: the caller supplies the clock.
public struct InputYield {
    private var blockedUntil = -TimeInterval.infinity
    private var by = ""
    private var lastReport = -TimeInterval.infinity
    private var lastNotice = -TimeInterval.infinity
    private var owesReport = false
    private var heldKeys = Set<UInt16>()
    private var heldButtons = Set<MouseButton>()
    private var droppedKeys = Set<UInt16>()
    private var droppedButtons = Set<MouseButton>()

    public init() {}

    /// Another device is operating A: block until `yieldWindow` from now.
    public mutating func yielded(to by: String, at now: TimeInterval) {
        blockedUntil = now + yieldWindow
        self.by = by
    }

    /// True once when a deferred input report is due.
    public mutating func tick(at now: TimeInterval) -> Bool {
        guard owesReport, now - lastReport >= inputReportEvery else { return false }
        owesReport = false
        lastReport = now
        return true
    }

    public mutating func admit(_ m: Message, at now: TimeInterval) -> YieldDecision {
        let blocking = now < blockedUntil
        switch m {
        case .text, .scroll, .paste, .menuPick, .focus, .selectInput:
            return blocking ? blocked(at: now) : passed(at: now)
        case let .key(code, _, down):
            if down {
                if heldKeys.contains(code) { return passed(at: now) }
                if droppedKeys.contains(code) { return .drop(notify: nil) }
                if blocking { droppedKeys.insert(code); return blocked(at: now) }
                heldKeys.insert(code)
                return passed(at: now)
            }
            if heldKeys.remove(code) != nil { return passed(at: now) }
            if droppedKeys.remove(code) != nil { return .drop(notify: nil) }
            return blocking ? blocked(at: now) : .pass(report: false)
        case let .mouse(kind, button, _, _, _, _):
            switch kind {
            case .move:
                return blocking ? blocked(at: now) : .pass(report: false)
            case .down:
                if heldButtons.contains(button) { return passed(at: now) }
                if droppedButtons.contains(button) { return .drop(notify: nil) }
                if blocking { droppedButtons.insert(button); return blocked(at: now) }
                heldButtons.insert(button)
                return passed(at: now)
            case .drag:
                if heldButtons.contains(button) { return passed(at: now) }
                if droppedButtons.contains(button) { return .drop(notify: nil) }
                return blocking ? blocked(at: now) : .pass(report: false)
            case .up:
                if heldButtons.remove(button) != nil { return passed(at: now) }
                if droppedButtons.remove(button) != nil { return .drop(notify: nil) }
                return blocking ? blocked(at: now) : .pass(report: false)
            }
        default:
            return .pass(report: false)
        }
    }

    private mutating func passed(at now: TimeInterval) -> YieldDecision {
        if now - lastReport >= inputReportEvery {
            lastReport = now
            owesReport = false
            return .pass(report: true)
        }
        owesReport = true
        return .pass(report: false)
    }

    private mutating func blocked(at now: TimeInterval) -> YieldDecision {
        guard now - lastNotice >= blockedNoticeEvery else { return .drop(notify: nil) }
        lastNotice = now
        return .drop(notify: by)
    }
}
