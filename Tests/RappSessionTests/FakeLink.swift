import Foundation
import RappCore
import RappSession

/// A MessageLink that records what is sent and lets a test feed messages.
final class FakeLink: MessageLink {
    var onMessage: ((Message) -> Void)?
    var onClosed: ((String) -> Void)?
    var onBytes: ((Int) -> Void)?
    var density: Float = 1
    private(set) var started = false
    private(set) var cancelled = false
    private(set) var sent = [Message]()

    func start() { started = true }
    func send(_ message: Message) { sent.append(message) }
    func cancel() { cancelled = true }

    func feed(_ message: Message) { onMessage?(message) }
    func drop(_ reason: String) { onClosed?(reason) }
}
