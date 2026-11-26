import CoreGraphics
import Foundation
import XCTest
@testable import RappCore

/// Geometry, window-table, view-region, desktop, hit-test and hint rules for
/// `rust/host-core/tests/rules_windows.rs`. Every case's `in` names the Rust function in
/// `"fn"` and carries its arguments in snake_case; `out` is what the Swift function returned.
/// Covers every scenario of GeometryTests, WindowsTests, ViewRegionTests, DesktopTests,
/// HitTestTests and HostHintsTests that touches a ported function, plus the plan's extras.
final class WindowRuleFixtures: XCTestCase {
    private typealias F = HostFixture

    // MARK: - JSON shapes

    private static func pt(_ p: CGPoint) -> [String: Any] { ["x": Double(p.x), "y": Double(p.y)] }
    private static func sz(_ s: CGSize) -> [String: Any] { ["width": Double(s.width), "height": Double(s.height)] }
    private static func cg(_ r: CGRect) -> [String: Any] {
        F.rect(x: Double(r.origin.x), y: Double(r.origin.y), width: Double(r.size.width), height: Double(r.size.height))
    }
    private static func j(_ w: WindowInfo) -> [String: Any] {
        ["id": Int(w.id), "parent": Int(w.parent), "kind": Int(w.kind.rawValue), "resizable": w.resizable,
         "focused": w.focused, "rect": F.rect(w.rect), "title_bar": F.f(w.titleBar), "title": w.title]
    }
    private static func js(_ ws: [WindowInfo]) -> [[String: Any]] { ws.map(j) }
    private static func region(_ r: CanvasRect?) -> Any { F.opt(r.map(F.rect)) }
    private static func view(_ v: (window: UInt32, rect: CanvasRect)?) -> Any {
        F.opt(v.map { ["window": Int($0.window), "rect": F.rect($0.rect)] as [String: Any] })
    }

    private static func win(_ id: UInt32, _ kind: WindowKind, _ x: Float, _ y: Float, _ w: Float, _ h: Float,
                            titleBar: Float = 0, parent: UInt32 = 0, title: String? = nil) -> WindowInfo {
        WindowInfo(id: id, parent: parent, kind: kind, resizable: true, focused: false,
                   rect: CanvasRect(x: x, y: y, w: w, h: h), titleBar: titleBar, title: title ?? "w\(id)")
    }

    private static func c(_ name: String, _ input: [String: Any], _ out: Any) -> [String: Any] {
        ["name": name, "in": input, "out": out]
    }

    // MARK: - geometry.json

    func testGeometry() {
        var cases: [[String: Any]] = []
        func point(_ name: String, _ x: Float, _ y: Float, _ frame: CGRect) {
            cases.append(Self.c(name, ["fn": "global_point", "x": F.f(x), "y": F.f(y), "frame": Self.cg(frame)],
                                Self.pt(globalPoint(x: x, y: y, windowFrame: frame))))
        }
        point("global point centre", 0.5, 0.5, CGRect(x: 100, y: 200, width: 800, height: 600))
        point("global point clamped", -1, 2, CGRect(x: 100, y: 200, width: 800, height: 600))
        point("global point origin", 0, 0, CGRect(x: 100, y: 82, width: 800, height: 568))
        point("global point one", 1, 1, CGRect(x: 100, y: 82, width: 800, height: 568))
        point("global point negative origin", 0.25, 0.75, CGRect(x: -1920, y: -200, width: 1920, height: 1080))
        point("global point zero frame", 0.5, 0.5, CGRect(x: 10, y: 10, width: 0, height: 0))
        point("global point 1x1", 0.5, 0.5, CGRect(x: 0, y: 0, width: 1, height: 1))

        func clamp(_ name: String, _ req: CGSize, _ origin: CGPoint, _ screen: CGRect) {
            cases.append(Self.c(name, ["fn": "clamp_size", "requested": Self.sz(req), "origin": Self.pt(origin),
                                       "screen": Self.cg(screen)],
                                Self.sz(clampSize(requested: req, origin: origin, screen: screen))))
        }
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        clamp("clamp size too big", CGSize(width: 3000, height: 2000), CGPoint(x: 100, y: 100), screen)
        clamp("clamp size too small", CGSize(width: 10, height: 10), CGPoint(x: 100, y: 100), screen)
        clamp("clamp size fits", CGSize(width: 640, height: 480), CGPoint(x: 100, y: 100), screen)
        clamp("clamp size left monitor", CGSize(width: 3000, height: 500), CGPoint(x: -1800, y: 0),
              CGRect(x: -1920, y: 0, width: 1920, height: 1080))
        clamp("clamp size origin past screen", CGSize(width: 500, height: 500), CGPoint(x: 1900, y: 1070), screen)

        func chunks(_ name: String, _ s: String, _ max: Int = 20) {
            cases.append(Self.c(name, ["fn": "chunk_utf16", "s": s, "max": max],
                                chunkUTF16(s, max: max).map { $0.map { Int($0) } }))
        }
        chunks("chunk emoji across the edge", String(repeating: "a", count: 19) + "😀b")
        chunks("chunk surrogate at units 20 and 21", String(repeating: "a", count: 19) + "😀")
        chunks("chunk empty", "")
        chunks("chunk chinese", "你好")
        chunks("chunk forty", String(repeating: "a", count: 40))
        chunks("chunk forty-one", String(repeating: "a", count: 41))
        chunks("chunk emoji only", String(repeating: "😀", count: 15))
        chunks("chunk flags and zwj", "🇨🇳🇯🇵👩‍👩‍👧‍👦é" + String(repeating: "b", count: 10))
        chunks("chunk max 1 with emoji", "a😀b", 1)
        chunks("chunk max 2", "😀😀a", 2)

        func size(_ name: String, _ content: CGSize, _ title: CGFloat, _ origin: CGPoint, _ screen: CGRect) {
            cases.append(Self.c(name, ["fn": "window_size", "content": Self.sz(content), "title_row": Double(title),
                                       "origin": Self.pt(origin), "screen": Self.cg(screen)],
                                Self.sz(windowSize(forContent: content, titleRow: title, origin: origin, screen: screen))))
        }
        size("window size adds title row", CGSize(width: 800, height: 568), 32, CGPoint(x: 100, y: 50), screen)
        size("window size clamped to screen", CGSize(width: 800, height: 1100), 32, CGPoint(x: 100, y: 50), screen)
        size("window size no title row", CGSize(width: 50, height: 50), 0, CGPoint(x: 0, y: 0), screen)

        func title(_ name: String, _ raw: String?, _ app: String?) {
            cases.append(Self.c(name, ["fn": "window_title", "raw": F.opt(raw), "app_name": F.opt(app)],
                                windowTitle(raw, appName: app)))
        }
        title("title raw", "文稿.txt", "TextEdit")
        title("title empty falls back", "", "TextEdit")
        title("title nil falls back", nil, "TextEdit")
        title("title nothing", nil, nil)
        title("title empty and nil", "", nil)
        title("title 200 graphemes", String(repeating: "é", count: 200), nil)
        title("title 201 graphemes", String(repeating: "e\u{301}", count: 201), nil)
        title("title 201 flags", String(repeating: "🇨🇳", count: 201), nil)
        title("title 201 zwj", String(repeating: "👩‍👩‍👧", count: 201), nil)

        F.check("geometry.json", F.cases(cases))
    }

    // MARK: - wintable.json

    func testWindowTable() {
        var cases: [[String: Any]] = []
        func demote(_ name: String, _ kind: WindowKind, close: Bool, title: String?, _ w: CGFloat, _ h: CGFloat) {
            let size = CGSize(width: w, height: h)
            cases.append(Self.c(name, ["fn": "demote_chromeless", "kind": Int(kind.rawValue), "close_button": close,
                                       "title": F.opt(title), "size": Self.sz(size)],
                                Int(demoteChromeless(kind, closeButton: close, title: title, size: size).rawValue)))
        }
        for kind in [WindowKind.normal, .dialog, .floating, .sheet, .popover, .menu, .tooltip] {
            for close in [true, false] {
                for title in ["", "菜单", nil, "计算器", "检查器"] as [String?] {
                    demote("demote \(kind) close \(close) title \(title ?? "nil")", kind, close: close, title: title, 220, 400)
                }
            }
        }
        demote("demote too wide", .normal, close: false, title: nil, 641, 400)
        demote("demote too tall", .floating, close: false, title: "", 300, 1001)
        demote("demote at the limit", .normal, close: false, title: "", 640, 1000)
        demote("demote zero size", .normal, close: true, title: "", 0, 0)

        func table(_ name: String, _ fn: String, _ ws: [WindowInfo], _ f: ([WindowInfo]) -> [WindowInfo]) {
            cases.append(Self.c(name, ["fn": fn, "windows": Self.js(ws)], Self.js(f(ws))))
        }
        let w = Self.win
        // dropStrayIndicators
        table("stray indicators", "drop_stray_indicators", [
            w(1, .normal, 0, 0, 400, 300, 0, 0, nil), w(2, .dialog, 0, 0, 66, 20, 0, 0, nil),
            w(3, .popover, 0, 0, 120, 48, 0, 0, nil), w(4, .menu, 0, 0, 100, 30, 0, 0, nil),
            w(5, .popover, 0, 0, 121, 30, 0, 0, nil), w(6, .tooltip, 0, 0, 40, 49, 0, 0, nil),
            w(7, .normal, 0, 0, 0, 0, 0, 0, nil),
        ], dropStrayIndicators)
        table("stray indicators empty", "drop_stray_indicators", [], dropStrayIndicators)
        // promoteMainWindow
        table("promote largest popover", "promote_main_window", [
            w(1, .popover, 0, 0, 100, 100, 0, 0, nil), w(2, .popover, 0, 0, 300, 200, 0, 0, nil),
            w(3, .menu, 0, 0, 500, 500, 0, 0, nil),
        ], promoteMainWindow)
        table("promote not with a decorated window", "promote_main_window", [
            w(1, .popover, 0, 0, 900, 900, 0, 0, nil), w(2, .dialog, 0, 0, 100, 100, 0, 0, nil),
        ], promoteMainWindow)
        table("promote nothing to promote", "promote_main_window", [w(1, .menu, 0, 0, 100, 100, 0, 0, nil)], promoteMainWindow)
        table("promote tie keeps the first", "promote_main_window", [
            w(1, .popover, 0, 0, 200, 100, 0, 0, nil), w(2, .popover, 50, 50, 100, 200, 0, 0, nil),
        ], promoteMainWindow)
        // assignParents
        table("parents decorated have none", "assign_parents", [
            w(1, .normal, 0, 0, 100, 100, 0, 9, nil), w(2, .dialog, 10, 10, 50, 50, 0, 9, nil),
        ], assignParents)
        table("parents most overlap", "assign_parents", [
            w(3, .menu, 90, 0, 40, 40, 0, 0, nil), w(1, .normal, 0, 0, 100, 100, 0, 0, nil),
            w(2, .normal, 100, 0, 100, 100, 0, 0, nil),
        ], assignParents)
        table("parents tie goes to the frontmost", "assign_parents", [
            w(3, .menu, 80, 0, 40, 40, 0, 0, nil), w(1, .normal, 0, 0, 100, 100, 0, 0, nil),
            w(2, .normal, 100, 0, 100, 100, 0, 0, nil),
        ], assignParents)
        table("parents no overlap goes to the first decorated", "assign_parents", [
            w(4, .tooltip, 500, 500, 40, 20, 0, 0, nil), w(3, .sheet, 0, 0, 50, 50, 0, 0, nil),
            w(2, .floating, 0, 0, 100, 100, 0, 0, nil), w(1, .normal, 200, 0, 100, 100, 0, 0, nil),
        ], assignParents)
        table("parents no decorated window", "assign_parents", [w(1, .menu, 0, 0, 40, 40, 0, 5, nil)], assignParents)
        table("parents empty", "assign_parents", [], assignParents)
        table("parents touching edges do not overlap", "assign_parents", [
            w(3, .menu, 100, 0, 40, 40, 0, 0, nil), w(1, .normal, 0, 0, 100, 100, 0, 0, nil),
            w(2, .normal, 300, 300, 100, 100, 0, 0, nil),
        ], assignParents)
        // dropTitleBarAccessories
        table("title bar accessory dropped", "drop_title_bar_accessories", [
            w(1, .normal, 100, 100, 400, 300, 28, 0, nil), w(2, .dialog, 106, 106, 66, 20, 0, 0, nil),
        ], dropTitleBarAccessories)
        table("title bar unmeasured counts as 28", "drop_title_bar_accessories", [
            w(1, .normal, 100, 100, 400, 300, 0, 0, nil), w(2, .menu, 106, 106, 66, 30, 0, 0, nil),
            w(3, .menu, 106, 106, 66, 22, 0, 0, nil),
        ], dropTitleBarAccessories)
        table("title bar only of decorated windows", "drop_title_bar_accessories", [
            w(1, .menu, 100, 100, 400, 300, 0, 0, nil), w(2, .tooltip, 106, 106, 66, 20, 0, 0, nil),
        ], dropTitleBarAccessories)
        table("title bar a window is not its own accessory", "drop_title_bar_accessories", [
            w(1, .normal, 100, 100, 400, 20, 28, 0, nil),
        ], dropTitleBarAccessories)

        // captureRegion
        func capture(_ name: String, _ ws: [WindowInfo], _ display: CGSize) {
            cases.append(Self.c(name, ["fn": "capture_region", "windows": Self.js(ws), "display": Self.sz(display)],
                                Self.region(captureRegion(windows: ws, display: display))))
        }
        capture("capture union rounded out", [w(1, .normal, 10, 20, 100, 50, 0, 0, nil), w(2, .menu, 105, 60, 30, 30, 0, 0, nil)],
                CGSize(width: 1000, height: 800))
        capture("capture aligned unchanged", [w(1, .normal, 16, 24, 80, 40, 0, 0, nil)], CGSize(width: 1000, height: 800))
        capture("capture clipped to odd display", [w(1, .normal, -50, 700, 200, 300, 0, 0, nil)], CGSize(width: 1001, height: 797))
        capture("capture no windows", [], CGSize(width: 1000, height: 800))
        capture("capture off display", [w(1, .normal, 2000, 2000, 100, 100, 0, 0, nil)], CGSize(width: 1000, height: 800))
        capture("capture zero-size window", [w(1, .normal, 40, 40, 0, 0, 0, 0, nil)], CGSize(width: 1000, height: 800))
        capture("capture 1x1 display", [w(1, .normal, 0, 0, 100, 100, 0, 0, nil)], CGSize(width: 1, height: 1))
        capture("capture negative origin", [w(1, .normal, -1920, 0, 1920, 1080, 0, 0, nil), w(2, .normal, 10, 10, 30, 30, 0, 0, nil)],
                CGSize(width: 1440, height: 900))
        var rng = HostRNG(seed: 7)
        for count in [256, 257] {
            let many = (0..<count).map { i in
                w(UInt32(i + 1), i % 3 == 0 ? .normal : .menu, Float(rng.int(-200...1400)), Float(rng.int(-100...900)),
                  Float(rng.int(0...400)), Float(rng.int(0...300)), 0, 0, nil)
            }
            capture("capture \(count) windows", many, CGSize(width: 1440, height: 900))
            table("parents \(count) windows", "assign_parents", many, assignParents)
            table("stray \(count) windows", "drop_stray_indicators", many, dropStrayIndicators)
            table("title bar \(count) windows", "drop_title_bar_accessories", many, dropTitleBarAccessories)
        }

        // clampedWindowOrigin
        func origin(_ name: String, _ o: CGPoint, _ size: CGSize, _ tb: CGFloat, _ canvas: CGSize) {
            cases.append(Self.c(name, ["fn": "clamped_window_origin", "origin": Self.pt(o), "size": Self.sz(size),
                                       "title_bar": Double(tb), "canvas": Self.sz(canvas)],
                                Self.pt(clampedWindowOrigin(o, size: size, titleBar: tb, canvas: canvas))))
        }
        let canvas = CGSize(width: 1000, height: 800)
        origin("origin far left and below", CGPoint(x: -500, y: 900), CGSize(width: 400, height: 300), 28, canvas)
        origin("origin far right and above", CGPoint(x: 2000, y: -50), CGSize(width: 400, height: 300), 28, canvas)
        origin("origin inside unchanged", CGPoint(x: 100, y: 100), CGSize(width: 400, height: 300), 28, canvas)
        origin("origin small window no title", CGPoint(x: 0, y: 5000), CGSize(width: 30, height: 30), 0, canvas)
        origin("origin tiny canvas", CGPoint(x: 50, y: 50), CGSize(width: 400, height: 300), 28, CGSize(width: 10, height: 10))

        // classificationIsFinal
        for (found, below, attempts) in [(false, true, 1), (false, true, 9), (false, true, 10), (false, true, 11),
                                         (true, true, 1), (false, false, 1), (false, true, 0)] {
            cases.append(Self.c("classification \(found) \(below) \(attempts)",
                                ["fn": "classification_is_final", "found_accessibility": found, "below_pop_up": below,
                                 "attempts": attempts],
                                classificationIsFinal(foundAccessibility: found, belowPopUp: below, attempts: attempts)))
        }
        F.check("wintable.json", F.cases(cases))
    }

    // MARK: - view.json

    func testViewRegion() {
        var cases: [[String: Any]] = []
        let display = CGSize(width: 1440, height: 900)
        let main = Self.win(1, .normal, 100, 50, 800, 600, titleBar: 28)
        func region(_ name: String, _ v: (window: UInt32, rect: CanvasRect)?, _ ws: [WindowInfo], _ d: CGSize = display) {
            cases.append(Self.c(name, ["fn": "view_region", "view": Self.view(v), "windows": Self.js(ws), "display": Self.sz(d)],
                                Self.region(viewRegion(view: v, windows: ws, display: d))))
        }
        let small = CanvasRect(x: 0, y: 0, w: 10, h: 10)
        region("view none", nil, [main])
        region("view window zero", (window: 0, rect: small), [main])
        region("view unknown window", (window: 99, rect: small), [main])
        region("view rect on canvas", (window: 1, rect: CanvasRect(x: 200, y: 100, w: 160, h: 120)), [main])
        let menu = Self.win(2, .menu, 700, 400, 200, 300, parent: 1)
        let other = Self.win(3, .menu, 20, 700, 100, 100, parent: 5)
        region("view takes child popups", (window: 1, rect: CanvasRect(x: 200, y: 100, w: 160, h: 120)), [main, menu, other])
        let off = Self.win(1, .normal, -200, 50, 800, 600, titleBar: 28)
        region("view off display", (window: 1, rect: CanvasRect(x: 20, y: 0, w: 100, h: 100)), [off])
        region("view clipped to display", (window: 1, rect: CanvasRect(x: 150, y: 0, w: 200, h: 100)), [off])
        region("view no windows", (window: 1, rect: small), [])
        region("view 1x1 display", (window: 1, rect: small), [main], CGSize(width: 1, height: 1))
        region("view zero rect", (window: 1, rect: CanvasRect(x: 0, y: 0, w: 0, h: 0)), [main])

        let rect = CanvasRect(x: 100, y: 100, w: 200, h: 150)
        for window in [UInt32(0), 1, 7] {
            cases.append(Self.c("view for \(window)", ["fn": "view_for", "window": Int(window), "rect": F.rect(rect)],
                                Self.view(viewFor(window: window, rect: rect))))
        }
        func change(_ name: String, _ v: (window: UInt32, rect: CanvasRect)?, _ ws: [WindowInfo], _ current: CanvasRect?) {
            cases.append(Self.c(name, ["fn": "region_change", "view": Self.view(v), "windows": Self.js(ws),
                                       "display": Self.sz(display), "current": Self.region(current)],
                                Self.region(regionChange(view: v, windows: ws, display: display, current: current))))
        }
        let base = captureRegion(windows: [main], display: display)
        let v = viewFor(window: 1, rect: rect)
        change("change set view", v, [main], base)
        let current = viewRegion(view: v, windows: [main], display: display)
        let popup = Self.win(2, .menu, 400, 120, 300, 200, parent: 1)
        change("change table with same view", v, [main, popup], current)
        let next = viewRegion(view: v, windows: [main, popup], display: display)
        change("change nothing new", v, [main, popup], next)
        change("change window zero", viewFor(window: 0, rect: rect), [main], current)
        change("change no region", v, [], nil)
        change("change from nil current", nil, [main], nil)
        let desk = desktopTable(width: 1440, height: 900, title: "屏幕 1")
        change("change desktop honours set view", v, desk, CanvasRect(x: 0, y: 0, w: 1440, h: 900))
        F.check("view.json", F.cases(cases))
    }

    // MARK: - desktop.json

    private static func display(_ d: DesktopDisplay) -> [String: Any] {
        ["id": Int(d.id), "name": d.name, "main": d.main, "frame": cg(d.frame)]
    }

    func testDesktop() {
        var cases: [[String: Any]] = []
        for app in ["desktop:", "desktop:69733382", "desktop:x", "desktop:-1", "desktop:99999999999", "desktop:１",
                    "com.apple.Safari", "term:abc", "desktop:3", "desktop", "desktop:+5", "desktop:-0", "desktop:4294967295",
                    "desktop:4294967296", "desktop: 1", "desktop:007", "desktop:+", "desktop:1 ", "Desktop:1", ""] {
            let out: Any
            switch desktopTarget(app) {
            case nil: out = NSNull()
            case .main?: out = ["kind": "main"]
            case .display(let id)?: out = ["kind": "display", "id": Int(id)] as [String: Any]
            }
            cases.append(Self.c("target \(app)", ["fn": "desktop_target", "app": app], out))
        }
        func d(_ id: UInt32, _ x: CGFloat, _ y: CGFloat = 0, main: Bool = false, w: CGFloat = 1920, h: CGFloat = 1080,
               name: String? = nil) -> DesktopDisplay {
            DesktopDisplay(id: id, name: name ?? "屏幕\(id)", main: main, frame: CGRect(x: x, y: y, width: w, height: h))
        }
        func ordered(_ name: String, _ ds: [DesktopDisplay]) {
            let out: [[String: Any]] = orderedDisplays(ds).map {
                var o = Self.display($0)
                o["width"] = $0.width
                o["height"] = $0.height
                return o
            }
            cases.append(Self.c(name, ["fn": "ordered_displays", "displays": ds.map(Self.display)], out))
        }
        let four = [d(3, 200), d(2, -100), d(1, 0, main: true), d(4, 200, -100)]
        ordered("ordered main then left then top", four)
        ordered("ordered rounding", [d(1, 0, main: true, w: 1512.5, h: 981.4), d(2, 1512.5, w: 0.4, h: 0.5)])
        ordered("ordered empty", [])
        ordered("ordered same position by id", [d(9, 0), d(5, 0), d(7, 0, main: true)])

        for (computer, number) in [("Mac mini", 2), (" ", 1), ("  书房 ", 3), ("", 10)] {
            cases.append(Self.c("title \(computer) \(number)", ["fn": "desktop_title", "computer": computer, "number": number],
                                desktopTitle(computer: computer, number: number)))
        }
        for (w, h, title) in [(1512.0, 982.0, "屏幕 1"), (1.0, 1.0, "Mac mini · 屏幕 2"), (1512.5, 981.25, "")] {
            cases.append(Self.c("table \(w)x\(h)", ["fn": "desktop_table", "width": w, "height": h, "title": title],
                                Self.js(desktopTable(width: w, height: h, title: title))))
        }
        for (name, ds) in [("entry four", four), ("entry none", []), ("entry one", [d(1, 0, main: true, name: "内建显示器")])] {
            cases.append(Self.c(name, ["fn": "desktop_entry", "displays": ds.map(Self.display)], F.opt(desktopEntry(ds))))
        }
        F.check("desktop.json", F.cases(cases))
    }

    // MARK: - hit-test.json

    func testHitTest() {
        var cases: [[String: Any]] = []
        let app: Int32 = 100, dock: Int32 = 50, other: Int32 = 70
        let point = CGPoint(x: 400, y: 300)
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        func win(_ pid: Int32, _ name: String, layer: Int = 0, frame: CGRect = CGRect(x: 0, y: 0, width: 800, height: 600),
                 alpha: Double = 1) -> ScreenWindow {
            ScreenWindow(pid: pid, name: name, layer: layer, alpha: alpha, frame: frame)
        }
        let fullScreenDock = win(dock, "Dock", layer: 20, frame: screen)
        func owner(_ name: String, _ ws: [ScreenWindow], hit: Int32?, displays: [CGRect] = [], dockPID: Int32? = dock,
                   at: CGPoint = point) {
            var calls = 0
            let o = topWindowOwner(at: at, windows: ws, dockPID: dockPID, displays: displays) { calls += 1; return hit }
            let input: [String: Any] = [
                "fn": "top_window_owner", "point": Self.pt(at), "dock_pid": F.opt(dockPID.map { Int($0) }),
                "displays": displays.map(Self.cg), "hit": F.opt(hit.map { Int($0) }),
                "windows": ws.map { ["pid": Int($0.pid), "name": $0.name, "layer": $0.layer, "alpha": $0.alpha,
                                     "frame": Self.cg($0.frame)] as [String: Any] },
            ]
            cases.append(Self.c(name, input, ["pid": Int(o.pid), "name": o.name, "calls": calls] as [String: Any]))
        }
        owner("dock overlay looked through", [fullScreenDock, win(app, "TextEdit")], hit: app)
        owner("dock bar covers", [fullScreenDock, win(app, "TextEdit")], hit: dock)
        owner("failed hit looks through dock", [fullScreenDock, win(app, "TextEdit")], hit: nil)
        owner("other app covers", [fullScreenDock, win(other, "Notes"), win(app, "TextEdit")], hit: app)
        owner("invisible, cursor and missed skipped", [win(other, "Clear", alpha: 0), win(other, "Cursor", layer: 2000),
                                                       win(other, "Elsewhere", frame: CGRect(x: 900, y: 0, width: 100, height: 100)),
                                                       win(app, "TextEdit")], hit: nil)
        owner("nothing", [], hit: nil)
        owner("layer 999 counts", [win(other, "High", layer: 999), win(app, "TextEdit")], hit: nil)
        owner("no dock pid", [fullScreenDock, win(app, "TextEdit")], hit: app, dockPID: nil)
        owner("edge is outside", [win(other, "Edge", frame: CGRect(x: 0, y: 0, width: 400, height: 300)), win(app, "TextEdit")],
              hit: nil)
        owner("negative origin window", [win(other, "Left", frame: CGRect(x: -1920, y: 0, width: 1920, height: 1080))],
              hit: nil, displays: [CGRect(x: -1920, y: 0, width: 1920, height: 1080), screen], at: CGPoint(x: -10, y: 10))
        owner("overlay looked through where the app is hit", [win(other, "Prompt", layer: 25, frame: screen), win(app, "TextEdit")],
              hit: app, displays: [screen])
        owner("overlay covers where it is hit", [win(other, "Prompt", layer: 25, frame: screen), win(app, "TextEdit")],
              hit: other, displays: [screen])
        owner("overlay covers when hit fails", [win(other, "Prompt", layer: 25, frame: screen), win(app, "TextEdit")],
              hit: nil, displays: [screen])
        owner("nearly full screen is overlay", [win(other, "Prompt", frame: CGRect(x: 0, y: 25, width: 1920, height: 1000)),
                                                win(app, "TextEdit")], hit: app, displays: [screen])
        owner("just under coverage is not overlay", [win(other, "Prompt", frame: CGRect(x: 0, y: 0, width: 1920, height: 917)),
                                                     win(app, "TextEdit")], hit: app, displays: [screen])
        owner("translucent hud", [win(other, "HUD", layer: 8, frame: CGRect(x: 300, y: 200, width: 300, height: 200), alpha: 0.4),
                                  win(app, "TextEdit")], hit: app, displays: [screen])
        owner("small opaque covers without asking", [win(other, "Notes", frame: CGRect(x: 300, y: 200, width: 300, height: 200)),
                                                     win(app, "TextEdit")], hit: nil, displays: [screen])
        owner("hit test once", [win(dock, "Dock", layer: 20, frame: screen), win(other, "Prompt", layer: 25, frame: screen),
                                win(app, "TextEdit")], hit: app, displays: [screen])
        owner("third process overlay", [win(other, "Prompt", layer: 25, frame: screen), win(71, "Notes"), win(app, "TextEdit")],
              hit: 71, displays: [screen])
        let second = CGRect(x: 1920, y: 0, width: 1920, height: 1080)
        owner("display holding the point wide", [win(other, "Wide", frame: CGRect(x: 0, y: 0, width: 3840, height: 1080)),
                                                 win(app, "TextEdit")], hit: app, displays: [screen, second])
        owner("display holding the point half", [win(other, "Half", frame: CGRect(x: 0, y: 0, width: 960, height: 1080)),
                                                 win(app, "TextEdit")], hit: app, displays: [screen, second])
        owner("zero-size display", [win(other, "Big", frame: screen), win(app, "TextEdit")], hit: app,
              displays: [CGRect(x: 400, y: 300, width: 0, height: 0), screen])
        owner("1x1 display", [win(other, "Big", frame: screen), win(app, "TextEdit")], hit: app,
              displays: [CGRect(x: 400, y: 300, width: 1, height: 1)])
        F.check("hit-test.json", F.cases(cases))
    }

    // MARK: - hints.json

    func testHints() {
        var cases: [[String: Any]] = []
        func notices(_ name: String, every: TimeInterval = 5, _ steps: [[String: Any]]) {
            var n = CoverNotices(every: every)
            var out: [[String: Any]] = []
            for s in steps {
                let pid = Int32(s["pid"] as! Int)
                switch s["op"] as! String {
                case "send":
                    out.append(["op": "sent", "value": n.shouldSend(pid: pid, at: s["now"] as! Double)])
                case "reported":
                    let p = s["point"] as! [String: Double]
                    n.reported(pid: pid, dismissable: s["dismissable"] as! Bool, at: CGPoint(x: p["x"]!, y: p["y"]!))
                    out.append(["op": "done"])
                case "point":
                    out.append(["op": "point", "value": F.opt(n.dismissPoint(pid: pid).map(Self.pt))])
                default:
                    n.forget(pid: pid)
                    out.append(["op": "done"])
                }
            }
            cases.append(Self.c(name, ["fn": "cover_notices", "every": every, "steps": steps], out))
        }
        func send(_ pid: Int, _ now: Double) -> [String: Any] { ["op": "send", "pid": pid, "now": now] }
        notices("cover notices throttle", [send(7, 100), send(7, 104.9), send(8, 104.9), send(7, 105), send(7, 106)])
        notices("cover notices boundary", [send(1, 0), send(1, 4.99), send(1, 5.0), send(1, 9.99), send(1, 10.01)])
        notices("cover notices just past", [send(1, 0), send(1, 5.01)])
        notices("cover notices every 0", every: 0, [send(1, 0), send(1, 0)])
        let point: [String: Double] = ["x": 12, "y": 34]
        notices("cover points", [
            ["op": "point", "pid": 7],
            ["op": "reported", "pid": 7, "dismissable": true, "point": point],
            ["op": "point", "pid": 7],
            ["op": "point", "pid": 8],
            ["op": "reported", "pid": 7, "dismissable": false, "point": point],
            ["op": "point", "pid": 7],
            ["op": "reported", "pid": 7, "dismissable": true, "point": point],
            ["op": "forget", "pid": 7],
            ["op": "point", "pid": 7],
        ])

        let ids: [String?] = ["com.apple.SecurityAgent", "com.apple.loginwindow", "com.apple.coreservices.uiagent",
                              "com.apple.UserNotificationCenter", "com.apple.LocalAuthentication.UIAgent",
                              "com.apple.accessibility.universalAccessAuthWarn", "com.apple.CoreAuthUI",
                              "com.apple.ScreenSaver.Engine", "com.apple.notificationcenterui", "com.example.PasswordHelper",
                              "com.example.keychainthing", "com.example.LoginItem", "com.example.permissions",
                              "com.example.Privacy", "com.example.authority", "com.apple.Safari", "com.apple.dock", nil, ""]
        for id in ids {
            for regular in [true, false] {
                cases.append(Self.c("dismissable \(id ?? "nil") \(regular)",
                                    ["fn": "cover_dismissable", "bundle_id": F.opt(id), "regular": regular],
                                    coverDismissable(bundleID: id, regular: regular)))
            }
        }

        func opened(_ name: String, bundle: String? = "com.apple.Safari", pid: Int32 = 30, regular: Bool = true,
                    since: TimeInterval? = 0.5) {
            cases.append(Self.c("opened \(name)", [
                "fn": "app_opened_worth_telling", "bundle_id": F.opt(bundle), "pid": Int(pid), "regular": regular,
                "session_pid": 10, "own_pid": 20, "since_input": F.opt(since),
            ], appOpenedWorthTelling(bundleID: bundle, pid: pid, regular: regular, sessionPID: 10, ownPID: 20,
                                     sinceInput: since)))
        }
        opened("default")
        opened("since 0", since: 0)
        opened("since 2", since: 2)
        opened("since 2.1", since: 2.1)
        opened("since nil", since: nil)
        opened("since -1", since: -1)
        opened("session pid", pid: 10)
        opened("own pid", pid: 20)
        opened("not regular", regular: false)
        opened("nil bundle", bundle: nil)
        opened("empty bundle", bundle: "")
        for id in ["com.rapp.rapp", "com.apple.dock", "com.apple.loginwindow", "com.apple.systemuiserver",
                   "com.apple.SecurityAgent", "com.apple.notificationcenterui", "com.apple.controlcenter",
                   "com.apple.Spotlight", "com.apple.coreservices.uiagent", "com.apple.WindowManager", "com.apple.finder"] {
            opened(id, bundle: id)
        }

        for (role, subrole) in [("AXTextField", "AXSecureTextField"), ("AXTextField", nil), ("AXTextArea", "AXSearchField"),
                                (nil, "AXSecureTextField"), (nil, nil), ("AXTextField", "axsecuretextfield")] as [(String?, String?)] {
            cases.append(Self.c("secure \(role ?? "nil") \(subrole ?? "nil")",
                                ["fn": "is_secure_field", "role": F.opt(role), "subrole": F.opt(subrole)],
                                isSecureField(role: role, subrole: subrole)))
        }
        F.check("hints.json", F.cases(cases))
    }
}
