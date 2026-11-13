import AppKit
import RappCore
import XCTest
@testable import RappSession

final class ClipCopiesTests: XCTestCase {
    private var board: NSPasteboard!
    private var pb: LocalPasteboard!
    private var copies: ClipCopies!

    override func setUp() {
        board = NSPasteboard(name: .init("rapp.test.\(UUID().uuidString)"))
        pb = LocalPasteboard(board: board)
        copies = ClipCopies()
    }

    override func tearDown() { board.releaseGlobally() }

    func testAddWriteDrop() {
        let n = copies.add(.text("t1"))
        XCTAssertEqual(n, 1)
        XCTAssertTrue(copies.write(n, to: pb))
        XCTAssertEqual(board.string(forType: .string), "t1")
        copies.drop(n)
        XCTAssertNil(copies.copy(n))
        XCTAssertFalse(copies.write(n, to: pb))
        XCTAssertFalse(copies.write(99, to: pb))
    }

    func testFilesCopyFailsWhenAFileIsGone() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rapp-test-\(UUID().uuidString).txt")
        try Data("x".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let n = copies.add(.files([url]))
        XCTAssertTrue(copies.write(n, to: pb))
        board.clearContents()
        try FileManager.default.removeItem(at: url)
        XCTAssertFalse(copies.write(n, to: pb))
        XCTAssertTrue(pb.fileURLs().isEmpty)
    }

    func testNumbersAreNotReused() {
        let a = copies.add(.text("a"))
        copies.drop(a)
        XCTAssertEqual(copies.add(.text("b")), 2)
    }
}
