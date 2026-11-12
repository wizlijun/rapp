import Foundation
import Network
import RappCore

/// A stand-in for A's side-connection listener: answers `fetch` with the served bytes.
/// Binds 127.0.0.1 on an ephemeral port; runs on its own queue.
final class FakeSideHost {
    private(set) var port: UInt16 = 0
    private let listener: NWListener
    private let queue = DispatchQueue(label: "FakeSideHost")
    private let serving: [UInt8]
    private let failWith: String?
    private let pauseAfter: Int?
    private let lock = NSLock()
    private var _fetches: [UInt64] = []
    private var connections: [NWConnection] = []

    /// The offset of every `fetch` received so far.
    var fetches: [UInt64] { lock.lock(); defer { lock.unlock() }; return _fetches }

    /// `pauseAfter`: stop sending after this many bytes and keep the connection open.
    init(serving: [UInt8], failWith: String? = nil, pauseAfter: Int? = nil) throws {
        self.serving = serving
        self.failWith = failWith
        self.pauseAfter = pauseAfter
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: params)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success, let p = listener.port?.rawValue else {
            throw CocoaError(.fileReadUnknown)
        }
        port = p
    }

    func stop() {
        listener.cancel()
        lock.lock()
        let all = connections
        connections = []
        lock.unlock()
        for c in all { c.cancel() }
    }

    private func accept(_ connection: NWConnection) {
        lock.lock(); connections.append(connection); lock.unlock()
        var parser = MessageParser()
        connection.start(queue: queue)
        func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
                guard let self else { return }
                if let data, !data.isEmpty {
                    parser.append([UInt8](data))
                    while let message = try? parser.next() {
                        if case let .fetch(_, _, _, offset) = message { self.serve(connection, offset: offset) }
                    }
                }
                if error == nil, !isComplete { receive() }
            }
        }
        receive()
    }

    private func serve(_ connection: NWConnection, offset: UInt64) {
        lock.lock(); _fetches.append(offset); lock.unlock()
        if let failWith {
            return connection.send(content: Data(Message.error(failWith).encoded()), completion: .idempotent)
        }
        var out = Message.transferStart(UInt64(serving.count)).encoded()
        let limit = min(serving.count, pauseAfter ?? serving.count)
        var position = min(Int(offset), serving.count)
        while position < limit {
            let end = min(position + 64 * 1024, limit)
            out += Message.chunk(Array(serving[position..<end])).encoded()
            position = end
        }
        let finished = limit >= serving.count
        connection.send(content: Data(out), completion: .contentProcessed { error in
            if finished || error != nil { connection.cancel() }
        })
    }
}
