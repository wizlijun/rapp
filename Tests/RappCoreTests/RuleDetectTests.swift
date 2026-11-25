import XCTest
@testable import RappCore

final class FakeReader: TextReader {
    var lines: [String]
    var calls = 0
    init(lines: [String]) { self.lines = lines }
    func lines(in image: RuleImage, rect: RuleRect) -> [String] { calls += 1; return lines }
}

final class RuleDetectTests: XCTestCase {
    func claudeLikePack() throws -> RulePack {
        let base = try RuleValue.parse(Data(genericChatJSON.utf8))
        let claude = try RuleValue.parse(Data(claudeDesktopJSON.utf8))
        return try RulePack.decode(base.merged(with: claude))
    }

    func testShapes() {
        XCTAssertEqual(shape(in: Canvas.button(icon: .square), rect: Canvas.buttonRect).name, .square)
        XCTAssertEqual(shape(in: Canvas.button(icon: .arrow), rect: Canvas.buttonRect).name, .arrow)
        XCTAssertEqual(shape(in: Canvas.button(icon: .none), rect: Canvas.buttonRect).name, .dot)
        XCTAssertEqual(shape(in: Canvas.bareSquare(), rect: Canvas.buttonRect).name, .square)
        XCTAssertEqual(shape(in: Canvas.ring(), rect: Canvas.buttonRect).name, .ring)
        XCTAssertEqual(shape(in: Canvas.solid(width: 64, height: 64), rect: RuleRect(x: 8, y: 8, w: 32, h: 32)).name, .none)
        // A rect that leaves the image, and an empty one, never trap.
        XCTAssertEqual(shape(in: Canvas.solid(width: 10, height: 10), rect: RuleRect(x: 5, y: 5, w: Int.max, h: 4)).name, .none)
        XCTAssertEqual(shape(in: Canvas.solid(width: 10, height: 10), rect: RuleRect(x: 0, y: 0, w: 0, h: 4)).name, .none)
        // A wide bar is `other`.
        var bar = Canvas.solid(width: 64, height: 64); Canvas.fill(&bar, RuleRect(x: 8, y: 20, w: 48, h: 8), Canvas.black)
        XCTAssertEqual(shape(in: bar, rect: RuleRect(x: 8, y: 20, w: 48, h: 8)).name, .other)
    }

    func testBigIconsAndThinRing() {
        let page = Canvas.white
        func disc(_ icon: (inout RuleImage) -> Void) -> RuleImage {
            var img = Canvas.solid(width: 64, height: 64, page)
            Canvas.disc(&img, x: 16, y: 16, size: 32, Canvas.black); icon(&img); return img
        }
        let sq = disc { Canvas.fill(&$0, RuleRect(x: 24, y: 24, w: 16, h: 16), Canvas.white) }
        XCTAssertEqual(shape(in: sq, rect: Canvas.buttonRect).name, .square)
        let arrow = disc { img in
            Canvas.fill(&img, RuleRect(x: 30, y: 24, w: 4, h: 16), Canvas.white)
            for row in 0..<8 { Canvas.fill(&img, RuleRect(x: 32 - (row + 1), y: 24 + row, w: 2 * (row + 1), h: 1), Canvas.white) }
        }
        XCTAssertEqual(shape(in: arrow, rect: Canvas.buttonRect).name, .arrow)
        var ring = Canvas.solid(width: 64, height: 64)
        Canvas.ring(&ring, x: 16, y: 16, size: 32, thickness: 4, Canvas.black, hole: Canvas.white)
        XCTAssertEqual(shape(in: ring, rect: Canvas.buttonRect).name, .ring)
    }

    func testMotionHistoryClearsOnResize() {
        let spec = SignalSpec(region: .named("a"), detects: [.motion(window: 0.4, min: 0.02)])
        let p = RulePack(id: "t", name: "t", rev: 0, regions: [:], signals: ["s": spec], states: [], require: [], variants: [])
        let ev = SignalEvaluator(caps: [], text: nil)
        let a = Canvas.solid(width: 64, height: 64), b = Canvas.solid(width: 64, height: 64, (0, 0, 0))
        func run(_ img: RuleImage, _ w: Int, _ t: Double) -> Bool? {
            ev.evaluate(p, regions: ["a": [RuleRect(x: 0, y: 0, w: w, h: 20)]], image: img, now: t)["s"]?.holds
        }
        XCTAssertEqual(run(a, 20, 0), false)
        XCTAssertEqual(run(b, 20, 0.5), true)       // same size, changed
        XCTAssertEqual(run(a, 30, 1.0), false)      // resized 20 -> 30: first frame is not moving
        XCTAssertEqual(run(b, 30, 1.5), true)
    }

    func testNamedColors() {
        XCTAssertTrue(ColorRange.named("green")!.contains(hsl(r: 52, g: 199, b: 89)))
        XCTAssertTrue(ColorRange.named("gray")!.contains(hsl(r: 160, g: 160, b: 160)))
        XCTAssertFalse(ColorRange.named("gray")!.contains(hsl(r: 52, g: 199, b: 89)))
        XCTAssertTrue(ColorRange.named("red")!.contains(hsl(r: 230, g: 40, b: 40)))
        XCTAssertNil(ColorRange.named("chartreuse"))
        let img = Canvas.dot(color: (150, 150, 150), on: (240, 240, 240))
        XCTAssertTrue(ColorRange.named("gray")!.contains(foregroundColor(in: img, rect: Canvas.dotRect)!))
        XCTAssertFalse(ColorRange.named("green")!.contains(HSL(h: .nan, s: 50, l: 50)))
    }

    func testTextPatterns() {
        XCTAssertTrue(textMatches(["Worked for*"], lines: ["Worked for 2m 10s"]))
        XCTAssertFalse(textMatches(["Worked for*"], lines: ["I worked for you"]))
        XCTAssertTrue(textMatches(["Allow"], lines: ["Allow once"]))
        XCTAssertFalse(textMatches(["Allow"], lines: ["Allowance"]))
        XCTAssertTrue(textMatches(["允许"], lines: ["是否允许访问"]))
        XCTAssertTrue(textMatches(["allow"], lines: ["ALLOW"]))
        XCTAssertTrue(textMatches(["Allow"], lines: ["  (Allow)  "]))
        XCTAssertTrue(textMatches(["a*b*c"], lines: ["axxbyyc"]))
        XCTAssertFalse(textMatches([""], lines: ["x"]))
    }

    func testCountsMotionNeedsAndTextThrottle() throws {
        let pack = try claudeLikePack()
        let ev = SignalEvaluator(caps: ["pixels"], text: nil)
        var img = Canvas.chatWindow(dots: [.green, .gray, .gray])
        var r = ev.evaluate(pack, regions: resolveRegions(pack, in: img), image: img, now: 0)
        XCTAssertEqual(r["rowDot"], SignalResult(holds: true, count: 1))
        XCTAssertEqual(r["rowGray"], SignalResult(holds: true, count: 2))
        XCTAssertEqual(r["stop"], SignalResult(holds: true, count: nil))
        XCTAssertEqual(r["ask"], SignalResult(holds: false, count: nil))       // needs text, no text cap
        XCTAssertEqual(r["rowBusy"]?.holds, false)                             // first frame: nothing to compare
        img = Canvas.chatWindow(dots: [.green, .gray, .gray], spinnerPhase: 1)
        r = ev.evaluate(pack, regions: resolveRegions(pack, in: img), image: img, now: 0.5)
        XCTAssertEqual(r["rowBusy"], SignalResult(holds: true, count: 3))
        r = ev.evaluate(pack, regions: resolveRegions(pack, in: img), image: nil, now: 1.0)
        XCTAssertEqual(r["rowBusy"]?.holds, false)
        XCTAssertEqual(r["rowGray"]?.count, 2)

        let reader = FakeReader(lines: ["Allow", "Deny"])
        let ev2 = SignalEvaluator(caps: ["pixels", "text"], text: reader)
        let a = Canvas.chatWindow(dots: [])
        _ = ev2.evaluate(pack, regions: resolveRegions(pack, in: a), image: a, now: 0)
        _ = ev2.evaluate(pack, regions: resolveRegions(pack, in: a), image: a, now: 0.5)
        let b = Canvas.chatWindow(dots: [], tailText: true)
        _ = ev2.evaluate(pack, regions: resolveRegions(pack, in: b), image: b, now: 1.0)
        let r2 = ev2.evaluate(pack, regions: resolveRegions(pack, in: b), image: b, now: 2.1)
        XCTAssertEqual(reader.calls, 2)
        XCTAssertEqual(r2["ask"]?.holds, true)
    }

    func testMissingRegionUnusableAndPresent() throws {
        let p = try RulePack.decode(try RuleValue.parse(Data(#"""
        {"format":"1.0","id":"t","regions":{"a":{"box":{"left":0,"top":0,"width":10,"height":10}}},
         "signals":{"here":{"in":"a","detect":{"present":true}},
                    "gone":{"in":"zzz","detect":{"present":true},"count":true},
                    "noIn":{"detect":{"present":true}},
                    "bad":{"in":"a","detect":{"wat":1}},
                    "nan":{"in":"a","detect":{"motion":{"window":0.4,"min":null}}}}}
        """#.utf8)))
        let ev = SignalEvaluator(caps: ["pixels"], text: nil)
        let img = Canvas.solid(width: 50, height: 50)
        let r = ev.evaluate(p, regions: resolveRegions(p, in: img), image: img, now: 0)
        XCTAssertEqual(r["here"], SignalResult(holds: true, count: nil))
        XCTAssertEqual(r["gone"], SignalResult(holds: false, count: nil))
        XCTAssertEqual(r["noIn"]?.holds, false)
        XCTAssertEqual(r["bad"]?.holds, false)
    }

    func testNaNThresholdsNeverFireAndNeverTrap() {
        var spec = SignalSpec(region: .named("a"), detects: [.shape("dot", min: .nan), .motion(window: .nan, min: .nan)], needs: ["pixels"])
        spec.usable = true
        let p = RulePack(id: "t", name: "t", rev: 0,
                         regions: ["a": .box(BoxSpec(left: .points(0), width: .points(12), height: .points(12)))],
                         signals: ["s": spec], states: [], require: [], variants: [])
        let ev = SignalEvaluator(caps: ["pixels"], text: nil)
        let img = Canvas.dot(color: (0, 0, 0), on: (255, 255, 255))
        for t in [0.0, 0.5, 1.0] {
            XCTAssertEqual(ev.evaluate(p, regions: ["a": [RuleRect(x: 26, y: 26, w: 12, h: 12)]], image: img, now: t)["s"]?.holds, false)
        }
    }
}
