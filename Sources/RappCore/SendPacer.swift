import Foundation

/// Tracks frames in flight and ack round trips; decides how many frames may be outstanding.
/// No clock of its own: callers pass time in seconds.
public struct SendPacer {
    public var fps: Int

    private struct Sample { let sentAt: TimeInterval; let rtt: TimeInterval }
    private var samples: [Sample] = []
    private var pending: [(sentAt: TimeInterval, captured: TimeInterval)] = []
    public private(set) var lastRtt: TimeInterval?

    private static let window: TimeInterval = 10
    private static let fallbackCount = 8
    private static let queueingMargin: TimeInterval = 0.1

    public init(fps: Int) { self.fps = fps }

    public var inFlight: Int { pending.count }

    public mutating func sent(at: TimeInterval, captured: TimeInterval) {
        pending.append((at, captured))
    }

    /// Matches the oldest in-flight frame. Nil (and no change) when nothing is in flight.
    public mutating func acked(at: TimeInterval, processingMs: UInt16) -> (rtt: TimeInterval, latency: TimeInterval)? {
        guard !pending.isEmpty else { return nil }
        let f = pending.removeFirst()
        let rtt = max(0, at - f.sentAt - Double(processingMs) / 1000)
        samples.append(Sample(sentAt: f.sentAt, rtt: rtt))
        if samples.count > 4096 { samples.removeFirst(samples.count - 4096) }
        lastRtt = rtt
        return (rtt, at - f.captured)
    }

    /// Min RTT among samples sent within the last 10 s; else min of the last 8 samples; else nil.
    public func baseRtt(now: TimeInterval) -> TimeInterval? {
        let inWindow = samples.filter { $0.sentAt >= now - Self.window }
        if let m = inWindow.map(\.rtt).min() { return m }
        return samples.suffix(Self.fallbackCount).map(\.rtt).min()
    }

    public func queueing(now: TimeInterval) -> Bool {
        guard let base = baseRtt(now: now) else { return false }
        let oldestAge = pending.first.map { now - $0.sentAt } ?? 0
        return max(lastRtt ?? 0, oldestAge) > base + Self.queueingMargin
    }

    public func cap(now: TimeInterval) -> Int {
        guard let base = baseRtt(now: now), !queueing(now: now) else { return 1 }
        // The epsilon keeps float noise (e.g. 9.000000000000002) from rounding a whole frame up.
        let want = 1 + Int((Double(fps) * base - 1e-9).rounded(.up))
        return min(want, max(2, fps))
    }

    public mutating func reset() {
        samples = []
        pending = []
        lastRtt = nil
    }
}
