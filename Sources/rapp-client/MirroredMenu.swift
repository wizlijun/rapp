import AppKit
import RappCore

/// The remote app's menus after this client's own app menu (spec §4.5).
/// Items carry no key equivalents, so every shortcut still goes to A as keys;
/// the shortcut is only shown, as text to the right of the title. Picking an
/// item sends its path.
final class MirroredMenu: NSObject {
    var send: ((Message) -> Void)?
    private weak var mainMenu: NSMenu?
    /// The top-level items this mirror added to the main menu.
    private var added: [NSMenuItem] = []
    /// A menu bar that arrived while a menu was open; applied when it closes,
    /// so an open menu never changes under the pointer.
    private var waiting: [MenuItem]?
    private var tracking = false

    init(mainMenu: NSMenu) {
        self.mainMenu = mainMenu
        super.init()
        let center = NotificationCenter.default
        center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: mainMenu, queue: .main) { [weak self] _ in
            self?.tracking = true
        }
        center.addObserver(forName: NSMenu.didEndTrackingNotification, object: mainMenu, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.tracking = false
            if let items = self.waiting {
                self.waiting = nil
                self.update(items)
            }
        }
    }

    func update(_ items: [MenuItem]) {
        guard !tracking else {
            waiting = items
            return
        }
        guard let mainMenu else { return }
        for item in added { mainMenu.removeItem(item) }
        added = []
        for (index, top) in items.enumerated() where !top.separator && !top.title.isEmpty {
            let item = NSMenuItem(title: top.title, action: nil, keyEquivalent: "")
            item.submenu = submenu(top.title, top.children, path: [UInt16(index)])
            item.isEnabled = top.enabled
            mainMenu.addItem(item)
            added.append(item)
        }
    }

    private func submenu(_ title: String, _ items: [MenuItem], path: [UInt16]) -> NSMenu {
        let menu = NSMenu(title: title)
        menu.autoenablesItems = false
        let font = NSFont.menuFont(ofSize: 0)
        func width(_ text: String) -> CGFloat { (text as NSString).size(withAttributes: [.font: font]).width }
        let shortcuts = items.map { shortcutText(key: $0.key, modifiers: $0.modifiers) }
        // One right-aligned tab stop per menu, past its widest title, lines the shortcuts up.
        let tabStop = (items.map { width($0.title) }.max() ?? 0) + 32 + (shortcuts.map(width).max() ?? 0)

        for (index, entry) in items.enumerated() {
            if entry.separator {
                menu.addItem(.separator())
                continue
            }
            let itemPath = path + [UInt16(index)]
            let item = NSMenuItem(title: entry.title, action: nil, keyEquivalent: "")
            item.isEnabled = entry.enabled
            item.state = entry.checked ? .on : .off
            if entry.children.isEmpty {
                item.action = #selector(pick(_:))
                item.target = self
                item.representedObject = itemPath
            } else {
                item.submenu = submenu(entry.title, entry.children, path: itemPath)
            }
            let shortcut = shortcuts[index]
            if !shortcut.isEmpty || !entry.enabled {
                item.attributedTitle = attributedTitle(entry.title, shortcut: shortcut, tabStop: tabStop, font: font,
                                             enabled: entry.enabled)
            }
            menu.addItem(item)
        }
        return menu
    }

    /// "Title⇥⌘N" with the shortcut right-aligned. An attributed title is not
    /// greyed out by AppKit, so a disabled one gets the disabled colour itself;
    /// enabled ones get no colour so the highlight still inverts them.
    private func attributedTitle(_ title: String, shortcut: String, tabStop: CGFloat, font: NSFont, enabled: Bool) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.tabStops = [NSTextTab(textAlignment: .right, location: tabStop)]
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: style]
        if !enabled { attributes[.foregroundColor] = NSColor.disabledControlTextColor }
        return NSAttributedString(string: shortcut.isEmpty ? title : "\(title)\t\(shortcut)", attributes: attributes)
    }

    @objc private func pick(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? [UInt16] else { return }
        send?(.menuPick(path))
    }
}
