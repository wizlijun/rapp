import AppKit
import RappCore
import UniformTypeIdentifiers

/// The numbers of items uploaded and pastes sent, one counter each per client process (starting at 1).
final class SendCounters {
    private var item: UInt32 = 0
    private var seq: UInt32 = 0

    func nextItem() -> UInt32 { item += 1; return item }
    func nextSeq() -> UInt32 { seq += 1; return seq }
}

/// Sends one window's composer content to A, item by item (spec §4.2): upload
/// what needs it, `paste`, wait for `pasted`, then the next. The editor stays
/// editable meanwhile; the round works on what was there when it began.
final class Sender {
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

    private weak var bar: ComposerBar?
    private let transfers: TransferQueue
    private let counters: SendCounters
    private let send: (Message) -> Void
    private var round: Round?
    /// The `paste` whose `pasted` is awaited.
    private var awaiting: UInt32?

    init(bar: ComposerBar, transfers: TransferQueue, counters: SendCounters, send: @escaping (Message) -> Void) {
        self.bar = bar
        self.transfers = transfers
        self.counters = counters
        self.send = send
    }

    /// Return or the send button; ignored while a send is running.
    func start() {
        guard round == nil, let bar else { return }
        let composer = bar.composer
        let pieces = composer.pieces()
        let items = composerItems(pieces)
        var payloads: [Int: ChipPayload] = [:]
        var uploads = 0
        for item in items {
            switch item.content {
            case let .chunk(chip):
                payloads[chip] = composer.payload(chip)
                uploads += 1
            case let .text(text):
                if needsUpload(text) { uploads += 1 }
            }
        }
        round = Round(pieces: pieces, items: items, payloads: payloads, uploads: uploads)
        bar.setSending(true)
        step()
    }

    /// A's answer to a `paste`; false when it is not this sender's.
    func pasted(seq: UInt32, error: String) -> Bool {
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
        guard let r = round, let bar else { return }
        guard r.index < r.items.count else { return finish(failure: nil) }
        switch r.items[r.index].content {
        case let .text(text) where !needsUpload(text):
            paste(.text(text))
        case let .text(text):
            upload(item: counters.nextItem(), kind: .text, uti: typeUTF8Text, name: "", data: .bytes(Array(text.utf8)))
        case let .chunk(chip):
            guard let payload = r.payloads[chip] else { return finish(failure: "找不到这一块的内容") }
            // The number goes on the block first, so a resend after a failure continues this upload.
            let composer = bar.composer
            let item = composer.uploadedItem(chip) ?? counters.nextItem()
            composer.setUploadedItem(chip, item)
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
            case let .failure(failure): self?.finish(failure: "上传失败：\(failure.reason)")
            }
        }
    }

    private func paste(_ source: PasteSource) {
        guard round != nil else { return }
        let seq = counters.nextSeq()
        awaiting = seq
        send(.paste(seq: seq, source))
    }

    /// Ends the round: all done (`failure` nil), or the message to show. What was pasted is
    /// removed from the editor, unless the user has changed that part meanwhile.
    private func finish(failure: String?) {
        guard let r = round else { return }
        round = nil
        awaiting = nil
        guard let bar else { return }
        bar.setSending(false)
        let composer = bar.composer
        let length = failure == nil ? r.pieces.reduce(0) { $0 + pieceLength($1) } : r.pastedEnd
        var lines = failure.map { [$0] } ?? []
        if length > 0 {
            if composerPrefixMatches(r.pieces, composer.pieces(), length: length) {
                composer.removeUpTo(length)
            } else {
                lines.append("（发送中改过内容，未清除）")
            }
        }
        bar.setStatus(lines.isEmpty ? nil : lines.joined(separator: " "))
    }

    private func pieceLength(_ piece: ComposerPiece) -> Int {
        switch piece {
        case let .text(text): return text.utf16.count
        case .chunk: return 1
        }
    }
}
