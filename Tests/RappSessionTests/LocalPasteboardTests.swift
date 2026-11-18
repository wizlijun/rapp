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

    /// Two sessions take a clip at the same moment on their own queues (crash 2026-11-18:
    /// NSPasteboard's type cache is not thread-safe, so both threads threw inside AppKit).
    func testTwoQueuesAtOnceDoNotCrash() {
        let pasteboard = LocalPasteboard(board: board)
        let done = expectation(description: "both queues finish")
        done.expectedFulfillmentCount = 2
        for n in 0..<2 {
            DispatchQueue(label: "rapp.test.session.\(n)").async {
                for i in 0..<3000 {
                    if pasteboard.string != "\(n)-\(i)" { pasteboard.write(text: "\(n)-\(i)") }
                }
                done.fulfill()
            }
        }
        wait(for: [done], timeout: 60)
    }
}
