import XCTest
@testable import RappSession

final class RevealPathTests: XCTestCase {
    private var root: URL!
    private var outside: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        root = base.appendingPathComponent("dl")
        outside = base.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("a".utf8).write(to: root.appendingPathComponent("a.log"))
        try Data("b".utf8).write(to: outside.appendingPathComponent("b.txt"))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }

    func testInsideIsAllowed() {
        XCTAssertNotNil(revealableURL(root.appendingPathComponent("a.log").path, within: [root]))
    }

    func testOutsideIsRefused() {
        XCTAssertNil(revealableURL(outside.appendingPathComponent("b.txt").path, within: [root]))
    }

    func testMissingIsRefused() {
        XCTAssertNil(revealableURL(root.appendingPathComponent("nope").path, within: [root]))
    }

    func testDotDotEscapeIsRefused() {
        XCTAssertNil(revealableURL(root.path + "/../out/b.txt", within: [root]))
    }

    func testSymlinkEscapeIsRefused() throws {
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        XCTAssertNil(revealableURL(link.appendingPathComponent("b.txt").path, within: [root]))
    }

    func testSiblingWithSamePrefixIsRefused() throws {
        let sib = root.deletingLastPathComponent().appendingPathComponent("dl2")
        try FileManager.default.createDirectory(at: sib, withIntermediateDirectories: true)
        try Data("c".utf8).write(to: sib.appendingPathComponent("c"))
        XCTAssertNil(revealableURL(sib.appendingPathComponent("c").path, within: [root]))
    }
}
