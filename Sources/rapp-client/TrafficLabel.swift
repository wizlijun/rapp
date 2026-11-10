import AppKit
import RappCore

/// Live received traffic, shown at the right of the title bar. Right-click or
/// Control-click it for two presets and the sample mode, capture density and frame rate.
final class TrafficLabel: NSTextField {
    /// Called whenever the choice changes.
    var onSelect: (() -> Void)?

    private(set) var mode: Mode
    private(set) var fps: UInt8
    private(set) var density = DensityChoice.adaptive
    private var bytesThisSecond = 0
    private var timer: Timer?

    private static let modeItems: [(String, Mode)] = [
        ("双色·灰度（文本优化）", .duogray),
        ("双色·彩色", .duocolor),
        ("高彩（图像优化）", .color16),
    ]
    private static let densityItems: [(String, DensityChoice)] = [
        ("省流 1x", .saver1x),
        ("自适应", .adaptive),
        ("原画", .original),
    ]
    private static let fpsItems: [(String, UInt8)] = [
        ("1 fps", 1),
        ("5 fps", 5),
        ("15 fps", 15),
        ("30 fps（看视频）", 30),
    ]
    private static let presetItems: [(String, StreamPreset)] = [
        ("最省流（双色·灰度 + 自适应 + 1 fps）", .leastTraffic),
        ("最清晰（高彩 + 原画 + 15 fps）", .sharpest),
    ]

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
        for (index, item) in Self.presetItems.enumerated() {
            menu.addItem(makeItem(item.0, tag: index, action: #selector(pickPreset(_:))))
        }
        menu.addItem(.separator())
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
            case #selector(pickDensity(_:)): item.state = Self.densityItems[item.tag].1 == density ? .on : .off
            case #selector(pickFps(_:)): item.state = Self.fpsItems[item.tag].1 == fps ? .on : .off
            default: item.state = .off      // presets are actions, never checked themselves
            }
        }
    }

    @objc private func pickMode(_ sender: NSMenuItem) {
        select(mode: Self.modeItems[sender.tag].1, fps: fps, density: density)
    }

    @objc private func pickDensity(_ sender: NSMenuItem) {
        select(mode: mode, fps: fps, density: Self.densityItems[sender.tag].1)
    }

    @objc private func pickFps(_ sender: NSMenuItem) {
        select(mode: mode, fps: Self.fpsItems[sender.tag].1, density: density)
    }

    @objc private func pickPreset(_ sender: NSMenuItem) {
        let preset = Self.presetItems[sender.tag].1
        select(mode: preset.mode, fps: preset.fps, density: preset.density)
    }

    private func select(mode newMode: Mode, fps newFps: UInt8, density newDensity: DensityChoice) {
        guard newMode != mode || newFps != fps || newDensity != density else { return }
        mode = newMode
        fps = newFps
        density = newDensity
        if let menu { updateChecks(menu) }
        onSelect?()
    }
}
