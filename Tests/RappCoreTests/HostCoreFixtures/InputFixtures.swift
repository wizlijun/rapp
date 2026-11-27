import Foundation
import XCTest
@testable import RappCore

/// Input rules for `rust/host-core/tests/rules_input.rs`. Every case is a trace
/// (`in.fn == "trace"`): `in.steps` are the calls made on one value, tagged by `op`, and
/// `out[i]` is what step i returned (`null` for calls that return nothing).
///
/// - `input-yield.json`: `InputYield`. Steps `yielded {by, now}`, `tick {now}` (out: bool),
///   `admit {msg, now}` (out: `{"decision":"pass","report":…}` or `{"decision":"drop","notify":…}`).
///   `msg.type` names the message; only the case and the key code / mouse kind and button
///   matter to the rules, the other fields are fixed (see `Msg`).
/// - `held-input.json`: `HeldInput`. Steps `press_key`, `release_key {code}`, `press_button`,
///   `release_button {button}`, `drain` (out: `{"keys", "buttons"}`).
/// - `peer-names.json`: `PeerNames`. Steps `set {name, port}` (out: count after it), `name {port}`
///   (out: the name or null).
///
/// Covers every scenario of InputYieldTests, HeldInputTests and PeerNamesTests, plus a right
/// button beside a held left one, a second yield that moves the end and the name, an empty
/// device name, the exact notice and report intervals, and the default branch (ping, frame ack).
final class InputFixtures: XCTestCase {
    private typealias F = HostFixture

    private static func c(_ name: String, _ steps: [[String: Any]], _ outs: [Any]) -> [String: Any] {
        ["name": name, "in": ["fn": "trace", "steps": steps], "out": outs]
    }

    // MARK: - input-yield.json

    /// A message for `admit` and its JSON form. Rust rebuilds the same fixed fields.
    private struct Msg {
        let m: Message
        let json: [String: Any]
    }

    private static func buttonName(_ b: MouseButton) -> String { b == .left ? "left" : "right" }
    private static func kindName(_ k: MouseKind) -> String {
        switch k {
        case .down: return "down"
        case .up: return "up"
        case .drag: return "drag"
        case .move: return "move"
        }
    }

    private static let text = Msg(m: .text("a"), json: ["type": "text"])
    private static func k(_ code: UInt16, _ down: Bool, _ modifiers: UInt64 = 0) -> Msg {
        Msg(m: .key(keyCode: code, modifiers: modifiers, down: down),
            json: ["type": "key", "code": Int(code), "modifiers": modifiers, "down": down])
    }
    private static func m(_ kind: MouseKind, _ button: MouseButton = .left) -> Msg {
        Msg(m: .mouse(kind: kind, button: button, window: 1, x: 0, y: 0, clickCount: 1),
            json: ["type": "mouse", "kind": kindName(kind), "button": buttonName(button)])
    }
    private static let scroll = Msg(m: .scroll(window: 1, x: 0, y: 0, dx: 0, dy: 1), json: ["type": "scroll"])
    private static let paste = Msg(m: .paste(seq: 1, .text("a")), json: ["type": "paste"])
    private static let menuPick = Msg(m: .menuPick([0]), json: ["type": "menu_pick"])
    private static let focus = Msg(m: .focus(1), json: ["type": "focus"])
    private static let selectInput = Msg(m: .selectInput(id: ""), json: ["type": "select_input"])
    private static let resize = Msg(m: .resize(window: 1, width: 10, height: 10), json: ["type": "resize"])
    private static let move = Msg(m: .move(window: 1, x: 0, y: 0), json: ["type": "move"])
    private static let close = Msg(m: .close(1), json: ["type": "close"])
    private static let setStream = Msg(m: .setStream(mode: .gray4, fps: 5, density: 1, pinned: false),
                                       json: ["type": "set_stream"])
    private static let ping = Msg(m: .ping(1), json: ["type": "ping"])
    private static let frameAck = Msg(m: .frameAck(processingMs: 3), json: ["type": "frame_ack"])

    private static func decision(_ d: YieldDecision) -> [String: Any] {
        switch d {
        case let .pass(report): return ["decision": "pass", "report": report]
        case let .drop(notify): return ["decision": "drop", "notify": F.opt(notify)]
        }
    }

    private final class YieldTrace {
        var y = InputYield()
        var steps: [[String: Any]] = []
        var outs: [Any] = []

        func yielded(_ by: String, _ now: Double) {
            y.yielded(to: by, at: now)
            steps.append(["op": "yielded", "by": by, "now": now])
            outs.append(NSNull())
        }
        @discardableResult func tick(_ now: Double) -> Bool {
            let r = y.tick(at: now)
            steps.append(["op": "tick", "now": now])
            outs.append(r)
            return r
        }
        @discardableResult func admit(_ msg: Msg, _ now: Double) -> YieldDecision {
            let r = y.admit(msg.m, at: now)
            steps.append(["op": "admit", "msg": msg.json, "now": now])
            outs.append(InputFixtures.decision(r))
            return r
        }
    }

    func testInputYield() {
        var cases: [[String: Any]] = []
        func trace(_ name: String, _ body: (YieldTrace) -> Void) {
            let t = YieldTrace()
            body(t)
            cases.append(Self.c(name, t.steps, t.outs))
        }
        let t = Self.text, k = Self.k, m = Self.m

        trace("own input passes and reports at most every quarter second") { y in
            y.admit(t, 0); y.admit(t, 0.1); y.admit(t, 0.3)
        }
        trace("steady input reports every quarter second and the trailing one") { y in
            y.admit(t, 0); y.admit(t, 0.1)
            y.tick(0.2); y.tick(0.25); y.tick(0.5)
        }
        trace("input within one second of a yield is dropped then passes") { y in
            y.yielded("Mac mini", 10)
            y.admit(t, 10.2); y.admit(t, 10.4); y.admit(t, 10.8); y.admit(t, 11.0)
        }
        trace("hover is blocked but never reported") { y in
            y.admit(m(.move, .left), 0)
            y.yielded("x", 1)
            y.admit(m(.move, .left), 1.1)
        }
        trace("release of an admitted press passes while blocked") { y in
            y.admit(k(56, true, 0), 0); y.admit(m(.down, .left), 0)
            y.yielded("x", 0.5)
            y.admit(k(56, false, 0), 0.6); y.admit(m(.up, .left), 0.9)
        }
        trace("drag of an admitted button is never blocked") { y in
            y.admit(m(.down, .left), 0)
            y.yielded("x", 0.1)
            y.admit(m(.drag, .left), 0.2); y.admit(m(.drag, .left), 0.3)
        }
        trace("drag and up of a blocked press are dropped") { y in
            y.yielded("x", 0)
            y.admit(m(.down, .left), 0.1); y.admit(m(.drag, .left), 1.5)
            y.admit(m(.up, .left), 1.6); y.admit(m(.down, .left), 1.7)
        }
        trace("stray release is dropped only while blocked") { y in
            y.admit(k(0, false, 0), 0)
            y.yielded("x", 1)
            y.admit(k(0, false, 0), 1.1)
        }
        trace("window commands are never blocked") { y in
            y.yielded("x", 0)
            for msg in [Self.resize, Self.move, Self.close, Self.setStream] { y.admit(msg, 0.1) }
        }
        trace("paste, menu pick, focus, scroll and select input are input") { y in
            y.yielded("x", 0)
            for msg in [Self.paste, Self.menuPick, Self.focus, Self.scroll, Self.selectInput] { y.admit(msg, 0.1) }
        }
        trace("released key is forgotten so the next press is judged fresh") { y in
            y.admit(k(5, true, 0), 0); y.admit(k(5, false, 0), 0.1)
            y.yielded("x", 0.2)
            y.admit(k(5, true, 0), 0.3)
        }
        trace("up of a blocked key press is dropped then a fresh press passes") { y in
            y.yielded("x", 0)
            y.admit(k(7, true, 0), 0.1); y.admit(k(7, false, 0), 1.5); y.admit(k(7, true, 0), 1.6)
        }
        trace("repeat down of a held key passes while blocked") { y in
            y.admit(k(7, true, 0), 0)
            y.yielded("x", 0.1)
            y.admit(k(7, true, 0), 0.5)
        }
        trace("drag with no recorded down follows the block state") { y in
            y.admit(m(.drag, .left), 0)
            y.yielded("x", 1)
            y.admit(m(.drag, .left), 1.1)
        }

        // Extras.
        trace("right button is judged apart from a held left one") { y in
            y.admit(m(.down, .left), 0)
            y.yielded("x", 0.1)
            y.admit(m(.down, .right), 0.2); y.admit(m(.drag, .left), 0.3); y.admit(m(.drag, .right), 0.4)
            y.admit(m(.up, .right), 0.5); y.admit(m(.up, .left), 0.6); y.admit(m(.down, .right), 1.2)
        }
        trace("a second yield moves the end and the name") { y in
            y.yielded("a", 0); y.admit(t, 0.1)
            y.yielded("b", 0.7); y.admit(t, 0.8); y.admit(t, 1.5); y.admit(t, 1.7)
        }
        trace("an empty device name is told as given") { y in
            y.yielded("", 0); y.admit(t, 0.1)
        }
        trace("notice exactly half a second later is told again") { y in
            y.yielded("x", 0); y.admit(t, 0.25); y.admit(t, 0.75); y.admit(t, 0.99)
        }
        trace("report exactly a quarter second later is due") { y in
            y.admit(t, 1); y.admit(t, 1.25); y.admit(t, 1.3); y.tick(1.5); y.tick(1.5)
        }
        trace("tick with nothing owed") { y in
            y.tick(0); y.tick(100)
        }
        trace("modifiers do not change a key's judgement") { y in
            y.admit(k(9, true, 0x100000), 0)
            y.yielded("x", 0.1)
            y.admit(k(9, true, 0), 0.2); y.admit(k(9, false, 0x20000), 0.3)
        }
        trace("other messages pass unreported while blocked") { y in
            y.yielded("x", 0)
            y.admit(Self.ping, 0.1); y.admit(Self.frameAck, 0.2)
        }
        trace("blocked input does not report and leaves no debt") { y in
            y.yielded("x", 0); y.admit(t, 0.1); y.tick(0.6); y.admit(t, 1.1); y.tick(1.2)
        }

        F.check("input-yield.json", F.cases(cases))
    }

    // MARK: - held-input.json

    private final class HeldTrace {
        var h = HeldInput()
        var steps: [[String: Any]] = []
        var outs: [Any] = []

        func pressKey(_ code: UInt16) { h.pressKey(code); steps.append(["op": "press_key", "code": Int(code)]); outs.append(NSNull()) }
        func releaseKey(_ code: UInt16) { h.releaseKey(code); steps.append(["op": "release_key", "code": Int(code)]); outs.append(NSNull()) }
        func pressButton(_ b: MouseButton) {
            h.pressButton(b); steps.append(["op": "press_button", "button": InputFixtures.buttonName(b)]); outs.append(NSNull())
        }
        func releaseButton(_ b: MouseButton) {
            h.releaseButton(b); steps.append(["op": "release_button", "button": InputFixtures.buttonName(b)]); outs.append(NSNull())
        }
        func drain() {
            let (keys, buttons) = h.drain()
            steps.append(["op": "drain"])
            outs.append(["keys": keys.map { Int($0) }, "buttons": buttons.map(InputFixtures.buttonName)])
        }
    }

    func testHeldInput() {
        var cases: [[String: Any]] = []
        func trace(_ name: String, _ body: (HeldTrace) -> Void) {
            let t = HeldTrace()
            body(t)
            cases.append(Self.c(name, t.steps, t.outs))
        }
        trace("pairs leave nothing held") { h in
            h.pressKey(55); h.releaseKey(55); h.pressButton(.left); h.releaseButton(.left); h.drain()
        }
        trace("held key and button come back once") { h in
            h.pressKey(55); h.pressButton(.right); h.drain(); h.drain()
        }
        trace("repeated down counts once") { h in
            h.pressKey(0); h.pressKey(0); h.pressKey(0); h.drain(); h.pressKey(0); h.releaseKey(0); h.drain()
        }
        trace("drain is sorted and complete") { h in
            h.pressKey(55); h.pressKey(3); h.pressKey(12); h.drain()
        }
        trace("dropped button is not tracked") { h in
            h.releaseButton(.left); h.drain()
        }
        // Extras.
        trace("both buttons come back left first") { h in
            h.pressButton(.right); h.pressButton(.left); h.pressKey(65535); h.pressKey(1); h.drain()
        }
        trace("release of a key never pressed") { h in
            h.releaseKey(9); h.pressKey(10); h.releaseKey(9); h.drain()
        }
        F.check("held-input.json", F.cases(cases))
    }

    // MARK: - peer-names.json

    private final class PeerTrace {
        var p = PeerNames()
        var steps: [[String: Any]] = []
        var outs: [Any] = []

        func set(_ name: String, _ port: UInt16) {
            p.set(name, for: port)
            steps.append(["op": "set", "name": name, "port": Int(port)])
            outs.append(p.count)
        }
        func name(_ port: UInt16) {
            steps.append(["op": "name", "port": Int(port)])
            outs.append(F.opt(p[port]))
        }
    }

    func testPeerNames() {
        var cases: [[String: Any]] = []
        func trace(_ name: String, _ body: (PeerTrace) -> Void) {
            let t = PeerTrace()
            body(t)
            cases.append(Self.c(name, t.steps, t.outs))
        }
        trace("announced name is found by port") { p in
            p.set("Mac mini", 50001); p.name(50001); p.name(50002)
        }
        trace("a later name for the port replaces the earlier one") { p in
            p.set("a", 1); p.set("b", 1); p.name(1)
        }
        trace("only the newest sixteen are kept") { p in
            for port in 1...17 { p.set("n\(port)", UInt16(port)) }
            p.name(1); p.name(2); p.name(17)
        }
        trace("renaming a port makes it the newest") { p in
            for port in 1...16 { p.set("n\(port)", UInt16(port)) }
            p.set("again", 1); p.set("n17", 17); p.name(1); p.name(2)
        }
        trace("an empty name is kept as given") { p in
            p.set("", 9); p.name(9)
        }
        // Extras.
        trace("port zero and the top port, Chinese name") { p in
            p.set("客厅的 Mac", 0); p.set("x", 65535); p.name(0); p.name(65535)
        }
        trace("eighteen names drop the two oldest") { p in
            for port in 1...18 { p.set("n\(port)", UInt16(port)) }
            p.name(1); p.name(2); p.name(3); p.name(18)
        }
        F.check("peer-names.json", F.cases(cases))
    }
}
