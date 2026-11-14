import Foundation
import RappCore

/// The most a single block may hold (A refuses more).
public let maxComposerBytes: UInt64 = 256 << 20

/// The embedded GUI's composer, minus the editor: the editor (text, cursor, block chips) lives in
/// Dart; this keeps what the blocks stand for and sends the editor's pieces to A through a `Sender`.
/// Same rules as `rapp-client`'s `Composer` (clipboard-composer spec §4.1, §4.2).
///
/// Threading: everything here, like the `Sender`, `ComposerBlocks` and `TransferQueue` it uses, lives
/// on the **main queue**. `send` must be safe to call from main (the session hops it onto its queue);
/// `emit` is called on main.
public final class EmbeddedComposer: ComposerSink {
    private let pasteboard: LocalPasteboard
    private let blocks = ComposerBlocks()
    private let emit: (ComposerEvent) -> Void
    private var sender: Sender?

    public init(pasteboard: LocalPasteboard, transfers: TransferQueue, counters: SendCounters,
                send: @escaping (Message) -> Void, emit: @escaping (ComposerEvent) -> Void) {
        self.pasteboard = pasteboard
        self.emit = emit
        sender = Sender(sink: self, transfers: transfers, counters: counters, send: send)
    }

    // MARK: Into the editor

    /// Main queue. ⌘V in the editor: what B's clipboard holds, by the paste rule.
    public func paste() -> PasteResult {
        // A copied block is a bare object-replacement character in text; never insert one.
        let text = pasteboard.string?.replacingOccurrences(of: "\u{FFFC}", with: "")
        switch pasteDecision(types: pasteboard.types, text: text) {
        case .files:
            return attach(pasteboard.fileURLs())
        case .image:
            guard let image = pasteboard.imagePNG() else { return .nothing }
            return .blocks([add(.image(png: image.png, width: image.width, height: image.height))])
        case let .inlineText(text):
            return .text(text)
        case let .textChunk(text):
            return .blocks([add(.text(text))])
        case let .data(uti):
            guard let bytes = pasteboard.data(uti: uti) else { return .nothing }
            return data(uti: uti, bytes)
        case .nothing:
            return .nothing
        }
    }

    /// Main queue. 「附件」 (or pasted files): one block per file. A folder or a file over 256 MB is
    /// refused with a line; when other files of the same pick became blocks, that line goes out as
    /// `.insert(.status)` and the blocks are returned.
    public func attach(_ urls: [URL]) -> PasteResult {
        var chips = [BlockChip]()
        var refusal: String?
        for url in urls {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            if values?.isDirectory == true {
                refusal = refusal ?? "不支持文件夹：\(url.lastPathComponent)"
                continue
            }
            let bytes = UInt64(max(values?.fileSize ?? 0, 0))
            if bytes > maxComposerBytes {
                refusal = refusal ?? Self.tooBig
                continue
            }
            chips.append(add(.file(url, bytes: bytes)))
        }
        guard !chips.isEmpty else { return refusal.map { .status($0) } ?? .nothing }
        if let refusal { emit(.insert(.status(refusal))) }
        return .blocks(chips)
    }

    /// Main queue. A clip's 「插入」: text by the paste rule, the rest as blocks; goes out as `.insert`.
    public func insert(_ info: ClipInfo, _ payload: InsertPayload) {
        let result: PasteResult
        switch (payload, info) {
        case let (.text(text), _):
            switch pasteDecision(types: [typeUTF8Text], text: text.replacingOccurrences(of: "\u{FFFC}", with: "")) {
            case let .inlineText(text): result = .text(text)
            case let .textChunk(text): result = .blocks([add(.text(text))])
            default: result = .nothing
            }
        case let (.bytes(png), .image(width, height, _)):
            result = .blocks([add(.image(png: png, width: Int(width), height: Int(height)))])
        case let (.bytes(bytes), .data(uti, _)):
            result = data(uti: uti, bytes)
        case let (.files(urls), _):
            result = attach(urls)
        default:
            result = .nothing
        }
        if result != .nothing { emit(.insert(result)) }
    }

    /// Main queue. A chip was removed from the editor.
    public func drop(_ n: Int) { blocks.remove(n) }

    // MARK: To A

    /// Main queue. Sends the editor's pieces in order; ignored while a round is running.
    public func send(_ pieces: [ComposerPiece]) { sender?.start(pieces: pieces) }

    /// Main queue. A's answer to a `paste`; false when it is not this composer's.
    public func pasted(seq: UInt32, error: String) -> Bool { sender?.pasted(seq: seq, error: error) ?? false }

    // MARK: ComposerSink (main queue, from the Sender)

    public func payload(_ chunk: Int) -> ChipPayload? { blocks.payload(chunk) }
    public func uploadedItem(_ chunk: Int) -> UInt32? { blocks.uploadedItem(chunk) }
    public func setUploadedItem(_ item: UInt32, for chunk: Int) { blocks.setUploadedItem(item, for: chunk) }
    public func setSending(_ on: Bool) { emit(.sending(on)) }

    /// The editor drops what went (and tells us which blocks with `drop`), unless it changed meanwhile.
    public func finished(pieces: [ComposerPiece], sent: Int, failure: String?) {
        emit(.done(sent: sent, failure: failure))
    }

    // MARK: Blocks

    private static let tooBig = "太大了，远端最多收 256 MB"

    private func add(_ payload: ChipPayload) -> BlockChip {
        let n = blocks.add(payload)
        return BlockChip(n: n, label: blocks.label(n) ?? "")
    }

    private func data(uti: String, _ bytes: [UInt8]) -> PasteResult {
        guard UInt64(bytes.count) <= maxComposerBytes else { return .status(Self.tooBig) }
        return .blocks([add(.data(uti: uti, bytes))])
    }
}
