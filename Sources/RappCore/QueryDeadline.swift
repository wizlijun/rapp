import Foundation

/// A fixed point in time a query must finish by; every AX call is given what is left of it.
public struct QueryDeadline: Equatable {
    public let end: TimeInterval
    public init(start: TimeInterval, budget: TimeInterval) { end = start + budget }

    /// Seconds left for the next call, or nil when nothing worth waiting for remains (under 1 ms).
    public func remaining(now: TimeInterval) -> TimeInterval? {
        let left = end - now
        return left >= 0.001 ? left : nil
    }

    public func expired(now: TimeInterval) -> Bool { remaining(now: now) == nil }
}
