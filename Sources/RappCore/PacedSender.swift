import Foundation

/// Sends encoded frames under the in-flight cap and drives the traffic-saving level (`WeakTier`).
///
/// Not thread safe: call everything (including `transmit` completions) on one queue.
///
/// At most `cap` frames are outstanding; a changed frame is cut into slices, one per free slot,
/// and only the newest offered frame is kept while the slices go out.
public final class PacedSender {
    public struct Stats {
        public var rttMs: Int?
        public var baseRttMs: Int?
        public var latencyMs: Int?
        public var inFlight: Int
        public var cap: Int
        public var weak: Bool
        public var level: Int
        /// Full frames encoded since the previous call.
        public var fullFrames: Int
        /// The slowest encode since the previous call, in ms (nil when none ran).
        public var encodeMsMax: Int?
    }

    private struct Offer {
        var samples: [UInt8]
        var raw: [UInt8]?
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
    /// Each settle frame is one slice of at most this many bytes, so a frame
    /// captured meanwhile waits for at most one such slice.
    private static let settleLimit = 8192

    private let now: () -> TimeInterval
    private let transmit: (CanvasRect, FramePayload) -> Void
    private var encoder: FrameEncoder
    private var pacer: SendPacer
    private var tier = WeakTier()

    private var latest: Offer?
    private var queue: [Slice] = []
    private var pumping = false
    private var sessionFirstFrame = true
    private var firstSentAt: TimeInterval?
    private var firstAckSeen = false
    private var latencyMs: Int?
    private var fullFrames = 0
    private var encodeMsMax: Int?
    /// The last time the canvas became more approximate (or first inexact); settle waits 0.3 s from here.
    private var divergedAt: TimeInterval?
    private var lastRegion = CanvasRect(x: 0, y: 0, w: 0, h: 0)
    private static let settleDelay = 0.3

    /// The saving level changed (0 = the ceiling).
    public var onLevelChange: ((Int) -> Void)?
    public var weak: Bool { tier.weak }
    public var level: Int { tier.level }

    public init(mode: Mode, fps: Int, now: @escaping () -> TimeInterval,
                transmit: @escaping (_ region: CanvasRect, _ payload: FramePayload) -> Void) {
        self.now = now
        self.transmit = transmit
        self.encoder = FrameEncoder(mode: mode)
        self.pacer = SendPacer(fps: fps)
    }

    /// `raw` is the frame's tightly packed BGRA, only for two-tone modes (nil otherwise).
    public func offer(samples: [UInt8], raw: [UInt8]?, width: Int, height: Int, region: CanvasRect,
                      captured: TimeInterval) {
        latest = Offer(samples: samples, raw: raw, width: width, height: height, region: region, captured: captured)
        pump()
    }

    public func ack(processingMs: UInt16) {
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
        divergedAt = nil
    }

    /// Call every 100 ms: once the canvas has differed from the exact quantization for 300 ms,
    /// nothing is queued or held and a send slot is free, sends the next correcting frame (one slice of at most 8 KB).
    /// Later calls go on with the next part without another wait, as long as nothing is queued or
    /// held; a captured frame goes out before the next part, and one that adds approximation
    /// restarts the 300 ms.
    public func settleIfIdle() {
        // A free send slot too: a settle frame left waiting in the queue would hold up a
        // keystroke captured after it.
        guard encoder.needsSettle, queue.isEmpty, latest == nil, pacer.inFlight < pacer.cap(now: now()),
              let at = divergedAt, now() - at >= Self.settleDelay else { return }
        let started = now()
        let slices = encoder.encodeSettle(limit: Self.settleLimit)
        let t = now()
        encodeMsMax = max(encodeMsMax ?? 0, Int(((t - started) * 1000).rounded()))
        if !encoder.needsSettle { divergedAt = nil }
        // Stamped now: the capture is old, but the correction was made just now.
        queue = slices.map { Slice(region: lastRegion, payload: $0, captured: t) }
        pump()
    }

    public func setFps(_ fps: Int) { pacer.fps = fps }

    /// Automatic saving off (true): back to level 0 at once, and it stays there.
    public func setPinned(_ pinned: Bool) {
        let was = tier.level
        tier.pinned = pinned
        if was != tier.level { onLevelChange?(tier.level) }
    }

    /// The levels that save something under the current ceiling (`SaveLadder.steps`).
    public func setSteps(_ steps: [Int]) {
        report(tier.setSteps(steps))
    }

    /// Call once a second: finds an outage (no acks arriving) that no ack can report.
    public func tick() {
        let t = now()
        // An idle link is not queueing: a stale slow RTT must not keep the weak timer running.
        report(tier.observe(now: t, queueing: pacer.inFlight > 0 && pacer.queueing(now: t), onAck: false))
    }

    /// Stats for the last second. `latencyMs` is the most recent capture-to-ack latency since the
    /// previous call (nil when no ack arrived); it is cleared by this call.
    public func takeStats() -> Stats {
        let t = now()
        defer { latencyMs = nil; fullFrames = 0; encodeMsMax = nil }
        return Stats(rttMs: pacer.lastRtt.map { Int(($0 * 1000).rounded()) },
                     baseRttMs: pacer.baseRtt(now: t).map { Int(($0 * 1000).rounded()) },
                     latencyMs: latencyMs, inFlight: pacer.inFlight, cap: pacer.cap(now: t), weak: tier.weak, level: tier.level,
                     fullFrames: fullFrames, encodeMsMax: encodeMsMax)
    }

    private func report(_ change: Int?) {
        if let c = change { onLevelChange?(c) }
    }

    private func pump() {
        guard !pumping else { return }
        pumping = true
        defer { pumping = false }
        while pacer.inFlight < pacer.cap(now: now()) {
            if queue.isEmpty {
                guard let o = latest else { return }
                latest = nil
                let first = sessionFirstFrame ? Self.firstSliceLimit : nil
                sessionFirstFrame = false
                let started = now()
                let slices = encoder.encodeSlices(samples: o.samples, raw: o.raw, width: o.width, height: o.height,
                                                  region: o.region, limit: Self.sliceLimit, firstLimit: first)
                let ms = Int(((now() - started) * 1000).rounded())
                encodeMsMax = max(encodeMsMax ?? 0, ms)
                if slices.first?.isFull == true { fullFrames += 1 }
                lastRegion = o.region
                if !encoder.needsSettle {
                    divergedAt = nil
                } else if encoder.lastEncodeAddedApproximation || divergedAt == nil {
                    divergedAt = now()
                }
                queue = slices.map { Slice(region: o.region, payload: $0, captured: o.captured) }
                continue
            }
            let s = queue.removeFirst()
            let t = now()
            if firstSentAt == nil { firstSentAt = t }
            pacer.sent(at: t, captured: s.captured)
            transmit(s.region, s.payload)
        }
    }
}
