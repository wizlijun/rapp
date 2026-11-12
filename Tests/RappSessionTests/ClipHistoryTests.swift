import AppKit
import RappCore
import XCTest
@testable import RappSession

final class ClipHistoryTests: XCTestCase {
    var board: NSPasteboard!
    var history: ClipHistory!

    override func setUp() {
        board = NSPasteboard(name: .init("rapp.test.\(UUID().uuidString)"))
        history = ClipHistory(pasteboard: LocalPasteboard(board: board), log: { _ in })
    }

    override func tearDown() { board.releaseGlobally() }

    func testClipHistoryKeepsNewestTwentyNewestFirst() {
        for id in 1...25 { history.add(id: UInt32(id), .text("t\(id)", truncated: false)) }
        XCTAssertEqual(history.entries.count, 20)
        XCTAssertEqual(history.entries[0].id, 25)
        XCTAssertEqual(history.entries.last!.id, 6)
        XCTAssertNil(history.info(5))
        XCTAssertEqual(history.info(25), .text("t25", truncated: false))
    }

    func testAddingTextPutsItOnTheBoardAndSignals() {
        var signalled = 0
        history.onClip = { signalled += 1 }
        history.add(id: 1, .text("hello", truncated: false))
        history.add(id: 1, .text("hello", truncated: false))
        XCTAssertEqual(history.entries.count, 1)
        XCTAssertEqual(board.string(forType: .string), "hello")
        XCTAssertEqual(signalled, 2)
    }

    func testPickTextWritesToTheGivenBoardOrInserts() {
        history.add(id: 3, .text("abc", truncated: false))
        let other = NSPasteboard(name: .init("rapp.test.\(UUID().uuidString)"))
        defer { other.releaseGlobally() }
        let transfers = TransferQueue(address: RemoteAddress(host: "127.0.0.1", port: 1, bundleID: "x", token: "t", mode: .color16))
        var inserted: InsertPayload?
        history.pick(3, insert: false, transfers: transfers, pasteboard: LocalPasteboard(board: other)) { _, p in inserted = p }
        XCTAssertEqual(other.string(forType: .string), "abc")
        XCTAssertNil(inserted)
        history.pick(3, insert: true, transfers: transfers, pasteboard: LocalPasteboard(board: other)) { _, p in inserted = p }
        guard case .text("abc")? = inserted else { return XCTFail("expected inserted text") }
    }

    func testLimitIsConfigurable() {
        let big = ClipHistory(pasteboard: LocalPasteboard(board: board), limit: 50, log: { _ in })
        for id in 1...60 { big.add(id: UInt32(id), .text("t\(id)", truncated: false)) }
        XCTAssertEqual(big.limit, 50)
        XCTAssertEqual(big.entries.count, 50)
        XCTAssertEqual(big.entries.first?.id, 60)
        XCTAssertEqual(big.entries.last?.id, 11)
        XCTAssertEqual(history.limit, 20)
    }
}
