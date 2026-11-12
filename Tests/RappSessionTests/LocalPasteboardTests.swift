import AppKit
import XCTest
@testable import RappSession

final class LocalPasteboardTests: XCTestCase {
    var board: NSPasteboard!

    override func setUp() { board = NSPasteboard(name: .init("rapp.test.\(UUID().uuidString)")) }

    override func tearDown() { board.releaseGlobally() }

    func testWritesToTheBoardItIsGiven() {
        LocalPasteboard(board: board).write(text: "x")
        XCTAssertEqual(board.string(forType: .string), "x")
    }

    func testReadsBackWhatWasWritten() {
        let pasteboard = LocalPasteboard(board: board)
        pasteboard.write(uti: "public.data", data: [1, 2, 3])
        XCTAssertEqual(pasteboard.data(uti: "public.data"), [1, 2, 3])
    }
}
