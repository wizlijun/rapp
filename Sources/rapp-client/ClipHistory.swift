import AppKit
import RappCore

/// What an Option-click on a history entry hands over once its content is on B.
enum InsertPayload { case text(String), bytes([UInt8]), files([URL]) }

/// A's clipboard history (spec §4.4, §4.5): the last `limit` clips, newest first,
/// and the "A 的剪贴板" menu to take one to B's clipboard. One per client process.
final class ClipHistory {
    static let limit = 20

    /// Option-click: the entry's content is on B; the composer inserts it.
    var onInsert: ((ClipInfo, InsertPayload) -> Void)?
    /// A clip arrived (the 复制 button waits for it).
    var onClip: (() -> Void)?

    private let pasteboard: LocalPasteboard
    private let transfers: TransferQueue
    private let log: (String) -> Void
    private var entries: [(id: UInt32, info: ClipInfo)] = []

    init(pasteboard: LocalPasteboard, transfers: TransferQueue, log: @escaping (String) -> Void) {
        self.pasteboard = pasteboard
        self.transfers = transfers
        self.log = log
    }

    func add(id: UInt32, _ info: ClipInfo) {
        // The host re-sends its newest clip when the same text is copied again: no new entry, but
        // B's clipboard and the 复制 feedback still follow.
        if entries.first?.id != id {
            entries.insert((id, info), at: 0)
            if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
        }
        if case let .text(text, _) = info, pasteboard.string != text { pasteboard.write(text: text) }
        onClip?()
    }

    /// A fresh "A 的剪贴板" item; its submenu is rebuilt from the latest entries each time it opens.
    func makeMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "A 的剪贴板", action: nil, keyEquivalent: "")
        let menu = HistoryMenu { [weak self] in self?.menuItems() ?? [] }
        item.submenu = menu
        return item
    }

    // MARK: Menu

    private func menuItems() -> [NSMenuItem] {
        guard !entries.isEmpty else {
            return [NSMenuItem(title: "（空）", action: nil, keyEquivalent: "")]
        }
        return entries.map { entry in
            let title = historyTitle(entry.info)
            if case .unsupported = entry.info { return NSMenuItem(title: title, action: nil, keyEquivalent: "") }
            return ActionItem(title) { [weak self] in
                let insert = NSApp.currentEvent?.modifierFlags.contains(.option) ?? false
                self?.pick(entry.id, entry.info, insert: insert)
            }
        }
    }

    // MARK: Picking

    /// Plain click: onto B's clipboard. Option-click: handed to `onInsert` instead.
    private func pick(_ id: UInt32, _ info: ClipInfo, insert: Bool) {
        switch info {
        case let .text(text, _):
            if insert { onInsert?(info, .text(text)) } else { pasteboard.write(text: text) }
        case let .image(_, _, bytes):
            fetchBytes(id, name: "image", total: bytes) { [weak self] data in
                guard let self else { return }
                if insert { self.onInsert?(info, .bytes(data)) } else { self.pasteboard.write(png: data) }
            }
        case let .data(uti, bytes):
            fetchBytes(id, name: uti, total: bytes) { [weak self] data in
                guard let self else { return }
                if insert { self.onInsert?(info, .bytes(data)) } else { self.pasteboard.write(uti: uti, data: data) }
            }
        case let .files(files):
            fetchFiles(id, files) { [weak self] urls in
                guard let self else { return }
                if insert { self.onInsert?(info, .files(urls)) } else { self.pasteboard.write(files: urls) }
            }
        case .unsupported:
            break
        }
    }

    private func fetchBytes(_ id: UInt32, name: String, total: UInt64, then use: @escaping ([UInt8]) -> Void) {
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
    private func fetchFiles(_ id: UInt32, _ files: [ClipFile], then use: @escaping ([URL]) -> Void) {
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

/// The submenu: rebuilds its items just before it opens.
private final class HistoryMenu: NSMenu, NSMenuDelegate {
    private let makeItems: () -> [NSMenuItem]

    init(makeItems: @escaping () -> [NSMenuItem]) {
        self.makeItems = makeItems
        super.init(title: "A 的剪贴板")
        delegate = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("not used") }

    func menuNeedsUpdate(_ menu: NSMenu) {
        removeAllItems()
        for item in makeItems() { addItem(item) }
    }
}
