import XCTest
@testable import RappCore

final class PeerNamesTests: XCTestCase {
    func testAnnouncedNameIsFoundByPort() {
        var names = PeerNames()
        names.set("Mac mini", for: 50001)
        XCTAssertEqual(names[50001], "Mac mini")
        XCTAssertNil(names[50002])
    }
    func testALaterNameForThePortReplacesTheEarlierOne() {
        var names = PeerNames()
        names.set("a", for: 1)
        names.set("b", for: 1)
        XCTAssertEqual(names[1], "b")
        XCTAssertEqual(names.count, 1)
    }
    func testOnlyTheNewestSixteenAreKept() {
        var names = PeerNames()
        for port in 1...17 { names.set("n\(port)", for: UInt16(port)) }
        XCTAssertEqual(names.count, peerNamesKept)
        XCTAssertNil(names[1])
        XCTAssertEqual(names[2], "n2")
        XCTAssertEqual(names[17], "n17")
    }
    func testRenamingAPortMakesItTheNewest() {
        var names = PeerNames()
        for port in 1...16 { names.set("n\(port)", for: UInt16(port)) }
        names.set("again", for: 1)
        names.set("n17", for: 17)
        XCTAssertEqual(names[1], "again")
        XCTAssertNil(names[2])
    }
    func testAnEmptyNameIsKeptAsGiven() {
        var names = PeerNames()
        names.set("", for: 9)
        XCTAssertEqual(names[9], "")
    }
}
