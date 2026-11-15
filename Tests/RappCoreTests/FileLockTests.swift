import XCTest
@testable import RappCore

final class FileLockTests: XCTestCase {
    private struct Boom: Error {}

    private func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("filelock-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: d) }
        return d
    }

    func testSecondHolderWaits() throws {
        let url = tempDir().appendingPathComponent("x.lock")
        let events = NSMutableArray()
        let guardLock = NSLock()
        func add(_ s: String) { guardLock.lock(); events.add(s); guardLock.unlock() }
        let done = DispatchGroup()
        done.enter()
        DispatchQueue.global().async {
            try? FileLock.exclusive(at: url) { add("1-in"); Thread.sleep(forTimeInterval: 0.3); add("1-out") }
            done.leave()
        }
        Thread.sleep(forTimeInterval: 0.05)
        done.enter()
        DispatchQueue.global().async {
            try? FileLock.exclusive(at: url) { add("2-in"); add("2-out") }
            done.leave()
        }
        done.wait()
        XCTAssertEqual(events as? [String], ["1-in", "1-out", "2-in", "2-out"])
    }

    func testReleasedOnThrow() throws {
        let url = tempDir().appendingPathComponent("x.lock")
        XCTAssertThrowsError(try FileLock.exclusive(at: url) { throw Boom() })
        let start = Date()
        XCTAssertEqual(try FileLock.exclusive(at: url) { 7 }, 7)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)
    }

    func testCreatesMissingDirectory() throws {
        let url = tempDir().appendingPathComponent("a/b/x.lock")
        XCTAssertEqual(try FileLock.exclusive(at: url) { 1 }, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }
}
