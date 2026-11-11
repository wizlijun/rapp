import AppKit
import RappCore

/// The stream choice (sample mode, capture density, frame rate) and the menu
/// that changes it: two presets, then the three groups. One instance serves
/// the app menu and every traffic label's right-click menu (spec §4.5).
final class StreamMenu: NSObject, NSMenuDelegate {
    /// Called whenever the choice changes.
    var onSelect: (() -> Void)?
    /// Makes the "A 的剪贴板" item that ends every menu; a menu cannot share an item with another.
    var makeHistoryItem: (() -> NSMenuItem)?

    private(set) var mode: Mode
    private(set) var fps: UInt8
    private(set) var density = DensityChoice.adaptive

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
        super.init()
    }

    /// A new menu with all the items; check marks are set each time it opens.
    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        addItems(to: menu)
        menu.delegate = self
        return menu
    }

    /// Appends the items to `menu`, which must have this object as its delegate
    /// for the check marks to stay current.
    func addItems(to menu: NSMenu) {
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
        if let historyItem = makeHistoryItem?() {
            menu.addItem(.separator())
            menu.addItem(historyItem)
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        for item in menu.items where item.target === self {
            switch item.action {
            case #selector(pickMode(_:)): item.state = Self.modeItems[item.tag].1 == mode ? .on : .off
            case #selector(pickDensity(_:)): item.state = Self.densityItems[item.tag].1 == density ? .on : .off
            case #selector(pickFps(_:)): item.state = Self.fpsItems[item.tag].1 == fps ? .on : .off
            default: item.state = .off      // presets are actions, never checked themselves
            }
        }
    }

    private func makeItem(_ title: String, tag: Int, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.tag = tag
        return item
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
        onSelect?()
    }
}
