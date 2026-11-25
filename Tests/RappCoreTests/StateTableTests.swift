import XCTest
@testable import RappCore

final class StateTableTests: XCTestCase {
    private let rows = [
        StateRow(state: "blocked", kind: "permission", when: .any([.signal("ask")]), hold: 0, release: 0),
        StateRow(state: "working", kind: nil, when: .any([.signal("stop"), .signal("busy")]), hold: 0.6, release: 2.0),
        StateRow(state: "done", kind: nil, when: .any([.signal("dot")]), hold: 0, release: 0),
        StateRow(state: "idle", kind: nil, when: nil, hold: 0, release: 0),
    ]

    func testHoldDelaysEnteringAndReleaseDelaysLeaving() {
        var t = StateTable(rows)
        XCTAssertEqual(t.step(on: ["stop"], now: 0)?.state, "idle")
        XCTAssertEqual(t.step(on: ["stop"], now: 0.5)?.state, "idle")
        XCTAssertEqual(t.step(on: ["stop"], now: 0.6)?.state, "working")
        XCTAssertEqual(t.step(on: [], now: 1.0)?.state, "working")
        XCTAssertEqual(t.step(on: ["dot"], now: 2.9)?.state, "working")
        XCTAssertEqual(t.step(on: ["dot"], now: 3.0)?.state, "done")
    }

    func testAFlickerNeverEnters() {
        var t = StateTable(rows)
        _ = t.step(on: ["stop"], now: 0)
        _ = t.step(on: [], now: 0.3)
        XCTAssertEqual(t.step(on: ["stop"], now: 0.5)?.state, "idle")
        XCTAssertEqual(t.step(on: ["stop"], now: 1.1)?.state, "working")
    }

    func testAHigherRowPreemptsAtOnce() {
        var t = StateTable(rows)
        _ = t.step(on: ["stop"], now: 0); _ = t.step(on: ["stop"], now: 1)
        XCTAssertEqual(t.step(on: ["stop", "ask"], now: 1.1)?.state, "blocked")
    }

    func testConditions() {
        XCTAssertTrue(holds(.all([.signal("a"), .not(.signal("b"))]), ["a"]))
        XCTAssertFalse(holds(.all([.signal("a"), .not(.signal("b"))]), ["a", "b"]))
        XCTAssertFalse(holds(.never, ["a"]))
        XCTAssertEqual(signalsIn(.any([.signal("a"), .not(.signal("b"))])), ["a", "b"])
        var empty = StateTable([])
        XCTAssertNil(empty.step(on: [], now: 0))
    }

    func testNoFallbackRowGivesIdle() {
        var t = StateTable([StateRow(state: "working", when: .signal("a"))])
        XCTAssertEqual(t.step(on: [], now: 0), StateRow(state: "idle"))
        XCTAssertEqual(t.step(on: ["a"], now: 1)?.state, "working")
    }

    func testReleaseRestartsWhenConditionComesBack() {
        var t = StateTable(rows)
        _ = t.step(on: ["stop"], now: 0); _ = t.step(on: ["stop"], now: 1)
        XCTAssertEqual(t.step(on: [], now: 2)?.state, "working")
        XCTAssertEqual(t.step(on: ["stop"], now: 3)?.state, "working")   // back on, release forgotten
        XCTAssertEqual(t.step(on: [], now: 4)?.state, "working")
        XCTAssertEqual(t.step(on: [], now: 5.9)?.state, "working")
        XCTAssertEqual(t.step(on: [], now: 6.0)?.state, "idle")
    }

    func testOddTimingsNeverTrap() {
        let odd = [
            StateRow(state: "working", when: .signal("a"), hold: .nan, release: -5),
            StateRow(state: "done", when: .signal("b"), hold: .infinity, release: .infinity),
            StateRow(state: "idle"),
        ]
        var t = StateTable(odd)
        XCTAssertEqual(t.step(on: ["a"], now: 0)?.state, "working")      // NaN hold = 0
        XCTAssertEqual(t.step(on: [], now: 1)?.state, "idle")             // negative release = 0
        XCTAssertEqual(t.step(on: ["b"], now: 2)?.state, "idle")
        XCTAssertEqual(t.step(on: ["b"], now: 2 + 3600)?.state, "done")   // huge hold capped at 3600 s
        XCTAssertNotNil(t.step(on: ["b"], now: .nan))
    }

    func testUnreadableAnywhereMakesTheWholeConditionNeverMatch() throws {
        func cond(_ json: String) throws -> Condition? {
            let p = try RulePack.decode(try RuleValue.parse(Data(
                #"{"format":"1.0","id":"x","states":[{"state":"done","when":\#(json)}]}"#.utf8)))
            return p.states[0].when
        }
        XCTAssertEqual(try cond(#"{"not":{"bogus":1}}"#), .never)
        XCTAssertEqual(try cond(#"{"any":[{"bogus":1},"a"]}"#), .never)
        XCTAssertEqual(try cond(#"{"all":["a",{"not":{"all":[]}}]}"#), .never)
        XCTAssertFalse(holds(try cond(#"{"not":{"bogus":1}}"#)!, []))
        XCTAssertFalse(holds(try cond(#"{"any":[{"bogus":1},"a"]}"#)!, ["a"]))
        XCTAssertEqual(try cond(#"{"any":["a",{"not":"b"}]}"#), .any([.signal("a"), .not(.signal("b"))]))
    }
}
