import Foundation

/// The traffic-saving level state machine (spec 2026-11-14-rapp-network-status §6.2). No clock of
/// its own: callers pass time in seconds. Queueing for 3 s goes one step down, 3 s more another;
/// 30 s without queueing (seen on an ack) goes one step up. `steps` are the levels below 0 that
/// save something (`SaveLadder.steps`).
public struct WeakTier {
    public private(set) var level = 0
    public var weak: Bool { level > 0 }
    public var steps: [Int] = [1, 2]
    /// Automatic saving is off: level 0, always.
    public var pinned = false {
        didSet { if pinned { level = 0 } }
    }

    private var queueingSince: TimeInterval?
    private var lastQueueing: TimeInterval?

    private static let downAfter: TimeInterval = 3
    private static let upAfter: TimeInterval = 30
    private static let slowFirstAck: TimeInterval = 1

    public init() {}

    /// Returns the new level when it changed, otherwise nil.
    public mutating func observe(now: TimeInterval, queueing: Bool, onAck: Bool) -> Int? {
        if queueing {
            if queueingSince == nil { queueingSince = now }
            lastQueueing = now
            if !pinned, let next = steps.first(where: { $0 > level }), now - queueingSince! >= Self.downAfter {
                level = next
                queueingSince = now
                return level
            }
            return nil
        }
        queueingSince = nil
        // Entered via probe: no queueing seen yet, so the 30 s count starts at the first observation.
        if weak, lastQueueing == nil { lastQueueing = now }
        if weak, onAck, let last = lastQueueing, now - last >= Self.upAfter {
            level = steps.last(where: { $0 < level }) ?? 0
            lastQueueing = now
            return level
        }
        return nil
    }

    /// First ack arrived later than 1 s: start at the last step (unless pinned).
    public mutating func probe(firstAckDelay: TimeInterval) -> Int? {
        guard firstAckDelay > Self.slowFirstAck, !pinned, level == 0, let last = steps.last else { return nil }
        level = last
        return level
    }

    /// A new ceiling. The level stays; one that is no longer a step (it would save nothing) becomes
    /// the step above it. Returns the new level when it changed.
    public mutating func setSteps(_ new: [Int]) -> Int? {
        steps = new
        guard level > 0, !new.contains(level) else { return nil }
        level = new.last(where: { $0 < level }) ?? 0
        return level
    }
}
