import XCTest
@testable import RappCore

final class RulePackTests: XCTestCase {
    private func v(_ s: String) throws -> RuleValue { try RuleValue.parse(Data(s.utf8)) }

    func testMergeByKeyNullDeletesArraysReplace() throws {
        let base = try v(#"{"a":{"x":1,"y":2},"b":[1,2],"c":3}"#)
        let patch = try v(#"{"a":{"y":null,"z":4},"b":[9],"d":{"e":null,"f":1}}"#)
        XCTAssertEqual(base.merged(with: patch), try v(#"{"a":{"x":1,"z":4},"b":[9],"c":3,"d":{"f":1}}"#))
    }

    func testGenericChatDecodes() throws {
        let p = try RulePack.decode(try v(genericChatJSON))
        XCTAssertEqual(p.id, "generic-chat")
        XCTAssertEqual(p.require, ["bottom"])
        XCTAssertEqual(p.states.map(\.state), ["working", "idle"])
        XCTAssertEqual(p.states[0].hold, 0.6); XCTAssertEqual(p.states[0].release, 2.0)
        XCTAssertEqual(p.signals["stop"]?.detects, [.shape("square", min: 0)])
        XCTAssertEqual(p.signals["rowBusy"]?.count, true)
        guard case .blob(let b)? = p.regions["markers"], case .inline(.strip(let s)) = b.inside else { return XCTFail() }
        XCTAssertEqual(s.of, .named("sidebar")); XCTAssertEqual(s.width, 40); XCTAssertEqual(b.pick, .all)
        XCTAssertEqual(b.size, 6...20)
    }

    func testShippedPacksDecode() throws {
        for j in [chatgptDesktopJSON, claudeDesktopJSON, antigravityAppJSON] {
            XCTAssertNoThrow(try RulePack.decode(try v(j)))
        }
    }

    func testForwardCompatibility() throws {
        let p = try RulePack.decode(try v(#"""
        {"format":"1.7","id":"x","rev":2,"future":true,
         "regions":{"a":{"box":{"top":0}},"b":{"hexagon":{}}},
         "signals":{"s1":{"in":"a","detect":{"present":true}},"s2":{"in":"a","detect":{"smell":"rose"}},
                    "s3":{"in":"b","detect":{"present":true}}},
         "states":[{"state":"working","when":{"any":["s1"]}},{"state":"sleeping","when":{"any":["s1"]}},{"state":"idle"}]}
        """#))
        XCTAssertEqual(p.regions["b"], .unknown)
        XCTAssertEqual(p.signals["s1"]?.usable, true)
        XCTAssertEqual(p.signals["s2"]?.usable, false)
        XCTAssertEqual(p.states.map(\.state), ["working", "idle"])
    }

    func testRejects() throws {
        XCTAssertThrowsError(try RulePack.decode(try v(#"{"format":"2.0","id":"x"}"#))) {
            XCTAssertEqual($0 as? RuleError, .unsupportedFormat("2.0"))
        }
        XCTAssertThrowsError(try RulePack.decode(try v(#"{"format":"1.0"}"#)))
        XCTAssertThrowsError(try RulePack.parse(Data("{".utf8))) { XCTAssertEqual($0 as? RuleError, .badJSON) }
        XCTAssertThrowsError(try RulePack.parse(Data("[]".utf8))) { XCTAssertEqual($0 as? RuleError, .badJSON) }
        XCTAssertThrowsError(try RulePack.parse(Data(repeating: 0x20, count: ruleBytesLimit + 1))) {
            XCTAssertEqual($0 as? RuleError, .tooLarge)
        }
    }

    func testDetectForms() throws {
        let p = try RulePack.decode(try v(#"""
        {"format":"1.0","id":"x","regions":{"r":{"box":{"left":"10%","width":30}}},
         "signals":{"a":{"in":"r","detect":{"shape":{"is":"dot","min":0.7},"color":{"h":[340,20],"l":[35,70]}}},
                    "b":{"in":"r","detect":{"motion":{"window":0.4}},"status":"seen"},
                    "c":{"in":"r","detect":{"text":["Worked for*"]},"needs":["text"],"status":"tested"},
                    "d":{"in":"r","detect":{"color":"green"}}}}
        """#))
        XCTAssertEqual(p.signals["a"]?.detects.first, .shape("dot", min: 0.7))
        XCTAssertEqual(p.signals["b"]?.detects, [.motion(window: 0.4, min: 0.02)])
        XCTAssertEqual(p.signals["b"]?.status, .seen)
        XCTAssertEqual(p.signals["c"]?.needs, ["text"])
        XCTAssertEqual(p.signals["d"]?.detects, [.color(ColorRange.named("green")!)])
        XCTAssertEqual(p.signals["a"]?.status, .untested)
        guard case .box(let b)? = p.regions["r"] else { return XCTFail() }
        XCTAssertEqual(b.left, .percent(10)); XCTAssertEqual(b.width, .points(30))
        // Hue range that wraps through 0 survives decoding.
        guard case .color(let c)? = p.signals["a"]?.detects.last else { return XCTFail() }
        XCTAssertTrue(c.hueContains(350)); XCTAssertTrue(c.hueContains(10)); XCTAssertFalse(c.hueContains(180))
    }

    func testConditionForms() throws {
        let p = try RulePack.decode(try v(#"""
        {"format":"1.0","id":"x","states":[
          {"state":"blocked","kind":"permission","when":{"all":["a",{"not":"b"}]}},
          {"state":"done","when":{"weird":1}},{"state":"idle"}]}
        """#))
        XCTAssertEqual(p.states[0].when, .all([.signal("a"), .not(.signal("b"))]))
        XCTAssertEqual(p.states[0].kind, "permission")
        XCTAssertEqual(p.states[1].when, .never)
        XCTAssertNil(p.states[2].when)
    }

    func testVariantsAndBadColor() throws {
        let p = try RulePack.decode(try v(#"""
        {"format":"1.0","id":"x","signals":{"u":{"in":"r","detect":{"color":"nonesuch"}}},
         "variants":[{"name":"dark","when":{"theme":"dark"},"patch":{"a":1}},{"when":{"os":"macos"},"patch":{}}]}
        """#))
        XCTAssertEqual(p.signals["u"]?.usable, false)
        XCTAssertEqual(p.variants.map(\.name), ["dark", "#1"])
        XCTAssertEqual(p.variants[0].patch["a"], .number(1))
        XCTAssertEqual(p.name, "x"); XCTAssertEqual(p.rev, 0)
    }
}
