import CryptoKit
import Foundation
import XCTest
@testable import RappCore

/// App-state rules for `rust/host-core/tests/state_rules.rs`. One test method writes all six
/// files, so the image list in `rule-image.bin` comes out in the same order every run.
///
/// Images (`rule-image.bin`) are listed once and referred to by index. Each image is two records:
/// - tag 4: the recipe as sorted JSON (`{"canvas": "chatWindow", …}`, see `render`; `"raw"` for
///   pixels that have no recipe). Rust draws the recipe with its port of `RuleCanvas.swift`.
/// - tag 1: `u16 width, u16 height`, BGRA, for images of at most `fullLimit` bytes; or
///   tag 3: `u16 width, u16 height`, the SHA-256 of the BGRA bytes, for bigger ones (an 800x600
///   window is 1.9 MB; storing every frame would make the file tens of megabytes).
/// After the images, tag 2 records hold the outputs of `RuleImage.sample` (`u16 w, u16 h`, BGRA),
/// referred to by index from `rule-regions.json`.
///
/// Numbers that JSON cannot carry are strings: `"nan"`, `"inf"`, `"-inf"`. Packs are JSON text
/// with sorted keys. Encodings of decoded values (`pack`, `region`, `signal`, `cond`, `row`,
/// `report`) are mirrored in the Rust test.
///
/// - `rule-pack.json`: `merge {base, patch}`, `decode {text}` (parse with the size check, then
///   decode; out `{"ok": pack}` or `{"error"}`), `named {name}`, `hue_contains {color, hue}`.
/// - `rule-regions.json`: `resolve {pack, image}`, `sample {src, width, height, bytesPerRow, crop,
///   scale, trim}`.
/// - `rule-detectors.json`: `shape`, `foreground_color`, `contains`, `hsl`, `distance`,
///   `text_matches`, and `evaluate` traces of a `SignalEvaluator` (a `FakeReader` when `reader`
///   is set; `ready` before a step sets the reader's flag).
/// - `state-table.json`: `step` traces, `holds`, `signals_in`.
/// - `state-engine.json`: `engine` traces (every scenario with `os` `macos` and `windows`),
///   `report_json`, `invalid`, `compare_versions`.
///
/// Covers every scenario of RulePackTests, RuleRegionTests, RuleDetectTests, StateTableTests and
/// StateEngineTests (the tick-cost one without its timing), plus the plan's extras: packs of
/// exactly 65536 and 65537 bytes, malformed JSON, an `os` condition that excludes the platform,
/// a text reader in the engine and caps without `text`, `compareVersions` edge cases, and
/// reports above the 4096-byte wire limit.
final class StateRuleFixtures: XCTestCase {
    private typealias F = HostFixture

    static let fullLimit = 128 * 128 * 4

    // MARK: - Images

    private final class Images {
        var recipes: [[String: Any]] = []
        var keys: [String: Int] = [:]
        var images: [RuleImage] = []
        var samples: [RuleImage] = []

        func add(_ recipe: [String: Any]) -> Int {
            let key = StateRuleFixtures.text(recipe)
            if let i = keys[key] { return i }
            keys[key] = images.count
            recipes.append(recipe)
            images.append(StateRuleFixtures.render(recipe))
            return images.count - 1
        }

        func raw(_ img: RuleImage) -> Int {
            recipes.append(["canvas": "raw"])
            images.append(img)
            return images.count - 1
        }

        func sample(_ img: RuleImage) -> Int {
            samples.append(img)
            return samples.count - 1
        }

        func bytes() -> [UInt8] {
            var recs: [(tag: UInt8, payload: [UInt8])] = []
            for (i, img) in images.enumerated() {
                recs.append((4, Array(StateRuleFixtures.text(recipes[i]).utf8)))
                let head = F.u16(UInt16(img.width)) + F.u16(UInt16(img.height))
                if img.pixels.count <= StateRuleFixtures.fullLimit {
                    recs.append((1, head + img.pixels))
                } else {
                    recs.append((3, head + Array(SHA256.hash(data: Data(img.pixels)))))
                }
            }
            for s in samples { recs.append((2, F.u16(UInt16(s.width)) + F.u16(UInt16(s.height)) + s.pixels)) }
            return F.records(recs)
        }
    }

    private let images = Images()

    private static func rgb(_ a: Any) -> Canvas.RGB {
        let v = a as! [Int]
        return (UInt8(v[0]), UInt8(v[1]), UInt8(v[2]))
    }

    private static func icon(_ s: String) -> Canvas.Icon {
        switch s {
        case "square": return .square
        case "arrow": return .arrow
        default: return .none
        }
    }

    /// Draws a recipe with `RuleCanvas.swift`, then its `ops` in order.
    static func render(_ r: [String: Any]) -> RuleImage {
        var img: RuleImage
        switch r["canvas"] as! String {
        case "solid":
            img = Canvas.solid(width: r["width"] as! Int, height: r["height"] as! Int, r["color"].map(rgb) ?? Canvas.white)
        case "chatWindow":
            img = Canvas.chatWindow(
                width: r["width"] as? Int ?? 800, height: r["height"] as? Int ?? 600,
                sidebar: r["sidebar"] as? Bool ?? true, dark: r["dark"] as? Bool ?? false,
                dots: (r["dots"] as? [String]).map { $0.map { $0 == "green" ? Canvas.Dot.green : Canvas.Dot.gray } },
                spinnerPhase: r["spinnerPhase"] as? Int ?? 0, tailText: r["tailText"] as? Bool ?? false,
                button: icon(r["button"] as? String ?? "square"))
        case "button": img = Canvas.button(icon: icon(r["icon"] as! String))
        case "bareSquare": img = Canvas.bareSquare()
        case "ring": img = Canvas.ring()
        case "dot": img = Canvas.dot(color: rgb(r["color"]!), on: rgb(r["on"]!))
        case "broken": img = RuleImage(width: r["width"] as! Int, height: r["height"] as! Int, pixels: [])
        default: fatalError("unknown canvas \(r)")
        }
        for op in r["ops"] as? [[String: Any]] ?? [] {
            let c = rgb(op["color"]!)
            switch op["op"] as! String {
            case "fill":
                let q = op["rect"] as! [Int]
                Canvas.fill(&img, RuleRect(x: q[0], y: q[1], w: q[2], h: q[3]), c)
            case "disc":
                Canvas.disc(&img, x: op["x"] as! Int, y: op["y"] as! Int, size: op["size"] as! Int, c)
            case "ring":
                Canvas.ring(&img, x: op["x"] as! Int, y: op["y"] as! Int, size: op["size"] as! Int,
                            thickness: op["thickness"] as! Int, c, hole: rgb(op["hole"]!))
            default: fatalError("unknown op \(op)")
            }
        }
        return img
    }

    private func chat(width: Int = 800, height: Int = 600, sidebar: Bool = true, dark: Bool = false,
                      dots: [String]? = nil, spinnerPhase: Int = 0, tailText: Bool = false,
                      button: String = "square") -> Int {
        var r: [String: Any] = ["canvas": "chatWindow", "width": width, "height": height, "sidebar": sidebar,
                                "dark": dark, "spinnerPhase": spinnerPhase, "tailText": tailText, "button": button]
        if let dots { r["dots"] = dots }
        return images.add(r)
    }

    private func solid(_ width: Int, _ height: Int, _ color: [Int] = [255, 255, 255], ops: [[String: Any]] = []) -> Int {
        images.add(["canvas": "solid", "width": width, "height": height, "color": color, "ops": ops])
    }

    private static func fillOp(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ c: [Int]) -> [String: Any] {
        ["op": "fill", "rect": [x, y, w, h], "color": c]
    }

    private static func discOp(_ x: Int, _ y: Int, _ size: Int, _ c: [Int]) -> [String: Any] {
        ["op": "disc", "x": x, "y": y, "size": size, "color": c]
    }

    // MARK: - Encodings

    static func num(_ v: Double) -> Any {
        if v.isNaN { return "nan" }
        if v == .infinity { return "inf" }
        if v == -.infinity { return "-inf" }
        return v
    }

    /// Sorted-key JSON text.
    static func text(_ o: Any) -> String {
        let d = try! JSONSerialization.data(withJSONObject: o, options: [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed])
        return String(decoding: d, as: UTF8.self)
    }

    private static func parsed(_ s: String) -> Any { try! JSONSerialization.jsonObject(with: Data(s.utf8)) }

    private static func c(_ name: String, _ input: [String: Any], _ out: Any) -> [String: Any] {
        ["name": name, "in": input, "out": out]
    }

    private static func rr(_ r: RuleRect) -> [String: Any] { ["x": r.x, "y": r.y, "w": r.w, "h": r.h] }

    static func rv(_ v: RuleValue) -> Any {
        switch v {
        case .null: return NSNull()
        case .bool(let b): return b
        case .number(let n): return num(n)
        case .string(let s): return s
        case .array(let a): return a.map(rv)
        case .object(let o): return o.mapValues(rv)
        }
    }

    private static func len(_ l: Length?) -> Any {
        guard let l else { return NSNull() }
        switch l {
        case .points(let v): return ["points": num(v)]
        case .percent(let v): return ["percent": num(v)]
        }
    }

    private static func ref(_ r: RegionRef?) -> Any {
        guard let r else { return NSNull() }
        switch r {
        case .named(let n): return ["named": n]
        case .inline(let s): return ["inline": region(s)]
        }
    }

    private static func range(_ r: ClosedRange<Double>?) -> Any {
        guard let r else { return NSNull() }
        return [num(r.lowerBound), num(r.upperBound)]
    }

    private static func region(_ s: RegionSpec) -> Any {
        switch s {
        case .box(let b):
            return ["box": ["in": ref(b.inside), "rightOf": F.opt(b.rightOf), "leftOf": F.opt(b.leftOf),
                            "above": F.opt(b.above), "below": F.opt(b.below), "top": len(b.top),
                            "bottom": len(b.bottom), "left": len(b.left), "right": len(b.right),
                            "width": len(b.width), "height": len(b.height)] as [String: Any]]
        case .edge(let e):
            return ["edge": ["in": ref(e.inside), "from": e.from.rawValue, "min": num(e.min), "max": num(e.max)] as [String: Any]]
        case .blob(let b):
            return ["blob": ["in": ref(b.inside), "round": b.round, "size": range(b.size), "pick": b.pick.rawValue] as [String: Any]]
        case .strip(let s):
            return ["strip": ["of": ref(s.of), "side": s.side.rawValue, "width": num(s.width)] as [String: Any]]
        case .unknown:
            return "unknown"
        }
    }

    static func color(_ c: ColorRange) -> [String: Any] {
        ["h": range(c.h), "hWraps": c.hWraps, "s": range(c.s), "l": range(c.l)]
    }

    private static func detect(_ d: Detect) -> Any {
        switch d {
        case .shape(let n, let m): return ["shape": ["is": n, "min": num(m)] as [String: Any]]
        case .color(let c): return ["color": color(c)]
        case .motion(let w, let m): return ["motion": ["window": num(w), "min": num(m)]]
        case .text(let t): return ["text": t]
        case .present: return "present"
        }
    }

    private static func signal(_ s: SignalSpec) -> [String: Any] {
        ["region": ref(s.region), "detects": s.detects.map(detect), "count": s.count, "needs": s.needs.sorted(),
         "status": s.status.rawValue, "usable": s.usable]
    }

    static func cond(_ c: Condition) -> Any {
        switch c {
        case .signal(let s): return ["signal": s]
        case .any(let cs): return ["any": cs.map(cond)]
        case .all(let cs): return ["all": cs.map(cond)]
        case .not(let c): return ["not": cond(c)]
        case .never: return "never"
        }
    }

    static func row(_ r: StateRow) -> [String: Any] {
        ["state": r.state, "kind": F.opt(r.kind), "when": r.when.map(cond) ?? NSNull(),
         "hold": num(r.hold), "release": num(r.release)]
    }

    private static func pack(_ p: RulePack) -> [String: Any] {
        ["id": p.id, "name": p.name, "rev": p.rev, "regions": p.regions.mapValues(region),
         "signals": p.signals.mapValues(signal), "states": p.states.map(row), "require": p.require,
         "variants": p.variants.map { ["name": $0.name, "when": rv($0.when), "patch": rv($0.patch)] }]
    }

    static func err(_ e: Error) -> String {
        switch e as? RuleError {
        case .tooLarge?: return "tooLarge"
        case .badJSON?: return "badJSON"
        case .unsupportedFormat(let f)?: return "unsupportedFormat:" + f
        case .notAPack(let w)?: return "notAPack:" + w
        case nil: return "other"
        }
    }

    private static func decoded(_ text: String) -> Any {
        do { return ["ok": pack(try RulePack.decode(try RulePack.parse(Data(text.utf8))))] }
        catch { return ["error": err(error)] }
    }

    private static func hslJSON(_ h: HSL) -> [String: Any] { ["h": num(h.h), "s": num(h.s), "l": num(h.l)] }

    static func report(_ r: AppStateReport) -> [String: Any] {
        ["pack": F.opt(r.pack), "rev": F.opt(r.rev), "state": F.opt(r.state), "kind": F.opt(r.kind), "by": r.by,
         "sure": r.sure, "counts": r.counts, "health": r.health, "variants": r.variants,
         "appVersion": F.opt(r.appVersion), "caps": r.caps, "error": F.opt(r.error)]
    }

    private static func results(_ r: [String: SignalResult]) -> [String: Any] {
        r.mapValues { ["holds": $0.holds, "count": F.opt($0.count)] }
    }

    // MARK: - Packs

    private static func object(_ json: String) -> [String: Any] {
        try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
    }

    private static func fragment(_ s: String) -> Any {
        try! JSONSerialization.jsonObject(with: Data(s.utf8), options: [.fragmentsAllowed])
    }

    private static var generic: String { text(object(genericChatJSON)) }

    /// `base` merged with `over`, `extends` removed when asked (StateEngineTests' resolved pack).
    private static func merged(_ base: String, _ over: String, dropExtends: Bool) -> String {
        var m = try! RuleValue.parse(Data(base.utf8)).merged(with: try! RuleValue.parse(Data(over.utf8)))
        if dropExtends, case .object(var o) = m { o["extends"] = nil; m = .object(o) }
        return text(rv(m))
    }

    private static var claudeResolved: String { merged(genericChatJSON, claudeDesktopJSON, dropExtends: true) }
    private static var claudeLike: String { merged(genericChatJSON, claudeDesktopJSON, dropExtends: false) }

    /// StateEngineTests' `pack(…)`: §6.1 with keys replaced, written with sorted keys.
    private static func pack(require: [String]? = nil, signals: String? = nil, states: String? = nil,
                             variants: String? = nil) -> String {
        var o = object(genericChatJSON)
        if let require { o["require"] = require }
        if let signals { o["signals"] = fragment(signals) }
        if let states { o["states"] = fragment(states) }
        if let variants { o["variants"] = fragment(variants) }
        return text(o)
    }

    /// §6.1 padded with a `pad` string to exactly `bytes` bytes.
    private static func padded(_ bytes: Int) -> String {
        var o = object(genericChatJSON)
        o["pad"] = ""
        let n = bytes - text(o).utf8.count
        o["pad"] = String(repeating: "x", count: n)
        let s = text(o)
        precondition(s.utf8.count == bytes)
        return s
    }

    /// The GUI's pack file with `extends` resolved the way RulePackTests does it.
    private static func shippedPacks() -> [(id: String, text: String)] {
        let url = F.root.appendingPathComponent("gui/assets/state_rules.json")
        let root = try! RuleValue.parse(try! Data(contentsOf: url))
        let packs = root["packs"]?.arrayValue ?? []
        var byId: [String: RuleValue] = [:]
        for p in packs { if let id = p["id"]?.stringValue { byId[id] = p } }
        func resolved(_ id: String, depth: Int = 0) -> RuleValue {
            let p = byId[id]!
            precondition(depth < 8)
            guard let base = p["extends"]?.stringValue else { return p }
            var child = p.objectValue!
            child["extends"] = nil
            return resolved(base, depth: depth + 1).merged(with: .object(child))
        }
        return byId.keys.sorted().map { ($0, text(rv(resolved($0)))) }
    }

    // MARK: - rule-pack.json

    private func packCases() -> [[String: Any]] {
        typealias S = StateRuleFixtures
        var out: [[String: Any]] = []
        let merges: [(String, String, String)] = [
            ("test", #"{"a":{"x":1,"y":2},"b":[1,2],"c":3}"#, #"{"a":{"y":null,"z":4},"b":[9],"d":{"e":null,"f":1}}"#),
            ("scalar patch replaces", #"{"k":{"a":1}}"#, #"{"k":7}"#),
            ("object onto scalar strips nulls", #"{"k":3}"#, #"{"k":{"a":null,"b":{"c":null,"d":1}}}"#),
            ("empty patch keeps", #"{"a":[1,{"b":2}],"c":"x"}"#, #"{}"#),
            ("null deletes, missing stays", #"{"a":1,"b":2}"#, #"{"a":null,"z":null}"#),
            ("arrays replace whole", #"{"a":[{"x":1},{"y":2}]}"#, #"{"a":[{"x":null}]}"#),
        ]
        for (name, base, patch) in merges {
            let m = try! RuleValue.parse(Data(base.utf8)).merged(with: try! RuleValue.parse(Data(patch.utf8)))
            out.append(S.c("merge " + name, ["fn": "merge", "base": base, "patch": patch], S.rv(m)))
        }

        var texts: [(String, String)] = [
            ("genericChat", genericChatJSON), ("chatgptDesktop", chatgptDesktopJSON),
            ("claudeDesktop", claudeDesktopJSON), ("antigravityApp", antigravityAppJSON),
            ("claude resolved", S.claudeResolved), ("claude like", S.claudeLike),
            ("chatgpt resolved", S.merged(genericChatJSON, chatgptDesktopJSON, dropExtends: true)),
        ]
        for rev in ["0", "2147483647", "2147483648", "-1", "1.5", "1e30", "\"7\"", "-1e30", "1e308", "2.9", "true", "null"] {
            texts.append(("rev " + rev, #"{"format":"1.0","id":"x","rev":\#(rev)}"#))
        }
        texts += [
            ("rev missing", #"{"format":"1.0","id":"x"}"#),
            ("forward compatibility", #"""
            {"format":"1.7","id":"x","rev":2,"future":true,
             "regions":{"a":{"box":{"top":0}},"b":{"hexagon":{}}},
             "signals":{"s1":{"in":"a","detect":{"present":true}},"s2":{"in":"a","detect":{"smell":"rose"}},
                        "s3":{"in":"b","detect":{"present":true}}},
             "states":[{"state":"working","when":{"any":["s1"]}},{"state":"sleeping","when":{"any":["s1"]}},{"state":"idle"}]}
            """#),
            ("format 2.0", #"{"format":"2.0","id":"x"}"#),
            ("long format", #"{"format":"9.9-名名名名名名名名名名名名名名名名名名名名名名名名名名名名名名名名名名","id":"x"}"#),
            ("no id", #"{"format":"1.0"}"#),
            ("no format", #"{"id":"x"}"#),
            ("id not a string", #"{"format":"1.0","id":7}"#),
            ("format not a string", #"{"format":1.0,"id":"x"}"#),
            ("malformed", "{"),
            ("truncated", #"{"format":"1.0","id":"#),
            ("top level array", "[]"),
            ("top level string", "\"x\""),
            ("empty", ""),
            ("detect forms", #"""
            {"format":"1.0","id":"x","regions":{"r":{"box":{"left":"10%","width":30}}},
             "signals":{"a":{"in":"r","detect":{"shape":{"is":"dot","min":0.7},"color":{"h":[340,20],"l":[35,70]}}},
                        "b":{"in":"r","detect":{"motion":{"window":0.4}},"status":"seen"},
                        "c":{"in":"r","detect":{"text":["Worked for*"]},"needs":["text"],"status":"tested"},
                        "d":{"in":"r","detect":{"color":"green"}}}}
            """#),
            ("condition forms", #"""
            {"format":"1.0","id":"x","states":[
              {"state":"blocked","kind":"permission","when":{"all":["a",{"not":"b"}]}},
              {"state":"done","when":{"weird":1}},{"state":"idle"}]}
            """#),
            ("variants and bad colour", #"""
            {"format":"1.0","id":"x","signals":{"u":{"in":"r","detect":{"color":"nonesuch"}}},
             "variants":[{"name":"dark","when":{"theme":"dark"},"patch":{"a":1}},{"when":{"os":"macos"},"patch":{}}]}
            """#),
            ("huge numbers", #"""
            {"format":"1.0","id":"x","rev":1,
             "regions":{"e":{"edge":{"from":"left","min":-1e30,"max":1e308}},
                        "b":{"box":{"top":1e30,"width":"1e30%"}},
                        "s":{"strip":{"of":"e","side":"left","width":1e308}},
                        "o":{"blob":{"in":"e","size":[-1e30,1e30]}}},
             "signals":{"a":{"in":"b","detect":{"motion":{"window":1e30,"min":-1e30},"color":{"h":[1e30,-1e30]}}}},
             "states":[{"state":"working","hold":1e30,"release":-1e308}]}
            """#),
            ("missing region nan motion", #"""
            {"format":"1.0","id":"t","regions":{"a":{"box":{"left":0,"top":0,"width":10,"height":10}}},
             "signals":{"here":{"in":"a","detect":{"present":true}},
                        "gone":{"in":"zzz","detect":{"present":true},"count":true},
                        "noIn":{"detect":{"present":true}},
                        "bad":{"in":"a","detect":{"wat":1}},
                        "nan":{"in":"a","detect":{"motion":{"window":0.4,"min":null}}}}}
            """#),
        ]
        for (i, json) in [#"{"not":{"bogus":1}}"#, #"{"any":[{"bogus":1},"a"]}"#, #"{"all":["a",{"not":{"all":[]}}]}"#,
                          #"{"any":["a",{"not":"b"}]}"#, #""a""#, #"7"#, #"{"any":"a"}"#, #"{"all":[]}"#,
                          #"{"any":[]}"#, #"{"not":["a"]}"#, #"{"any":["a"],"all":["b"]}"#].enumerated() {
            texts.append(("condition \(i) \(json)", #"{"format":"1.0","id":"x","states":[{"state":"done","when":\#(json)}]}"#))
        }
        for (id, t) in S.shippedPacks() { texts.append(("shipped " + id, t)) }
        texts.append(("65536 bytes", S.padded(ruleBytesLimit)))
        texts.append(("65537 bytes", S.padded(ruleBytesLimit + 1)))
        texts.append(("65536 spaces", String(repeating: " ", count: ruleBytesLimit)))
        texts.append(("65537 spaces", String(repeating: " ", count: ruleBytesLimit + 1)))
        for (name, t) in texts { out.append(S.c("decode " + name, ["fn": "decode", "text": t], S.decoded(t))) }

        for name in ["green", "red", "orange", "blue", "gray", "grey", "chartreuse", "", "Green"] {
            out.append(S.c("named " + name, ["fn": "named", "name": name], ColorRange.named(name).map(S.color) ?? NSNull()))
        }
        let wrap = ColorRange(h: 20...340, hWraps: true)
        let plain = ColorRange(h: 90...170)
        for (cname, cr) in [("wrap", wrap), ("plain", plain), ("none", ColorRange())] {
            for hue in [0.0, 10, 20, 21, 90, 170, 180, 339.9, 340, 350, .nan] {
                out.append(S.c("hue \(cname) \(hue)", ["fn": "hue_contains", "color": S.color(cr), "hue": S.num(hue)],
                               cr.hueContains(hue)))
            }
        }
        return out
    }

    // MARK: - rule-regions.json

    private func regionCases() -> [[String: Any]] {
        typealias S = StateRuleFixtures
        var out: [[String: Any]] = []
        func resolve(_ name: String, _ text: String, _ image: Int) {
            let p = try! RulePack.decode(try! RuleValue.parse(Data(text.utf8)))
            let r = resolveRegions(p, in: images.images[image]).mapValues { $0.map(S.rr) }
            out.append(S.c("resolve " + name, ["fn": "resolve", "pack": text, "image": image], r))
        }
        func local(_ regions: String) -> String { #"{"format":"1.0","id":"t","regions":\#(regions)}"# }

        resolve("generic chat window", S.generic, chat())
        resolve("generic no sidebar", S.generic, chat(sidebar: false))
        resolve("generic dark narrow", S.generic, chat(width: 400, dark: true))
        resolve("generic 1600x1000", S.generic, chat(width: 1600, height: 1000))
        resolve("generic dots", S.generic, chat(dots: ["green", "gray", "gray"]))
        resolve("generic no dots", S.generic, chat(dots: []))
        resolve("generic tail text", S.generic, chat(dots: [], tailText: true))
        resolve("generic arrow", S.generic, chat(button: "arrow"))
        resolve("generic no button", S.generic, chat(button: "none"))
        resolve("generic dark spinner", S.generic, chat(dark: true, spinnerPhase: 1))
        // Smallest window `Canvas.chatWindow` draws without an inverted range (it traps on those).
        resolve("generic small", S.generic, chat(width: 360, height: 560))
        resolve("claude dots", S.claudeResolved, chat(dots: ["green", "gray", "gray"]))
        resolve("generic solid", S.generic, solid(400, 300))

        resolve("box lengths and anchors", local(#"""
        {"a":{"box":{"left":"25%","width":"50%"}},
         "b":{"box":{"left":10,"right":10,"top":10,"bottom":10}},
         "c":{"box":{"in":"b","bottom":0,"height":100}},
         "d":{"box":{"in":"b","above":"c","height":50}},
         "e":{"box":{"in":"nowhere"}},
         "f":{"box":{"in":"d"}},
         "loop1":{"box":{"in":"loop2"}},"loop2":{"box":{"in":"loop1"}}}
        """#), solid(400, 300))

        let gray = [200, 200, 200], dim = [100, 100, 100]
        resolve("edge from every direction", local(#"""
        {"l":{"edge":{"from":"left","min":10,"max":300}},
         "r":{"edge":{"from":"right","min":10,"max":300}},
         "b":{"edge":{"from":"bottom","min":0,"max":200}},
         "t":{"edge":{"from":"top","min":0,"max":200}},
         "none":{"edge":{"from":"left","min":150,"max":300}},
         "inverted":{"edge":{"from":"left","min":300,"max":10}}}
        """#), solid(400, 300, ops: [S.fillOp(0, 0, 100, 300, gray), S.fillOp(350, 0, 50, 300, gray),
                                     S.fillOp(0, 250, 400, 50, dim)]))

        let black = [0, 0, 0]
        resolve("blob picks", local(#"""
        {"all":{"blob":{"in":{"box":{}},"size":[5,50],"pick":"all"}},
         "right":{"blob":{"in":{"box":{}},"size":[5,50],"pick":"rightmost"}},
         "left":{"blob":{"in":{"box":{}},"size":[5,50],"pick":"leftmost"}},
         "top":{"blob":{"in":{"box":{}},"size":[5,50],"pick":"topmost"}},
         "bottom":{"blob":{"in":{"box":{}},"size":[5,50],"pick":"bottommost"}},
         "big":{"blob":{"in":{"box":{}},"size":[5,50],"pick":"largest"}},
         "round":{"blob":{"in":{"box":{}},"round":true,"size":[5,50],"pick":"all"}},
         "huge":{"blob":{"in":{"box":{}},"size":[60,90]}}}
        """#), solid(200, 100, ops: [S.fillOp(10, 10, 20, 20, black), S.discOp(60, 40, 24, black),
                                     S.fillOp(120, 60, 40, 10, black), S.fillOp(190, 90, 2, 2, black)]))

        resolve("strip of a region", local(#"""
        {"a":{"box":{"left":100,"width":200}},
         "right":{"strip":{"of":"a","side":"right","width":40}},
         "left":{"strip":{"of":"a","side":"left","width":40}},
         "top":{"strip":{"of":"a","side":"top","width":10}},
         "bottom":{"strip":{"of":"a","side":"bottom","width":10}},
         "wide":{"strip":{"of":"a","side":"left","width":999}}}
        """#), solid(400, 300))

        resolve("absurd numbers", local(#"""
        {"a":{"box":{"left":1e308,"width":1e308}},
         "b":{"box":{"left":-1e308,"right":-1e308}},
         "c":{"box":{"top":-1e308,"height":1e308}},
         "d":{"box":{"left":"1e308%","width":"-1e308%"}},
         "e":{"box":{"left":50,"right":400}},
         "f":{"edge":{"from":"left","min":1e308,"max":1e308}},
         "g":{"edge":{"from":"top","min":-1e308,"max":1e308}},
         "h":{"edge":{"from":"left","min":50,"max":10}},
         "i":{"strip":{"of":{"box":{}},"side":"left","width":1e308}},
         "j":{"strip":{"of":{"box":{}},"side":"left","width":-5}},
         "k":{"blob":{"in":"a","size":[-1e308,1e308]}}}
        """#), solid(100, 100))

        let cycles = [
            #"{"a":{"box":{"rightOf":"b"}},"b":{"box":{"rightOf":"a"}}}"#,
            #"{"b":{"box":{"rightOf":"a"}},"a":{"box":{"rightOf":"b"}},"0dep":{"box":{"rightOf":"a"}}}"#,
            #"{"x":{"box":{"rightOf":"z"}},"y":{"box":{"below":"x"}},"z":{"box":{"leftOf":"y"}}}"#,
            #"{"z":{"box":{"rightOf":"y"}},"y":{"box":{"below":"x"}},"x":{"box":{"leftOf":"z"}},"0in":{"box":{"in":"y"}}}"#,
        ]
        for (i, json) in cycles.enumerated() {
            resolve("cycle \(i)", local(String(json.dropLast()) + #","ok":{"box":{"left":10,"width":20}}}"#), solid(100, 100))
        }
        resolve("relations both sides", local(#"""
        {"l":{"box":{"width":100}},"r":{"box":{"left":300}},
         "mid":{"box":{"rightOf":"l","leftOf":"r"}},"top":{"box":{"height":50}},
         "under":{"box":{"below":"top","above":"foot"}},"foot":{"box":{"bottom":0,"height":40}},
         "inline":{"box":{"in":{"box":{"left":"10%","right":"10%"}},"top":"50%"}}}
        """#), solid(400, 300))

        // RuleImage.sample
        let src4: [UInt8] = [1, 0, 0, 255, 2, 0, 0, 255, 3, 0, 0, 255, 4, 0, 0, 255,
                             5, 0, 0, 255, 6, 0, 0, 255, 7, 0, 0, 255, 8, 0, 0, 255]
        let s4 = images.raw(RuleImage(width: 4, height: 2, pixels: src4))
        var rng = HostRNG(seed: 12)
        let s40 = images.raw(RuleImage(width: 42, height: 30, pixels: rng.bytes(42 * 30 * 4)))
        func sample(_ name: String, _ src: Int, _ width: Int, _ height: Int, _ bpr: Int, _ crop: RuleRect,
                    _ scale: Double, trim: Int = 0) {
            let bytes = Array(images.images[src].pixels.dropLast(trim))
            let img = bytes.withUnsafeBytes {
                RuleImage.sample(bgra: $0, width: width, height: height, bytesPerRow: bpr, crop: crop, scale: scale)
            }
            let o: Any = img.map { ["image": images.sample($0), "width": $0.width, "height": $0.height] } ?? NSNull()
            out.append(S.c("sample " + name, ["fn": "sample", "src": src, "width": width, "height": height,
                                              "bytesPerRow": bpr, "crop": S.rr(crop), "scale": S.num(scale),
                                              "trim": trim], o))
        }
        sample("test 2x", s4, 4, 2, 16, RuleRect(x: 0, y: 0, w: 4, h: 2), 2)
        sample("test leaves", s4, 4, 2, 16, RuleRect(x: 3, y: 0, w: 4, h: 2), 2)
        for bad in [0.0, -1, .nan, .infinity, 1e-320] {
            sample("test scale \(bad)", s4, 4, 2, 16, RuleRect(x: 0, y: 0, w: 4, h: 2), bad)
        }
        let full = RuleRect(x: 0, y: 0, w: 40, h: 30)
        for scale in [1.0, 1.5, 2, 3.7, 0.5, 100, 1e300] { sample("padded \(scale)", s40, 40, 30, 168, full, scale) }
        sample("crop 1.5", s40, 40, 30, 168, RuleRect(x: 3, y: 5, w: 30, h: 20), 1.5)
        sample("crop edge", s40, 40, 30, 168, RuleRect(x: 39, y: 29, w: 1, h: 1), 1)
        sample("crop negative", s40, 40, 30, 168, RuleRect(x: -1, y: 0, w: 10, h: 10), 1)
        sample("crop empty", s40, 40, 30, 168, RuleRect(x: 0, y: 0, w: 0, h: 10), 1)
        sample("crop too wide", s40, 40, 30, 168, RuleRect(x: 1, y: 0, w: 40, h: 30), 1)
        sample("row too short", s40, 40, 30, 159, full, 1)
        sample("zero width", s40, 0, 30, 168, full, 1)
        sample("trim 8", s40, 40, 30, 168, full, 2, trim: 8)
        sample("trim 9", s40, 40, 30, 168, full, 2, trim: 9)
        return out
    }

    // MARK: - rule-detectors.json

    private func detectorCases() -> [[String: Any]] {
        typealias S = StateRuleFixtures
        var out: [[String: Any]] = []
        let buttonRect = Canvas.buttonRect
        func shapeCase(_ name: String, _ image: Int, _ rect: RuleRect) {
            let s = shape(in: images.images[image], rect: rect)
            out.append(S.c("shape " + name, ["fn": "shape", "image": image, "rect": S.rr(rect)],
                           ["name": s.name.rawValue, "score": S.num(s.score)]))
        }
        shapeCase("square", images.add(["canvas": "button", "icon": "square"]), buttonRect)
        shapeCase("arrow", images.add(["canvas": "button", "icon": "arrow"]), buttonRect)
        shapeCase("none is a dot", images.add(["canvas": "button", "icon": "none"]), buttonRect)
        shapeCase("bare square", images.add(["canvas": "bareSquare"]), buttonRect)
        shapeCase("ring", images.add(["canvas": "ring"]), buttonRect)
        shapeCase("blank", solid(64, 64), RuleRect(x: 8, y: 8, w: 32, h: 32))
        shapeCase("leaves the image", solid(10, 10), RuleRect(x: 5, y: 5, w: 1000, h: 4))
        shapeCase("empty rect", solid(10, 10), RuleRect(x: 0, y: 0, w: 0, h: 4))
        shapeCase("negative origin", solid(10, 10), RuleRect(x: -5, y: -5, w: 8, h: 8))
        shapeCase("wide bar", solid(64, 64, ops: [S.fillOp(8, 20, 48, 8, [0, 0, 0])]), RuleRect(x: 8, y: 20, w: 48, h: 8))
        let disc32 = S.discOp(16, 16, 32, [0, 0, 0])
        shapeCase("big square", solid(64, 64, ops: [disc32, S.fillOp(24, 24, 16, 16, [255, 255, 255])]), buttonRect)
        var arrowOps: [[String: Any]] = [disc32, S.fillOp(30, 24, 4, 16, [255, 255, 255])]
        for row in 0..<8 { arrowOps.append(S.fillOp(32 - (row + 1), 24 + row, 2 * (row + 1), 1, [255, 255, 255])) }
        shapeCase("big arrow", solid(64, 64, ops: arrowOps), buttonRect)
        shapeCase("thin ring", solid(64, 64, ops: [["op": "ring", "x": 16, "y": 16, "size": 32, "thickness": 4,
                                                    "color": [0, 0, 0], "hole": [255, 255, 255]]]), buttonRect)
        shapeCase("window square", chat(), RuleRect(x: 740, y: 520, w: 32, h: 32))
        shapeCase("window arrow", chat(button: "arrow"), RuleRect(x: 740, y: 520, w: 32, h: 32))
        shapeCase("window dark square", chat(dark: true), RuleRect(x: 740, y: 520, w: 32, h: 32))
        shapeCase("window marker", chat(dots: ["green", "gray", "gray"]), RuleRect(x: 210, y: 100, w: 12, h: 12))
        shapeCase("plain dot", images.add(["canvas": "dot", "color": [0, 0, 0], "on": [255, 255, 255]]), Canvas.dotRect)

        func fg(_ name: String, _ image: Int, _ rect: RuleRect) {
            let h = foregroundColor(in: images.images[image], rect: rect)
            out.append(S.c("foreground " + name, ["fn": "foreground_color", "image": image, "rect": S.rr(rect)],
                           h.map(S.hslJSON) ?? NSNull()))
        }
        fg("gray dot", images.add(["canvas": "dot", "color": [150, 150, 150], "on": [240, 240, 240]]), Canvas.dotRect)
        fg("green dot", images.add(["canvas": "dot", "color": [52, 199, 89], "on": [255, 255, 255]]), Canvas.dotRect)
        fg("blank", solid(64, 64), Canvas.dotRect)
        fg("empty rect", solid(64, 64), RuleRect(x: 0, y: 0, w: 0, h: 0))
        fg("window marker", chat(dots: ["green", "gray", "gray"]), RuleRect(x: 210, y: 100, w: 12, h: 12))
        fg("window button", chat(), RuleRect(x: 740, y: 520, w: 32, h: 32))

        var rng = HostRNG(seed: 7)
        var colours: [(Int, Int, Int)] = [(255, 0, 0), (0, 255, 0), (0, 0, 255), (128, 128, 128), (52, 199, 89),
                                          (160, 160, 160), (230, 40, 40), (150, 150, 150), (0, 0, 0), (255, 255, 255),
                                          (255, 255, 0), (0, 255, 255), (255, 0, 255), (240, 240, 240)]
        for _ in 0..<24 { colours.append((rng.int(0...255), rng.int(0...255), rng.int(0...255))) }
        for (r, g, b) in colours {
            let h = hsl(r: UInt8(r), g: UInt8(g), b: UInt8(b))
            out.append(S.c("hsl \(r) \(g) \(b)", ["fn": "hsl", "rgb": [r, g, b]], S.hslJSON(h)))
        }
        var pairs: [((Int, Int, Int), (Int, Int, Int))] = [((10, 20, 30), (15, 20, 10)), ((0, 0, 0), (255, 255, 255))]
        for _ in 0..<10 { pairs.append(((rng.int(0...255), rng.int(0...255), rng.int(0...255)),
                                        (rng.int(0...255), rng.int(0...255), rng.int(0...255)))) }
        for (a, b) in pairs {
            let d = colorDistance((UInt8(a.0), UInt8(a.1), UInt8(a.2)), (UInt8(b.0), UInt8(b.1), UInt8(b.2)))
            out.append(S.c("distance \(a) \(b)", ["fn": "distance", "a": [a.0, a.1, a.2], "b": [b.0, b.1, b.2]], d))
        }

        let probes: [(String, HSL)] = [
            ("green dot", hsl(r: 52, g: 199, b: 89)), ("gray 160", hsl(r: 160, g: 160, b: 160)),
            ("red", hsl(r: 230, g: 40, b: 40)), ("orange", hsl(r: 240, g: 140, b: 20)), ("blue", hsl(r: 30, g: 90, b: 230)),
            ("nan", HSL(h: .nan, s: 50, l: 50)), ("edge", HSL(h: 90, s: 25, l: 20)), ("wrap 345", HSL(h: 345, s: 50, l: 50)),
            ("wrap 15", HSL(h: 15, s: 50, l: 50)), ("white", hsl(r: 255, g: 255, b: 255)),
        ]
        for name in ["green", "red", "orange", "blue", "gray"] {
            let cr = ColorRange.named(name)!
            for (pname, h) in probes {
                out.append(S.c("contains \(name) \(pname)", ["fn": "contains", "color": S.color(cr), "hsl": S.hslJSON(h)],
                               cr.contains(h)))
            }
        }

        let texts: [([String], [String])] = [
            (["Worked for*"], ["Worked for 2m 10s"]), (["Worked for*"], ["I worked for you"]), (["Allow"], ["Allow once"]),
            (["Allow"], ["Allowance"]), (["允许"], ["是否允许访问"]), (["allow"], ["ALLOW"]), (["Allow"], ["  (Allow)  "]),
            (["a*b*c"], ["axxbyyc"]), ([""], ["x"]),
            (["*"], ["x"]), (["*"], []), ([], ["x"]), (["Allow"], ["allow,"]), (["a*"], ["ba"]), (["*a"], ["ba"]),
            (["Worked for*"], ["worked for"]), (["é"], ["CAFÉ"]), (["σας"], ["ΣΑΣ"]), (["Deny", "Allow"], ["x", "Deny it"]),
            (["a b"], ["xa by"]), (["a b"], ["x a b y"]), (["拒绝"], ["拒绝"]), (["a*c"], ["abd"]), (["**"], ["q"]),
            (["Allow"], ["Allow\u{301}"]), (["e\u{301}"], ["caf\u{e9}"]), (["Allow"], ["\tAllow\n"]), (["x"], ["x_y"]),
            (["x"], ["x1"]), (["x"], ["1x"]), (["x"], ["名x名"]),
        ]
        for (i, (p, l)) in texts.enumerated() {
            out.append(S.c("text \(i)", ["fn": "text_matches", "patterns": p, "lines": l], textMatches(p, lines: l)))
        }

        // SignalEvaluator traces.
        struct Step { var regions: Any; var image: Int?; var now: Double; var ready: Bool? = nil }
        func trace(_ name: String, pack: [String: Any], decoded p: RulePack, caps: [String], reader: [String]?, _ steps: [Step]) {
            let fake = reader.map { FakeReader(lines: $0) }
            let ev = SignalEvaluator(caps: Set(caps), text: fake)
            var res: [Any] = [], calls: [Int] = []
            for s in steps {
                if let r = s.ready { fake?.ready = r }
                // Rects first: an empty dictionary would also cast to `[String: Int]`.
                let regions: [String: [RuleRect]]
                if let q = s.regions as? [String: [[Int]]] {
                    regions = q.mapValues { $0.map { RuleRect(x: $0[0], y: $0[1], w: $0[2], h: $0[3]) } }
                } else {
                    regions = resolveRegions(p, in: images.images[(s.regions as! [String: Int])["resolve"]!])
                }
                res.append(S.results(ev.evaluate(p, regions: regions, image: s.image.map { images.images[$0] }, now: s.now)))
                calls.append(fake?.calls ?? 0)
            }
            let input: [String: Any] = pack.merging([
                "fn": "evaluate", "caps": caps, "reader": F.opt(reader),
                "steps": steps.map { s -> [String: Any] in
                    let rg: Any = (s.regions as? [String: [[Int]]]).map { ["rects": $0] as Any }
                        ?? (s.regions as! [String: Int])
                    return ["regions": rg, "image": F.opt(s.image), "now": S.num(s.now), "ready": F.opt(s.ready)]
                },
            ]) { a, _ in a }
            out.append(S.c("evaluate " + name, input, ["results": res, "calls": calls]))
        }
        func textPack(_ t: String) -> ([String: Any], RulePack) {
            (["pack": t], try! RulePack.decode(try! RuleValue.parse(Data(t.utf8))))
        }

        let motionText = #"{"format":"1.0","id":"t","signals":{"s":{"in":"a","detect":{"motion":{"window":0.4,"min":0.02}}}}}"#
        let (mIn, mPack) = textPack(motionText)
        let mBuilt = RulePack(id: "t", name: "t", rev: 0, regions: [:],
                              signals: ["s": SignalSpec(region: .named("a"), detects: [.motion(window: 0.4, min: 0.02)])],
                              states: [], require: [], variants: [])
        XCTAssertEqual(mPack, mBuilt, "the motion trace's JSON must decode to RuleDetectTests' pack")
        let white64 = solid(64, 64), black64 = solid(64, 64, [0, 0, 0])
        trace("motion clears on resize", pack: mIn, decoded: mPack, caps: [], reader: nil, [
            Step(regions: ["a": [[0, 0, 20, 20]]], image: white64, now: 0),
            Step(regions: ["a": [[0, 0, 20, 20]]], image: black64, now: 0.5),
            Step(regions: ["a": [[0, 0, 30, 20]]], image: white64, now: 1.0),
            Step(regions: ["a": [[0, 0, 30, 20]]], image: black64, now: 1.5),
            Step(regions: ["a": [[0, 0, 30, 20]]], image: nil, now: 2.0),
            Step(regions: ["a": [[0, 0, 30, 20]]], image: nil, now: 3.1),
            Step(regions: ["a": [[0, 0, 30, 20], [30, 0, 30, 20]]], image: white64, now: 3.5),
            Step(regions: ["a": [[0, 0, 30, 20], [30, 0, 30, 20]]], image: black64, now: 4.0),
        ])

        let (cIn, cPack) = textPack(S.claudeLike)
        let g3 = chat(dots: ["green", "gray", "gray"]), g3s = chat(dots: ["green", "gray", "gray"], spinnerPhase: 1)
        trace("counts motion needs", pack: cIn, decoded: cPack, caps: ["pixels"], reader: nil, [
            Step(regions: ["resolve": g3], image: g3, now: 0),
            Step(regions: ["resolve": g3s], image: g3s, now: 0.5),
            Step(regions: ["resolve": g3s], image: nil, now: 1.0),
            Step(regions: ["resolve": g3s], image: nil, now: 2.5),
        ])
        let a0 = chat(dots: []), b0 = chat(dots: [], tailText: true)
        trace("text throttle", pack: cIn, decoded: cPack, caps: ["pixels", "text"], reader: ["Allow", "Deny"], [
            Step(regions: ["resolve": a0], image: a0, now: 0),
            Step(regions: ["resolve": a0], image: a0, now: 0.5),
            Step(regions: ["resolve": b0], image: b0, now: 1.0),
            Step(regions: ["resolve": b0], image: b0, now: 2.1),
            Step(regions: ["resolve": a0], image: a0, now: 3.0),
            Step(regions: ["resolve": a0], image: a0, now: 4.2),
            Step(regions: ["resolve": a0], image: nil, now: 9.0),
        ])
        trace("text without the cap", pack: cIn, decoded: cPack, caps: ["pixels"], reader: ["Allow"], [
            Step(regions: ["resolve": b0], image: b0, now: 0),
            Step(regions: ["resolve": a0], image: a0, now: 3),
        ])
        trace("text cap without a reader", pack: cIn, decoded: cPack, caps: ["pixels", "text"], reader: nil, [
            Step(regions: ["resolve": b0], image: b0, now: 0),
        ])

        let (twoIn, twoPack) = textPack(#"""
        {"format":"1.0","id":"t","regions":{"a":{"box":{"left":0,"top":0,"width":40,"height":40}}},
         "signals":{"x":{"in":"a","detect":{"text":["Allow"]},"needs":["text"]},
                    "y":{"in":"a","detect":{"text":["Deny"]},"needs":["text"]}}}
        """#)
        let w50 = solid(50, 50)
        trace("two text signals one call", pack: twoIn, decoded: twoPack, caps: ["pixels", "text"], reader: ["Allow"], [
            Step(regions: ["resolve": w50], image: w50, now: 0),
            Step(regions: ["resolve": w50], image: w50, now: 5),
        ])
        let (waitIn, waitPack) = textPack(#"""
        {"format":"1.0","id":"t","regions":{"a":{"box":{"left":0,"top":0,"width":40,"height":40}}},
         "signals":{"x":{"in":"a","detect":{"text":["Allow"]},"needs":["text"]}}}
        """#)
        trace("text waits for the reader", pack: waitIn, decoded: waitPack, caps: ["pixels", "text"], reader: ["Allow"], [
            Step(regions: ["resolve": w50], image: w50, now: 0, ready: false),
            Step(regions: ["resolve": w50], image: w50, now: 0.5, ready: true),
        ])
        let (missIn, missPack) = textPack(#"""
        {"format":"1.0","id":"t","regions":{"a":{"box":{"left":0,"top":0,"width":10,"height":10}}},
         "signals":{"here":{"in":"a","detect":{"present":true}},
                    "gone":{"in":"zzz","detect":{"present":true},"count":true},
                    "noIn":{"detect":{"present":true}},
                    "bad":{"in":"a","detect":{"wat":1}},
                    "nan":{"in":"a","detect":{"motion":{"window":0.4,"min":null}}},
                    "inline":{"in":{"box":{"left":0,"width":5}},"detect":{"present":true},"count":true}}}
        """#)
        trace("missing region unusable present", pack: missIn, decoded: missPack, caps: ["pixels"], reader: nil, [
            Step(regions: ["resolve": w50], image: w50, now: 0),
            Step(regions: ["resolve": w50], image: nil, now: 1),
        ])

        var nanSpec = SignalSpec(region: .named("a"), detects: [.shape("dot", min: .nan), .motion(window: .nan, min: .nan)],
                                 needs: ["pixels"])
        nanSpec.usable = true
        let nanPack = RulePack(id: "t", name: "t", rev: 0,
                               regions: ["a": .box(BoxSpec(left: .points(0), width: .points(12), height: .points(12)))],
                               signals: ["s": nanSpec], states: [], require: [], variants: [])
        let dotImg = images.add(["canvas": "dot", "color": [0, 0, 0], "on": [255, 255, 255]])
        trace("nan thresholds", pack: ["builtin": "nan"], decoded: nanPack, caps: ["pixels"], reader: nil,
              [0.0, 0.5, 1.0].map { Step(regions: ["a": [[26, 26, 12, 12]]], image: dotImg, now: $0) })

        let (gIn, gPack) = textPack(S.generic)
        let ga = chat(button: "arrow"), gb = chat(spinnerPhase: 1, button: "arrow")
        trace("motion false two seconds after the last frame", pack: gIn, decoded: gPack, caps: ["pixels"], reader: nil, [
            Step(regions: ["resolve": ga], image: ga, now: 0),
            Step(regions: ["resolve": gb], image: gb, now: 1),
            Step(regions: [String: [[Int]]](), image: nil, now: 2.5),
            Step(regions: [String: [[Int]]](), image: nil, now: 3.0),
            Step(regions: [String: [[Int]]](), image: nil, now: 3.5),
        ])
        return out
    }

    // MARK: - state-table.json

    private func tableCases() -> [[String: Any]] {
        typealias S = StateRuleFixtures
        var out: [[String: Any]] = []
        let rows = [
            StateRow(state: "blocked", kind: "permission", when: .any([.signal("ask")]), hold: 0, release: 0),
            StateRow(state: "working", kind: nil, when: .any([.signal("stop"), .signal("busy")]), hold: 0.6, release: 2.0),
            StateRow(state: "done", kind: nil, when: .any([.signal("dot")]), hold: 0, release: 0),
            StateRow(state: "idle", kind: nil, when: nil, hold: 0, release: 0),
        ]
        func trace(_ name: String, _ rows: [StateRow], _ steps: [([String], Double)]) {
            var t = StateTable(rows)
            let got: [Any] = steps.map { t.step(on: Set($0.0), now: $0.1).map(S.row) ?? NSNull() }
            out.append(S.c("step " + name, ["fn": "step", "rows": rows.map(S.row),
                                            "steps": steps.map { ["on": $0.0, "now": S.num($0.1)] }], got))
        }
        trace("hold and release", rows, [(["stop"], 0), (["stop"], 0.5), (["stop"], 0.6), ([], 1.0), (["dot"], 2.9), (["dot"], 3.0)])
        trace("flicker", rows, [(["stop"], 0), ([], 0.3), (["stop"], 0.5), (["stop"], 1.1)])
        trace("preempt", rows, [(["stop"], 0), (["stop"], 1), (["stop", "ask"], 1.1), (["stop"], 1.2), ([], 1.3)])
        trace("empty", [], [([], 0), (["a"], 1)])
        trace("no fallback row", [StateRow(state: "working", when: .signal("a"))], [([], 0), (["a"], 1), ([], 1.5)])
        trace("release restarts", rows, [(["stop"], 0), (["stop"], 1), ([], 2), (["stop"], 3), ([], 4), ([], 5.9), ([], 6.0)])
        let odd = [
            StateRow(state: "working", when: .signal("a"), hold: .nan, release: -5),
            StateRow(state: "done", when: .signal("b"), hold: .infinity, release: .infinity),
            StateRow(state: "idle"),
        ]
        trace("odd timings", odd, [(["a"], 0), ([], 1), (["b"], 2), (["b"], 2 + 3600), (["b"], .nan), ([], 4000),
                                   ([], 4000 + 3599), ([], 4000 + 3601), (["a"], .infinity), (["a"], -.infinity)])
        trace("never row", [StateRow(state: "done", when: .never), StateRow(state: "idle")], [(["a"], 0), ([], 1)])
        trace("lower row waits for release", rows, [(["stop"], 0), (["stop"], 0.7), (["dot"], 1), (["dot"], 2.69), (["dot"], 2.7)])

        let conds: [(Condition, [String])] = [
            (.all([.signal("a"), .not(.signal("b"))]), ["a"]), (.all([.signal("a"), .not(.signal("b"))]), ["a", "b"]),
            (.never, ["a"]), (.any([]), ["a"]), (.all([]), []), (.not(.never), []), (.any([.signal("a"), .never]), ["a"]),
            (.signal("名"), ["名"]),
        ]
        for (i, (cnd, on)) in conds.enumerated() {
            out.append(S.c("holds \(i)", ["fn": "holds", "cond": S.cond(cnd), "on": on], holds(cnd, Set(on))))
        }
        for (i, cnd) in [Condition.any([.signal("a"), .not(.signal("b"))]), .never, .all([.signal("z"), .any([.signal("a"), .signal("z")])]),
                         .not(.not(.signal("q")))].enumerated() {
            out.append(S.c("signals in \(i)", ["fn": "signals_in", "cond": S.cond(cnd)], signalsIn(cnd).sorted()))
        }
        return out
    }

    // MARK: - state-engine.json

    private struct Tick { var image: Int?; var visible = true; var now: Double }

    private func engine(_ name: String, _ rules: String, os: String, version: String?, locale: String = "en",
                        caps: [String] = ["pixels"], reread: String? = nil, reader: [String]? = nil,
                        _ ticks: [Tick]) -> [String: Any] {
        typealias S = StateRuleFixtures
        var rereads = 0
        let env = RuleEnv(appVersion: version, os: os, locale: locale, caps: Set(caps),
                          rereadVersion: { rereads += 1; return reread })
        let fake = reader.map { FakeReader(lines: $0) }
        let input: [String: Any] = [
            "fn": "engine", "rules": rules,
            "env": ["appVersion": F.opt(version), "os": os, "locale": locale, "caps": caps, "reread": F.opt(reread)],
            "reader": F.opt(reader),
            "ticks": ticks.map { ["image": F.opt($0.image), "visible": $0.visible, "now": S.num($0.now)] },
        ]
        let e: StateEngine
        do { e = try StateEngine(rules: Data(rules.utf8), env: env, text: fake) }
        catch { return S.c(name, input, ["error": S.err(error)]) }
        var out: [[String: Any]] = []
        for t in ticks {
            let r = e.tick(image: t.image.map { images.images[$0] }, visible: t.visible, now: t.now)
            out.append(["ret": r.map(S.report) ?? NSNull(), "report": S.report(e.report)])
        }
        let j = e.report.json()
        return S.c(name, input, ["ticks": out, "rereads": rereads, "readerCalls": fake?.calls ?? 0,
                                 "json": S.parsed(j), "bytes": j.utf8.count])
    }

    private func engineCases() -> [[String: Any]] {
        typealias S = StateRuleFixtures
        var out: [[String: Any]] = []
        let img = chat(), off = chat(sidebar: false)
        func seq(_ parts: [(Int, Int)], start: Double = 0, visible: Bool = true) -> [Tick] {
            var t = start, ticks: [Tick] = []
            for (image, n) in parts { for _ in 0..<n { ticks.append(Tick(image: image, visible: visible, now: t)); t += 1 } }
            return ticks
        }
        let variantRules = S.pack(variants: #"""
        [{"name":"old","when":{"appVersion":{"max":"1.9"}},"patch":{"signals":{"stop":{"detect":{"shape":"dot"}}}}},
         {"name":"new","when":{"appVersion":{"min":"2.0"}},"patch":{}},
         {"name":"dark","when":{"theme":"dark"},"patch":{}},
         {"name":"zh","when":{"locale":"zh"},"patch":{}},
         {"name":"narrow","when":{"windowWidth":{"max":500}},"patch":{}},
         {"name":"noSide","when":{"missing":["sidebar"]},"patch":{}},
         {"name":"mac","when":{"os":"windows"},"patch":{}},
         {"name":"odd","when":{"moon":"full"},"patch":{}}]
        """#)
        let switchRules = S.pack(require: ["bottom"], variants: #"""
        [{"name":"old","when":{"appVersion":{"max":"1.9"}},"patch":{}},
         {"name":"new","when":{"appVersion":{"min":"2.0"}},"patch":{"regions":{"bottom":{"box":{"in":"nowhere"}}}}}]
        """#)
        let badRules = S.pack(require: ["bottom"], variants: #"[{"name":"v","when":{"appVersion":{"min":"1"}},"patch":{"regions":{"bottom":{"box":{"in":"nowhere"}}}}}]"#)
        let forceRules = S.pack(require: ["bottom"], variants: #"""
        [{"name":"v1","when":{"appVersion":{"max":"1.9"}},"patch":{"regions":{"bottom":{"box":{"in":"nowhere"}}}}},
         {"name":"v2","when":{"appVersion":{"min":"2.0"}},"patch":{}}]
        """#)
        let rereadRules = S.pack(require: ["bottom"], variants: #"""
        [{"name":"v1","when":{"appVersion":{"max":"1.9"}},"patch":{"regions":{"bottom":{"box":{"in":"nowhere"}}}}}]
        """#)
        let stickyRules = S.pack(require: ["sidebar"], variants: #"[{"name":"v1","when":{"appVersion":{"max":"1.9"}},"patch":{}}]"#)
        var sigs: [String] = []
        for i in 0..<40 { sigs.append("\"\(String(repeating: "s", count: 300))\(i)\":{\"in\":\"bottom\",\"detect\":{\"present\":true},\"count\":true}") }
        let names = (0..<40).map { "\"\(String(repeating: "s", count: 300))\($0)\"" }
        let bigRules = S.pack(signals: "{\(sigs.joined(separator: ","))}",
                              states: "[{\"state\":\"working\",\"when\":{\"any\":[\(names.joined(separator: ","))]}},{\"state\":\"idle\"}]")
        let big1 = chat(width: 1600, height: 1000), big2 = chat(width: 1600, height: 1000, spinnerPhase: 1)
        let broken = images.add(["canvas": "broken", "width": 10, "height": 10])
        let tail = chat(dots: [], tailText: true)
        let osRules = S.pack(variants: #"""
        [{"name":"onlyMac","when":{"os":"macos"},"patch":{"signals":{"stop":{"status":"tested"}}}},
         {"name":"onlyWin","when":{"os":"windows"},"patch":{}},
         {"name":"winDark","when":{"os":"windows","theme":"dark"},"patch":{}},
         {"name":"linux","when":{"os":"linux"},"patch":{}}]
        """#)

        for os in ["macos", "windows"] {
            func add(_ name: String, _ rules: String, version: String?, locale: String = "en", caps: [String] = ["pixels"],
                     reread: String? = nil, reader: [String]? = nil, _ ticks: [Tick]) {
                out.append(engine("\(name) [\(os)]", rules, os: os, version: version, locale: locale, caps: caps,
                                  reread: reread, reader: reader, ticks))
            }
            add("claude working then done", S.claudeResolved, version: "7.37095.0", [
                Tick(image: chat(button: "square"), now: 0), Tick(image: nil, now: 0.5), Tick(image: nil, now: 0.7),
                Tick(image: chat(dots: ["green"], button: "arrow"), now: 1), Tick(image: nil, now: 1.2),
                Tick(image: nil, now: 3.0), Tick(image: nil, now: 4.9), Tick(image: nil, now: 5.1),
            ])
            add("motion at one fps", S.generic, version: nil, (0..<8).map { k in
                Tick(image: k % 2 == 0 ? chat(spinnerPhase: (k / 2) % 2, button: "arrow") : nil, now: Double(k) * 0.5)
            })
            add("variants all", variantRules, version: "2.3", locale: "zh-Hans",
                [Tick(image: chat(width: 400, sidebar: false, dark: true), now: 0)])
            add("variants no version", variantRules, version: nil, [Tick(image: img, now: 0)])
            add("variants old version", variantRules, version: "1.5", [Tick(image: img, now: 0)])
            add("variants locale underscore", variantRules, version: "2.0", locale: "ZH_tw", [Tick(image: img, now: 0)])
            add("variants locale prefix only", variantRules, version: "2.0", locale: "zhx", [Tick(image: img, now: 0)])
            add("self check switches", switchRules, version: "2.0", reread: "2.0", seq([(img, 5)]))
            add("self check gives up", badRules, version: "2.0", reread: "2.0", seq([(img, 10)]))
            add("invisible rounds never count", badRules, version: "2.0", seq([(img, 20)], visible: false))
            add("forces the untried variant", forceRules, version: "1.0", reread: "1.0", seq([(img, 5)]))
            add("reread new version", rereadRules, version: "1.0", reread: "3.0", seq([(img, 15)]))
            add("unfit recovers", S.pack(require: ["sidebar"]), version: "2.0", reread: "2.0",
                seq([(off, 5), (img, 4), (off, 1), (img, 4), (img, 1), (off, 5)]))
            add("switched is sticky", stickyRules, version: "1.0", reread: "3.0", seq([(off, 5), (off, 10), (img, 5), (off, 5)]))
            add("patch breaks", S.pack(variants: #"""
            [{"name":"good","when":{},"patch":{}},
             {"name":"breaks","when":{},"patch":{"id":null}},
             {"name":"scalar","when":{},"patch":7}]
            """#), version: nil, [Tick(image: img, now: 0)])
            add("sure only for tested", S.pack(signals: #"{"ask":{"in":"tail","detect":{"present":true},"status":"tested"}}"#,
                                               states: #"[{"state":"blocked","kind":"permission","when":{"any":["ask"]}},{"state":"idle"}]"#),
                version: nil, [Tick(image: img, now: 0)])
            add("report over the limit", bigRules, version: nil, [Tick(image: img, now: 0)])
            add("non-finite time", S.pack(states: #"[{"state":"working","when":"stop","hold":1e308,"release":-5},{"state":"idle"}]"#,
                                          variants: #"[{"name":"w","when":{"windowWidth":{"min":1e300,"max":-1e300}},"patch":{}},{"name":"x","when":{"appVersion":{"min":5}},"patch":{}}]"#),
                version: "1", [Tick(image: img, now: 0), Tick(image: img, now: .nan), Tick(image: img, now: .infinity),
                               Tick(image: img, now: 1), Tick(image: broken, now: 2), Tick(image: nil, now: 3)])
            add("nothing before the first frame", S.pack(), version: nil,
                [Tick(image: nil, now: 0), Tick(image: broken, now: 1), Tick(image: img, now: 2)])
            add("1600x1000 window", S.claudeResolved, version: "7.37095.0",
                (0...20).map { Tick(image: $0 == 0 ? big1 : ($0 % 2 == 0 ? big1 : big2), now: Double($0) * 0.1) })
            add("bad json", "{", version: nil, [])
            add("truncated json", #"{"format":"1.0","id":"x""#, version: nil, [])
            add("top level array", "[]", version: nil, [])
            add("format 2.0", #"{"format":"2.0","id":"x"}"#, version: nil, [])
            add("no id", #"{"format":"1.0"}"#, version: nil, [])
            add("65536 bytes", S.padded(ruleBytesLimit), version: nil, [Tick(image: img, now: 0)])
            add("65537 bytes", S.padded(ruleBytesLimit + 1), version: nil, [])
            add("os conditions", osRules, version: nil, [Tick(image: img, now: 0), Tick(image: chat(dark: true), now: 1)])
            let tailTicks = [Tick(image: tail, now: 0), Tick(image: tail, now: 0.5), Tick(image: tail, now: 1.0),
                             Tick(image: tail, now: 2.5), Tick(image: chat(dots: []), now: 5), Tick(image: nil, now: 8)]
            add("text reader", S.claudeResolved, version: "7.37095.0", caps: ["pixels", "text"], reader: ["Allow", "Deny"], tailTicks)
            add("text reader saying nothing", S.claudeResolved, version: "7.37095.0", caps: ["pixels", "text"], reader: [], tailTicks)
            add("text cap without reader", S.claudeResolved, version: "7.37095.0", caps: ["pixels", "text"], tailTicks)
            add("reader without the text cap", S.claudeResolved, version: "7.37095.0", caps: ["pixels"], reader: ["Allow"], tailTicks)
            add("no caps", S.claudeResolved, version: "7.37095.0", caps: [], reader: ["Allow"], tailTicks)
            for (id, t) in S.shippedPacks() {
                add("shipped " + id, t, version: nil, caps: ["pixels", "text"], reader: ["Allow"],
                    [Tick(image: chat(), now: 0), Tick(image: chat(dots: ["green", "gray"], button: "arrow"), now: 1),
                     Tick(image: nil, now: 2), Tick(image: tail, now: 3), Tick(image: nil, now: 6)])
            }
        }

        // AppStateReport.json()
        func reportCase(_ name: String, _ r: AppStateReport, exact: Bool = false) {
            let j = r.json()
            var o: [String: Any] = ["json": S.parsed(j), "bytes": j.utf8.count]
            if exact { o["text"] = j }
            out.append(S.c("report " + name, ["fn": "report_json", "report": S.report(r)], o))
        }
        reportCase("wire shape", AppStateReport(pack: "claude-desktop", rev: 1, state: "working", by: ["stop"], counts: ["rowDot": 0],
                                                variants: [], appVersion: "7.37095.0", caps: ["pixels", "text"]), exact: true)
        reportCase("default", AppStateReport(), exact: true)
        let long = String(repeating: "名", count: 400)
        var counts: [String: Int] = [:]
        for i in 0..<500 { counts["\(long)\(i)"] = i }
        reportCase("everything huge", AppStateReport(
            pack: long, rev: 1, state: "idle", kind: long, by: (0..<50).map { "\(long)\($0)" }, sure: true, counts: counts,
            health: "invalid", variants: (0..<50).map { "\(long)\($0)" }, appVersion: long,
            caps: (0..<50).map { "\(long)\($0)" }, error: long + long + long))
        reportCase("everything huge, odd state", AppStateReport(
            pack: long, rev: 1, state: long, kind: long, by: (0..<50).map { "\(long)\($0)" }, sure: true, counts: counts,
            health: "ok", variants: (0..<50).map { "\(long)\($0)" }, appVersion: long, caps: (0..<50).map { "\(long)\($0)" }))
        var small: [String: Int] = [:]
        for i in 0..<300 { small["count\(i)"] = i }
        reportCase("many counts", AppStateReport(pack: "p", rev: 1, state: "working", counts: small))
        var mid: [String: Int] = [:]
        for i in 0..<20 { mid["\(String(repeating: "c", count: 250))\(i)"] = i }
        reportCase("twenty long counts", AppStateReport(pack: "p", rev: 1, state: "working", counts: mid))
        reportCase("long error", AppStateReport(health: "invalid", error: String(repeating: "é", count: 3000)))
        reportCase("long lists", AppStateReport(by: (0..<200).map { "b\($0)" }, variants: (0..<200).map { "v\($0)" },
                                                caps: (0..<200).map { "c\($0)" }))
        reportCase("long names", AppStateReport(pack: String(repeating: "p", count: 1500), kind: String(repeating: "k", count: 1500),
                                                by: [String(repeating: "b", count: 1500)], appVersion: String(repeating: "v", count: 1500)))
        reportCase("error not shown unless invalid", AppStateReport(health: "ok", error: "x"))
        reportCase("invalid without error", AppStateReport(health: "invalid"))
        reportCase("escapes", AppStateReport(pack: "a\"b\\c/d\u{1}\n\t", state: "名", by: ["\u{7f}", "😀"]))
        reportCase("negative rev", AppStateReport(pack: "p", rev: -3, counts: ["a": -1, "b": Int(Int32.max)]))

        for (e, name) in [(RuleError.tooLarge, "too large"), (.badJSON, "bad json"), (.unsupportedFormat("2.0"), "format"),
                          (.unsupportedFormat(String(repeating: "名", count: 40)), "long format"),
                          (.notAPack("missing id"), "not a pack"), (.notAPack(String(repeating: "w", count: 50)), "long not a pack")] {
            for (caps, version) in [(["pixels"], nil), (["pixels", "text"], "1.2.3")] as [([String], String?)] {
                let r = AppStateReport.invalid(e, caps: caps, appVersion: version)
                let j = r.json()
                out.append(S.c("invalid \(name) \(caps.count)", ["fn": "invalid", "error": S.err(e), "caps": caps,
                                                                 "appVersion": F.opt(version)],
                               ["report": S.report(r), "json": S.parsed(j), "bytes": j.utf8.count]))
            }
        }

        let versions: [(String, String)] = [
            ("7.37095.0", "7.4"), ("2.0", "2"), ("1.9", "1.10"), ("1.10", "1.9"), ("1.0", "1"), ("1.a", "1.b"), ("1.a", "1.1"),
            ("1.1", "1.a"), ("", ""), ("", "0"), ("1..2", "1.0.2"), ("-1", "0"), ("+1", "1"), (" 1", "1"), ("１", "1"),
            ("99999999999999999999", "1"), ("007", "7"), ("1.0.0.0.1", "1"), ("a", "B"), ("é", "e\u{301}"), ("名", "1"),
            ("1.", "1"), (".1", "0.1"), ("2.0-beta", "2.0"),
        ]
        for (a, b) in versions {
            out.append(S.c("versions \(a) \(b)", ["fn": "compare_versions", "a": a, "b": b], compareVersions(a, b)))
        }
        return out
    }

    // MARK: - Writing

    func testStateRuleFixtures() {
        F.check("rule-pack.json", F.cases(packCases()))
        F.check("rule-regions.json", F.cases(regionCases()))
        F.check("rule-detectors.json", F.cases(detectorCases()))
        F.check("state-table.json", F.cases(tableCases()))
        F.check("state-engine.json", F.cases(engineCases()))
        F.check("rule-image.bin", images.bytes())
    }
}
