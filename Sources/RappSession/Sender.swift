import AppKit
import RappCore
import UniformTypeIdentifiers

/// What a send round needs from the editor it sends.
public protocol ComposerSink: AnyObject {
    func payload(_ chunk: Int) -> ChipPayload?
    func uploadedItem(_ chunk: Int) -> UInt32?
    func setUploadedItem(_ item: UInt32, for chunk: Int)
    func setSending(_ on: Bool)
    /// The round ended. `sent` is the number of leading `pieces` pasted into A completely; `failure` is nil
    /// when all went, else the message to show ("" keeps what the transfer strip says).
    func finished(pieces: [ComposerPiece], sent: Int, failure: String?)
}

/// Sends one window's composer content to A, item by item (spec §4.2): upload
/// what needs it, `paste`, wait for `pasted`, then the next. The editor stays
/// editable meanwhile; the round works on what was there when it began.
public final class Sender {
    private struct Round {
        let pieces: [ComposerPiece]
        let items: [ComposerItem]
        let payloads: [Int: ChipPayload]
        let uploads: Int
        var uploaded = 0
        /// The item being sent, and the editor offset up to which everything has been pasted.
        var index = 0
        var pastedEnd = 0
    }

    private weak var sink: ComposerSink?
    private let transfers: TransferQueue
    private let counters: SendCounters
    private let send: (Message) -> Void
    private var round: Round?
    /// The `paste` whose `pasted` is awaited.
    private var awaiting: UInt32?

    public init(sink: ComposerSink, transfers: TransferQueue, counters: SendCounters, send: @escaping (Message) -> Void) {
        self.sink = sink
        self.transfers = transfers
        self.counters = counters
        self.send = send
    }

    /// Return or the send button, with the editor's content; ignored while a send is running.
    public func start(pieces: [ComposerPiece]) {
        guard round == nil, let sink else { return }
        let items = composerItems(pieces)
        var payloads: [Int: ChipPayload] = [:]
        var uploads = 0
        for item in items {
            switch item.content {
            case let .chunk(chip):
                payloads[chip] = sink.payload(chip)
                uploads += 1
            case let .text(text):
                if needsUpload(text) { uploads += 1 }
            }
        }
        round = Round(pieces: pieces, items: items, payloads: payloads, uploads: uploads)
        sink.setSending(true)
        step()
    }

    /// A's answer to a `paste`; false when it is not this sender's.
    public func pasted(seq: UInt32, error: String) -> Bool {
        guard seq == awaiting else { return false }
        awaiting = nil
        if !error.isEmpty { finish(failure: pasteErrorMessage(error)) } else if var r = round {
            r.pastedEnd = r.items[r.index].end
            r.index += 1
            round = r
            step()
        }
        return true
    }

    // MARK: Steps

    private func step() {
        guard let r = round, let sink else { return }
        guard r.index < r.items.count else { return finish(failure: nil) }
        switch r.items[r.index].content {
        case let .text(text) where !needsUpload(text):
            paste(.text(text))
        case let .text(text):
            upload(item: counters.nextItem(), kind: .text, uti: typeUTF8Text, name: "", data: .bytes(Array(text.utf8)))
        case let .chunk(chip):
            guard let payload = r.payloads[chip] else { return finish(failure: "找不到这一块的内容") }
            // The number goes on the block first, so a resend after a failure continues this upload.
            let item = sink.uploadedItem(chip) ?? counters.nextItem()
            sink.setUploadedItem(item, for: chip)
            switch payload {
            case let .text(text):
                upload(item: item, kind: .text, uti: typeUTF8Text, name: "", data: .bytes(Array(text.utf8)))
            case let .image(png, _, _):
                upload(item: item, kind: .image, uti: typePNG, name: "", data: .bytes(png))
            case let .data(uti, bytes):
                upload(item: item, kind: .data, uti: uti, name: "", data: .bytes(bytes))
            case let .file(url, _):
                let uti = UTType(filenameExtension: url.pathExtension)?.identifier ?? "public.data"
                upload(item: item, kind: .files, uti: uti, name: url.lastPathComponent, data: .file(url))
            }
        }
    }

    private func upload(item: UInt32, kind: ClipKind, uti: String, name: String, data: UploadData) {
        guard var r = round else { return }
        r.uploaded += 1
        round = r
        // The queue prefixes this with "上传" and appends the percentage.
        let label = name.isEmpty ? "\(r.uploaded)/\(r.uploads)" : "\(r.uploaded)/\(r.uploads) · \(name)"
        transfers.upload(item: item, kind: kind, uti: uti, name: name, data: data, label: label) { [weak self] result in
            switch result {
            case .success: self?.paste(.item(item))
            // The queue has already shown why in the strip.
            case .failure: self?.finish(failure: "")
            }
        }
    }

    private func paste(_ source: PasteSource) {
        guard round != nil else { return }
        let seq = counters.nextSeq()
        awaiting = seq
        send(.paste(seq: seq, source))
    }

    /// Ends the round: all done (`failure` nil), or the message to show ("" keeps what the strip says).
    private func finish(failure: String?) {
        guard let r = round else { return }
        round = nil
        awaiting = nil
        guard let sink else { return }
        sink.setSending(false)
        // Pieces whose end lies within what was pasted.
        var sent = 0, end = 0
        if failure == nil {
            sent = r.pieces.count
        } else {
            for piece in r.pieces {
                end += pieceLength(piece)
                if end > r.pastedEnd { break }
                sent += 1
            }
        }
        sink.finished(pieces: r.pieces, sent: sent, failure: failure)
    }

    private func pieceLength(_ piece: ComposerPiece) -> Int {
        switch piece {
        case let .text(text): return text.utf16.count
        case .chunk: return 1
        }
    }
}
