import CoreGraphics
import XCTest
@testable import RappCore

/// `SendPacer`, `WeakTier`, `SaveLadder`, `PacedSender` and `PauseOutbox` traces, recorded for
/// `rust/host-core/tests/pacing.rs`.
///
/// Every fixture is a case list (`HostFixture.cases`). A trace case is
/// `{"name", "in": {…, "calls": [call]}, "out": [result per call]}`; each call is an object with
/// an `"op"` and its arguments, and Rust replays the calls in order and compares each result.
///
/// - `send-pacer.json`: `in.fps`; ops `sent{at,captured}`, `acked{at,ms}` → `{rtt,latency}`|null,
///   `base_rtt{now}` → number|null, `queueing{now}` → bool, `cap{now}` → int, `in_flight` → int,
///   `last_rtt` → number|null, `reset`, `fps{fps}` (assigns `fps`). Results of ops without one are null.
/// - `weak-tier.json`: ops `steps{steps}` (assigns `steps`), `pinned{on}` (assigns `pinned`),
///   `observe{now,queueing,on_ack}`, `probe{delay}`, `set_steps{steps}`; each result is
///   `{"r": int|null, "level", "weak"}`.
/// - `save-ladder.json`: one case per ceiling, `in` = `{mode, fps, density}`,
///   `out` = `{"steps": [int], "streams": [{level, mode, fps, density}]}` for levels -1...4.
/// - `pause-outbox.json`: messages are hex of `Message.encoded()`; ops `pass{msg,now}` → hex|null,
///   `due{now}` → hex|null, `changed{now}` → hex|null, `set_paused{on,now}` → [hex]; each result is
///   `{"r": …, "paused": bool}`.
/// - `paced-sender.json`: `in` = `{mode, fps, pictures, calls}`. A picture is a generator spec
///   (below) plus `samples_fnv`/`raw_fnv` (FNV-1a, 16 hex digits; `raw_fnv` null without raw
///   pixels), so a generator mismatch shows up apart from a sender mismatch. Ops:
///   `offer{pic,captured,now}`, `ack{ms,now}`, `settle{now}`, `tick{now}`, `set_paused{on,now}`,
///   `set_mode{mode}`, `set_fps{fps}`, `set_pinned{on}`, `set_steps{steps}`, `take_stats{now}`.
///   Each result is `{"events": [event], "level", "weak"}` plus `"stats"` for `take_stats`. Events,
///   in callback order: `{"frame": {"len", "fnv", "hex"}}` for each `transmit` (the encoded
///   `Message.frame`, `hex` only up to 512 bytes, null above), `{"level": n}` for `onLevelChange`,
///   `{"encoded": {region, width, height, full, changed, copy}}` for `onEncoded` (`copy` is
///   `[x, y, w, h]` of `copyBounds` or null). The clock only moves between calls, so every
///   encode takes 0 ms, as in `PacedSenderTests`.
///
/// Picture specs: `{"gen": "random", w, h, mode, seed, region}` is `randomSamples` with no raw
/// pixels; `{"gen": "scene", x, y, w, h, noise_from, region, quantize, edits}` is
/// `PacedSenderTests.scene` (BGRA, then edits in order, samples quantized for `quantize`, raw =
/// the BGRA). Edits: `{"kind": "typed", "n"}` (`page`'s typed cells), `{"kind": "touch", "seed",
/// "row"}` (`testSettleDoesNotJumpAHeldOffer`'s block), `{"kind": "corner", "i"}`
/// (`testSettleRunsWhileOtherTilesKeepChanging`'s bottom-right block).
final class PacingFixtures: XCTestCase {
    static func modeName(_ m: Mode) -> String { TileFixtures.modeNames[Int(m.rawValue)] }
    static func fnvHex(_ bytes: [UInt8]) -> String { String(format: "%016llx", TileFixtures.fnv(bytes)) }
    static func opt(_ v: Double?) -> Any { v.map { $0 as Any } ?? NSNull() }
    static func opt(_ v: Int?) -> Any { v.map { $0 as Any } ?? NSNull() }

    // MARK: - SendPacer

    struct PacerTrace {
        let name: String
        var p: SendPacer
        let fps: Int
        var calls: [[String: Any]] = []
        var outs: [Any] = []

        init(_ name: String, fps: Int) {
            self.name = name
            self.fps = fps
            p = SendPacer(fps: fps)
        }

        mutating func sent(at: Double, captured: Double) {
            p.sent(at: at, captured: captured)
            calls.append(["op": "sent", "at": at, "captured": captured])
            outs.append(NSNull())
        }

        @discardableResult
        mutating func acked(at: Double, ms: UInt16) -> (rtt: Double, latency: Double)? {
            let r = p.acked(at: at, processingMs: ms)
            calls.append(["op": "acked", "at": at, "ms": Int(ms)])
            outs.append(r.map { ["rtt": $0.rtt, "latency": $0.latency] as Any } ?? NSNull())
            return r
        }

        mutating func exchange(at: Double, rtt: Double) {
            sent(at: at, captured: at)
            acked(at: at + rtt, ms: 0)
        }

        mutating func baseRtt(_ now: Double) {
            calls.append(["op": "base_rtt", "now": now])
            outs.append(PacingFixtures.opt(p.baseRtt(now: now)))
        }

        mutating func queueing(_ now: Double) {
            calls.append(["op": "queueing", "now": now])
            outs.append(p.queueing(now: now))
        }

        mutating func cap(_ now: Double) {
            calls.append(["op": "cap", "now": now])
            outs.append(p.cap(now: now))
        }

        mutating func state(_ now: Double) {
            calls.append(["op": "in_flight"])
            outs.append(p.inFlight)
            calls.append(["op": "last_rtt"])
            outs.append(PacingFixtures.opt(p.lastRtt))
            baseRtt(now)
            queueing(now)
            cap(now)
        }

        mutating func reset() {
            p.reset()
            calls.append(["op": "reset"])
            outs.append(NSNull())
        }

        mutating func setFps(_ fps: Int) {
            p.fps = fps
            calls.append(["op": "fps", "fps": fps])
            outs.append(NSNull())
        }

        var json: [String: Any] { ["name": name, "in": ["fps": fps, "calls": calls] as [String: Any], "out": outs] }
    }

    static func pacerTraces() -> [PacerTrace] {
        var out = [PacerTrace]()

        var a = PacerTrace("cap is one before any sample", fps: 30)
        a.state(0)
        out.append(a)

        var b = PacerTrace("lan cap is two", fps: 30)
        for i in 0..<5 { b.exchange(at: Double(i) * 0.1, rtt: 0.002) }
        b.state(0.5)
        out.append(b)

        var c = PacerTrace("cap at 80 ms and 30 fps is four", fps: 30)
        for i in 0..<5 { c.exchange(at: Double(i) * 0.1, rtt: 0.08) }
        c.state(0.6)
        out.append(c)

        var d = PacerTrace("cap clamped to one second of frames", fps: 5)
        for i in 0..<5 { d.exchange(at: Double(i), rtt: 3) }
        d.state(20)
        out.append(d)

        var e = PacerTrace("processing time is subtracted", fps: 30)
        e.sent(at: 0, captured: 0)
        e.acked(at: 0.25, ms: 50)
        e.state(0.25)
        out.append(e)

        var f = PacerTrace("latency is ack minus capture", fps: 30)
        f.sent(at: 0.1, captured: 0)
        f.acked(at: 0.4, ms: 0)
        out.append(f)

        var g = PacerTrace("queueing when rtt rises over 100 ms", fps: 30)
        g.exchange(at: 0, rtt: 0.3)
        g.exchange(at: 1, rtt: 0.45)
        g.state(1.45)
        g.exchange(at: 2, rtt: 0.35)
        g.state(2.35)
        out.append(g)

        var h = PacerTrace("queueing while the oldest unacked waits too long", fps: 30)
        h.exchange(at: -1, rtt: 0.3)
        h.sent(at: 0, captured: 0)
        h.state(0.3)
        h.state(0.5)
        out.append(h)

        var i = PacerTrace("base window is 10 seconds", fps: 30)
        i.exchange(at: 0, rtt: 0.1)
        for s in 5...12 { i.exchange(at: Double(s), rtt: 0.3) }
        i.state(9)
        i.state(11)
        out.append(i)

        var j = PacerTrace("post-outage ack does not become base", fps: 30)
        for s in 0...200 { j.exchange(at: Double(s) * 0.1, rtt: 0.3) }
        j.sent(at: 20, captured: 20)
        j.acked(at: 31, ms: 0)
        j.state(31)
        j.exchange(at: 31, rtt: 0.3)
        j.state(31.3)
        out.append(j)

        var k = PacerTrace("extra ack ignored", fps: 30)
        k.acked(at: 1, ms: 0)
        k.state(1)
        out.append(k)

        var l = PacerTrace("acks match oldest first and reset clears", fps: 30)
        l.sent(at: 0, captured: 0)
        l.sent(at: 1, captured: 1)
        l.state(1)
        l.acked(at: 1.2, ms: 0)
        l.state(1.2)
        l.reset()
        l.state(2)
        out.append(l)

        var m = PacerTrace("sample list capped at 4096", fps: 60)
        for s in 0..<4200 { m.exchange(at: Double(s) * 0.001, rtt: s < 100 ? 0.001 : 0.05) }
        m.state(4.2)
        m.state(30)
        out.append(m)

        // Random traces: sends, acks (processing time up to 300 ms), fps changes and queries.
        for seed in 1...4 {
            var rng = HostRNG(seed: UInt64(100 + seed))
            var r = PacerTrace("random \(seed)", fps: [1, 5, 30, 60][seed - 1])
            var now = 0.0
            for _ in 0..<600 {
                now += Double(rng.int(0...400)) / 1000
                switch rng.int(0...9) {
                case 0...3: r.sent(at: now, captured: now - Double(rng.int(0...200)) / 1000)
                case 4...6: r.acked(at: now, ms: UInt16(rng.int(0...300)))
                case 7: r.state(now)
                case 8: if rng.int(0...20) == 0 { r.reset() } else { r.cap(now) }
                default: if rng.int(0...10) == 0 { r.setFps(rng.int(0...90)) } else { r.queueing(now) }
                }
            }
            r.state(now)
            out.append(r)
        }
        return out
    }

    func testSendPacer() {
        let traces = Self.pacerTraces()
        HostFixture.check("send-pacer.json", HostFixture.cases(traces.map(\.json)))
    }

    // MARK: - WeakTier

    struct TierTrace {
        let name: String
        var t = WeakTier()
        var calls: [[String: Any]] = []
        var outs: [Any] = []

        init(_ name: String) { self.name = name }

        private mutating func record(_ call: [String: Any], _ r: Int?) {
            calls.append(call)
            outs.append(["r": PacingFixtures.opt(r), "level": t.level, "weak": t.weak] as [String: Any])
        }

        mutating func steps(_ s: [Int]) {
            t.steps = s
            record(["op": "steps", "steps": s], nil)
        }

        mutating func pinned(_ on: Bool) {
            t.pinned = on
            record(["op": "pinned", "on": on], nil)
        }

        mutating func observe(_ now: Double, _ queueing: Bool, _ onAck: Bool) {
            let r = t.observe(now: now, queueing: queueing, onAck: onAck)
            record(["op": "observe", "now": now, "queueing": queueing, "on_ack": onAck], r)
        }

        mutating func probe(_ delay: Double) {
            let r = t.probe(firstAckDelay: delay)
            record(["op": "probe", "delay": delay], r)
        }

        mutating func setSteps(_ s: [Int]) {
            let r = t.setSteps(s)
            record(["op": "set_steps", "steps": s], r)
        }

        var json: [String: Any] { ["name": name, "in": ["calls": calls], "out": outs] }
    }

    static func tierTraces() -> [TierTrace] {
        var out = [TierTrace]()

        var a = TierTrace("ladder down every three seconds, up every thirty")
        a.steps([1, 2])
        for (now, q) in [(0.0, true), (2.9, true), (3, true), (5.9, true), (6, true), (20, true),
                         (49.9, false), (50, false), (79.9, false), (80, false), (200, false)] {
            a.observe(now, q, true)
        }
        out.append(a)

        var b = TierTrace("short queueing does not enter")
        for (now, q) in [(0.0, true), (2.9, true), (3.0, false), (4, true), (6.9, true)] { b.observe(now, q, true) }
        out.append(b)

        var c = TierTrace("idle does not go up")
        c.steps([2])
        c.observe(7, true, true)
        c.observe(10, true, true)
        for s in stride(from: 11.0, through: 70.0, by: 1.0) { c.observe(s, false, false) }
        out.append(c)

        var d = TierTrace("pinned goes back to zero and stays")
        d.observe(0, true, true)
        d.observe(3, true, true)
        d.pinned(true)
        for s in 4...14 { d.observe(Double(s), true, true) }
        d.probe(2.0)
        d.pinned(false)
        for s in 15...19 { d.observe(Double(s), true, true) }
        out.append(d)

        var e = TierTrace("slow first slice starts at the last step")
        e.steps([1, 2])
        e.probe(1.01)
        e.probe(3)
        out.append(e)
        var e2 = TierTrace("fast first slice stays")
        e2.probe(0.9)
        e2.probe(1.0)
        out.append(e2)
        var e3 = TierTrace("no steps, no probe")
        e3.steps([])
        e3.probe(3)
        e3.observe(0, true, true)
        e3.observe(5, true, true)
        out.append(e3)

        var f = TierTrace("probe-entered goes up after 30 s without queueing")
        f.steps([2])
        f.probe(1.5)
        f.observe(0, false, true)
        f.observe(29.9, false, true)
        f.observe(30, false, true)
        out.append(f)

        var g = TierTrace("new steps keep the level unless it is gone")
        g.steps([1, 2])
        g.probe(2)
        g.setSteps([1, 2])
        g.setSteps([1])
        out.append(g)
        var g2 = TierTrace("level 1 gone under a slow ceiling")
        g2.observe(0, true, true)
        g2.observe(3, true, true)
        g2.setSteps([2])
        g2.setSteps([])
        out.append(g2)

        for seed in 1...4 {
            var rng = HostRNG(seed: UInt64(200 + seed))
            var r = TierTrace("random \(seed)")
            let stepSets: [[Int]] = [[1, 2], [2], [1], [], [1, 2, 3]]
            var now = 0.0
            for _ in 0..<800 {
                now += Double(rng.int(0...2000)) / 1000
                switch rng.int(0...39) {
                case 0: r.setSteps(stepSets[rng.int(0...4)])
                case 1: r.steps(stepSets[rng.int(0...4)])
                case 2: r.pinned(rng.int(0...1) == 0)
                case 3: r.probe(Double(rng.int(0...3000)) / 1000)
                default:
                    // Long stretches of one state, so both the 3 s and the 30 s rules fire.
                    let q = (Int(now) / 40) % 2 == 0 ? rng.int(0...9) < 8 : rng.int(0...9) == 0
                    r.observe(now, q, rng.int(0...3) != 0)
                }
            }
            out.append(r)
        }
        return out
    }

    func testWeakTier() {
        HostFixture.check("weak-tier.json", HostFixture.cases(Self.tierTraces().map(\.json)))
    }

    // MARK: - SaveLadder

    static func spec(_ s: StreamSpec) -> [String: Any] {
        ["mode": modeName(s.mode), "fps": s.fps, "density": HostFixture.f(s.density)]
    }

    func testSaveLadder() {
        var cases = [[String: Any]]()
        for mode in Mode.allCases {
            for fps in [0, 1, 4, 5, 6, 15, 30, 60] {
                for density: Float in [0.25, 0.5, 0.999, 1, 1.0001, 1.5, 2, 8] {
                    let ceiling = StreamSpec(mode: mode, fps: fps, density: density)
                    let streams = (-1...4).map { level -> [String: Any] in
                        var d = Self.spec(SaveLadder.stream(level: level, ceiling: ceiling))
                        d["level"] = level
                        return d
                    }
                    cases.append(["name": "\(Self.modeName(mode)) \(fps) fps \(density)",
                                  "in": Self.spec(ceiling),
                                  "out": ["steps": SaveLadder.steps(ceiling: ceiling),
                                          "streams": streams] as [String: Any]])
                }
            }
        }
        XCTAssertEqual(SaveLadder.steps(ceiling: StreamSpec(mode: .color16, fps: 30, density: 2)), [1, 2])
        HostFixture.check("save-ladder.json", HostFixture.cases(cases))
    }

    // MARK: - PauseOutbox

    struct OutboxTrace {
        let name: String
        var o = PauseOutbox()
        var calls: [[String: Any]] = []
        var outs: [Any] = []

        init(_ name: String) { self.name = name }

        static func hex(_ m: Message?) -> Any { m.map { HostFixture.hex($0.encoded()) as Any } ?? NSNull() }

        private mutating func record(_ call: [String: Any], _ r: Any) {
            calls.append(call)
            outs.append(["r": r, "paused": o.paused] as [String: Any])
        }

        mutating func pass(_ m: Message, _ now: Double) {
            let r = o.pass(m, now: now)
            record(["op": "pass", "msg": HostFixture.hex(m.encoded()), "now": now], Self.hex(r))
        }

        mutating func due(_ now: Double) {
            let r = o.due(now: now)
            record(["op": "due", "now": now], Self.hex(r))
        }

        mutating func changed(_ now: Double) {
            let r = o.changed(now: now)
            record(["op": "changed", "now": now], Self.hex(r))
        }

        mutating func setPaused(_ on: Bool, _ now: Double) {
            let r = o.setPaused(on, now: now)
            record(["op": "set_paused", "on": on, "now": now], r.map { HostFixture.hex($0.encoded()) })
        }

        var json: [String: Any] { ["name": name, "in": ["calls": calls], "out": outs] }
    }

    static func table(_ id: UInt32) -> Message {
        .windows([WindowInfo(id: id, parent: 0, kind: .normal, resizable: true, focused: true,
                             rect: CanvasRect(x: 0, y: 0, w: 1, h: 1), titleBar: 0, title: "t\(id)")])
    }

    static func outboxTraces() -> [OutboxTrace] {
        let w1 = Message.windows([]), menu = Message.menuBar([])
        let focus = Message.focusRegion(window: 7, rects: [])
        var out = [OutboxTrace]()

        var a = OutboxTrace("streaming passes everything")
        for m in [w1, menu, focus, .pong(1), .clip(id: 1, .unsupported("x"))] { a.pass(m, 0) }
        a.changed(0)
        a.due(100)
        out.append(a)

        var b = OutboxTrace("paused holds menu and focus keeping the newest")
        b.setPaused(true, 0)
        b.pass(menu, 1)
        b.pass(focus, 1)
        b.pass(.focusRegion(window: 9, rects: []), 2)
        b.pass(.pong(3), 2)
        b.pass(.secureFocus(true), 2)
        b.setPaused(false, 3)
        b.setPaused(true, 4)
        b.setPaused(false, 5)
        out.append(b)

        var c = OutboxTrace("paused window table at most every five seconds")
        c.pass(table(1), 0)
        c.setPaused(true, 1)
        c.pass(table(2), 2)
        c.pass(table(3), 4)
        c.due(4.9)
        c.due(5)
        c.due(20)
        c.pass(table(4), 20)
        c.pass(table(5), 21)
        out.append(c)

        var d = OutboxTrace("resume flushes windows, menu, focus in order")
        d.pass(table(1), 0)
        d.setPaused(true, 0)
        d.pass(focus, 1)
        d.pass(table(2), 1)
        d.pass(menu, 2)
        d.setPaused(false, 3)
        d.pass(table(3), 3.5)
        out.append(d)

        var e = OutboxTrace("changed at most once per second, only while paused")
        e.changed(0)
        e.setPaused(true, 0)
        for now in [0, 0.5, 0.99, 1] { e.changed(now) }
        e.setPaused(false, 2)
        e.changed(5)
        out.append(e)

        var f = OutboxTrace("pausing twice keeps what is held")
        f.setPaused(true, 0)
        f.pass(menu, 1)
        f.setPaused(true, 2)
        f.pass(table(8), 2)
        f.setPaused(false, 3)
        f.pass(table(9), 3.1)
        out.append(f)

        for seed in 1...3 {
            var rng = HostRNG(seed: UInt64(300 + seed))
            var r = OutboxTrace("random \(seed)")
            var now = 0.0
            for _ in 0..<500 {
                now += Double(rng.int(0...1500)) / 1000
                switch rng.int(0...11) {
                case 0: r.setPaused(rng.int(0...2) != 0, now)
                case 1, 2: r.pass(table(UInt32(rng.int(1...50))), now)
                case 3: r.pass(.menuBar([MenuItem(title: "m\(rng.int(0...9))")]), now)
                case 4: r.pass(.focusRegion(window: UInt32(rng.int(0...9)),
                                            rects: [CanvasRect(x: 1, y: 2, w: 3, h: Float(rng.int(1...9)))]), now)
                case 5: r.pass(.pong(UInt32(rng.int(0...1000))), now)
                case 6: r.pass(.secureFocus(rng.int(0...1) == 0), now)
                case 7, 8: r.due(now)
                default: r.changed(now)
                }
            }
            out.append(r)
        }
        return out
    }

    func testPauseOutbox() {
        HostFixture.check("pause-outbox.json", HostFixture.cases(Self.outboxTraces().map(\.json)))
    }

    // MARK: - PacedSender

    enum Edit {
        case typed(Int)
        case touch(seed: UInt8, row: Int)
        case corner(Int)

        var json: [String: Any] {
            switch self {
            case let .typed(n): return ["kind": "typed", "n": n]
            case let .touch(seed, row): return ["kind": "touch", "seed": Int(seed), "row": row]
            case let .corner(i): return ["kind": "corner", "i": i]
            }
        }
    }

    /// `PacedSenderTests.scene`: opaque blocky pixels in screen space.
    static func sceneBGRA(x: Int, y: Int, w: Int, h: Int, noiseFrom: Int?) -> [UInt8] {
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
        return bgra
    }

    static func apply(_ e: Edit, _ bgra: inout [UInt8], w: Int, h: Int) {
        switch e {
        case let .typed(n):
            for c in 0..<n {
                for py in (h - 40)..<(h - 24) {
                    for px in (w - 200 + c * 8)..<(w - 194 + c * 8) {
                        let o = (py * w + px) * 4
                        (bgra[o], bgra[o + 1], bgra[o + 2]) = (10, 10, 10)
                    }
                }
            }
        case let .touch(seed, row):
            for py in row..<(row + 16) { for px in 0..<16 { bgra[(py * w + px) * 4] = seed &+ UInt8(px) } }
        case let .corner(i):
            for py in (h - 64)..<h {
                for px in (w - 64)..<w {
                    let o = (py * w + px) * 4
                    bgra[o] = UInt8(truncatingIfNeeded: i * 37 + px)
                    bgra[o + 1] = UInt8(truncatingIfNeeded: i * 11 + py)
                }
            }
        }
    }

    struct Picture {
        var samples: [UInt8]
        var raw: [UInt8]?
        var width: Int
        var height: Int
        var region: CanvasRect
    }

    final class SenderTrace {
        let name: String
        let mode: Mode
        let fps: Int
        var t = 0.0
        var s: PacedSender!
        var calls: [[String: Any]] = []
        var outs: [[String: Any]] = []
        var events: [[String: Any]] = []
        var pictures: [[String: Any]] = []
        var pictureData: [Picture] = []
        var pictureIndex: [String: Int] = [:]
        /// Every frame transmitted, with the time it went out.
        var sent: [(at: Double, payload: FramePayload)] = []
        var levelChanges: [Int] = []

        init(_ name: String, mode: Mode = .gray4, fps: Int = 30) {
            self.name = name
            self.mode = mode
            self.fps = fps
            s = PacedSender(mode: mode, fps: fps, now: { [unowned self] in self.t }) { [unowned self] r, p in
                let bytes = Message.frame(region: r, p).encoded()
                let hex: Any = bytes.count <= 512 ? HostFixture.hex(bytes) : NSNull()
                let frame: [String: Any] = ["len": bytes.count, "fnv": PacingFixtures.fnvHex(bytes), "hex": hex]
                self.events.append(["frame": frame])
                self.sent.append((self.t, p))
            }
            s.onLevelChange = { [unowned self] in
                self.events.append(["level": $0])
                self.levelChanges.append($0)
            }
            s.onEncoded = { [unowned self] r in
                let copy: Any = r.copyBounds.map {
                    [Int($0.minX), Int($0.minY), Int($0.width), Int($0.height)] as Any
                } ?? NSNull()
                let report: [String: Any] = ["region": HostFixture.rect(r.region), "width": r.width,
                                             "height": r.height, "full": r.full, "changed": r.changed,
                                             "copy": copy]
                self.events.append(["encoded": report])
            }
        }

        private func add(_ spec: [String: Any], _ p: Picture) -> Int {
            let key = String(decoding: try! JSONSerialization.data(withJSONObject: spec, options: [.sortedKeys]),
                             as: UTF8.self)
            if let i = pictureIndex[key] { return i }
            var d = spec
            d["samples_fnv"] = PacingFixtures.fnvHex(p.samples)
            d["raw_fnv"] = p.raw.map { PacingFixtures.fnvHex($0) as Any } ?? NSNull()
            pictures.append(d)
            pictureData.append(p)
            pictureIndex[key] = pictures.count - 1
            return pictures.count - 1
        }

        /// `randomSamples`, no raw pixels.
        func random(_ w: Int, _ h: Int, mode: Mode, seed: UInt32,
                    region: CanvasRect = CanvasRect(x: 0, y: 0, w: 1, h: 1)) -> Int {
            let spec: [String: Any] = ["gen": "random", "w": w, "h": h, "mode": PacingFixtures.modeName(mode),
                                       "seed": Int(seed), "region": HostFixture.rect(region)]
            return add(spec, Picture(samples: randomSamples(width: w, height: h, mode: mode, seed: seed), raw: nil,
                                     width: w, height: h, region: region))
        }

        /// `PacedSenderTests.scene`, quantized for duogray, with raw pixels.
        func scene(x: Int, y: Int, w: Int, h: Int, noiseFrom: Int? = nil, region: CanvasRect? = nil,
                   edits: [Edit] = []) -> Int {
            let r = region ?? CanvasRect(x: Float(x), y: Float(y), w: Float(w), h: Float(h))
            let spec: [String: Any] = ["gen": "scene", "x": x, "y": y, "w": w, "h": h,
                                       "noise_from": PacingFixtures.opt(noiseFrom), "region": HostFixture.rect(r),
                                       "quantize": "duogray", "edits": edits.map(\.json)]
            var bgra = PacingFixtures.sceneBGRA(x: x, y: y, w: w, h: h, noiseFrom: noiseFrom)
            for e in edits { PacingFixtures.apply(e, &bgra, w: w, h: h) }
            let q = bgra.withUnsafeBytes {
                Quantizer.quantize(bgra: $0, width: w, height: h, bytesPerRow: w * 4, mode: .duogray)
            }
            return add(spec, Picture(samples: q, raw: bgra, width: w, height: h, region: r))
        }

        /// `PacedSenderTests.page`: a terminal page scrolled in a fixed region.
        func page(_ scroll: Int, typed: Int = 0, w: Int = 1024, h: Int = 768) -> Int {
            scene(x: 100, y: 50 + scroll, w: w, h: h, region: CanvasRect(x: 100, y: 50, w: Float(w), h: Float(h)),
                  edits: typed > 0 ? [.typed(typed)] : [])
        }

        func samples(_ pic: Int) -> [UInt8] { pictureData[pic].samples }

        private func call(_ c: [String: Any], stats: [String: Any]? = nil, _ body: () -> Void) {
            events = []
            body()
            var o: [String: Any] = ["events": events, "level": s.level, "weak": s.weak]
            if let st = stats { o["stats"] = st }
            calls.append(c)
            outs.append(o)
        }

        func offer(_ pic: Int, captured: Double? = nil) {
            let p = pictureData[pic], cap = captured ?? t
            call(["op": "offer", "pic": pic, "captured": cap, "now": t]) {
                s.offer(samples: p.samples, raw: p.raw, width: p.width, height: p.height, region: p.region,
                        captured: cap)
            }
        }

        func ack(_ ms: UInt16 = 0) { call(["op": "ack", "ms": Int(ms), "now": t]) { s.ack(processingMs: ms) } }
        func settle() { call(["op": "settle", "now": t]) { s.settleIfIdle() } }
        func tick() { call(["op": "tick", "now": t]) { s.tick() } }
        func setPaused(_ on: Bool) { call(["op": "set_paused", "on": on, "now": t]) { s.setPaused(on) } }
        func setMode(_ m: Mode) { call(["op": "set_mode", "mode": PacingFixtures.modeName(m)]) { s.setMode(m) } }
        func setFps(_ f: Int) { call(["op": "set_fps", "fps": f]) { s.setFps(f) } }
        func setPinned(_ on: Bool) { call(["op": "set_pinned", "on": on]) { s.setPinned(on) } }
        func setSteps(_ steps: [Int]) { call(["op": "set_steps", "steps": steps]) { s.setSteps(steps) } }

        @discardableResult
        func stats() -> PacedSender.Stats {
            let st = s.takeStats()
            let d: [String: Any] = [
                "rtt_ms": PacingFixtures.opt(st.rttMs), "base_rtt_ms": PacingFixtures.opt(st.baseRttMs),
                "latency_ms": PacingFixtures.opt(st.latencyMs), "in_flight": st.inFlight, "cap": st.cap,
                "weak": st.weak, "level": st.level, "full_frames": st.fullFrames,
                "encode_ms_max": PacingFixtures.opt(st.encodeMsMax),
            ]
            call(["op": "take_stats", "now": t], stats: d) {}
            return st
        }

        /// Acks until nothing more goes out.
        func drain() {
            for _ in 0..<2000 {
                let c = sent.count
                ack()
                if sent.count == c { return }
            }
            XCTFail("\(name): never settled")
        }

        /// `settleIfIdle` (draining after each) until it sends nothing more. Returns the frame count.
        @discardableResult
        func settleAll() -> Int {
            var n = 0
            for _ in 0..<2000 {
                let c = sent.count
                settle()
                if sent.count == c { return n }
                n += sent.count - c
                drain()
            }
            XCTFail("\(name): settle never finished")
            return n
        }

        var json: [String: Any] {
            ["name": name,
             "in": ["mode": PacingFixtures.modeName(mode), "fps": fps, "pictures": pictures,
                    "calls": calls] as [String: Any],
             "out": outs]
        }
    }

    /// Every `PacedSenderTests` scenario, as traces.
    static func senderTestTraces() -> [SenderTrace] {
        var out = [SenderTrace]()
        func small(_ tr: SenderTrace, _ seed: UInt32) -> Int { tr.random(64, 64, mode: .gray4, seed: seed) }

        let a = SenderTrace("onEncoded per encode")
        a.offer(small(a, 1)); a.ack(); a.offer(small(a, 2))
        out.append(a)

        let b = SenderTrace("only cap frames in flight and newest wins")
        b.offer(small(b, 1)); b.offer(small(b, 2)); b.offer(small(b, 3)); b.ack()
        out.append(b)

        let c = SenderTrace("large frame goes out as slices one per slot")
        c.offer(c.random(1920, 1080, mode: .gray4, seed: 9))
        c.offer(small(c, 1))
        for _ in 0..<500 {
            c.ack()
            if c.sent.last?.payload.width == 64 { break }
        }
        XCTAssertGreaterThan(c.sent.count, 3)
        out.append(c)

        let d = SenderTrace("mode change drops queued slices and sends full")
        d.offer(d.random(1920, 1080, mode: .gray4, seed: 9))
        d.setMode(.duogray)
        d.offer(d.random(1920, 1080, mode: .duogray, seed: 4))
        d.ack()
        for _ in 0..<500 {
            let n = d.sent.count
            d.ack()
            if d.sent.count == n { break }
        }
        out.append(d)

        let e = SenderTrace("mode change drops held offer")
        e.offer(small(e, 1)); e.offer(small(e, 2)); e.setMode(.color16); e.ack()
        out.append(e)

        let f = SenderTrace("probe enters weak when first ack slow")
        f.offer(small(f, 1)); f.t += 1.2; f.ack()
        XCTAssertEqual(f.levelChanges, [2])
        out.append(f)

        let g = SenderTrace("outage enters weak via tick")
        g.offer(small(g, 1)); g.ack(); g.t = 0.3; g.offer(small(g, 2)); g.ack(); g.offer(small(g, 3))
        for _ in 0..<4 { g.t += 1; g.tick() }
        XCTAssertEqual(g.levelChanges, [1])
        out.append(g)

        let h = SenderTrace("idle after one slow ack does not enter weak")
        h.offer(small(h, 1)); h.t = 0.01; h.ack(); h.offer(small(h, 2)); h.t = 0.26; h.ack(); h.stats()
        for _ in 0..<5 { h.t += 1; h.tick() }
        out.append(h)

        let i = SenderTrace("pin while weak leaves at once")
        i.offer(small(i, 1)); i.t += 1.2; i.ack(); i.setPinned(true); i.offer(small(i, 2))
        for _ in 0..<10 { i.t += 1; i.tick() }
        XCTAssertEqual(i.levelChanges, [2, 0])
        out.append(i)

        let j = SenderTrace("new steps report a level that is gone")
        j.offer(small(j, 1)); j.ack(); j.t = 0.3; j.offer(small(j, 2)); j.ack(); j.offer(small(j, 3))
        for _ in 0..<4 { j.t += 1; j.tick() }
        j.setSteps([2])
        XCTAssertEqual(j.levelChanges, [1, 0])
        out.append(j)

        let k = SenderTrace("stats report rtt, latency and cap")
        k.offer(small(k, 1), captured: k.t - 0.15); k.t += 0.2; k.ack(); k.stats(); k.stats()
        out.append(k)

        let l = SenderTrace("settle after 300 ms of no divergence", mode: .duogray)
        l.offer(l.scene(x: 100, y: 50, w: 256, h: 128)); l.drain()
        l.offer(l.scene(x: 95, y: 50, w: 261, h: 128)); l.drain()
        l.t += 0.29; l.settle()
        l.t += 0.02
        XCTAssertGreaterThan(l.settleAll(), 0)
        l.t += 1; l.settle()
        out.append(l)

        // Settle waits for the queue and the held offer: the reference run, then the real one.
        let (sw, sh) = (1280, 800)
        let ref = SenderTrace("settle waits for queue and held offer (reference)", mode: .duogray)
        ref.offer(ref.scene(x: 100, y: 50, w: sw, h: sh)); ref.drain()
        let refBefore = ref.sent.count
        ref.offer(ref.scene(x: 95, y: 50, w: sw + 5, h: sh, noiseFrom: sh / 4)); ref.drain()
        let bFrames = ref.sent.count - refBefore
        XCTAssertGreaterThan(bFrames, 2)
        out.append(ref)
        let m = SenderTrace("settle waits for queue and held offer", mode: .duogray)
        m.offer(m.scene(x: 100, y: 50, w: sw, h: sh)); m.drain()
        let before = m.sent.count
        let mb = m.scene(x: 95, y: 50, w: sw + 5, h: sh, noiseFrom: sh / 4)
        m.offer(mb)
        m.t += 0.5
        m.offer(mb)
        m.settle()
        while m.sent.count < before + bFrames {
            let n = m.sent.count
            m.ack()
            if m.sent.count == n { break }
            if m.sent.count < before + bFrames { m.settle() }
        }
        m.drain()
        m.t += 0.31
        XCTAssertGreaterThan(m.settleAll(), 0)
        out.append(m)

        let n = SenderTrace("settle runs while other tiles keep changing", mode: .duogray)
        n.offer(n.scene(x: 100, y: 50, w: 256, h: 128)); n.drain()
        n.offer(n.scene(x: 95, y: 50, w: 261, h: 128)); n.drain()
        var edits = [Edit]()
        for k in 1...6 {
            n.t += 0.1
            edits.append(.corner(k))
            n.offer(n.scene(x: 95, y: 50, w: 261, h: 128, edits: edits)); n.drain()
            n.settleAll()
        }
        out.append(n)

        let o = SenderTrace("no settle during continuous scroll", mode: .duogray)
        let region = CanvasRect(x: 100, y: 50, w: 256, h: 192)
        o.offer(o.scene(x: 100, y: 50, w: 256, h: 192, region: region)); o.drain()
        for k in 1...10 {
            o.t += 0.1
            o.offer(o.scene(x: 100, y: 50 + k * 5, w: 256, h: 192, region: region)); o.drain()
            o.settle()
        }
        o.t += 0.29; o.settle()
        o.t += 0.02
        XCTAssertGreaterThan(o.settleAll(), 0)
        out.append(o)

        for settleOn in [false, true] {
            let p = SenderTrace("settle does not jump a held offer (settle \(settleOn))", mode: .duogray)
            p.offer(p.scene(x: 100, y: 50, w: 256, h: 128)); p.drain()
            p.offer(p.scene(x: 95, y: 50, w: 261, h: 128)); p.drain()
            p.offer(p.scene(x: 95, y: 50, w: 261, h: 128, edits: [.touch(seed: 7, row: 100)]))
            p.offer(p.scene(x: 95, y: 50, w: 261, h: 128,
                            edits: [.touch(seed: 7, row: 100), .touch(seed: 99, row: 100)]))
            p.t += 0.5
            if settleOn { p.settle() }
            p.ack()
            out.append(p)
        }

        let q = SenderTrace("large settle goes out as independent bounded frames", mode: .duogray)
        q.offer(q.page(0)); q.drain(); q.offer(q.page(5)); q.drain()
        q.t += 0.31
        XCTAssertGreaterThan(q.settleAll(), 2)
        q.t += 5; q.settle()
        out.append(q)

        let r = SenderTrace("keystroke goes out between settle frames", mode: .duogray)
        r.offer(r.page(0)); r.drain(); r.offer(r.page(5)); r.drain()
        r.t += 0.31; r.settle()
        r.offer(r.page(5, typed: 3)); r.settle(); r.ack(); r.drain()
        XCTAssertGreaterThan(r.settleAll(), 1)
        out.append(r)

        let s = SenderTrace("settle tick on a full link queues nothing", mode: .duogray)
        s.offer(s.page(0)); s.drain(); s.offer(s.page(5)); s.drain()
        s.t += 0.31; s.settle(); s.settle()
        s.offer(s.page(5, typed: 3)); s.ack(); s.drain()
        XCTAssertGreaterThan(s.settleAll(), 1)
        out.append(s)

        let u = SenderTrace("settle frames are stamped and timed now", mode: .duogray)
        u.offer(u.page(0)); u.drain(); u.offer(u.page(5)); u.drain(); u.stats()
        u.t += 5; u.settle(); u.t += 0.05; u.ack(); u.stats()
        out.append(u)

        let v = SenderTrace("stats count full frames and encode time")
        v.offer(small(v, 1)); v.stats(); v.ack(); v.offer(small(v, 2)); v.stats()
        out.append(v)

        func ackAll(_ tr: SenderTrace) {
            for _ in 0..<1000 {
                let c = tr.sent.count
                tr.ack()
                if tr.sent.count == c { break }
            }
        }

        let w = SenderTrace("paused offers send nothing and resume sends one diff")
        w.offer(small(w, 1)); w.ack(); w.setPaused(true); w.offer(small(w, 2)); w.offer(small(w, 3)); w.tick()
        w.offer(small(w, 4)); w.setPaused(false)
        XCTAssertEqual(w.sent.count, 2)
        XCTAssertFalse(w.sent[1].payload.isFull)
        out.append(w)

        let x = SenderTrace("slices queued before pause still go out")
        x.offer(x.random(1920, 1080, mode: .gray4, seed: 9)); x.setPaused(true); x.offer(small(x, 1)); ackAll(x)
        x.setPaused(false); ackAll(x)
        out.append(x)

        let y = SenderTrace("pause does not change the saving level")
        y.offer(small(y, 1)); y.ack(); y.setPaused(true)
        for _ in 0..<30 { y.t += 1; y.offer(small(y, UInt32(y.t))); y.tick() }
        y.stats()
        out.append(y)

        let z = SenderTrace("no settle while paused", mode: .duogray)
        z.offer(z.page(0)); z.drain(); z.offer(z.page(5)); z.drain(); z.setPaused(true); z.t += 5; z.settle()
        z.setPaused(false); z.settle()
        out.append(z)

        let pm = SenderTrace("paused mode change resumes with full frame")
        pm.offer(small(pm, 1)); pm.ack(); pm.setPaused(true); pm.setMode(.color16)
        pm.offer(pm.random(64, 64, mode: .color16, seed: 7)); pm.setPaused(false)
        out.append(pm)

        return out
    }

    /// Acks every frame sent at least `delay` ago (oldest first), as a link with that delay would.
    static func ackDue(_ tr: SenderTrace, acked: inout Int, delay: Double) {
        while acked < tr.sent.count, tr.sent[acked].at + delay <= tr.t + 1e-9 {
            acked += 1
            tr.ack()
        }
    }

    /// The plan's traces (plan B Task 6 Step 1).
    static func senderPlanTraces() -> [SenderTrace] {
        var out = [SenderTrace]()

        // Steady 30 fps with prompt acks (5 ms), a frame-rate change halfway.
        let a = SenderTrace("steady 30 fps with prompt acks")
        for k in 0..<90 {
            if k == 45 { a.setFps(5) }
            a.offer(a.random(32, 32, mode: .gray4, seed: UInt32(1000 + k)))
            a.t += 0.005
            a.ack()
            a.t += 1.0 / 30 - 0.005
            if k % 30 == 29 { a.tick(); a.stats() }
        }
        out.append(a)

        // No acks for 5 s: the cap holds, only the newest offer is kept.
        let b = SenderTrace("no acks for 5 s")
        b.offer(b.random(32, 32, mode: .gray4, seed: 1)); b.t += 0.01; b.ack()
        for k in 0..<150 {
            b.t += 1.0 / 30
            b.offer(b.random(32, 32, mode: .gray4, seed: UInt32(2 + k)))
            if k % 30 == 29 { b.tick(); b.stats() }
        }
        XCTAssertEqual(b.sent.count, 2, "one frame in flight, the rest held")
        b.ack()
        out.append(b)

        // Acks 400 ms late for 9 s after a prompt start: weak engages, then recovers.
        // `delayed`: also pinned, then unpinned, while the link is slow.
        for pin in [false, true] {
            let c = SenderTrace(pin ? "set pinned under delay" : "acks delayed 400 ms")
            var acked = 0
            var k = 0
            while c.t < 75 {
                let delay = (c.t >= 2 && c.t < 11) ? 0.4 : 0.01
                c.offer(c.random(32, 32, mode: .gray4, seed: UInt32(5000 + k)))
                Self.ackDue(c, acked: &acked, delay: delay)
                c.t += 0.1
                Self.ackDue(c, acked: &acked, delay: delay)
                if k % 10 == 9 { c.tick(); c.stats() }
                if pin, k == 80 { c.setPinned(true) }
                if pin, k == 100 { c.setPinned(false) }
                k += 1
            }
            if !pin {
                XCTAssertTrue(c.levelChanges.contains(1), "the weak tier must engage")
                XCTAssertEqual(c.levelChanges.last, 0, "and recover")
            } else {
                XCTAssertTrue(c.levelChanges.contains(0))
            }
            out.append(c)
        }

        // Pause, offers, resume.
        let d = SenderTrace("pause, offers, resume")
        d.offer(d.random(64, 64, mode: .gray4, seed: 1)); d.t += 0.01; d.ack()
        d.setPaused(true)
        for k in 0..<10 { d.t += 0.1; d.offer(d.random(64, 64, mode: .gray4, seed: UInt32(10 + k))); d.tick() }
        d.setPaused(true)
        d.t += 0.1; d.setPaused(false); d.t += 0.01; d.ack()
        d.setPaused(false)
        out.append(d)

        // setMode mid-stream, with a frame in flight and one held.
        let e = SenderTrace("set mode mid-stream")
        for k in 0..<5 { e.offer(e.random(48, 40, mode: .gray4, seed: UInt32(20 + k))); e.t += 0.02; e.ack() }
        e.offer(e.random(48, 40, mode: .gray4, seed: 30))
        e.offer(e.random(48, 40, mode: .gray4, seed: 31))
        e.setMode(.color8)
        e.offer(e.random(48, 40, mode: .color8, seed: 32))
        e.t += 0.02; e.ack(); e.ack()
        for k in 0..<4 { e.offer(e.random(48, 40, mode: .color8, seed: UInt32(40 + k))); e.t += 0.02; e.ack() }
        // Scene samples are quantized for duogray (one byte per sample), so the mode must be duogray.
        e.setMode(.duogray)
        e.offer(e.scene(x: 0, y: 0, w: 48, h: 40))
        e.t += 0.02; e.ack()
        e.stats()
        out.append(e)

        // Idle 0.3 s, then settle, in a duo mode. The scene generator quantizes for duogray only,
        // so duocolor gets a separate run below with `random` pictures and no raw pixels.
        let f = SenderTrace("idle 0.3 s then settle", mode: .duogray)
        f.offer(f.scene(x: 40, y: 20, w: 200, h: 120)); f.drain()
        f.offer(f.scene(x: 37, y: 20, w: 203, h: 120)); f.drain()
        for _ in 0..<5 { f.t += 0.1; f.settle() }
        f.drain()
        f.settleAll()
        f.stats()
        out.append(f)

        let g = SenderTrace("duocolor without raw pixels never settles", mode: .duocolor)
        g.offer(g.random(80, 64, mode: .duocolor, seed: 3)); g.drain()
        g.offer(g.random(80, 64, mode: .duocolor, seed: 4)); g.drain()
        g.t += 0.5; g.settle()
        out.append(g)
        return out
    }

    func testPacedSender() {
        let traces = Self.senderTestTraces() + Self.senderPlanTraces()
        HostFixture.check("paced-sender.json", HostFixture.cases(traces.map(\.json)))
    }
}
