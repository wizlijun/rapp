import XCTest
@testable import RappCore

final class PacedSenderTests: XCTestCase {
    private struct Sent { let region: CanvasRect; let payload: FramePayload }

    private var t = 0.0
    private var sent: [Sent] = []
    private var weakChanges: [Bool] = []
    private let rect = CanvasRect(x: 0, y: 0, w: 1, h: 1)

    private func make(mode: Mode = .gray4, fps: Int = 30) -> PacedSender {
        t = 0
        sent = []
        weakChanges = []
        let s = PacedSender(mode: mode, fps: fps, now: { [unowned self] in self.t }) { [unowned self] r, p in
            self.sent.append(Sent(region: r, payload: p))
        }
        s.onWeakChange = { [unowned self] in self.weakChanges.append($0) }
        return s
    }

    private func small(_ seed: UInt32) -> [UInt8] { randomSamples(width: 64, height: 64, mode: .gray4, seed: seed) }

    private func offerSmall(_ s: PacedSender, _ seed: UInt32) {
        s.offer(samples: small(seed), raw: nil, width: 64, height: 64, region: rect, captured: t)
    }

    func testOnlyCapFramesInFlightAndNewestWins() throws {
        let s = make()
        let a = small(1), b = small(2), c = small(3)
        s.offer(samples: a, raw: nil, width: 64, height: 64, region: rect, captured: t)
        s.offer(samples: b, raw: nil, width: 64, height: 64, region: rect, captured: t)
        s.offer(samples: c, raw: nil, width: 64, height: 64, region: rect, captured: t)
        XCTAssertEqual(sent.count, 1)
        s.ack(processingMs: 0)
        XCTAssertEqual(sent.count, 2)
        let dec = FrameDecoder()
        try dec.decode(sent[0].payload)
        try dec.decode(sent[1].payload)
        XCTAssertEqual(dec.samples, c)
    }

    func testLargeFrameGoesOutAsSlicesOnePerSlot() throws {
        let s = make()
        let w = 1920, h = 1080
        let n = randomSamples(width: w, height: h, mode: .gray4, seed: 9)
        s.offer(samples: n, raw: nil, width: w, height: h, region: rect, captured: t)
        XCTAssertEqual(sent.count, 1)
        XCTAssertTrue(sent[0].payload.isFull)
        XCTAssertLessThanOrEqual(sent[0].payload.data.count, 8192 + 30 * 64 * 64 / 2)
        // A newer frame is held, not encoded, while slices are queued.
        s.offer(samples: small(1), raw: nil, width: 64, height: 64, region: rect, captured: t)
        var count = 1
        while count < 500 {
            s.ack(processingMs: 0)
            XCTAssertEqual(sent.count, count + 1, "one frame per ack")
            count = sent.count
            if sent[count - 1].payload.width == 64 { break }
            XCTAssertFalse(sent[count - 1].payload.isFull)
        }
        // Slices first, then the held newer frame (a resize, sent as a canvas move).
        XCTAssertGreaterThan(count, 3)
        XCTAssertEqual(sent.last?.payload.width, 64)
        XCTAssertEqual(sent.dropLast().filter { $0.payload.width == 64 }.count, 0)
    }

    func testModeChangeDropsQueuedSlicesAndSendsFull() throws {
        let s = make()
        let w = 1920, h = 1080
        let first = randomSamples(width: w, height: h, mode: .gray4, seed: 9)
        s.offer(samples: first, raw: nil, width: w, height: h, region: rect, captured: t)
        XCTAssertEqual(sent.count, 1)
        s.setMode(.duogray)
        let last = randomSamples(width: w, height: h, mode: .duogray, seed: 4)
        s.offer(samples: last, raw: nil, width: w, height: h, region: rect, captured: t)
        let before = sent.count
        s.ack(processingMs: 0)
        XCTAssertGreaterThan(sent.count, before)
        XCTAssertTrue(sent[before].payload.isFull)
        XCTAssertEqual(sent[before].payload.mode, .duogray)
        var guardCount = 0
        while guardCount < 500 {
            let c = sent.count
            s.ack(processingMs: 0)
            if sent.count == c { break }
            guardCount += 1
        }
        let dec = FrameDecoder()
        for f in sent { try dec.decode(f.payload) }
        XCTAssertEqual(dec.samples, last)
    }

    func testModeChangeDropsHeldOffer() {
        let s = make()
        offerSmall(s, 1)
        offerSmall(s, 2)  // held (cap 1)
        s.setMode(.color16)  // held samples were gray4-sized; must not be encoded by the new encoder
        s.ack(processingMs: 0)
        XCTAssertEqual(sent.count, 1)
    }

    func testProbeEntersWeakWhenFirstAckSlow() {
        let s = make()
        offerSmall(s, 1)
        t += 1.2
        s.ack(processingMs: 0)
        XCTAssertEqual(weakChanges, [true])
        XCTAssertTrue(s.weak)
    }

    func testOutageEntersWeakViaTick() {
        let s = make()
        offerSmall(s, 1)
        s.ack(processingMs: 0)  // rtt 0.3 below
        t = 0.3
        offerSmall(s, 2)
        s.ack(processingMs: 0)  // sample, rtt 0
        offerSmall(s, 3)  // sent, never acked
        for _ in 0..<3 {
            t += 1
            s.tick()
            XCTAssertTrue(weakChanges.isEmpty)
        }
        t += 1
        s.tick()
        XCTAssertEqual(weakChanges, [true])
    }

    func testIdleAfterOneSlowAckDoesNotEnterWeak() {
        let s = make()
        offerSmall(s, 1)
        t = 0.01
        s.ack(processingMs: 0)  // base rtt 10 ms
        offerSmall(s, 2)
        t = 0.26
        s.ack(processingMs: 0)  // one slow ack (250 ms), nothing in flight afterwards
        XCTAssertEqual(s.takeStats().inFlight, 0)
        for _ in 0..<5 {
            t += 1
            s.tick()
        }
        XCTAssertTrue(weakChanges.isEmpty)
        XCTAssertFalse(s.weak)
    }

    func testPinWhileWeakLeavesAtOnce() {
        let s = make()
        offerSmall(s, 1)
        t += 1.2
        s.ack(processingMs: 0)
        XCTAssertEqual(weakChanges, [true])
        s.setPinned(true)
        XCTAssertEqual(weakChanges, [true, false])
        XCTAssertFalse(s.weak)
        offerSmall(s, 2)
        for _ in 0..<10 {
            t += 1
            s.tick()
        }
        XCTAssertEqual(weakChanges, [true, false])
    }

    func testStatsReportRttLatencyAndCap() {
        let s = make()
        s.offer(samples: small(1), raw: nil, width: 64, height: 64, region: rect, captured: t - 0.15)
        t += 0.2
        s.ack(processingMs: 0)
        let st = s.takeStats()
        XCTAssertEqual(st.rttMs, 200)
        XCTAssertEqual(st.latencyMs, 350)
        XCTAssertEqual(st.baseRttMs, 200)
        XCTAssertEqual(st.cap, 1 + 6)
        XCTAssertEqual(st.inFlight, 0)
        XCTAssertFalse(st.weak)
        XCTAssertNil(s.takeStats().latencyMs)
    }

    // MARK: Settle and stats

    /// Opaque blocky pixels in screen space (the same scene ScrollCopyTests uses).
    private func scene(x: Int, y: Int, w: Int, h: Int, noiseFrom: Int? = nil) -> (bgra: [UInt8], region: CanvasRect) {
        var bgra = [UInt8](repeating: 255, count: w * h * 4)
        var rng: UInt32 = 12345
        for py in 0..<h {
            for px in 0..<w {
                let o = (py * w + px) * 4
                var v = UInt32(truncatingIfNeeded: ((x + px) / 3) &* 2_654_435_761 ^ ((y + py) / 2) &* 40503)
                if let n = noiseFrom, py >= n { rng = rng &* 1_664_525 &+ 1_013_904_223; v = rng }
                bgra[o] = UInt8(v & 0xFF)
                bgra[o + 1] = UInt8(v >> 8 & 0xFF)
                bgra[o + 2] = UInt8(v >> 16 & 0xFF)
            }
        }
        return (bgra, CanvasRect(x: Float(x), y: Float(y), w: Float(w), h: Float(h)))
    }

    private func quantize(_ bgra: [UInt8], _ w: Int, _ h: Int) -> [UInt8] {
        bgra.withUnsafeBytes { Quantizer.quantize(bgra: $0, width: w, height: h, bytesPerRow: w * 4, mode: .duogray) }
    }

    private func offerRaw(_ s: PacedSender, _ f: (bgra: [UInt8], region: CanvasRect), _ w: Int, _ h: Int) {
        s.offer(samples: quantize(f.bgra, w, h), raw: f.bgra, width: w, height: h, region: f.region, captured: t)
    }

    /// Acks until nothing more goes out.
    private func drain(_ s: PacedSender) {
        for _ in 0..<2000 {
            let c = sent.count
            s.ack(processingMs: 0)
            if sent.count == c { return }
        }
        XCTFail("never settled")
    }

    private func decoded() throws -> [UInt8] {
        let dec = FrameDecoder(mode: .duogray)
        for f in sent { try dec.decode(f.payload) }
        return dec.samples
    }

    func testSettleAfter300msOfNoDivergence() throws {
        let s = make(mode: .duogray)
        let (w, h) = (256, 128)
        offerRaw(s, scene(x: 100, y: 50, w: w, h: h), w, h)
        drain(s)
        // A 5 px region move keeps tiles on raw match: the canvas differs from the quantized frame.
        let b = scene(x: 95, y: 50, w: w + 5, h: h)
        let qb = quantize(b.bgra, w + 5, h)
        offerRaw(s, b, w + 5, h)
        drain(s)
        XCTAssertNotEqual(try decoded(), qb, "input must really diverge")
        let before = sent.count
        t += 0.29
        s.settleIfIdle()
        XCTAssertEqual(sent.count, before)
        t += 0.02
        s.settleIfIdle()
        XCTAssertGreaterThan(sent.count, before)
        drain(s)
        XCTAssertEqual(try decoded(), qb)
        let after = sent.count
        t += 1
        s.settleIfIdle()
        XCTAssertEqual(sent.count, after)
    }

    func testSettleWaitsForQueueAndHeldOffer() throws {
        let (w, h) = (1280, 800)
        let a = scene(x: 100, y: 50, w: w, h: h)
        // Same move, but the lower three quarters are noise: many slices, the top still raw-matches.
        let b = scene(x: 95, y: 50, w: w + 5, h: h, noiseFrom: h / 4)
        let qb = quantize(b.bgra, w + 5, h)

        // Reference: no settleIfIdle calls at all until everything is out.
        let ref = make(mode: .duogray)
        offerRaw(ref, a, w, h)
        drain(ref)
        let refBefore = sent.count
        offerRaw(ref, b, w + 5, h)
        drain(ref)
        let bFrames = sent.count - refBefore
        XCTAssertGreaterThan(bFrames, 2, "the frame must queue several slices")
        XCTAssertNotEqual(try decoded(), qb, "input must really diverge")

        let s = make(mode: .duogray)
        offerRaw(s, a, w, h)
        drain(s)
        let before = sent.count
        offerRaw(s, b, w + 5, h)   // first slice out, the rest queued
        // Far past 300 ms, with slices queued and a newer frame held: no settle may jump the queue.
        t += 0.5
        offerRaw(s, b, w + 5, h)   // held (identical: encodes to nothing)
        s.settleIfIdle()
        XCTAssertEqual(sent.count, before + 1)
        while sent.count < before + bFrames {
            let c = sent.count
            s.ack(processingMs: 0)
            XCTAssertGreaterThan(sent.count, c)
            if sent.count < before + bFrames {   // slices still queued
                s.settleIfIdle()
            }
        }
        XCTAssertEqual(sent.count, before + bFrames)
        drain(s)
        XCTAssertEqual(sent.count, before + bFrames)
        t += 0.31
        s.settleIfIdle()
        XCTAssertGreaterThan(sent.count, before + bFrames)
        drain(s)
        XCTAssertEqual(try decoded(), qb)
    }

    func testSettleRunsWhileOtherTilesKeepChanging() throws {
        let s = make(mode: .duogray)
        let (w, h) = (256, 128)
        offerRaw(s, scene(x: 100, y: 50, w: w, h: h), w, h)
        drain(s)
        var f = scene(x: 95, y: 50, w: w + 5, h: h)
        offerRaw(s, f, w + 5, h)
        drain(s)
        let w2 = w + 5
        XCTAssertNotEqual(try decoded(), quantize(f.bgra, w2, h), "input must really diverge")
        var settledAt: Double?
        for i in 1...6 {
            t += 0.1
            // Only the bottom-right block changes; the rest still matches on raw pixels.
            for py in (h - 64)..<h {
                for px in (w2 - 64)..<w2 {
                    let o = (py * w2 + px) * 4
                    f.bgra[o] = UInt8(truncatingIfNeeded: i * 37 + px)
                    f.bgra[o + 1] = UInt8(truncatingIfNeeded: i * 11 + py)
                }
            }
            offerRaw(s, f, w2, h)
            drain(s)
            let c = sent.count
            s.settleIfIdle()
            if sent.count > c, settledAt == nil { settledAt = t }
            drain(s)
        }
        XCTAssertNotNil(settledAt, "settle must run although a tile keeps changing")
        XCTAssertEqual(try decoded(), quantize(f.bgra, w2, h))
    }

    func testStatsCountFullFramesAndEncodeTime() {
        let s = make()
        offerSmall(s, 1)
        let st = s.takeStats()
        XCTAssertEqual(st.fullFrames, 1)
        XCTAssertNotNil(st.encodeMsMax)
        s.ack(processingMs: 0)
        offerSmall(s, 2)
        XCTAssertEqual(s.takeStats().fullFrames, 0)
    }
}
