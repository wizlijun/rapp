import AppKit
import RappCore
import RappSession

/// The "远程剪贴板" menu over a `ClipHistory`: click puts an entry on B's clipboard,
/// Option-click hands it to `onInsert`.
final class ClipHistoryMenu {
    /// Option-click: the entry's content is on B; the composer inserts it.
    var onInsert: ((ClipInfo, InsertPayload) -> Void)?

    private let history: ClipHistory
    private let transfers: TransferQueue
    private let pasteboard: LocalPasteboard

    init(history: ClipHistory, transfers: TransferQueue, pasteboard: LocalPasteboard) {
        self.history = history
        self.transfers = transfers
        self.pasteboard = pasteboard
    }

    /// A fresh "远程剪贴板" item; its submenu is rebuilt from the latest entries each time it opens.
    func makeMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "远程剪贴板", action: nil, keyEquivalent: "")
        let menu = HistoryMenu { [weak self] in self?.menuItems() ?? [] }
        item.submenu = menu
        return item
    }

    private func menuItems() -> [NSMenuItem] {
        guard !history.entries.isEmpty else {
            return [NSMenuItem(title: "（空）", action: nil, keyEquivalent: "")]
        }
        return history.entries.map { entry in
            let title = historyTitle(entry.info)
            if case .unsupported = entry.info { return NSMenuItem(title: title, action: nil, keyEquivalent: "") }
            return ActionItem(title) { [weak self] in
                guard let self else { return }
                let insert = NSApp.currentEvent?.modifierFlags.contains(.option) ?? false
                self.history.pick(entry.id, insert: insert, transfers: self.transfers, pasteboard: self.pasteboard) {
                    [weak self] info, payload in self?.onInsert?(info, payload)
                }
            }
        }
    }
}

/// The submenu: rebuilds its items just before it opens.
private final class HistoryMenu: NSMenu, NSMenuDelegate {
    private let makeItems: () -> [NSMenuItem]

    init(makeItems: @escaping () -> [NSMenuItem]) {
        self.makeItems = makeItems
        super.init(title: "远程剪贴板")
        delegate = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("not used") }

    func menuNeedsUpdate(_ menu: NSMenu) {
        removeAllItems()
        for item in makeItems() { addItem(item) }
    }
}
