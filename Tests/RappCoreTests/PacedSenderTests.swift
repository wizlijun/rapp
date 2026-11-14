import XCTest
@testable import RappCore

final class PacedSenderTests: XCTestCase {
    private struct Sent { let region: CanvasRect; let payload: FramePayload }

    private var t = 0.0
    private var sent: [Sent] = []
    private var levelChanges: [Int] = []
    private let rect = CanvasRect(x: 0, y: 0, w: 1, h: 1)

    private func make(mode: Mode = .gray4, fps: Int = 30) -> PacedSender {
        t = 0
        sent = []
        levelChanges = []
        let s = PacedSender(mode: mode, fps: fps, now: { [unowned self] in self.t }) { [unowned self] r, p in
            self.sent.append(Sent(region: r, payload: p))
        }
        s.onLevelChange = { [unowned self] in self.levelChanges.append($0) }
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
        XCTAssertEqual(levelChanges, [2])
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
            XCTAssertTrue(levelChanges.isEmpty)
        }
        t += 1
        s.tick()
        XCTAssertEqual(levelChanges, [1])
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
        XCTAssertTrue(levelChanges.isEmpty)
        XCTAssertFalse(s.weak)
    }

    func testPinWhileWeakLeavesAtOnce() {
        let s = make()
        offerSmall(s, 1)
        t += 1.2
        s.ack(processingMs: 0)
        XCTAssertEqual(levelChanges, [2])
        s.setPinned(true)
        XCTAssertEqual(levelChanges, [2, 0])
        XCTAssertFalse(s.weak)
        offerSmall(s, 2)
        for _ in 0..<10 {
            t += 1
            s.tick()
        }
        XCTAssertEqual(levelChanges, [2, 0])
    }

    func testNewStepsReportALevelThatIsGone() {
        let s = make()
        offerSmall(s, 1)
        s.ack(processingMs: 0)
        t = 0.3
        offerSmall(s, 2)
        s.ack(processingMs: 0)
        offerSmall(s, 3)
        for _ in 0..<4 {
            t += 1
            s.tick()
        }
        XCTAssertEqual(levelChanges, [1])
        XCTAssertEqual(s.level, 1)
        s.setSteps([2])
        XCTAssertEqual(levelChanges, [1, 0])
        XCTAssertFalse(s.weak)
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

    /// Calls `settleIfIdle` (draining after each) until it sends nothing more, without moving the
    /// clock: once settle has started, its later frames need no further wait. Returns the frames sent.
    @discardableResult
    private func settleAll(_ s: PacedSender) -> [FramePayload] {
        var frames = [FramePayload]()
        for _ in 0..<2000 {
            let c = sent.count
            s.settleIfIdle()
            if sent.count == c { return frames }
            frames += sent[c...].map(\.payload)
            drain(s)
        }
        XCTFail("settle never finished")
        return frames
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
        XCTAssertFalse(settleAll(s).isEmpty)
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
        XCTAssertFalse(settleAll(s).isEmpty)
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
            if !settleAll(s).isEmpty, settledAt == nil { settledAt = t }
        }
        XCTAssertNotNil(settledAt, "settle must run although a tile keeps changing")
        XCTAssertEqual(try decoded(), quantize(f.bgra, w2, h))
    }

    func testNoSettleDuringContinuousScroll() throws {
        let (w, h) = (256, 192)
        func frame(_ scroll: Int) -> (bgra: [UInt8], region: CanvasRect) {
            var f = scene(x: 100, y: 50 + scroll, w: w, h: h)
            f.region = CanvasRect(x: 100, y: 50, w: Float(w), h: Float(h))
            return f
        }
        let s = make(mode: .duogray)
        offerRaw(s, frame(0), w, h)
        drain(s)
        var last = frame(0)
        for i in 1...10 {
            t += 0.1
            last = frame(i * 5)
            offerRaw(s, last, w, h)
            drain(s)
            let c = sent.count
            s.settleIfIdle()
            XCTAssertEqual(sent.count, c, "scroll frame \(i)")
        }
        let q = quantize(last.bgra, w, h)
        XCTAssertNotEqual(try decoded(), q, "the scroll must really leave the canvas approximate")
        // The scroll stops: settle comes 300 ms later.
        let before = sent.count
        t += 0.29
        s.settleIfIdle()
        XCTAssertEqual(sent.count, before)
        t += 0.02
        XCTAssertFalse(settleAll(s).isEmpty)
        XCTAssertEqual(try decoded(), q)
    }

    func testSettleDoesNotJumpAHeldOffer() throws {
        let (w, h) = (256, 128)
        let a = scene(x: 100, y: 50, w: w, h: h)
        let b = scene(x: 95, y: 50, w: w + 5, h: h)
        let w2 = w + 5
        func touched(_ f: (bgra: [UInt8], region: CanvasRect), _ seed: UInt8, row: Int) -> (bgra: [UInt8], region: CanvasRect) {
            var g = f
            for py in row..<(row + 16) { for px in 0..<16 { g.bgra[(py * w2 + px) * 4] = seed &+ UInt8(px) } }
            return g
        }
        let c = touched(b, 7, row: 100), d = touched(c, 99, row: 100)
        func play(settle: Bool) throws -> [Sent] {
            let s = make(mode: .duogray)
            offerRaw(s, a, w, h)
            drain(s)
            offerRaw(s, b, w2, h)
            drain(s)
            XCTAssertNotEqual(try decoded(), quantize(b.bgra, w2, h), "input must really diverge")
            offerRaw(s, c, w2, h)   // sent, in flight
            offerRaw(s, d, w2, h)   // held, queue empty
            t += 0.5
            let n = sent.count
            if settle { s.settleIfIdle() }
            XCTAssertEqual(sent.count, n)
            s.ack(processingMs: 0)
            XCTAssertGreaterThan(sent.count, n)
            return sent
        }
        let plain = try play(settle: false)
        let withSettle = try play(settle: true)
        // The held frame goes out next; no correction was queued ahead of it.
        XCTAssertEqual(withSettle.count, plain.count)
        XCTAssertEqual(withSettle.map(\.payload), plain.map(\.payload))
    }

    /// A terminal page scrolled by `scroll` px in a fixed region, large enough that a duogray
    /// settle after a 5 px scroll is far over 8 KB, with `typed` dark cells near the bottom right.
    private func page(_ scroll: Int, typed: Int = 0, w: Int = 1024, h: Int = 768) -> (bgra: [UInt8], region: CanvasRect) {
        var f = scene(x: 100, y: 50 + scroll, w: w, h: h)
        f.region = CanvasRect(x: 100, y: 50, w: Float(w), h: Float(h))
        for c in 0..<typed {
            for py in (h - 40)..<(h - 24) { for px in (w - 200 + c * 8)..<(w - 194 + c * 8) {
                let o = (py * w + px) * 4
                (f.bgra[o], f.bgra[o + 1], f.bgra[o + 2]) = (10, 10, 10)
            } }
        }
        return f
    }

    func testLargeSettleGoesOutAsIndependentBoundedFrames() throws {
        let s = make(mode: .duogray)
        let (w, h) = (1024, 768)
        offerRaw(s, page(0), w, h)
        drain(s)
        offerRaw(s, page(5), w, h)
        drain(s)
        let q = quantize(page(5).bgra, w, h)
        XCTAssertNotEqual(try decoded(), q, "input must really diverge")
        t += 0.31
        let frames = settleAll(s)
        XCTAssertGreaterThan(frames.count, 2, "the settle must really need several frames")
        for f in frames {
            XCTAssertEqual(f.flags, [.start, .end])
            XCTAssertEqual(f.dx, 0)
            XCTAssertEqual(f.dy, 0)
            XCTAssertLessThanOrEqual(f.data.count, 8192)
        }
        XCTAssertEqual(try decoded(), q)
        // Done: nothing more, however long the calm.
        t += 5
        let after = sent.count
        s.settleIfIdle()
        XCTAssertEqual(sent.count, after)
    }

    /// Typing right after a scroll stops: the keystroke frame waits for at most the one settle
    /// frame in flight, then the settle goes on and ends at the newest frame's quantization.
    func testKeystrokeGoesOutBetweenSettleFrames() throws {
        let s = make(mode: .duogray)
        let (w, h) = (1024, 768)
        offerRaw(s, page(0), w, h)
        drain(s)
        offerRaw(s, page(5), w, h)
        drain(s)
        t += 0.31
        let before = sent.count
        s.settleIfIdle()
        XCTAssertEqual(sent.count, before + 1, "one settle frame per call")
        XCTAssertEqual(sent[before].payload.flags, [.start, .end])
        // The keystroke is captured while that settle frame is in flight: it is held, and settle
        // must not send its next frame ahead of it.
        let typed = page(5, typed: 3)
        offerRaw(s, typed, w, h)
        XCTAssertEqual(sent.count, before + 1)
        s.settleIfIdle()
        XCTAssertEqual(sent.count, before + 1)
        s.ack(processingMs: 0)
        XCTAssertEqual(sent.count, before + 2)
        // The frame that went out next carries the typed cells.
        let dec = FrameDecoder(mode: .duogray)
        for f in sent { try dec.decode(f.payload) }
        let qt = quantize(typed.bgra, w, h)
        for py in (h - 40)..<(h - 24) {
            let o = py * w + w - 200
            XCTAssertEqual(Array(dec.samples[o..<(o + 24)]), Array(qt[o..<(o + 24)]), "typed row \(py)")
        }
        drain(s)
        // Settle goes on right away (no new 300 ms: the keystroke added no approximation).
        XCTAssertGreaterThan(settleAll(s).count, 1)
        XCTAssertEqual(try decoded(), qt)
    }

    /// A settle tick while the link is full makes nothing: no settle frame may wait in the queue,
    /// where a keystroke captured just after would have to queue behind it.
    func testSettleTickOnFullLinkQueuesNothing() throws {
        let s = make(mode: .duogray)
        let (w, h) = (1024, 768)
        offerRaw(s, page(0), w, h)
        drain(s)
        offerRaw(s, page(5), w, h)
        drain(s)
        t += 0.31
        let before = sent.count
        s.settleIfIdle()
        XCTAssertEqual(sent.count, before + 1)
        s.settleIfIdle()   // the one slot is taken
        XCTAssertEqual(sent.count, before + 1)
        // The keystroke arrives after that tick: it must go out on the next ack, not a settle frame.
        let typed = page(5, typed: 3)
        offerRaw(s, typed, w, h)
        s.ack(processingMs: 0)
        XCTAssertEqual(sent.count, before + 2)
        let dec = FrameDecoder(mode: .duogray)
        for f in sent { try dec.decode(f.payload) }
        let qt = quantize(typed.bgra, w, h)
        for py in (h - 40)..<(h - 24) {
            let o = py * w + w - 200
            XCTAssertEqual(Array(dec.samples[o..<(o + 24)]), Array(qt[o..<(o + 24)]), "typed row \(py)")
        }
        drain(s)
        XCTAssertGreaterThan(settleAll(s).count, 1)
        XCTAssertEqual(try decoded(), qt)
    }

    func testSettleFramesAreStampedAndTimedNow() {
        let s = make(mode: .duogray)
        let (w, h) = (1024, 768)
        offerRaw(s, page(0), w, h)
        drain(s)
        offerRaw(s, page(5), w, h)
        drain(s)
        _ = s.takeStats()
        // Long after the capture: the settle frame's latency counts from when it was made.
        t += 5
        let before = sent.count
        s.settleIfIdle()
        XCTAssertEqual(sent.count, before + 1)
        t += 0.05
        s.ack(processingMs: 0)
        let st = s.takeStats()
        XCTAssertEqual(st.latencyMs, 50)
        XCTAssertNotNil(st.encodeMsMax, "the settle encode must be timed")
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
