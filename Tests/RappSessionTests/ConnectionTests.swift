import Network
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

/// A message sent before the TCP connection is ready must not overtake the hello: A rejects a
/// connection whose first message is anything else ("first message must be hello, fetch or put").
final class ConnectionHelloFirstTests: XCTestCase {
    func testMessagesSentBeforeReadyFollowTheHello() throws {
        let listener = try NWListener(using: .tcp, on: .any)
        let queue = DispatchQueue(label: "rapp.test.hello-first")
        var parser = MessageParser()
        var received: [Message] = []
        let got = expectation(description: "two messages")
        listener.newConnectionHandler = { conn in
            conn.start(queue: queue)
            func read() {
                conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { data, _, done, _ in
                    if let data { parser.append([UInt8](data)) }
                    while let m = try? parser.next() { received.append(m) }
                    if received.count >= 2 { got.fulfill(); return }
                    if !done { read() }
                }
            }
            read()
        }
        let up = expectation(description: "listening")
        listener.stateUpdateHandler = { if case .ready = $0 { up.fulfill() } }
        listener.start(queue: queue)
        wait(for: [up], timeout: 2)

        let address = RemoteAddress(host: "127.0.0.1", port: listener.port!.rawValue, bundleID: "x", token: "t", mode: .color16)
        let connection = Connection(address: address, queue: DispatchQueue(label: "rapp.test.hello-first.client"))
        connection.start()
        connection.send(.menuPick([1]))  // before `.ready`, as a reconnect's first set_view is
        wait(for: [got], timeout: 3)
        connection.cancel()
        listener.cancel()

        guard case .hello = received[0] else { return XCTFail("first message: \(received[0])") }
        XCTAssertEqual(received[1], .menuPick([1]))
    }
}
