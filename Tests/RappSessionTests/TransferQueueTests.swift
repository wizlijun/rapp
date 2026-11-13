import XCTest
import RappCore
@testable import RappSession

final class TransferQueueTests: XCTestCase {
    private var directory: URL!
    private var host: FakeSideHost!
    private var queue: TransferQueue!
    private var events: [TransferProgress] = []
    private var statuses: [String?] = []
    private let content = (0..<300_000).map { UInt8($0 % 251) }

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("rapp-test-\(UUID().uuidString)")
    }

    override func tearDown() {
        queue?.cancel()
        host?.stop()
        try? FileManager.default.removeItem(at: directory)
    }

    private func start(failWith: String? = nil, pauseAfter: Int? = nil) throws {
        host = try FakeSideHost(serving: content, failWith: failWith, pauseAfter: pauseAfter)
        let address = RemoteAddress(host: "127.0.0.1", port: host.port, bundleID: "x", token: "t", mode: .color16)
        queue = TransferQueue(address: address, downloads: directory)
        queue.onProgress = { [unowned self] in events.append($0) }
        queue.onStatus = { [unowned self] in statuses.append($0) }
    }

    private func wait(_ what: String, timeout: TimeInterval = 10, until condition: @escaping () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertTrue(condition(), "timed out: \(what)")
    }

    private func events(_ id: UInt32) -> [TransferProgress] { events.filter { $0.id == id } }
    private func last(_ id: UInt32) -> TransferState? { events(id).last?.state }
    private func isFinal(_ id: UInt32) -> Bool { last(id).map { $0 != .running } ?? false }

    func testDownloadReportsIdsAndProgressThenDone() throws {
        try start()
        let first = queue.download(clip: 1, file: 0, name: "a.bin", total: 300_000, toDisk: true) { _ in }
        let second = queue.download(clip: 1, file: 1, name: "b.bin", total: 300_000, toDisk: false) { _ in }
        XCTAssertEqual(first, 1)
        XCTAssertEqual(second, 2)
        wait("both done") { self.isFinal(1) && self.isFinal(2) }

        let a = events(1)
        XCTAssertEqual(a.first?.state, .running)
        XCTAssertEqual(a.first?.done, 0)
        XCTAssertEqual(a.first?.dir, .down)
        XCTAssertEqual(a.first?.name, "a.bin")
        XCTAssertNil(a.first?.kind)
        XCTAssertEqual(a.map(\.done), a.map(\.done).sorted())
        for (x, y) in zip(a, a.dropFirst()) where x.state == .running && y.state == .running {
            XCTAssertNotEqual(x.done * 100 / x.total, y.done * 100 / y.total)
        }
        XCTAssertEqual(a.last?.state, .done)
        XCTAssertEqual(a.last?.path, directory.appendingPathComponent("a.bin").path)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("a.bin")), Data(content))
        XCTAssertEqual(events(2).last?.state, .done)
        XCTAssertNil(events(2).last?.path)
    }

    func testDownloadsGoToTheInjectedDirectory() throws {
        let real = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("rapp/a.bin").path
        let before = FileManager.default.fileExists(atPath: real)
        try start()
        queue.download(clip: 1, file: 0, name: "a.bin", total: 300_000, toDisk: true) { _ in }
        wait("done") { self.isFinal(1) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("a.bin").path))
        XCTAssertEqual(FileManager.default.fileExists(atPath: real), before)
    }

    func testCancelByIdLeavesOthersAndKeepsPart() throws {
        try start(pauseAfter: 128 * 1024)
        queue.download(clip: 1, file: 0, name: "a.bin", total: 300_000, toDisk: true) { _ in }
        queue.download(clip: 1, file: 1, name: "b.bin", total: 300_000, toDisk: false) { _ in }
        wait("A received 64 KB") { (self.events(1).last?.done ?? 0) >= 64 * 1024 }
        queue.cancel(id: 1)
        XCTAssertEqual(last(1), .cancelled)
        let part = directory.appendingPathComponent("a.bin.rapp-part")
        let size = (try? FileManager.default.attributesOfItem(atPath: part.path))?[.size] as? UInt64 ?? 0
        XCTAssertGreaterThan(size, 0)
        wait("B started") { self.host.fetches.count == 2 }
        XCTAssertEqual(events(2).first?.state, .running)
        XCTAssertNotEqual(last(2), .cancelled)
    }

    func testCancelQueuedById() throws {
        try start()
        queue.download(clip: 1, file: 0, name: "a.bin", total: 300_000, toDisk: true) { _ in }
        queue.download(clip: 1, file: 1, name: "b.bin", total: 300_000, toDisk: false) { _ in }
        queue.cancel(id: 2)
        XCTAssertEqual(last(2), .cancelled)
        wait("A done") { self.isFinal(1) }
        XCTAssertEqual(last(1), .done)
        XCTAssertEqual(host.fetches.count, 1)
    }

    func testCancelUnknownIdDoesNothing() throws {
        try start()
        queue.cancel(id: 99)
        XCTAssertTrue(events.isEmpty)
    }

    func testCancelAllStillCancelsEverything() throws {
        try start(pauseAfter: 64 * 1024)
        queue.download(clip: 1, file: 0, name: "a.bin", total: 300_000, toDisk: true) { _ in }
        queue.download(clip: 1, file: 1, name: "b.bin", total: 300_000, toDisk: false) { _ in }
        queue.cancel()
        XCTAssertEqual(last(1), .cancelled)
        XCTAssertEqual(last(2), .cancelled)
        XCTAssertEqual(statuses.last ?? "x", nil)
    }

    func testUploadProgressCarriesTheFileNameNotTheStripLabel() throws {
        try start(pauseAfter: 0)
        let file = queue.upload(item: 1, kind: .files, uti: "public.data", name: "report.pdf", data: .bytes([1, 2, 3]),
                                label: "2/3 · report.pdf") { _ in }
        let image = queue.upload(item: 2, kind: .image, uti: "public.png", name: "", data: .bytes([4]), label: "3/3") { _ in }
        queue.cancel()
        XCTAssertEqual(events(file).first?.dir, .up)
        XCTAssertEqual(events(file).map(\.name), Array(repeating: "report.pdf", count: events(file).count))
        XCTAssertEqual(events(image).map(\.name), Array(repeating: "", count: events(image).count))
        XCTAssertEqual(events(image).last?.state, .cancelled)
        XCTAssertEqual(events(file).last?.kind, .files)
        XCTAssertEqual(events(image).last?.kind, .image)
        XCTAssertNil(events.first { $0.dir == .up && $0.kind == nil })
    }

    func testHostErrorIsFailedWithReason() throws {
        try start(failWith: "unknown clip")
        queue.download(clip: 9, file: 0, name: "a.bin", total: 10, toDisk: false) { _ in }
        wait("failed") { self.isFinal(1) }
        XCTAssertEqual(events.last?.state, .failed)
        XCTAssertEqual(events.last?.error, "unknown clip")
    }
}
