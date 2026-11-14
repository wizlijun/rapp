import XCTest
@testable import RappCore

final class PacedSenderTests: XCTestCase {
    private struct Sent { let region: CanvasRect; let payload: FramePayload; let done: () -> Void }

    private var t = 0.0
    private var sent: [Sent] = []
    private var weakChanges: [Bool] = []
    private let rect = CanvasRect(x: 0, y: 0, w: 1, h: 1)

    private func make(mode: Mode = .gray4, fps: Int = 30, acks: Bool = true) -> PacedSender {
        t = 0
        sent = []
        weakChanges = []
        let s = PacedSender(mode: mode, fps: fps, acks: acks, now: { [unowned self] in self.t }) { [unowned self] r, p, d in
            self.sent.append(Sent(region: r, payload: p, done: d))
        }
        s.onWeakChange = { [unowned self] in self.weakChanges.append($0) }
        return s
    }

    private func small(_ seed: UInt32) -> [UInt8] { randomSamples(width: 64, height: 64, mode: .gray4, seed: seed) }

    private func offerSmall(_ s: PacedSender, _ seed: UInt32) {
        s.offer(samples: small(seed), width: 64, height: 64, region: rect, captured: t)
    }

    func testOnlyCapFramesInFlightAndNewestWins() throws {
        let s = make()
        let a = small(1), b = small(2), c = small(3)
        s.offer(samples: a, width: 64, height: 64, region: rect, captured: t)
        s.offer(samples: b, width: 64, height: 64, region: rect, captured: t)
        s.offer(samples: c, width: 64, height: 64, region: rect, captured: t)
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
        s.offer(samples: n, width: w, height: h, region: rect, captured: t)
        XCTAssertEqual(sent.count, 1)
        XCTAssertTrue(sent[0].payload.isFull)
        XCTAssertLessThanOrEqual(sent[0].payload.data.count, 8192 + 30 * 64 * 64 / 2)
        // A newer frame is held, not encoded, while slices are queued.
        s.offer(samples: small(1), width: 64, height: 64, region: rect, captured: t)
        var count = 1
        while count < 500 {
            s.ack(processingMs: 0)
            XCTAssertEqual(sent.count, count + 1, "one frame per ack")
            count = sent.count
            if sent[count - 1].payload.width == 64 { break }
            XCTAssertFalse(sent[count - 1].payload.isFull)
        }
        // Slices first, then the held newer frame (size change makes it full).
        XCTAssertGreaterThan(count, 3)
        XCTAssertEqual(sent.last?.payload.width, 64)
        XCTAssertEqual(sent.dropLast().filter { $0.payload.width == 64 }.count, 0)
    }

    func testModeChangeDropsQueuedSlicesAndSendsFull() throws {
        let s = make()
        let w = 1920, h = 1080
        let first = randomSamples(width: w, height: h, mode: .gray4, seed: 9)
        s.offer(samples: first, width: w, height: h, region: rect, captured: t)
        XCTAssertEqual(sent.count, 1)
        s.setMode(.duogray)
        let last = randomSamples(width: w, height: h, mode: .duogray, seed: 4)
        s.offer(samples: last, width: w, height: h, region: rect, captured: t)
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

    func testV6PathUsesCompletionNotAcks() {
        let s = make(acks: false)
        offerSmall(s, 1)
        offerSmall(s, 2)
        XCTAssertEqual(sent.count, 1)
        s.ack(processingMs: 0)
        XCTAssertEqual(sent.count, 1)
        sent[0].done()
        XCTAssertEqual(sent.count, 2)
        // A large frame is not sliced.
        let w = 1920, h = 1080
        s.offer(samples: randomSamples(width: w, height: h, mode: .gray4, seed: 9), width: w, height: h,
                region: rect, captured: t)
        sent[1].done()
        XCTAssertEqual(sent.count, 3)
        sent[2].done()
        XCTAssertEqual(sent.count, 3)
        t += 10
        s.tick()
        XCTAssertFalse(s.weak)
        XCTAssertTrue(weakChanges.isEmpty)
    }

    func testStatsReportRttLatencyAndCap() {
        let s = make()
        s.offer(samples: small(1), width: 64, height: 64, region: rect, captured: t - 0.15)
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
}
