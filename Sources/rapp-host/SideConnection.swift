import Foundation
import Network
import RappCore

/// One `fetch` or `put` connection (spec §2.4): it carries a single transfer
/// and closes. Lives on the session queue, like the `TransferStore` it uses.
final class SideConnection {
    private let connection: NWConnection
    private var parser: MessageParser
    private let first: Message
    private let token: String
    private let slots: SideSlots
    private let transfers: TransferStore?
    private let output: WorkerOutput
    private let queue: DispatchQueue
    private let onEnd: () -> Void

    private var tookSlot = false
    private var ended = false
    private var source: FetchSource?
    private var sink: PutSink?
    /// Set once the closing message has been sent; later input is ignored.
    private var finishing = false

    init(connection: NWConnection, parser: MessageParser, first: Message, token: String, slots: SideSlots,
         transfers: TransferStore?, output: WorkerOutput, queue: DispatchQueue, onEnd: @escaping () -> Void) {
        self.onEnd = onEnd
        self.connection = connection
        self.parser = parser
        self.first = first
        self.token = token
        self.slots = slots
        self.transfers = transfers
        self.output = output
        self.queue = queue
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.end()
            default: break
            }
        }
        guard slots.take() else { return fail("busy") }
        tookSlot = true
        do {
            switch first {
            case let .fetch(clientToken, clip, file, offset):
                guard constantTimeEquals(clientToken, token) else { return fail("bad token") }
                guard let transfers else { return fail("no session") }
                output.log("side fetch clip \(clip) file \(file) from \(offset)")
                let source = try transfers.fetch(clip: clip, file: file, offset: offset)
                self.source = source
                send(.transferStart(source.total)) { [weak self] in self?.sendNextChunk() }
            case let .put(clientToken, item, kind, uti, name, total):
                guard constantTimeEquals(clientToken, token) else { return fail("bad token") }
                guard let transfers else { return fail("no session") }
                let sink = try transfers.put(item: item, kind: kind, uti: uti, name: name, total: total)
                output.log("side put item \(item) have \(sink.have)")
                self.sink = sink
                send(.transferStart(sink.have))
                if sink.have == sink.total { return finish() }
            default:
                return fail("unexpected message from client")
            }
        } catch let error as TransferError {
            return fail(error.reason)
        } catch {
            return fail("write failed")
        }
        drain()
        receive()
    }

    // MARK: Fetch

    /// Each chunk goes out after the previous one has left, so a slow B holds the file reads back.
    private func sendNextChunk() {
        guard !ended else { return }
        do {
            if let chunk = try source?.next() {
                send(.chunk(chunk)) { [weak self] in self?.sendNextChunk() }
            } else {
                close()
            }
        } catch let error as TransferError {
            fail(error.reason)
        } catch {
            fail("file changed")
        }
    }

    // MARK: Put

    private func handle(_ message: Message) {
        guard !finishing else { return }
        guard let sink else { return }
        guard case let .chunk(bytes) = message else { return fail("unexpected message from client") }
        do {
            if try sink.write(bytes) { finish() }
        } catch let error as TransferError {
            fail(error.reason)
        } catch {
            fail("write failed")
        }
    }

    /// The upload is complete: an empty chunk tells B, then the connection closes.
    private func finish() {
        finishing = true
        send(.chunk([])) { [weak self] in self?.close() }
    }

    // MARK: Receiving

    private func drain() {
        do {
            while !ended, let message = try parser.next() { handle(message) }
        } catch {
            fail("bad data from client")
        }
    }

    private func receive() {
        guard !ended else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 512 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, !self.ended else { return }
            if let data, !data.isEmpty {
                self.parser.append([UInt8](data))
                self.drain()
            }
            if error != nil || isComplete {
                // A client that has sent everything may close at once; what is queued still goes out.
                if !self.finishing { self.end() }
            } else {
                self.receive()
            }
        }
    }

    // MARK: Sending and ending

    private func send(_ message: Message, then next: (() -> Void)? = nil) {
        connection.send(content: Data(message.encoded()), completion: .contentProcessed { [weak self] error in
            guard let self, !self.ended else { return }
            if error != nil { self.end() } else { next?() }
        })
    }

    private func fail(_ reason: String) {
        guard !ended else { return }
        finishing = true
        output.log("side connection: \(reason)")
        send(.error(reason)) { [weak self] in self?.close() }
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.end() }
    }

    private func close() { end() }

    private func end() {
        guard !ended else { return }
        ended = true
        if tookSlot { slots.release() }
        source = nil
        sink = nil
        connection.cancel()
        onEnd()
    }
}
