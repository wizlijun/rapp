import XCTest
@testable import RappCore

final class TransferTests: XCTestCase {
    var dir: URL!
    var uploads: URL { dir.appendingPathComponent("uploads") }

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func bytes(_ n: Int) -> [UInt8] { (0..<n).map { _ in UInt8.random(in: 0...255) } }
    private func store(limit: Int = 256 << 20) -> TransferStore {
        TransferStore(clips: ClipStore(changeCount: 0), uploads: uploads, memoryLimit: limit)
    }
    private func fileClip(_ s: TransferStore, _ data: [UInt8]) throws -> (UInt32, URL) {
        let url = dir.appendingPathComponent("src.bin")
        try Data(data).write(to: url)
        let a = try FileManager.default.attributesOfItem(atPath: url.path)
        let ref = FileRef(url: url, size: UInt64(data.count), modified: a[.modificationDate] as! Date)
        let c = s.clips.add(.files([ClipFile(name: "src.bin", bytes: ref.size)]), payload: .files([ref]))
        return (c.id, url)
    }
    private func drain(_ f: FetchSource) throws -> [[UInt8]] {
        var out: [[UInt8]] = []
        while let c = try f.next() { out.append(c) }
        return out
    }
    private func assertThrows(_ reason: String, file: StaticString = #filePath, line: UInt = #line, _ body: () throws -> Void) {
        XCTAssertThrowsError(try body(), file: file, line: line) { XCTAssertEqual($0 as? TransferError, TransferError(reason), file: file, line: line) }
    }

    func testChangeWhileOtherAppFrontmostIsNotRecorded() {
        let s = ClipStore(changeCount: 10)
        XCTAssertFalse(s.changed(changeCount: 11, targetFrontmost: false))
        XCTAssertFalse(s.changed(changeCount: 11, targetFrontmost: true))
        XCTAssertTrue(s.changed(changeCount: 12, targetFrontmost: true))
    }
    func testOwnWritesAreNotRecorded() {
        let s = ClipStore(changeCount: 1); s.noteOwnWrite(changeCount: 2)
        XCTAssertFalse(s.changed(changeCount: 2, targetFrontmost: true))
        XCTAssertTrue(s.changed(changeCount: 3, targetFrontmost: true))
    }
    func testStoreKeepsFiftyNumberedFromOne() {
        let s = ClipStore(changeCount: 0)
        for i in 0..<51 { s.add(.text("\(i)", truncated: false), payload: .inline) }
        XCTAssertNil(s.clip(1)); XCTAssertEqual(s.clip(2)?.info, .text("1", truncated: false)); XCTAssertEqual(s.clip(51)?.id, 51)
    }
    func testFetchResumesFromOffset() throws {
        let data = bytes(600 * 1024)
        let s = store(); let (id, _) = try fileClip(s, data)
        let first = try s.fetch(clip: id, file: 0, offset: 0)
        XCTAssertEqual(first.total, 600 * 1024)
        let c1 = try XCTUnwrap(first.next())
        XCTAssertLessThanOrEqual(c1.count, chunkSize)
        let rest = try s.fetch(clip: id, file: 0, offset: UInt64(c1.count))
        let chunks = try drain(rest)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= chunkSize })
        XCTAssertEqual(c1 + chunks.flatMap { $0 }, data)
    }
    func testFetchOfImageFromMemory() throws {
        let s = store(); let data = bytes(1000)
        let c = s.clips.add(.image(width: 1, height: 1, bytes: 1000), payload: .bytes(data))
        XCTAssertEqual(try drain(try s.fetch(clip: c.id, file: 0, offset: 0)).flatMap { $0 }, data)
        assertThrows("unknown clip") { _ = try s.fetch(clip: c.id, file: 1, offset: 0) }
    }
    func testFetchOfUnknownClipFails() {
        let s = store()
        let t = s.clips.add(.text("x", truncated: false), payload: .inline)
        assertThrows("unknown clip") { _ = try s.fetch(clip: 99, file: 0, offset: 0) }
        assertThrows("unknown clip") { _ = try s.fetch(clip: t.id, file: 0, offset: 0) }
    }
    func testFetchOffsetPastTotalFails() throws {
        let s = store(); let (id, _) = try fileClip(s, bytes(10))
        assertThrows("unknown clip") { _ = try s.fetch(clip: id, file: 0, offset: 11) }
    }
    func testFetchOfChangedFileFails() throws {
        let s = store(); let (id, url) = try fileClip(s, bytes(100))
        let h = try FileHandle(forWritingTo: url); try h.seekToEnd(); try h.write(contentsOf: Data([1])); try h.close()
        assertThrows("file changed") { _ = try s.fetch(clip: id, file: 0, offset: 0) }
    }
    func testPutResumesWithHave() throws {
        let s = store(); let data = bytes(300 * 1024)
        var sink: PutSink? = try s.put(item: 1, kind: .files, uti: "", name: "app.log", total: 300 * 1024)
        XCTAssertFalse(try sink!.write(Array(data[..<(100 * 1024)])))
        sink = nil
        let again = try s.put(item: 1, kind: .files, uti: "", name: "app.log", total: 300 * 1024)
        XCTAssertEqual(again.have, 100 * 1024)
        XCTAssertTrue(try again.write(Array(data[(100 * 1024)...])))
        let final = uploads.appendingPathComponent("app.log")
        XCTAssertEqual(s.received(1), .file(final))
        XCTAssertEqual([UInt8](try Data(contentsOf: final)), data)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: uploads.path).contains { $0.hasSuffix(".rapp-part") })
    }
    func testPutOfCompleteItemReportsHaveEqualsTotal() throws {
        let s = store()
        let sink = try s.put(item: 1, kind: .files, uti: "", name: "a.txt", total: 3)
        XCTAssertTrue(try sink.write([1, 2, 3]))
        let again = try s.put(item: 1, kind: .files, uti: "", name: "a.txt", total: 3)
        XCTAssertEqual(again.have, again.total)
        XCTAssertEqual(s.received(1), .file(uploads.appendingPathComponent("a.txt")))
    }
    func testPutWithDifferentTotalStartsOver() throws {
        let s = store()
        let sink = try s.put(item: 1, kind: .files, uti: "", name: "a.txt", total: 10)
        _ = try sink.write([1, 2, 3])
        XCTAssertEqual(try s.put(item: 1, kind: .files, uti: "", name: "a.txt", total: 20).have, 0)
    }
    func testPutNamesAreSafeAndUnique() throws {
        try FileManager.default.createDirectory(at: uploads, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: uploads.appendingPathComponent("app.log"))
        let s = store()
        let sink = try s.put(item: 1, kind: .files, uti: "", name: "../app.log", total: 2)
        XCTAssertTrue(try sink.write([1, 2]))
        XCTAssertEqual(s.received(1), .file(uploads.appendingPathComponent("app (2).log")))
    }
    func testPutTextInMemoryAndLimit() throws {
        let s = store(limit: 10)
        assertThrows("too large") { _ = try s.put(item: 1, kind: .text, uti: "", name: "", total: 11) }
        let sink = try s.put(item: 2, kind: .text, uti: "", name: "", total: 6)
        XCTAssertTrue(try sink.write(Array("你好".utf8)))
        XCTAssertEqual(s.received(2), .text("你好"))
    }
    func testWriteBeyondTotalFails() throws {
        let sink = try store().put(item: 1, kind: .image, uti: "", name: "", total: 2)
        assertThrows("too large") { _ = try sink.write([1, 2, 3]) }
    }
    func testReceivedIsNilUntilComplete() throws {
        let s = store()
        let sink = try s.put(item: 1, kind: .data, uti: "com.x", name: "", total: 2)
        XCTAssertNil(s.received(1))
        _ = try sink.write([1])
        XCTAssertNil(s.received(1))
        _ = try sink.write([2])
        XCTAssertEqual(s.received(1), .data(uti: "com.x", [1, 2]))
    }
    func testSideSlotsLimitFour() {
        let s = SideSlots()
        for _ in 0..<4 { XCTAssertTrue(s.take()) }
        XCTAssertFalse(s.take())
        s.release()
        XCTAssertTrue(s.take())
    }
}
