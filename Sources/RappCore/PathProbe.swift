import Foundation

/// B's measure of the whole path to A (spec 2026-11-14-rapp-network-status §3.3): a `ping` at
/// once, then every 10 s, every 2 s while the user is operating (input in the last 5 s) or a ping
/// went unanswered. A ping with nothing at all from A within 2 s is a miss (a pong may wait
/// behind frames, but then the frames arrive); two misses in a row are `stalled`, and anything
/// from A ends that. No clock of its own: callers pass time in seconds and tick once a second.
public struct PathProbe {
    private var seq: UInt32 = 0
    private var pending: (seq: UInt32, at: TimeInterval, missed: Bool)?
    private var lastPing: TimeInterval?
    private var lastReceived: TimeInterval?
    private var lastInput: TimeInterval?
    private var misses = 0
    public private(set) var stalled = false

    static let idleEvery: TimeInterval = 10
    static let fastEvery: TimeInterval = 2
    static let wait: TimeInterval = 2
    static let activeFor: TimeInterval = 5
    static let missesStalled = 2

    public init() {}

    /// The user sent input.
    public mutating func input(now: TimeInterval) { lastInput = now }

    /// Once a second: the ping to send, if one is due, and the new `stalled` when it changed.
    public mutating func tick(now: TimeInterval) -> (ping: UInt32?, stalled: Bool?) {
        var change: Bool?
        if let p = pending, !p.missed, now - p.at >= Self.wait, (lastReceived ?? -.infinity) < p.at {
            pending!.missed = true
            misses += 1
            if misses >= Self.missesStalled, !stalled {
                stalled = true
                change = true
            }
        }
        let active = lastInput.map { now - $0 < Self.activeFor } ?? false
        let every = active || misses > 0 ? Self.fastEvery : Self.idleEvery
        guard lastPing.map({ now - $0 >= every }) ?? true else { return (nil, change) }
        seq &+= 1
        pending = (seq, now, false)
        lastPing = now
        return (seq, change)
    }

    /// Something arrived from A. Returns false when that ends a stall.
    public mutating func received(now: TimeInterval) -> Bool? {
        lastReceived = now
        misses = 0
        guard stalled else { return nil }
        stalled = false
        return false
    }

    /// The round trip in ms when `seq` is the newest ping (call `received` too).
    public mutating func pong(seq: UInt32, now: TimeInterval) -> Int? {
        guard let p = pending, p.seq == seq else { return nil }
        pending = nil
        return Int(((now - p.at) * 1000).rounded())
    }
}
