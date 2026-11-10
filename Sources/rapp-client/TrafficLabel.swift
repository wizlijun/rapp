import AppKit
import RappCore

/// Live received traffic, shown at the right of the title bar. Right-click or
/// Control-click it to pick the sample mode, the capture density and the frame rate.
final class TrafficLabel: NSTextField {
    /// Called with the new (mode, fps, saver1x) whenever the choice changes.
    var onSelect: ((Mode, UInt8, Bool) -> Void)?

    private(set) var mode: Mode
    private(set) var fps: UInt8
    private(set) var saver1x = false
    private var bytesThisSecond = 0
    private var timer: Timer?

    private static let modeItems: [(String, Mode)] = [
        ("灰度 16 级 (gray4)", .gray4),
        ("256 色 (color8)", .color8),
        ("高彩 (color16)", .color16),
        ("双色·灰度 (duogray)", .duogray),
        ("双色·彩色 (duocolor)", .duocolor),
    ]
    private static let densityItems: [(String, Bool)] = [
        ("跟随 B 屏幕", false),
        ("省流 (1x)", true),
    ]
    private static let fpsItems: [(String, UInt8)] = [
        ("15 fps", 15),
        ("5 fps", 5),
    ]
    /// The one-click lowest-traffic combination.
    static let extreme: (mode: Mode, fps: UInt8, saver1x: Bool) = (.duogray, 5, false)

    init(mode: Mode, fps: UInt8) {
        self.mode = mode
        self.fps = fps
        super.init(frame: .zero)
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = false
        font = .systemFont(ofSize: 11)
        textColor = .secondaryLabelColor
        alignment = .right
        // Never wrap onto a second line in the title bar.
        usesSingleLineMode = true
        maximumNumberOfLines = 1
        lineBreakMode = .byClipping
        stringValue = formatRate(bytes: 0)
        isHidden = true
        menu = buildMenu()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    deinit { timer?.invalidate() }

    func add(bytes: Int) {
        bytesThisSecond += bytes
    }

    /// Shows the label and refreshes it once a second with the bytes received
    /// in that second.
    func start() {
        guard timer == nil else { return }
        isHidden = false
        bytesThisSecond = 0
        stringValue = formatRate(bytes: 0)
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.stringValue = formatRate(bytes: self.bytesThisSecond)
            self.bytesThisSecond = 0
        }
    }

    // A click here must open the menu, not start dragging the window.
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control), let menu {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        } else {
            super.mouseDown(with: event)
        }
    }

    // MARK: Menu

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        for (index, item) in Self.modeItems.enumerated() {
            menu.addItem(makeItem(item.0, tag: index, action: #selector(pickMode(_:))))
        }
        menu.addItem(.separator())
        for (index, item) in Self.densityItems.enumerated() {
            menu.addItem(makeItem(item.0, tag: index, action: #selector(pickDensity(_:))))
        }
        menu.addItem(.separator())
        for (index, item) in Self.fpsItems.enumerated() {
            menu.addItem(makeItem(item.0, tag: index, action: #selector(pickFps(_:))))
        }
        menu.addItem(.separator())
        menu.addItem(makeItem("极限省流（双色·灰度 + 跟随 B 屏幕 + 5 fps）", tag: 0, action: #selector(pickExtreme(_:))))
        updateChecks(menu)
        return menu
    }

    private func makeItem(_ title: String, tag: Int, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.tag = tag
        return item
    }

    private func updateChecks(_ menu: NSMenu) {
        for item in menu.items where !item.isSeparatorItem {
            switch item.action {
            case #selector(pickMode(_:)): item.state = Self.modeItems[item.tag].1 == mode ? .on : .off
            case #selector(pickDensity(_:)): item.state = Self.densityItems[item.tag].1 == saver1x ? .on : .off
            case #selector(pickFps(_:)): item.state = Self.fpsItems[item.tag].1 == fps ? .on : .off
            default: item.state = .off      // 极限省流 is an action, never checked itself
            }
        }
    }

    @objc private func pickMode(_ sender: NSMenuItem) {
        select(mode: Self.modeItems[sender.tag].1, fps: fps, saver1x: saver1x)
    }

    @objc private func pickDensity(_ sender: NSMenuItem) {
        select(mode: mode, fps: fps, saver1x: Self.densityItems[sender.tag].1)
    }

    @objc private func pickFps(_ sender: NSMenuItem) {
        select(mode: mode, fps: Self.fpsItems[sender.tag].1, saver1x: saver1x)
    }

    @objc private func pickExtreme(_ sender: NSMenuItem) {
        select(mode: Self.extreme.mode, fps: Self.extreme.fps, saver1x: Self.extreme.saver1x)
    }

    private func select(mode newMode: Mode, fps newFps: UInt8, saver1x newSaver: Bool) {
        guard newMode != mode || newFps != fps || newSaver != saver1x else { return }
        mode = newMode
        fps = newFps
        saver1x = newSaver
        if let menu { updateChecks(menu) }
        onSelect?(mode, fps, saver1x)
    }
}
