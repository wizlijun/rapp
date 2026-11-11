import Foundation
import Network
import RappCore

/// One `fetch` or `put` connection (spec §2.4): it carries a single transfer.
/// Everything runs on the main queue. After `cancel()` no callback is made.
final class SideConnection {
    enum End {
        /// A sent `error`; retrying would not help.
        case hostError(String)
        /// The connection broke or closed.
        case disconnected
    }

    /// The host's `transferStart`: the total size (fetch) or the bytes it already has (put).
    var onStart: ((UInt64) -> Void)?
    var onChunk: (([UInt8]) -> Void)?
    var onEnd: ((End) -> Void)?

    private let connection: NWConnection
    private let first: Message
    private var parser = MessageParser()
    private var closed = false

    init(address: RemoteAddress, first: Message) {
        self.first = first
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        connection = NWConnection(host: NWEndpoint.Host(address.host),
                                  port: NWEndpoint.Port(rawValue: address.port) ?? NWEndpoint.Port(rawValue: defaultPort)!,
                                  using: NWParameters(tls: nil, tcp: tcp))
    }

    /// Connects and sends the `fetch` or `put`.
    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.send(self.first)
                self.receive()
            case .waiting, .failed, .cancelled:
                self.close(.disconnected)
            default:
                break
            }
        }
        connection.start(queue: .main)
    }

    /// `then` runs once the message has left, so an upload can pace itself on it.
    func send(_ message: Message, then next: (() -> Void)? = nil) {
        guard !closed else { return }
        connection.send(content: Data(message.encoded()), completion: .contentProcessed { [weak self] error in
            guard let self, !self.closed else { return }
            if error != nil { self.close(.disconnected) } else { next?() }
        })
    }

    /// Stops without a callback.
    func cancel() {
        guard !closed else { return }
        closed = true
        connection.cancel()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self, !self.closed else { return }
            if let data, !data.isEmpty {
                self.parser.append([UInt8](data))
                do {
                    while let message = try self.parser.next() {
                        self.handle(message)
                        if self.closed { return }
                    }
                } catch {
                    self.close(.disconnected)
                    return
                }
            }
            if error != nil || isComplete {
                self.close(.disconnected)
            } else {
                self.receive()
            }
        }
    }

    private func handle(_ message: Message) {
        switch message {
        case let .transferStart(n): onStart?(n)
        case let .chunk(bytes): onChunk?(bytes)
        case let .error(reason): close(.hostError(reason))
        default: close(.disconnected)
        }
    }

    private func close(_ end: End) {
        guard !closed else { return }
        closed = true
        connection.cancel()
        onEnd?(end)
    }
}
