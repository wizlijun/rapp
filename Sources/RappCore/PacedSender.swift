import Foundation

/// Sends encoded frames under the in-flight cap and drives the weak-network tier.
///
/// Not thread safe: call everything (including `transmit` completions) on one queue.
///
/// With `acks` (v7 clients) at most `cap` frames are outstanding; a changed frame is cut
/// into slices, one per free slot, and only the newest offered frame is kept while the
/// slices go out. Without `acks` (v6 clients) it behaves as before: one frame at a time,
/// `transmit`'s `done` releases the next, the newest pending frame wins, no slicing, never weak.
public final class PacedSender {
    public struct Stats {
        public var rttMs: Int?
        public var baseRttMs: Int?
        public var latencyMs: Int?
        public var inFlight: Int
        public var cap: Int
        public var weak: Bool
    }

    private struct Offer {
        var samples: [UInt8]
        var width: Int
        var height: Int
        var region: CanvasRect
        var captured: TimeInterval
    }

    private struct Slice {
        var region: CanvasRect
        var payload: FramePayload
        var captured: TimeInterval
    }

    private static let sliceLimit = 32768
    private static let firstSliceLimit = 8192

    private let acks: Bool
    private let now: () -> TimeInterval
    private let transmit: (CanvasRect, FramePayload, @escaping () -> Void) -> Void
    private var encoder: FrameEncoder
    private var pacer: SendPacer
    private var tier = WeakTier()

    private var latest: Offer?
    private var queue: [Slice] = []
    private var busy = false  // v6 only: a frame is waiting for its completion
    private var pumping = false
    private var sessionFirstFrame = true
    private var firstSentAt: TimeInterval?
    private var firstAckSeen = false
    private var latencyMs: Int?

    public var onWeakChange: ((Bool) -> Void)?
    public var weak: Bool { tier.weak }

    public init(mode: Mode, fps: Int, acks: Bool, now: @escaping () -> TimeInterval,
                transmit: @escaping (_ region: CanvasRect, _ payload: FramePayload, _ done: @escaping () -> Void) -> Void) {
        self.acks = acks
        self.now = now
        self.transmit = transmit
        self.encoder = FrameEncoder(mode: mode)
        self.pacer = SendPacer(fps: fps)
    }

    public func offer(samples: [UInt8], width: Int, height: Int, region: CanvasRect, captured: TimeInterval) {
        latest = Offer(samples: samples, width: width, height: height, region: region, captured: captured)
        pump()
    }

    public func ack(processingMs: UInt16) {
        guard acks else { return }
        let t = now()
        guard let r = pacer.acked(at: t, processingMs: processingMs) else { return }
        latencyMs = Int((r.latency * 1000).rounded())
        if !firstAckSeen {
            firstAckSeen = true
            if let sentAt = firstSentAt { report(tier.probe(firstAckDelay: t - sentAt)) }
        }
        report(tier.observe(now: t, queueing: pacer.queueing(now: t), onAck: true))
        pump()
    }

    /// New encoder: queued slices and the held offer (quantized for the old mode) are dropped,
    /// the next frame is full. Frames already in flight stay tracked and their acks still count.
    public func setMode(_ mode: Mode) {
        encoder = FrameEncoder(mode: mode)
        queue = []
        latest = nil
    }

    public func setFps(_ fps: Int) { pacer.fps = fps }

    public func setPinned(_ pinned: Bool) {
        let was = tier.weak
        tier.pinned = pinned
        if was && !tier.weak { onWeakChange?(false) }
    }

    /// Call once a second: finds an outage (no acks arriving) that no ack can report.
    public func tick() {
        guard acks else { return }
        let t = now()
        // An idle link is not queueing: a stale slow RTT must not keep the weak timer running.
        report(tier.observe(now: t, queueing: pacer.inFlight > 0 && pacer.queueing(now: t), onAck: false))
    }

    /// Stats for the last second. `latencyMs` is the most recent capture-to-ack latency since the
    /// previous call (nil when no ack arrived); it is cleared by this call.
    public func takeStats() -> Stats {
        let t = now()
        defer { latencyMs = nil }
        return Stats(rttMs: pacer.lastRtt.map { Int(($0 * 1000).rounded()) },
                     baseRttMs: pacer.baseRtt(now: t).map { Int(($0 * 1000).rounded()) },
                     latencyMs: latencyMs, inFlight: pacer.inFlight, cap: pacer.cap(now: t), weak: tier.weak)
    }

    private func report(_ change: Bool?) {
        if let c = change { onWeakChange?(c) }
    }

    private func pump() {
        if !acks { pumpV6(); return }
        guard !pumping else { return }
        pumping = true
        defer { pumping = false }
        while pacer.inFlight < pacer.cap(now: now()) {
            if queue.isEmpty {
                guard let o = latest else { return }
                latest = nil
                let first = sessionFirstFrame ? Self.firstSliceLimit : nil
                sessionFirstFrame = false
                let slices = encoder.encodeSlices(samples: o.samples, width: o.width, height: o.height,
                                                  limit: Self.sliceLimit, firstLimit: first)
                queue = slices.map { Slice(region: o.region, payload: $0, captured: o.captured) }
                continue
            }
            let s = queue.removeFirst()
            let t = now()
            if firstSentAt == nil { firstSentAt = t }
            pacer.sent(at: t, captured: s.captured)
            transmit(s.region, s.payload) {}
        }
    }

    private func pumpV6() {
        while !busy, let o = latest {
            latest = nil
            guard let p = encoder.encode(samples: o.samples, width: o.width, height: o.height) else { continue }
            busy = true
            transmit(o.region, p) { [weak self] in
                self?.busy = false
                self?.pumpV6()
            }
        }
    }
}
