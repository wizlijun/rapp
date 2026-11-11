import AppKit
import RappCore

/// Live received traffic, shown at the right of a title bar. Right-click or
/// Control-click it for the stream menu. Every B window has one; a
/// `TrafficMeter` keeps them all showing the same rate.
final class TrafficLabel: NSTextField {
    init(menu streamMenu: NSMenu) {
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
        menu = streamMenu
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    // A click here must open the menu, not start dragging the window.
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control), let menu {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        } else {
            super.mouseDown(with: event)
        }
    }

    /// Puts the label at the right end of `window`'s title bar, 8 points in.
    func attach(to window: NSWindow) {
        // Wide enough for "999.9 KB/s" at 11 points plus the margin, no wider:
        // the centred title gives way to it in narrow windows.
        let holder = NSView(frame: NSRect(x: 0, y: 0, width: 80, height: 28))
        translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(self)
        NSLayoutConstraint.activate([
            trailingAnchor.constraint(equalTo: holder.trailingAnchor, constant: -8),
            leadingAnchor.constraint(greaterThanOrEqualTo: holder.leadingAnchor),
            centerYAnchor.constraint(equalTo: holder.centerYAnchor),
        ])
        let accessory = NSTitlebarAccessoryViewController()
        accessory.layoutAttribute = .trailing
        accessory.view = holder
        window.addTitlebarAccessoryViewController(accessory)
    }
}

/// Counts received bytes and, once a second after `start()`, shows the rate
/// on every label made by `makeLabel()` that is still alive.
final class TrafficMeter {
    private let streamMenu: StreamMenu
    private var labels = NSHashTable<TrafficLabel>.weakObjects()
    private var bytesThisSecond = 0
    private var shown = formatRate(bytes: 0)
    private var timer: Timer?

    init(streamMenu: StreamMenu) {
        self.streamMenu = streamMenu
    }

    deinit { timer?.invalidate() }

    func makeLabel() -> TrafficLabel {
        let label = TrafficLabel(menu: streamMenu.makeMenu())
        label.stringValue = shown
        label.isHidden = timer == nil
        labels.add(label)
        return label
    }

    func add(bytes: Int) {
        bytesThisSecond += bytes
    }

    func start() {
        guard timer == nil else { return }
        bytesThisSecond = 0
        for label in labels.allObjects { label.isHidden = false }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.shown = formatRate(bytes: self.bytesThisSecond)
            self.bytesThisSecond = 0
            for label in self.labels.allObjects { label.stringValue = self.shown }
        }
    }
}
