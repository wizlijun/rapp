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

    // MARK: save / load

    private func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("rapp-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: d) }
        return d
    }

    func testSaveTextWritesMarkdown() throws {
        let root = try tempDir()
        let n = copies.add(.text("# 标题\n\n  原文 \n"))
        let url = try copies.save(n, textDir: root.appendingPathComponent("t"), fileDir: root.appendingPathComponent("f"), stem: "s")
        XCTAssertEqual(url, root.appendingPathComponent("t/s.md"))
        XCTAssertEqual(try String(contentsOf: url!, encoding: .utf8), "# 标题\n\n  原文 \n")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("t").path), ["s.md"])
    }

    func testSaveAvoidsNameClashes() throws {
        let root = try tempDir()
        let t = root.appendingPathComponent("t"), f = root.appendingPathComponent("f")
        let a = copies.add(.text("a")), b = copies.add(.text("b")), c = copies.add(.text("c"))
        XCTAssertEqual(try copies.save(a, textDir: t, fileDir: f, stem: "s")?.lastPathComponent, "s.md")
        XCTAssertEqual(try copies.save(b, textDir: t, fileDir: f, stem: "s")?.lastPathComponent, "s-2.md")
        XCTAssertEqual(try copies.save(c, textDir: t, fileDir: f, stem: "s")?.lastPathComponent, "s-3.md")
    }

    func testSaveImageAndData() throws {
        let root = try tempDir()
        let t = root.appendingPathComponent("t"), f = root.appendingPathComponent("f")
        let img = copies.add(.image([1, 2, 3]))
        let rtf = copies.add(.data(uti: "public.rtf", [4, 5]))
        let odd = copies.add(.data(uti: "dyn.nothing-known", [6]))
        let u1 = try copies.save(img, textDir: t, fileDir: f, stem: "s")
        let u2 = try copies.save(rtf, textDir: t, fileDir: f, stem: "s")
        let u3 = try copies.save(odd, textDir: t, fileDir: f, stem: "s")
        XCTAssertEqual(u1, f.appendingPathComponent("s.png"))
        XCTAssertEqual(try Data(contentsOf: u1!), Data([1, 2, 3]))
        XCTAssertEqual(u2, f.appendingPathComponent("s.rtf"))
        XCTAssertEqual(try Data(contentsOf: u2!), Data([4, 5]))
        XCTAssertEqual(u3, f.appendingPathComponent("s.bin"))
    }

    func testSaveFilesCopiesIntoAFolder() throws {
        let root = try tempDir()
        let src = try tempDir()
        let a = src.appendingPathComponent("a.txt"), b = src.appendingPathComponent("b.txt")
        try Data("A".utf8).write(to: a)
        try Data("B".utf8).write(to: b)
        let n = copies.add(.files([a, b]))
        let f = root.appendingPathComponent("f")
        let dir = try copies.save(n, textDir: root.appendingPathComponent("t"), fileDir: f, stem: "s")
        XCTAssertEqual(dir?.path, f.appendingPathComponent("s").path)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir!.path).sorted(), ["a.txt", "b.txt"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: b.path))
        let again = try copies.save(n, textDir: root.appendingPathComponent("t"), fileDir: f, stem: "s")
        XCTAssertEqual(again?.path, f.appendingPathComponent("s-2").path)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.path).sorted(), ["s", "s-2"])
    }

    func testLoadRoundTrips() throws {
        let root = try tempDir()
        let t = root.appendingPathComponent("t"), f = root.appendingPathComponent("f")
        let src = try tempDir()
        let file = src.appendingPathComponent("a.txt")
        try Data("A".utf8).write(to: file)
        let ids = [copies.add(.text("文字")), copies.add(.image([9, 8, 7])),
                   copies.add(.data(uti: "public.rtf", [1, 2])), copies.add(.files([file]))]
        let kinds = ["text", "image", "data", "files"]
        for (id, kind) in zip(ids, kinds) {
            let url = try XCTUnwrap(try copies.save(id, textDir: t, fileDir: f, stem: "s"))
            let loaded = try XCTUnwrap(copies.load(url))
            XCTAssertEqual(loaded.kind, kind)
            XCTAssertTrue(copies.write(loaded.n, to: pb))
            switch kind {
            case "text": XCTAssertEqual(pb.string, "文字")
            case "image": XCTAssertEqual(pb.data(uti: typePNG), [9, 8, 7])
            case "data": XCTAssertEqual(pb.data(uti: "public.rtf"), [1, 2])
            default: XCTAssertEqual(pb.fileURLs().map(\.lastPathComponent), ["a.txt"])
            }
        }
        XCTAssertNil(copies.load(root.appendingPathComponent("missing.md")))
    }

    func testLoadFilesFolderSortsAndSkipsDotFiles() throws {
        let root = try tempDir()
        let dir = root.appendingPathComponent("d")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in ["b", "a", ".hidden"] { try Data().write(to: dir.appendingPathComponent(name)) }
        let loaded = try XCTUnwrap(copies.load(dir))
        guard case let .files(urls)? = copies.copy(loaded.n) else { return XCTFail("not files") }
        XCTAssertEqual(urls.map(\.lastPathComponent), ["a", "b"])
    }

    func testUnknownCopyIsNil() throws {
        let root = try tempDir()
        XCTAssertNil(try copies.save(99, textDir: root, fileDir: root, stem: "s"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }
}
