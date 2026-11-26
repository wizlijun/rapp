import CoreGraphics
import Foundation
import XCTest
@testable import RappCore

/// Focus pane, focus tracker and query rules for `rust/host-core/tests/rules_focus.rs`.
///
/// - `focus-pane.json`: one case per call; `in.fn` is `panel`, `window_rect` or `window_tiles`.
/// - `focus-tracker.json`: every case is a trace (`in.fn == "trace"`). `in.steps` are the calls
///   made on one `FocusTracker`, tagged by `op`; `out[i]` is what step i returned (`actions`)
///   plus the tracker's public state right after it (`state`). Setup calls are steps too, so
///   Rust replays exactly what Swift ran.
/// - `query.json`: coalescer traces (`fn == "coalescer"`), deadlines and `Query.kind`.
///
/// Covers every scenario of FocusPaneTests, FocusTrackerTests, QueryCoalescerTests and
/// QueryDeadlineTests, plus the plan's extras (41-level chain, 15 % / 85 % shares and just
/// outside, 239x160 and 240x159, four candidate rects, a stale generation after a newer query).
final class FocusFixtures: XCTestCase {
    private typealias F = HostFixture
    fileprivate typealias T = FocusTracker

    // MARK: - JSON shapes

    fileprivate static func pt(_ p: CGPoint) -> [String: Any] { ["x": Double(p.x), "y": Double(p.y)] }
    fileprivate static func sz(_ s: CGSize) -> [String: Any] { ["width": Double(s.width), "height": Double(s.height)] }
    fileprivate static func cg(_ r: CGRect) -> [String: Any] {
        F.rect(x: Double(r.origin.x), y: Double(r.origin.y), width: Double(r.size.width), height: Double(r.size.height))
    }
    fileprivate static func pick(_ p: PanelPick) -> [String: Any] {
        ["rect": cg(p.rect), "depth": p.depth, "share": p.share]
    }
    fileprivate static func result(_ r: Result<PanelPick, PanelMiss>) -> [String: Any] {
        switch r {
        case .success(let p): return ["pick": pick(p), "miss": NSNull()]
        case .failure(let m): return ["pick": NSNull(), "miss": m.rawValue]
        }
    }
    fileprivate static func query(_ q: T.Query) -> [String: Any] {
        switch q {
        case .keyboard: return ["kind": "keyboard", "at": NSNull()]
        case .pointer(let p): return ["kind": "pointer", "at": pt(p)]
        case .follow(let p): return ["kind": "follow", "at": pt(p)]
        }
    }
    fileprivate static func action(_ a: T.Action) -> [String: Any] {
        switch a {
        case .query(let q, let g): return ["op": "query", "query": query(q), "generation": g]
        case .send(let o):
            return ["op": "send", "window": Int(o.window), "rects": o.rects.map(cg), "cause": o.cause.rawValue]
        }
    }
    fileprivate static func state(_ t: T) -> [String: Any] {
        ["generation": t.generation,
         "keyboard_panel": F.opt(t.keyboardPanel.map(cg)),
         "keyboard_miss": F.opt(t.keyboardMiss?.rawValue),
         "pointer_panel": F.opt(t.pointerPanel.map(cg)),
         "pointer_miss": F.opt(t.pointerMiss?.rawValue),
         "follow_panel": F.opt(t.followPanel.map(cg))]
    }
    fileprivate static func tiles(_ w: WindowTiles) -> [String: Any] {
        ["changed": w.changed.map(cg), "total": w.total, "copy_bounds": F.opt(w.copyBounds.map(cg)), "full": w.full]
    }
    private static func kindName(_ k: QueryKind) -> String {
        switch k {
        case .keyboard: return "keyboard"
        case .pointer: return "pointer"
        case .follow: return "follow"
        }
    }

    private static func c(_ name: String, _ input: [String: Any], _ out: Any) -> [String: Any] {
        ["name": name, "in": input, "out": out]
    }

    // MARK: - focus-pane.json

    func testFocusPane() {
        var cases: [[String: Any]] = []
        let win = CGSize(width: 1000, height: 800)
        func r(_ w: CGFloat, _ h: CGFloat) -> CGRect { CGRect(x: 0, y: 0, width: w, height: h) }
        func panel(_ name: String, _ chain: [CGRect], _ window: CGSize) {
            cases.append(Self.c(name, ["fn": "panel", "chain": chain.map(Self.cg), "window": Self.sz(window)],
                                Self.result(FocusPane.panel(chain: chain, window: window))))
        }
        // FocusPaneTests
        panel("largest under max", [r(100, 50), r(600, 800), r(1000, 800)], win)
        panel("all small", [r(100, 50), r(200, 100)], win)
        panel("empty chain", [], win)
        panel("only huge", [r(950, 800), r(1000, 800)], win)
        panel("tall container intersected first", [CGRect(x: 0, y: -2000, width: 600, height: 5000)], win)
        panel("tie takes outer", [r(600, 800), r(600, 800)], win)
        panel("min width", [r(230, 800)], win)
        panel("min height", [r(1000, 150)], win)
        var deep = [CGRect](repeating: r(10, 10), count: 40)
        deep.append(r(600, 800))
        panel("depth capped at 40 (41 levels)", deep, win)
        // Extras
        var deep39 = [CGRect](repeating: r(10, 10), count: 39)
        deep39.append(r(600, 800))
        deep39.append(r(700, 800))
        panel("41 levels, the 40th counts", deep39, win)
        panel("share exactly 15%", [r(240, 500)], win)
        panel("share just under 15%", [r(240, 499)], win)
        panel("share just over 15%", [r(240, 501)], win)
        panel("share exactly 85%", [r(850, 800)], win)
        panel("share just under 85%", [r(849, 800)], win)
        panel("share just over 85%", [r(851, 800)], win)
        let small = CGSize(width: 500, height: 400)
        panel("240x160 in 500x400", [r(240, 160)], small)
        panel("239x160 in 500x400", [r(239, 160)], small)
        panel("240x159 in 500x400", [r(240, 159)], small)
        panel("four candidates", [r(250, 200), r(400, 300), CGRect(x: 100, y: 100, width: 500, height: 600),
                                  r(900, 800)], win)
        panel("four candidates, later larger huge", [r(300, 300), r(500, 500), r(860, 800), r(1000, 800)], win)
        panel("disjoint layer", [CGRect(x: 2000, y: 0, width: 300, height: 300), r(400, 400)], win)
        panel("only disjoint", [CGRect(x: 2000, y: 0, width: 300, height: 300)], win)
        panel("touching edge", [CGRect(x: 1000, y: 0, width: 300, height: 800)], win)
        panel("zero window", [r(300, 300)], CGSize(width: 0, height: 800))
        panel("negative origin", [CGRect(x: -100, y: -50, width: 500, height: 600)], win)
        panel("fractional", [CGRect(x: 0.5, y: 0.25, width: 400.3, height: 700.7)], win)

        func windowRect(_ name: String, _ g: CGRect, _ d: CGRect, _ w: CanvasRect) {
            cases.append(Self.c(name, ["fn": "window_rect", "global": Self.cg(g), "display": Self.cg(d),
                                       "window": F.rect(w)],
                                Self.cg(FocusPane.windowRect(global: g, display: d, window: w))))
        }
        windowRect("window rect", CGRect(x: 110, y: 85, width: 10, height: 10),
                   CGRect(x: 0, y: 25, width: 1440, height: 875), CanvasRect(x: 100, y: 50, w: 400, h: 300))
        windowRect("window rect second display", CGRect(x: -1800, y: 120, width: 300, height: 40),
                   CGRect(x: -1920, y: 0, width: 1920, height: 1080), CanvasRect(x: 20.5, y: 30.25, w: 800, h: 600))

        func windowTiles(_ name: String, _ rep: EncodeReport, _ w: CanvasRect) {
            let input: [String: Any] = [
                "fn": "window_tiles",
                "report": ["region": F.rect(rep.region), "width": rep.width, "height": rep.height, "full": rep.full,
                           "changed": rep.changed, "copy_bounds": F.opt(rep.copyBounds.map(Self.cg))] as [String: Any],
                "window": F.rect(w),
            ]
            cases.append(Self.c(name, input, Self.tiles(FocusPane.windowTiles(rep, window: w))))
        }
        windowTiles("retina", EncodeReport(region: CanvasRect(x: 0, y: 0, w: 800, h: 600), width: 1600, height: 1200,
                                           full: false, changed: [0, 24, 25 * 5 + 20],
                                           copyBounds: CGRect(x: 0, y: 0, width: 2000, height: 128)),
                    CanvasRect(x: 0, y: 0, w: 400, h: 300))
        windowTiles("copy bounds outside", EncodeReport(region: CanvasRect(x: 0, y: 0, w: 100, h: 100), width: 100,
                                                        height: 100, full: true, changed: [],
                                                        copyBounds: CGRect(x: 90, y: 90, width: 10, height: 10)),
                    CanvasRect(x: 0, y: 0, w: 50, h: 50))
        windowTiles("zero width", EncodeReport(region: CanvasRect(x: 0, y: 0, w: 100, h: 100), width: 0, height: 100,
                                               full: true, changed: [0], copyBounds: nil),
                    CanvasRect(x: 0, y: 0, w: 50, h: 50))
        windowTiles("zero region", EncodeReport(region: CanvasRect(x: 0, y: 0, w: 0, h: 100), width: 100, height: 100,
                                                full: false, changed: [0], copyBounds: nil),
                    CanvasRect(x: 0, y: 0, w: 50, h: 50))
        windowTiles("edge tiles, offset window, index past end",
                    EncodeReport(region: CanvasRect(x: 16, y: 24, w: 500, h: 300), width: 1000, height: 600, full: false,
                                 changed: [0, 1, 15, 16, 17, 40, 159, 160, 1000],
                                 copyBounds: CGRect(x: 960, y: 500, width: 40, height: 100)),
                    CanvasRect(x: 40, y: 64, w: 300, h: 200))
        windowTiles("scale 1, window larger than region",
                    EncodeReport(region: CanvasRect(x: 100, y: 100, w: 130, h: 70), width: 130, height: 70, full: false,
                                 changed: [0, 1, 2, 3, 4, 5],
                                 copyBounds: CGRect(x: 0, y: 0, width: 130, height: 70)),
                    CanvasRect(x: 0, y: 0, w: 1000, h: 800))
        windowTiles("copy bounds touching", EncodeReport(region: CanvasRect(x: 0, y: 0, w: 100, h: 100), width: 100,
                                                         height: 100, full: false, changed: [],
                                                         copyBounds: CGRect(x: 50, y: 0, width: 10, height: 10)),
                    CanvasRect(x: 0, y: 0, w: 50, h: 50))
        F.check("focus-pane.json", F.cases(cases))
    }

    // MARK: - focus-tracker.json

    fileprivate final class Trace {
        let t = T()
        var steps: [[String: Any]] = []
        var outs: [[String: Any]] = []
        var generation: Int { t.generation }

        @discardableResult
        private func rec(_ step: [String: Any], _ a: [T.Action]) -> [T.Action] {
            steps.append(step)
            outs.append(["actions": a.map(FocusFixtures.action), "state": FocusFixtures.state(t)])
            return a
        }
        @discardableResult func start(_ now: Double) -> [T.Action] {
            rec(["op": "start", "now": now], t.start(now: now))
        }
        @discardableResult func window(_ id: UInt32?, _ size: CGSize, appeared: Double?, now: Double) -> [T.Action] {
            rec(["op": "window", "id": F.opt(id.map { Int($0) }), "size": FocusFixtures.sz(size),
                 "appeared": F.opt(appeared), "now": now],
                t.window(id: id, size: size, appeared: appeared, now: now))
        }
        @discardableResult func locked(_ on: Bool, now: Double) -> [T.Action] {
            rec(["op": "locked", "on": on, "now": now], t.locked(on, now: now))
        }
        @discardableResult func pointer(_ kind: T.Pointer, _ p: CGPoint, now: Double) -> [T.Action] {
            let name: String
            switch kind {
            case .click: name = "click"
            case .drag: name = "drag"
            case .scroll: name = "scroll"
            case .move: name = "move"
            }
            return rec(["op": "pointer", "kind": name, "at": FocusFixtures.pt(p), "now": now],
                       t.pointer(kind, at: p, now: now))
        }
        @discardableResult func key(now: Double) -> [T.Action] {
            rec(["op": "key", "now": now], t.key(now: now))
        }
        @discardableResult func keyboardChanged(now: Double) -> [T.Action] {
            rec(["op": "keyboard_changed", "now": now], t.keyboardChanged(now: now))
        }
        @discardableResult
        func result(_ q: T.Query, _ generation: Int, _ r: Result<PanelPick, PanelMiss>, now: Double) -> [T.Action] {
            var step: [String: Any] = ["op": "result", "query": FocusFixtures.query(q), "generation": generation,
                                       "now": now]
            for (k, v) in FocusFixtures.result(r) { step[k] = v }
            return rec(step, t.result(q, generation: generation, r, now: now))
        }
        @discardableResult func keyboard(_ r: Result<PanelPick, PanelMiss>, now: Double) -> [T.Action] {
            result(.keyboard, t.generation, r, now: now)
        }
        @discardableResult func frame(_ w: WindowTiles, now: Double) -> [T.Action] {
            rec(["op": "frame", "tiles": FocusFixtures.tiles(w), "now": now], t.frame(w, now: now))
        }
        @discardableResult func tick(now: Double) -> [T.Action] {
            rec(["op": "tick", "now": now], t.tick(now: now))
        }
    }

    func testFocusTracker() {
        var cases: [[String: Any]] = []
        let win = CGSize(width: 1000, height: 800)
        let left = CGRect(x: 0, y: 0, width: 400, height: 800)
        let right = CGRect(x: 500, y: 0, width: 500, height: 800)
        let sidebar = CGRect(x: 0, y: 0, width: 300, height: 800)
        let editor = CGRect(x: 400, y: 0, width: 400, height: 800)
        func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }
        func pick(_ r: CGRect) -> Result<PanelPick, PanelMiss> { .success(PanelPick(rect: r, depth: 1, share: 0.5)) }
        func tiles(cols: ClosedRange<Int>, rows: ClosedRange<Int>) -> [CGRect] {
            rows.flatMap { y in cols.map { x in CGRect(x: x * 100, y: y * 100, width: 100, height: 100) } }
        }
        func frame(_ changed: [CGRect], copy: CGRect? = nil, full: Bool = false) -> WindowTiles {
            WindowTiles(changed: changed, total: 80, copyBounds: copy, full: full)
        }
        func started(_ tr: Trace, size: CGSize? = nil, appeared: Double? = -10) {
            tr.window(1, size ?? win, appeared: appeared, now: 0)
            tr.start(0)
        }
        func trace(_ name: String, _ body: (Trace) -> Void) {
            let tr = Trace()
            body(tr)
            cases.append(Self.c(name, ["fn": "trace", "steps": tr.steps], tr.outs))
        }
        func clicked(_ t: Trace) {
            started(t)
            t.keyboard(pick(left), now: 0.5)
            t.pointer(.click, P(100, 100), now: 1)
            t.result(.pointer(P(100, 100)), t.generation, pick(left), now: 1)
        }
        func hoveredSidebar(_ t: Trace) {
            started(t)
            t.keyboard(pick(editor), now: 0.5)
            t.pointer(.move, P(100, 100), now: 1)
            t.tick(now: 1.5)
            t.result(.pointer(P(100, 100)), t.generation, pick(sidebar), now: 1.6)
        }

        // MARK: start, windows, whole-window cases (rule 7)
        trace("start queries keyboard and sends whole") { t in
            t.window(1, win, appeared: -10, now: 0)
            t.start(0)
        }
        trace("click queries at once") { t in
            started(t)
            t.pointer(.click, P(700, 400), now: 1)
            t.tick(now: 1.1); t.tick(now: 1.2); t.tick(now: 1.3)
            t.result(.pointer(P(700, 400)), t.generation, pick(right), now: 1.3)
        }
        trace("move across does not query") { t in
            started(t)
            for i in 0...10 {
                let now = 1 + Double(i) * 0.1
                t.pointer(.move, P(CGFloat(Double(i) * 95), 400), now: now)
                t.tick(now: now + 0.05)
            }
            t.tick(now: 2.3)
        }
        trace("hover after half a second once") { t in
            started(t)
            t.pointer(.move, P(700, 400), now: 1)
            t.tick(now: 1.4); t.tick(now: 1.5); t.tick(now: 1.6); t.tick(now: 3)
            t.result(.pointer(P(700, 400)), t.generation, pick(right), now: 3)
        }
        trace("no query inside current pointer panel") { t in
            started(t)
            t.pointer(.click, P(700, 400), now: 1)
            t.result(.pointer(P(700, 400)), t.generation, pick(right), now: 1)
            t.tick(now: 1.2)
            t.pointer(.click, P(800, 100), now: 2)
            t.pointer(.scroll, P(600, 600), now: 2.1)
            t.pointer(.drag, P(610, 600), now: 2.15)
            t.tick(now: 2.3)
            t.pointer(.move, P(900, 700), now: 3)
            t.tick(now: 3.6)
            t.pointer(.click, P(100, 100), now: 4)
        }
        trace("pointer miss keeps panel") { t in
            started(t)
            t.result(.pointer(P(700, 400)), t.generation, pick(right), now: 1)
            t.result(.pointer(P(100, 100)), t.generation, .failure(.small), now: 2)
        }
        trace("empty keyboard uses pointer only") { t in
            started(t)
            t.keyboard(.failure(.small), now: 0.5)
            t.pointer(.click, P(700, 400), now: 1)
            t.result(.pointer(P(700, 400)), t.generation, pick(right), now: 1)
        }
        trace("keyboard miss clears panel") { t in
            started(t)
            t.keyboard(pick(left), now: 1)
            t.keyboardChanged(now: 2)
            t.keyboard(.failure(.large), now: 2)
        }
        trace("union over 85% is whole") { t in
            started(t)
            t.keyboard(pick(CGRect(x: 0, y: 0, width: 600, height: 800)), now: 1)
            t.pointer(.click, P(900, 400), now: 2)
            t.result(.pointer(P(900, 400)), t.generation, pick(right), now: 2)
        }
        trace("contained rect dropped") { t in
            started(t)
            t.keyboard(pick(right), now: 1)
            t.pointer(.click, P(200, 100), now: 2)
            t.result(.pointer(P(200, 100)), t.generation, pick(CGRect(x: 600, y: 100, width: 300, height: 300)), now: 2)
        }
        trace("equal rects keep one") { t in
            started(t)
            t.keyboard(pick(left), now: 1)
            t.pointer(.click, P(450, 100), now: 2)
            t.result(.pointer(P(450, 100)), t.generation, pick(left), now: 2)
        }
        trace("two panels sent") { t in
            started(t)
            t.keyboard(pick(left), now: 1)
            t.pointer(.click, P(500, 100), now: 2)
            t.result(.pointer(P(500, 100)), t.generation, pick(CGRect(x: 400, y: 0, width: 300, height: 400)), now: 2)
        }
        trace("small window whole") { t in
            t.window(1, CGSize(width: 479, height: 800), appeared: -10, now: 0)
            t.start(0)
            t.keyboard(pick(CGRect(x: 0, y: 0, width: 300, height: 800)), now: 1)
            t.tick(now: 2)
        }
        trace("short window whole") { t in
            started(t, size: CGSize(width: 1000, height: 319))
            t.keyboard(pick(CGRect(x: 0, y: 0, width: 400, height: 319)), now: 1)
        }
        trace("480x320 window is not small") { t in
            started(t, size: CGSize(width: 480, height: 320))
            t.keyboard(pick(CGRect(x: 0, y: 0, width: 240, height: 320)), now: 1)
        }
        trace("first two seconds whole") { t in
            t.window(1, win, appeared: 0, now: 0)
            t.start(0)
            t.keyboard(pick(left), now: 0.5)
            t.tick(now: 1.9); t.tick(now: 2.0); t.tick(now: 2.1)
        }
        trace("no appeared time") { t in
            started(t, appeared: nil)
            t.keyboard(pick(left), now: 0.5)
        }
        trace("locked whole") { t in
            started(t)
            t.keyboard(pick(left), now: 1)
            t.locked(true, now: 2)
            t.locked(false, now: 3)
        }
        trace("locked before start") { t in
            t.window(1, win, appeared: -10, now: 0)
            t.locked(true, now: 0)
            t.start(0)
            t.keyboard(pick(left), now: 1)
        }
        trace("no window whole") { t in
            started(t)
            t.keyboard(pick(left), now: 1)
            t.window(nil, .zero, appeared: nil, now: 2)
            t.pointer(.click, P(10, 10), now: 3)
            t.keyboardChanged(now: 3)
            t.tick(now: 4)
        }
        trace("start without window") { t in
            t.start(0)
            t.key(now: 1)
            t.tick(now: 2)
        }
        trace("before start nothing") { t in
            t.window(1, win, appeared: -10, now: 0)
            t.pointer(.click, P(10, 10), now: 0.1)
            t.key(now: 0.2)
            t.keyboardChanged(now: 0.3)
            t.result(.keyboard, t.generation, pick(left), now: 0.4)
            t.frame(frame(tiles(cols: 5...9, rows: 0...7), copy: left), now: 0.5)
            t.tick(now: 0.6)
            t.locked(true, now: 0.7)
            t.window(1, win, appeared: -10, now: 0.8)
        }
        trace("new window requeries and resets") { t in
            started(t)
            t.keyboard(pick(left), now: 1)
            t.window(2, win, appeared: -10, now: 2)
            t.window(2, win, appeared: -10, now: 3)
        }
        trace("throttle keeps last") { t in
            started(t)
            let b = CGRect(x: 0, y: 0, width: 500, height: 800)
            t.keyboard(pick(left), now: 0.1)
            t.keyboardChanged(now: 0.2)
            t.keyboard(pick(b), now: 0.2)
            t.tick(now: 0.25); t.tick(now: 0.3); t.tick(now: 0.4)
        }
        trace("unchanged not sent") { t in
            started(t)
            t.keyboard(pick(left), now: 1)
            t.keyboardChanged(now: 2)
            t.keyboard(pick(left), now: 2)
            t.tick(now: 3)
        }

        // MARK: rule 5: follow
        trace("follow within one second") { t in
            clicked(t)
            t.frame(frame(tiles(cols: 5...9, rows: 0...1) + tiles(cols: 0...3, rows: 0...7)), now: 1.3)
            t.frame(frame(tiles(cols: 5...9, rows: 0...1)), now: 1.4)
            t.frame(frame(tiles(cols: 5...7, rows: 2...2)), now: 1.5)
            t.frame(frame(tiles(cols: 4...9, rows: 3...7)), now: 1.6)
            t.result(.follow(P(750, 150)), t.generation, pick(CGRect(x: 500, y: 0, width: 300, height: 400)), now: 1.7)
        }
        trace("follow exactly at the share") { t in
            clicked(t)
            // 12 tiles = 80 * 0.15: not enough; the 13th is.
            t.frame(frame(tiles(cols: 5...9, rows: 0...1) + tiles(cols: 5...6, rows: 2...2)), now: 1.3)
            t.frame(frame(tiles(cols: 7...7, rows: 2...2)), now: 1.35)
        }
        trace("follow at one second edge") { t in
            clicked(t)
            t.frame(frame(tiles(cols: 5...9, rows: 0...7)), now: 2.0)
        }
        trace("no follow after one second") { t in
            clicked(t)
            t.frame(frame(tiles(cols: 5...9, rows: 0...7)), now: 2.1)
        }
        trace("no follow without action") { t in
            started(t)
            t.keyboard(pick(left), now: 0.5)
            t.frame(frame(tiles(cols: 5...9, rows: 0...7)), now: 1)
        }
        trace("no follow while whole") { t in
            started(t)
            t.key(now: 1)
            t.frame(frame(tiles(cols: 5...9, rows: 0...7)), now: 1.2)
        }
        trace("no follow with zero total") { t in
            clicked(t)
            t.frame(WindowTiles(changed: tiles(cols: 5...9, rows: 0...7), total: 0, copyBounds: nil, full: false),
                    now: 1.2)
        }
        trace("key arms follow and rechecks") { t in
            started(t)
            t.keyboard(pick(left), now: 0.5)
            t.key(now: 1)
            t.tick(now: 1.2)
            t.frame(frame(tiles(cols: 5...9, rows: 0...7)), now: 1.3)
        }
        trace("second key keeps the first recheck") { t in
            started(t)
            t.keyboard(pick(left), now: 0.5)
            t.key(now: 1)
            t.key(now: 1.1)
            t.tick(now: 1.2)
            t.tick(now: 1.3)
        }
        trace("tick clears an old action") { t in
            clicked(t)
            t.tick(now: 2.05)
            t.frame(frame(tiles(cols: 5...9, rows: 0...7)), now: 2.06)
        }
        trace("scroll and move do not arm follow") { t in
            started(t)
            t.keyboard(pick(left), now: 0.5)
            t.pointer(.scroll, P(100, 100), now: 1)
            t.pointer(.move, P(120, 100), now: 1.1)
            t.pointer(.drag, P(130, 100), now: 1.15)
            t.frame(frame(tiles(cols: 5...9, rows: 0...7)), now: 1.2)
        }
        trace("next click clears follow") { t in
            clicked(t)
            t.frame(frame(tiles(cols: 5...9, rows: 0...7)), now: 1.2)
            let f = CGRect(x: 500, y: 0, width: 300, height: 400)
            t.result(.follow(P(750, 400)), t.generation, pick(f), now: 1.3)
            t.pointer(.click, P(100, 200), now: 2)
            t.result(.follow(P(750, 400)), t.generation, pick(f), now: 2.1)
            t.frame(frame(tiles(cols: 5...9, rows: 4...7)), now: 2.5)
        }
        trace("follow answer at another point dropped") { t in
            clicked(t)
            t.frame(frame(tiles(cols: 5...9, rows: 0...7)), now: 1.2)
            t.result(.follow(P(1, 1)), t.generation, pick(right), now: 1.3)
            t.result(.follow(P(750, 400)), t.generation, .failure(.small), now: 1.4)
            t.result(.follow(P(750, 400)), t.generation, pick(right), now: 1.5)
        }
        trace("full frame never follows") { t in
            clicked(t)
            t.frame(frame(tiles(cols: 0...9, rows: 0...7), full: true), now: 1.2)
            t.frame(frame(tiles(cols: 5...9, rows: 0...1)), now: 1.3)
        }

        // MARK: rule 6: copy tiles
        trace("copy bounds when blocked") { t in
            started(t)
            t.keyboard(.failure(.blocked), now: 0.5)
            t.frame(frame([], copy: CGRect(x: 300, y: 0, width: 600, height: 800)), now: 1)
            t.frame(frame([]), now: 2)
            t.pointer(.click, P(10, 10), now: 3)
            t.result(.pointer(P(10, 10)), t.generation, .failure(.blocked), now: 3)
            t.tick(now: 4)
        }
        trace("no copy fallback when small") { t in
            started(t)
            t.keyboard(.failure(.small), now: 0.5)
            t.frame(frame([], copy: CGRect(x: 300, y: 0, width: 600, height: 800)), now: 1)
        }
        trace("no copy fallback when pointer large") { t in
            started(t)
            t.keyboard(.failure(.blocked), now: 0.5)
            t.pointer(.click, P(10, 10), now: 0.6)
            t.result(.pointer(P(10, 10)), t.generation, .failure(.large), now: 0.6)
            t.frame(frame([], copy: CGRect(x: 300, y: 0, width: 600, height: 800)), now: 1)
            t.tick(now: 2)
        }
        trace("copy bounds below threshold whole") { t in
            started(t)
            t.keyboard(.failure(.blocked), now: 0.5)
            t.frame(frame([], copy: CGRect(x: 0, y: 0, width: 100, height: 100)), now: 1)
            t.frame(frame([], copy: CGRect(x: 0, y: 0, width: 950, height: 800)), now: 2)
            t.tick(now: 3)
        }
        trace("empty copy bounds ignored") { t in
            started(t)
            t.keyboard(.failure(.blocked), now: 0.5)
            t.frame(frame([], copy: CGRect(x: 300, y: 0, width: 0, height: 800)), now: 1)
            t.tick(now: 2)
        }

        // MARK: review focus
        trace("stale result after window change dropped") { t in
            started(t)
            let old = t.generation
            t.window(2, win, appeared: -10, now: 1)
            t.result(.keyboard, old, pick(left), now: 2)
            t.tick(now: 3)
            t.keyboard(pick(left), now: 4)
            t.window(2, CGSize(width: 900, height: 800), appeared: -10, now: 5)
            t.result(.keyboard, old + 1, .failure(.small), now: 6)
            t.result(.pointer(P(700, 400)), old + 1, pick(right), now: 6)
            t.tick(now: 7)
        }
        trace("stale generation after a newer query") { t in
            started(t)
            let old = t.generation
            t.window(1, CGSize(width: 1000, height: 900), appeared: -10, now: 1)
            t.keyboardChanged(now: 1.1)
            t.result(.keyboard, old, pick(left), now: 1.2)
            t.result(.keyboard, t.generation, pick(right), now: 1.3)
            t.tick(now: 1.6)
        }
        trace("output clipped to window") { t in
            started(t)
            let p = CGRect(x: 600, y: 0, width: 400, height: 800)
            t.keyboard(pick(p), now: 1)
            t.window(1, CGSize(width: 800, height: 800), appeared: -10, now: 2)
            t.keyboard(pick(p), now: 3)
            t.keyboard(pick(CGRect(x: 500, y: 0, width: 500, height: 800)), now: 4)
        }
        trace("pick outside window dropped") { t in
            started(t)
            t.keyboard(pick(CGRect(x: 1200, y: 0, width: 300, height: 800)), now: 1)
            t.keyboard(pick(CGRect(x: 1000, y: 0, width: 300, height: 800)), now: 2)
        }
        trace("resize requeries pointer at last point") { t in
            started(t)
            t.keyboard(.failure(.small), now: 0.5)
            t.pointer(.click, P(700, 400), now: 1)
            t.result(.pointer(P(700, 400)), t.generation, pick(right), now: 1)
            t.tick(now: 1.2)
            t.window(1, CGSize(width: 900, height: 800), appeared: -10, now: 2)
            t.result(.pointer(P(700, 400)), t.generation, pick(CGRect(x: 450, y: 0, width: 450, height: 800)), now: 2.3)
            t.pointer(.scroll, P(700, 400), now: 3)
        }
        trace("follow panel dropped on resize") { t in
            clicked(t)
            t.frame(frame(tiles(cols: 5...9, rows: 0...7)), now: 1.2)
            t.result(.follow(P(750, 400)), t.generation, pick(CGRect(x: 500, y: 0, width: 300, height: 400)), now: 1.3)
            t.window(1, CGSize(width: 1000, height: 900), appeared: -10, now: 2)
        }
        trace("copy bounds dropped on resize") { t in
            started(t)
            t.keyboard(.failure(.blocked), now: 0.5)
            t.frame(frame([], copy: CGRect(x: 300, y: 0, width: 600, height: 800)), now: 1)
            t.window(1, CGSize(width: 1000, height: 900), appeared: -10, now: 2)
            t.keyboard(.failure(.blocked), now: 2.5)
            t.frame(frame([], copy: CGRect(x: 300, y: 0, width: 600, height: 900)), now: 3)
            t.window(2, win, appeared: -10, now: 4)
        }

        // MARK: resize drops the old geometry
        trace("resize sends only fresh panels") { t in
            hoveredSidebar(t)
            let old = t.generation
            t.window(1, CGSize(width: 1400, height: 800), appeared: -10, now: 3)
            t.keyboard(pick(CGRect(x: 400, y: 0, width: 700, height: 800)), now: 3.1)
            t.tick(now: 3.3)
            t.result(.pointer(P(100, 100)), old, pick(sidebar), now: 3.4)
            t.tick(now: 3.7)
            t.result(.pointer(P(100, 100)), old + 1, pick(CGRect(x: 0, y: 0, width: 350, height: 800)), now: 3.8)
        }
        trace("resize sends whole at once") { t in
            hoveredSidebar(t)
            t.keyboardChanged(now: 1.7)
            t.keyboard(pick(sidebar), now: 1.7)
            t.window(1, CGSize(width: 1400, height: 800), appeared: -10, now: 1.8)
            t.window(1, CGSize(width: 1410, height: 800), appeared: -10, now: 1.9)
            t.tick(now: 2.2)
            t.tick(now: 2.5)
        }
        trace("resize keeps pending hover position") { t in
            started(t)
            t.keyboard(pick(editor), now: 0.5)
            t.pointer(.move, P(100, 100), now: 1)
            t.window(1, CGSize(width: 1400, height: 800), appeared: -10, now: 1.2)
            t.tick(now: 1.5)
        }
        trace("resize skips point outside new bounds") { t in
            started(t)
            t.keyboard(pick(editor), now: 0.5)
            t.pointer(.click, P(900, 400), now: 1)
            t.window(1, CGSize(width: 800, height: 800), appeared: -10, now: 2)
        }
        trace("resize with point on the new edge") { t in
            started(t)
            t.keyboard(pick(editor), now: 0.5)
            t.pointer(.click, P(800, 400), now: 1)
            t.window(1, CGSize(width: 800, height: 800), appeared: -10, now: 2)
        }
        trace("same window same size resends nothing new") { t in
            started(t)
            t.keyboard(pick(left), now: 0.5)
            t.window(1, win, appeared: -10, now: 1)
            t.window(1, win, appeared: 0.9, now: 1.5)
            t.tick(now: 3)
        }
        trace("rects rounded outward") { t in
            started(t)
            t.keyboard(pick(CGRect(x: 0.4, y: 10.6, width: 300.2, height: 400.1)), now: 1)
        }
        trace("rects rounded outward at the edge") { t in
            started(t)
            t.keyboard(pick(CGRect(x: 600.5, y: 0.5, width: 399.8, height: 799.8)), now: 1)
        }
        F.check("focus-tracker.json", F.cases(cases))
    }

    // MARK: - query.json

    func testQuery() {
        var cases: [[String: Any]] = []
        func coalescer(_ name: String, _ ops: [(QueryKind, String)?]) {
            var c = QueryCoalescer<String>()
            var steps: [[String: Any]] = []
            var outs: [Any] = []
            for op in ops {
                if let op = op {
                    let (kind, job) = op
                    steps.append(["op": "submit", "kind": Self.kindName(kind), "job": job])
                    outs.append(F.opt(c.submit(kind, job)))
                } else {
                    steps.append(["op": "finish"])
                    outs.append(F.opt(c.finish()))
                }
            }
            cases.append(Self.c(name, ["fn": "coalescer", "steps": steps], outs))
        }
        coalescer("idle runs at once", [(.keyboard, "k1"), nil])
        coalescer("newer pointer replaces pending pointer", [(.pointer, "p1"), (.pointer, "p2"), (.pointer, "p3"), nil, nil])
        coalescer("pointer does not replace keyboard",
                  [(.pointer, "p1"), (.keyboard, "k1"), (.pointer, "p2"), (.follow, "f1"), nil, nil, nil, nil])
        coalescer("idle again after drain", [(.keyboard, "k1"), (.keyboard, "k2"), nil, nil, (.follow, "f1")])
        coalescer("finish while idle", [nil, nil, (.pointer, "p1"), nil])
        coalescer("follow then keyboard order", [(.follow, "f0"), (.follow, "f1"), (.keyboard, "k1"), (.follow, "f2"),
                                                 nil, nil, nil])

        func deadline(_ name: String, _ start: Double, _ budget: Double, _ now: Double) {
            let d = QueryDeadline(start: start, budget: budget)
            cases.append(Self.c(name, ["fn": "deadline", "start": start, "budget": budget, "now": now],
                                ["remaining": F.opt(d.remaining(now: now)), "expired": d.expired(now: now)]))
        }
        deadline("deadline at start", 10, 0.05, 10)
        deadline("deadline shrinks", 10, 0.05, 10.02)
        deadline("deadline at end", 10, 0.05, 10.05)
        deadline("deadline under 1 ms", 10, 0.05, 10.0495)
        deadline("deadline after", 10, 0.05, 11)
        deadline("deadline expired", 10, 0.05, 10.06)
        deadline("deadline not expired", 10, 0.05, 10.01)
        deadline("deadline exactly 1 ms", 0, 0.002, 0.001)
        deadline("deadline before start", 10, 0.05, 9)

        for (i, q) in [T.Query.keyboard, .pointer(.zero), .follow(.zero), .pointer(CGPoint(x: 3, y: 4))].enumerated() {
            cases.append(Self.c("query kind \(i)", ["fn": "kind", "query": Self.query(q)],
                                Self.kindName(q.kind)))
        }
        F.check("query.json", F.cases(cases))
    }
}
