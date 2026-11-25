import XCTest
@testable import RappCore

/// Spec §6.3 laid over §6.1 (what the pack loader's `extends` produces).
private let claudeDesktopResolvedJSON: String = {
    let base = try! RuleValue.parse(Data(genericChatJSON.utf8))
    let over = try! RuleValue.parse(Data(claudeDesktopJSON.utf8))
    var merged = base.merged(with: over)
    if case .object(var o) = merged { o["extends"] = nil; merged = .object(o) }
    return String(data: try! JSONSerialization.data(withJSONObject: toAny(merged)), encoding: .utf8)!
}()

private func toAny(_ v: RuleValue) -> Any {
    switch v {
    case .null: return NSNull()
    case .bool(let b): return b
    case .number(let n): return n
    case .string(let s): return s
    case .array(let a): return a.map(toAny)
    case .object(let o): return o.mapValues(toAny)
    }
}

/// §6.1 with the given keys replaced (each argument is a JSON snippet).
private func pack(require: [String]? = nil, signals: String? = nil, states: String? = nil,
                  variants: String? = nil) -> Data {
    var o = try! JSONSerialization.jsonObject(with: Data(genericChatJSON.utf8)) as! [String: Any]
    func json(_ s: String) -> Any { try! JSONSerialization.jsonObject(with: Data(s.utf8), options: [.fragmentsAllowed]) }
    if let require { o["require"] = require }
    if let signals { o["signals"] = json(signals) }
    if let states { o["states"] = json(states) }
    if let variants { o["variants"] = json(variants) }
    return try! JSONSerialization.data(withJSONObject: o)
}

private func env(version: String?, locale: String = "en", caps: Set<String> = ["pixels"],
                 reread: @escaping () -> String? = { nil }) -> RuleEnv {
    RuleEnv(appVersion: version, os: "macos", locale: locale, caps: caps, rereadVersion: reread)
}

final class StateEngineTests: XCTestCase {
    func testClaudeWorkingThenDone() throws {
        let e = try StateEngine(rules: Data(claudeDesktopResolvedJSON.utf8), env: env(version: "7.37095.0"), text: nil)
        XCTAssertEqual(e.tick(image: Canvas.chatWindow(button: .square), visible: true, now: 0)?.state, "idle")
        XCTAssertNil(e.tick(image: nil, visible: true, now: 0.5))
        let w = try XCTUnwrap(e.tick(image: nil, visible: true, now: 0.7))
        XCTAssertEqual(w.state, "working"); XCTAssertEqual(w.by, ["stop"]); XCTAssertFalse(w.sure)
        // The frame that swaps the button for an arrow and turns a dot green also moves the dots
        // (rowBusy fires on that one frame), so the release clock starts at the next, still frame.
        _ = e.tick(image: Canvas.chatWindow(dots: [.green], button: .arrow), visible: true, now: 1)
        XCTAssertEqual(e.report.state, "working")
        _ = e.tick(image: nil, visible: true, now: 1.2)
        _ = e.tick(image: nil, visible: true, now: 3.0)                // release 2 s not over
        XCTAssertEqual(e.report.state, "working")
        let d = try XCTUnwrap(e.tick(image: nil, visible: true, now: 3.3))
        XCTAssertEqual(d.state, "done"); XCTAssertEqual(d.counts["rowDot"], 1)
        XCTAssertEqual(d.json().contains("\"inferred\":true"), true)
    }

    func testVariantsByVersionThemeLocaleWidthAndFound() throws {
        let rules = pack(variants: #"""
        [{"name":"old","when":{"appVersion":{"max":"1.9"}},"patch":{"signals":{"stop":{"detect":{"shape":"dot"}}}}},
         {"name":"new","when":{"appVersion":{"min":"2.0"}},"patch":{}},
         {"name":"dark","when":{"theme":"dark"},"patch":{}},
         {"name":"zh","when":{"locale":"zh"},"patch":{}},
         {"name":"narrow","when":{"windowWidth":{"max":500}},"patch":{}},
         {"name":"noSide","when":{"missing":["sidebar"]},"patch":{}},
         {"name":"mac","when":{"os":"windows"},"patch":{}},
         {"name":"odd","when":{"moon":"full"},"patch":{}}]
        """#)
        let e = try StateEngine(rules: rules, env: env(version: "2.3", locale: "zh-Hans"), text: nil)
        let r = try XCTUnwrap(e.tick(image: Canvas.chatWindow(width: 400, sidebar: false, dark: true), visible: true, now: 0))
        XCTAssertEqual(r.variants, ["new", "dark", "zh", "narrow", "noSide"])
        // No version: of the appVersion variants only the newest applies.
        let e2 = try StateEngine(rules: rules, env: env(version: nil), text: nil)
        XCTAssertEqual(e2.tick(image: Canvas.chatWindow(), visible: true, now: 0)?.variants, ["new"])
        // An old version picks the old variant, and a found variant needs the region.
        let e3 = try StateEngine(rules: rules, env: env(version: "1.5"), text: nil)
        XCTAssertEqual(e3.tick(image: Canvas.chatWindow(), visible: true, now: 0)?.variants, ["old"])
    }

    func testSelfCheckSwitchesVariantThenRereadsThenGivesUp() throws {
        let rules = pack(require: ["bottom"], variants: #"""
        [{"name":"old","when":{"appVersion":{"max":"1.9"}},"patch":{}},
         {"name":"new","when":{"appVersion":{"min":"2.0"}},"patch":{"regions":{"bottom":{"box":{"in":"nowhere"}}}}}]
        """#)
        var rereads = 0
        let e = try StateEngine(rules: rules, env: env(version: "2.0", reread: { rereads += 1; return "2.0" }), text: nil)
        let img = Canvas.chatWindow()
        for i in 0..<4 { _ = e.tick(image: img, visible: true, now: Double(i)) }
        XCTAssertEqual(e.report.health, "ok")
        _ = e.tick(image: img, visible: true, now: 4)                              // 5th miss
        XCTAssertEqual(e.report.health, "switched"); XCTAssertEqual(e.report.variants, ["old"])
        XCTAssertNotNil(e.report.state)

        let bad = pack(require: ["bottom"], variants: #"[{"name":"v","when":{"appVersion":{"min":"1"}},"patch":{"regions":{"bottom":{"box":{"in":"nowhere"}}}}}]"#)
        rereads = 0
        let e2 = try StateEngine(rules: bad, env: env(version: "2.0", reread: { rereads += 1; return "2.0" }), text: nil)
        for i in 0..<10 { _ = e2.tick(image: img, visible: true, now: Double(i)) }
        XCTAssertEqual(rereads, 1)
        XCTAssertEqual(e2.report.health, "unfit"); XCTAssertNil(e2.report.state)
        // Invisible rounds never count.
        let e3 = try StateEngine(rules: bad, env: env(version: "2.0"), text: nil)
        for i in 0..<20 { _ = e3.tick(image: img, visible: false, now: Double(i)) }
        XCTAssertEqual(e3.report.health, "ok")
    }

    func testSelfCheckForcesTheUntriedVersionVariantBeforeAnyReread() throws {
        let rules = pack(require: ["bottom"], variants: #"""
        [{"name":"v1","when":{"appVersion":{"max":"1.9"}},"patch":{"regions":{"bottom":{"box":{"in":"nowhere"}}}}},
         {"name":"v2","when":{"appVersion":{"min":"2.0"}},"patch":{}}]
        """#)
        var rereads = 0
        let e = try StateEngine(rules: rules, env: env(version: "1.0", reread: { rereads += 1; return "1.0" }), text: nil)
        for i in 0..<5 { _ = e.tick(image: Canvas.chatWindow(), visible: true, now: Double(i)) }
        XCTAssertEqual(e.report.variants, ["v2"]); XCTAssertEqual(e.report.health, "switched")
        XCTAssertEqual(rereads, 0)
    }

    func testRereadReturningANewVersionRestartsTheSearch() throws {
        // v1 (the only versioned variant) breaks the pack and is tried first; the reread says 3.0, to which
        // no variant applies, so the plain pack fits again.
        let rules = pack(require: ["bottom"], variants: #"""
        [{"name":"v1","when":{"appVersion":{"max":"1.9"}},"patch":{"regions":{"bottom":{"box":{"in":"nowhere"}}}}}]
        """#)
        var rereads = 0
        let e = try StateEngine(rules: rules, env: env(version: "1.0", reread: { rereads += 1; return "3.0" }), text: nil)
        let img = Canvas.chatWindow()
        for i in 0..<5 { _ = e.tick(image: img, visible: true, now: Double(i)) }
        XCTAssertEqual(rereads, 1)
        XCTAssertEqual(e.report.appVersion, "3.0"); XCTAssertEqual(e.report.variants, [])
        XCTAssertEqual(e.report.health, "switched"); XCTAssertNotNil(e.report.state)
        for i in 5..<15 { _ = e.tick(image: img, visible: true, now: Double(i)) }
        XCTAssertEqual(rereads, 1)
    }

    func testUnfitRecoversAfterFiveFoundRounds() throws {
        let rules = pack(require: ["sidebar"])
        var rereads = 0
        let e = try StateEngine(rules: rules, env: env(version: "2.0", reread: { rereads += 1; return "2.0" }), text: nil)
        let off = Canvas.chatWindow(sidebar: false), on = Canvas.chatWindow()
        var t = 0.0
        func rounds(_ img: RuleImage, _ n: Int) { for _ in 0..<n { _ = e.tick(image: img, visible: true, now: t); t += 1 } }
        rounds(off, 5)
        XCTAssertEqual(e.report.health, "unfit"); XCTAssertNil(e.report.state)
        XCTAssertEqual(rereads, 1)
        rounds(on, 4)
        XCTAssertEqual(e.report.health, "unfit"); XCTAssertNil(e.report.state)
        rounds(off, 1)                                   // a miss resets the streak
        rounds(on, 4)
        XCTAssertEqual(e.report.health, "unfit")
        rounds(on, 1)
        XCTAssertEqual(e.report.health, "ok"); XCTAssertNotNil(e.report.state)
        // The search runs in full again after a recovery: reread is allowed once more.
        rounds(off, 5)
        XCTAssertEqual(e.report.health, "unfit"); XCTAssertEqual(rereads, 2)
    }

    func testSwitchedIsStickyAndRecoveryReopensTheSearch() throws {
        let rules = pack(require: ["sidebar"], variants: #"""
        [{"name":"v1","when":{"appVersion":{"max":"1.9"}},"patch":{}}]
        """#)
        var rereads = 0
        let e = try StateEngine(rules: rules, env: env(version: "1.0", reread: { rereads += 1; return "3.0" }), text: nil)
        var t = 0.0
        func rounds(_ img: RuleImage, _ n: Int) { for _ in 0..<n { _ = e.tick(image: img, visible: true, now: t); t += 1 } }
        rounds(Canvas.chatWindow(sidebar: false), 5)     // v1 spent, reread brings 3.0 -> switched
        XCTAssertEqual(e.report.health, "switched"); XCTAssertEqual(rereads, 1)
        rounds(Canvas.chatWindow(sidebar: false), 10)    // v1 untried after the restart: forced, spent; rereaded: unfit
        XCTAssertEqual(e.report.health, "unfit"); XCTAssertEqual(rereads, 1)
        rounds(Canvas.chatWindow(), 5)
        XCTAssertEqual(e.report.health, "switched")      // sticky: it did change things on its own
        XCTAssertNotNil(e.report.state)
        rounds(Canvas.chatWindow(sidebar: false), 5)     // the search runs in full again: v1 spent, reread once more
        XCTAssertEqual(rereads, 2); XCTAssertEqual(e.report.health, "unfit")
    }

    func testAVariantWhosePatchBreaksThePackIsNotReported() throws {
        let rules = pack(variants: #"""
        [{"name":"good","when":{},"patch":{}},
         {"name":"breaks","when":{},"patch":{"id":null}},
         {"name":"scalar","when":{},"patch":7}]
        """#)
        let e = try StateEngine(rules: rules, env: env(version: nil), text: nil)
        let r = try XCTUnwrap(e.tick(image: Canvas.chatWindow(), visible: true, now: 0))
        XCTAssertEqual(r.variants, ["good"])
        XCTAssertEqual(r.pack, "generic-chat")
    }

    func testSureOnlyForTestedSignals() throws {
        let rules = pack(signals: #"{"ask":{"in":"tail","detect":{"present":true},"status":"tested"}}"#,
                         states: #"[{"state":"blocked","kind":"permission","when":{"any":["ask"]}},{"state":"idle"}]"#)
        let e = try StateEngine(rules: rules, env: env(version: nil), text: nil)
        let r = try XCTUnwrap(e.tick(image: Canvas.chatWindow(), visible: true, now: 0))
        XCTAssertEqual(r.state, "blocked"); XCTAssertEqual(r.kind, "permission"); XCTAssertTrue(r.sure)
    }

    func testBadRulesAndReportLimits() {
        XCTAssertThrowsError(try StateEngine(rules: Data("{".utf8), env: env(version: nil), text: nil))
        let inv = AppStateReport.invalid(.badJSON, caps: ["pixels"], appVersion: nil)
        XCTAssertEqual(inv.health, "invalid"); XCTAssertNil(inv.state)
        XCTAssertLessThanOrEqual(inv.json().utf8.count, appStateLimit)
        XCTAssertTrue(inv.json().contains("\"error\""))
        XCTAssertEqual(compareVersions("7.37095.0", "7.4"), 1)
        XCTAssertEqual(compareVersions("2.0", "2"), 0)
        XCTAssertEqual(compareVersions("1.9", "1.10"), -1)
    }

    func testWireShape() {
        let r = AppStateReport(pack: "claude-desktop", rev: 1, state: "working", by: ["stop"], counts: ["rowDot": 0],
                               variants: [], appVersion: "7.37095.0", caps: ["pixels", "text"])
        XCTAssertEqual(r.json(), #"{"appVersion":"7.37095.0","by":["stop"],"caps":["pixels","text"],"counts":{"rowDot":0},"health":"ok","inferred":true,"kind":null,"pack":"claude-desktop","rev":1,"state":"working","sure":false,"variants":[]}"#)
    }

    func testReportNeverExceedsTheWireLimit() throws {
        // Report level: everything huge.
        let long = String(repeating: "名", count: 400)
        var counts: [String: Int] = [:]
        for i in 0..<500 { counts["\(long)\(i)"] = i }
        let big = AppStateReport(pack: long, rev: 1, state: "idle", kind: long, by: (0..<50).map { "\(long)\($0)" },
                                 sure: true, counts: counts, health: "invalid", variants: (0..<50).map { "\(long)\($0)" },
                                 appVersion: long, caps: (0..<50).map { "\(long)\($0)" }, error: long + long + long)
        let s = big.json()
        XCTAssertLessThanOrEqual(s.utf8.count, appStateLimit)
        XCTAssertNotNil(try? JSONSerialization.jsonObject(with: Data(s.utf8)))
        XCTAssertTrue(s.contains("\"inferred\":true"))

        // Engine level: a pack with many count signals and long names.
        var sigs: [String] = []
        for i in 0..<40 { sigs.append("\"\(String(repeating: "s", count: 300))\(i)\":{\"in\":\"bottom\",\"detect\":{\"present\":true},\"count\":true}") }
        let names = (0..<40).map { "\(String(repeating: "s", count: 300))\($0)" }
        let states = "[{\"state\":\"working\",\"when\":{\"any\":[\(names.map { "\"\($0)\"" }.joined(separator: ","))]}},{\"state\":\"idle\"}]"
        let rules = pack(signals: "{\(sigs.joined(separator: ","))}", states: states)
        let e = try StateEngine(rules: rules, env: env(version: nil), text: nil)
        let r = try XCTUnwrap(e.tick(image: Canvas.chatWindow(), visible: true, now: 0))
        XCTAssertEqual(r.counts.count, reportCountKeys)
        XCTAssertGreaterThan(r.json().utf8.count, 0)
        XCTAssertLessThanOrEqual(r.json().utf8.count, appStateLimit)
    }

    func testNonFiniteTimeAndHostileNumbersDoNotPoisonOrTrap() throws {
        let rules = pack(states: #"[{"state":"working","when":"stop","hold":1e308,"release":-5},{"state":"idle"}]"#,
                         variants: #"[{"name":"w","when":{"windowWidth":{"min":1e300,"max":-1e300}},"patch":{}},{"name":"x","when":{"appVersion":{"min":5}},"patch":{}}]"#)
        let e = try StateEngine(rules: rules, env: env(version: "1"), text: nil)
        let img = Canvas.chatWindow()
        XCTAssertEqual(e.tick(image: img, visible: true, now: 0)?.state, "idle")
        XCTAssertNil(e.tick(image: img, visible: true, now: .nan))
        XCTAssertNil(e.tick(image: img, visible: true, now: .infinity))
        XCTAssertEqual(e.report.state, "idle")
        XCTAssertNil(e.tick(image: img, visible: true, now: 1))
        XCTAssertEqual(e.report.variants, [])
        // A frame with a broken buffer is treated as no frame.
        XCTAssertNil(e.tick(image: RuleImage(width: 10, height: 10, pixels: []), visible: true, now: 2))
    }

    func testNothingBeforeTheFirstFrame() throws {
        let e = try StateEngine(rules: pack(), env: env(version: nil), text: nil)
        XCTAssertNil(e.tick(image: nil, visible: true, now: 0))
        XCTAssertNil(e.report.state)
    }

    func testTickCostOnA1600x1000Window() throws {
        let e = try StateEngine(rules: Data(claudeDesktopResolvedJSON.utf8), env: env(version: "7.37095.0"), text: nil)
        let frames = [Canvas.chatWindow(width: 1600, height: 1000), Canvas.chatWindow(width: 1600, height: 1000, spinnerPhase: 1)]
        _ = e.tick(image: frames[0], visible: true, now: 0)
        let start = Date()
        for i in 1...20 { _ = e.tick(image: frames[i % 2], visible: true, now: Double(i) * 0.1) }
        let per = Date().timeIntervalSince(start) / 20
        #if DEBUG
        XCTAssertLessThan(per, 0.5, "debug build; run -c release for the 15 ms budget")
        #else
        XCTAssertLessThan(per, 0.015)
        #endif
        print("tick cost: \(per * 1000) ms")
    }
}
