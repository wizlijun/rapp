import Foundation
import RappCore

/// What taking a history entry "into the composer" hands over once its content is on B.
public enum InsertPayload { case text(String), bytes([UInt8]), files([URL]) }

/// A's clipboard history (spec §4.4, §4.5): the last `limit` clips, newest first.
/// One per session. The menu that shows it lives in the client.
public final class ClipHistory {
    public static let limit = 20

    /// A clip arrived (the 复制 button waits for it).
    public var onClip: (() -> Void)?

    private let pasteboard: LocalPasteboard
    private let log: (String) -> Void
    /// Newest first.
    public private(set) var entries: [(id: UInt32, info: ClipInfo)] = []

    public init(pasteboard: LocalPasteboard, log: @escaping (String) -> Void) {
        self.pasteboard = pasteboard
        self.log = log
    }

    public func add(id: UInt32, _ info: ClipInfo) {
        // The host re-sends its newest clip when the same text is copied again: no new entry, but
        // B's clipboard and the 复制 feedback still follow.
        if entries.first?.id != id {
            entries.insert((id, info), at: 0)
            if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
        }
        if case let .text(text, _) = info, pasteboard.string != text { pasteboard.write(text: text) }
        onClip?()
    }

    public func info(_ id: UInt32) -> ClipInfo? {
        entries.first { $0.id == id }?.info
    }

    /// Insert false: the entry's content goes onto B's clipboard. Insert true: it is handed to `onInsert`
    /// instead, once it is on B.
    public func pick(_ id: UInt32, insert: Bool, transfers: TransferQueue, pasteboard: LocalPasteboard,
                     onInsert: @escaping (ClipInfo, InsertPayload) -> Void) {
        guard let info = info(id) else { return }
        switch info {
        case let .text(text, _):
            if insert { onInsert(info, .text(text)) } else { pasteboard.write(text: text) }
        case let .image(_, _, bytes):
            fetchBytes(id, name: "image", total: bytes, transfers: transfers) { data in
                if insert { onInsert(info, .bytes(data)) } else { pasteboard.write(png: data) }
            }
        case let .data(uti, bytes):
            fetchBytes(id, name: uti, total: bytes, transfers: transfers) { data in
                if insert { onInsert(info, .bytes(data)) } else { pasteboard.write(uti: uti, data: data) }
            }
        case let .files(files):
            fetchFiles(id, files, transfers: transfers) { urls in
                if insert { onInsert(info, .files(urls)) } else { pasteboard.write(files: urls) }
            }
        case .unsupported:
            break
        }
    }

    private func fetchBytes(_ id: UInt32, name: String, total: UInt64, transfers: TransferQueue,
                            then use: @escaping ([UInt8]) -> Void) {
        transfers.download(clip: id, file: 0, name: name, total: total, toDisk: false) { [log] result in
            switch result {
            case let .success(.bytes(data)): use(data)
            case .success: break
            case let .failure(failure): log("clip \(id) download failed: \(failure.reason)")
            }
        }
    }

    /// Downloads the files to disk one after another, then calls `use` with the URLs in the clip's order.
    /// A failure ends the chain: the remaining files are not fetched.
    private func fetchFiles(_ id: UInt32, _ files: [ClipFile], transfers: TransferQueue,
                            then use: @escaping ([URL]) -> Void) {
        var urls: [URL] = []
        func next() {
            guard urls.count < files.count else { return use(urls) }
            let index = urls.count
            transfers.download(clip: id, file: UInt16(index), name: files[index].name, total: files[index].bytes,
                               toDisk: true) { [log] result in
                switch result {
                case let .success(.file(url)):
                    urls.append(url)
                    next()
                case .success:
                    break
                case let .failure(failure):
                    log("clip \(id) download failed: \(failure.reason)")
                }
            }
        }
        next()
    }
}
