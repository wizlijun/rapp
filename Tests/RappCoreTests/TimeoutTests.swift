import XCTest
@testable import RappCore

final class TimeoutTests: XCTestCase {
    func testFastOperationReturns() async throws {
        let v = try await withTimeout(seconds: 1) { 42 }
        XCTAssertEqual(v, 42)
    }

    func testOperationThatNeverReturnsTimesOut() async {
        let start = Date()
        do {
            _ = try await withTimeout(seconds: 0.2) {
                await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }  // never resumed
            }
            XCTFail("expected timeout")
        } catch {
            XCTAssertTrue(error is TimeoutError, "\(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
    }

    func testOperationErrorIsPassedThrough() async {
        do {
            _ = try await withTimeout(seconds: 1) { () async throws -> Int in throw CodecError("x") }
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error is CodecError, "\(error)")
        }
    }
}
