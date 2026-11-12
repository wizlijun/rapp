import RappCore
import XCTest
@testable import RappSession

final class ConnectionTests: XCTestCase {
    func testCancelDoesNotCallOnClosed() {
        let address = RemoteAddress(host: "127.0.0.1", port: 1, bundleID: "x", token: "t", mode: .color16)
        let queue = DispatchQueue(label: "rapp.test.connection")
        let connection = Connection(address: address, queue: queue)
        var closed = false
        connection.onClosed = { _ in closed = true }
        connection.start()
        connection.cancel()
        let settled = expectation(description: "settled")
        queue.asyncAfter(deadline: .now() + 0.3) { settled.fulfill() }
        wait(for: [settled], timeout: 2)
        XCTAssertFalse(closed)
    }
}
