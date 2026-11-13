import Foundation

/// Weak-network tier state machine. No clock of its own: callers pass time in seconds.
public struct WeakTier {
    public private(set) var weak = false
    public var pinned = false {
        didSet { if pinned { weak = false } }
    }

    private var queueingSince: TimeInterval?
    private var lastQueueing: TimeInterval?

    private static let enterAfter: TimeInterval = 3
    private static let leaveAfter: TimeInterval = 30
    private static let slowFirstAck: TimeInterval = 1

    public init() {}

    /// Returns the new `weak` value when it changed, otherwise nil.
    public mutating func observe(now: TimeInterval, queueing: Bool, onAck: Bool) -> Bool? {
        if queueing {
            if queueingSince == nil { queueingSince = now }
            lastQueueing = now
            if !weak, !pinned, now - queueingSince! >= Self.enterAfter {
                weak = true
                return true
            }
            return nil
        }
        queueingSince = nil
        if weak, onAck, let last = lastQueueing, now - last >= Self.leaveAfter {
            weak = false
            return false
        }
        return nil
    }

    /// First ack arrived later than 1 s: start weak (unless pinned).
    public mutating func probe(firstAckDelay: TimeInterval) -> Bool? {
        guard firstAckDelay > Self.slowFirstAck, !pinned, !weak else { return nil }
        weak = true
        return true
    }
}
