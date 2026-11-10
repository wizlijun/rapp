import Foundation
import Network
import RappCore

/// The client's side of the connection. Everything runs on the main queue.
final class Connection {
    var onMessage: ((Message) -> Void)?
    var onClosed: ((String) -> Void)?
    /// Called with the size of every chunk received, headers included.
    var onBytes: ((Int) -> Void)?

    private let address: RemoteAddress
    private let connection: NWConnection
    private var parser = MessageParser()
    private var closed = false

    init(address: RemoteAddress) {
        self.address = address
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        connection = NWConnection(host: NWEndpoint.Host(address.host),
                                  port: NWEndpoint.Port(rawValue: address.port) ?? NWEndpoint.Port(rawValue: defaultPort)!,
                                  using: NWParameters(tls: nil, tcp: tcp))
    }

    /// Capture pixels per A point announced in the hello; set before `start()`.
    var density: Float = 2

    /// Connects and introduces itself with a hello message.
    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.send(.hello(token: self.address.token, bundleID: self.address.bundleID,
                                 mode: self.address.mode, fps: self.address.fps, density: self.density))
                self.receive()
            case let .waiting(error):
                self.close("cannot reach \(self.address.host):\(self.address.port) (\(error.localizedDescription))")
            case let .failed(error):
                self.close("connection failed: \(error.localizedDescription)")
            case .cancelled:
                self.close("connection closed")
            default:
                break
            }
        }
        connection.start(queue: .main)
    }

    func send(_ message: Message) {
        guard !closed else { return }
        connection.send(content: Data(message.encoded()), completion: .contentProcessed { [weak self] error in
            if let error { self?.close("send failed: \(error.localizedDescription)") }
        })
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self, !self.closed else { return }
            if let data, !data.isEmpty {
                self.onBytes?(data.count)
                self.parser.append([UInt8](data))
                do {
                    while let message = try self.parser.next() {
                        self.onMessage?(message)
                        if self.closed { return }
                    }
                } catch {
                    self.close("bad data from host: \(error)")
                    return
                }
            }
            if let error {
                self.close("connection error: \(error.localizedDescription)")
            } else if isComplete {
                self.close("the host closed the connection")
            } else {
                self.receive()
            }
        }
    }

    private func close(_ reason: String) {
        guard !closed else { return }
        closed = true
        connection.cancel()
        onClosed?(reason)
    }
}
