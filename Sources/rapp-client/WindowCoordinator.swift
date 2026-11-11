import AppKit
import RappCore

/// Keeps one B window per A window (spec §4.1–§4.4): applies each window
/// table, places new windows by the canvas <-> B mapping, hands every window
/// its part of each frame, and turns what the user does to the B windows
/// (resize, focus, close) into messages for A. Moving a B window never moves
/// A's: once shown, a B window stays where the user puts it.
final class WindowCoordinator: NSObject, NSWindowDelegate {
    /// Sends a message to the host.
    var send: (Message) -> Void = { _ in }
    /// Zoom or the backing scale may have changed: the capture density may need updating.
    var onStreamMayChange: () -> Void = {}

    private let meter: TrafficMeter
    private var table: [WindowInfo] = []
    private var windows: [UInt32: RemoteWindow] = [:]
    private var popups: [UInt32: PopupPanel] = [:]
    private let placeholder: NSWindow
    private let placeholderText = NSTextField(labelWithString: "")
    private var placement: WindowPlacement?
    private(set) var zoom: CGFloat = 1
    /// Set while the client itself changes a window's frame or the key
    /// window, so the delegate calls that follow are not sent back to A.
    private var placing = false
    private var applyingFocus = false
    private var lastFocused: UInt32?
    private var lastOrder: [UInt32] = []
    private var pendingResizes = PendingActions<UInt32>()

    init(meter: TrafficMeter, connectingTo host: String) {
        self.meter = meter
        placeholder = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 140),
                               styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        super.init()
        placeholder.isReleasedWhenClosed = false
        placeholder.delegate = self
        placeholder.title = "rapp"
        placeholderText.stringValue = "Connecting to \(host)…"
        placeholderText.alignment = .center
        placeholderText.textColor = .secondaryLabelColor
        placeholderText.frame = NSRect(x: 20, y: 55, width: 380, height: 30)
        placeholderText.autoresizingMask = [.width, .minYMargin, .maxYMargin]
        placeholder.contentView?.addSubview(placeholderText)
        meter.makeLabel().attach(to: placeholder)
        placeholder.center()
        placeholder.makeKeyAndOrderFront(nil)
    }

    /// The host is ready: the placeholder shows the app's name until a window arrives.
    func ready(appName: String) {
        placeholder.title = appName
        placeholderText.stringValue = "没有打开的窗口，可以用菜单栏新建"
    }

    /// The input bar of the key window, nil when the key window has none.
    var keyInputBar: InputBar? { (NSApp.keyWindow as? RemoteWindow)?.inputBar }

    /// The pixel density of the screen the client mostly shows on.
    var backingScale: CGFloat {
        (NSApp.keyWindow ?? windows.values.first ?? placeholder).backingScaleFactor
    }

    // MARK: Window table

    func apply(_ newTable: [WindowInfo]) {
        table = newTable
        let decorated = newTable.filter { $0.kind.isDecorated }
        let ids = Set(newTable.map(\.id))
        if placement == nil, let anchor = decorated.first(where: \.focused) ?? decorated.first ?? newTable.first {
            placement = .centering(content: contentRect(anchor), on: topLeft(NSScreen.main?.visibleFrame ?? .zero),
                                   zoom: zoom)
        }
        // Show the placeholder before closing the last window, so the client never has none.
        if decorated.isEmpty { placeholder.orderFront(nil) }

        pendingResizes.keep(only: ids)
        for (id, window) in windows where !ids.contains(id) {
            window.delegate = nil
            window.close()
            windows[id] = nil
        }
        for (id, panel) in popups where !ids.contains(id) {
            panel.parent?.removeChildWindow(panel)
            panel.close()
            popups[id] = nil
        }

        for info in decorated {
            if let window = windows[info.id] {
                let resized = window.info.rect.w != info.rect.w || window.info.rect.h != info.rect.h
                    || window.info.titleBar != info.titleBar
                window.update(info)
                // A's size only (spec §4.2): B keeps the window where it is, and
                // never changes it under a resize the user is still doing.
                if resized, !window.inLiveResize, !window.isMiniaturized { resizeInPlace(window) }
            } else {
                let label = meter.makeLabel()
                let id = info.id
                label.menu?.insertItem(.separator(), at: 0)
                label.menu?.insertItem(ActionItem(Self.moveToTopLeftTitle) { [weak self] in self?.moveToTopLeft(id) }, at: 0)
                let window = RemoteWindow(info: info, label: label)
                window.delegate = self
                window.remoteView.onMouse = { [weak self] in self?.send($0) }
                window.inputBar.onSend = { [weak self] in self?.send($0) }
                windows[info.id] = window
                place(window)
                window.orderFront(nil)
            }
        }
        reorder(decorated.map(\.id))

        for info in newTable where !info.kind.isDecorated {
            let panel = popups[info.id] ?? makePopup(info)
            panel.update(info)
            placePopup(panel)
            let parent = windows[info.parent]
            if panel.parent !== parent {
                panel.parent?.removeChildWindow(panel)
                if let parent { parent.addChildWindow(panel, ordered: .above) }
            }
            if !panel.isVisible { panel.orderFront(nil) }
        }

        let focused = decorated.first(where: \.focused)?.id
        if focused != lastFocused {
            lastFocused = focused
            // Follow A's focus only while the client is the active app.
            if NSApp.isActive, let id = focused, let window = windows[id], !window.isKeyWindow {
                applyingFocus = true
                window.makeKeyAndOrderFront(nil)
                applyingFocus = false
            }
        }
        if !decorated.isEmpty { placeholder.orderOut(nil) }
    }

    private func makePopup(_ info: WindowInfo) -> PopupPanel {
        let panel = PopupPanel(info: info)
        panel.remoteView.onMouse = { [weak self] in self?.send($0) }
        popups[info.id] = panel
        return panel
    }

    /// Puts the decorated windows in the table's front-to-back order, when it changed.
    private func reorder(_ order: [UInt32]) {
        guard order != lastOrder else { return }
        lastOrder = order
        for (above, below) in zip(order, order.dropFirst()) {
            guard let a = windows[above], let b = windows[below], !b.isMiniaturized else { continue }
            b.order(.below, relativeTo: a.windowNumber)
        }
    }

    // MARK: Placement (spec §4.2)

    /// A decorated window's content rectangle on the canvas (below A's title row).
    private func contentRect(_ info: WindowInfo) -> CGRect {
        CGRect(x: CGFloat(info.rect.x), y: CGFloat(info.rect.y + info.titleBar),
               width: CGFloat(info.rect.w), height: CGFloat(info.rect.h - info.titleBar))
    }

    /// AppKit counts y up from the bottom of the primary screen; the mapping counts it down from the top.
    private var primaryHeight: CGFloat { NSScreen.screens.first?.frame.maxY ?? 0 }

    private func appKitRect(topLeft p: CGPoint, size: CGSize) -> NSRect {
        NSRect(x: p.x, y: primaryHeight - p.y - size.height, width: size.width, height: size.height)
    }

    private func topLeft(_ rect: NSRect) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    private func contentTopLeft(_ window: NSWindow) -> CGPoint {
        topLeft(window.contentRect(forFrameRect: window.frame)).origin
    }

    /// Where a new window first shows: by the mapping, so B starts out laid out like A.
    private func place(_ window: RemoteWindow) {
        guard let placement else { return }
        let content = appKitRect(topLeft: placement.contentTopLeftInB(window.info), size: window.contentSize(zoom: zoom))
        setFrame(window, window.frameRect(forContentRect: content))
    }

    /// A new size (A's, or the zoom's) with the content's top-left kept where it is in B.
    private func resizeInPlace(_ window: RemoteWindow) {
        let content = appKitRect(topLeft: contentTopLeft(window), size: window.contentSize(zoom: zoom))
        setFrame(window, window.frameRect(forContentRect: content))
    }

    /// Attached to the parent's content wherever that is in B (spec §1.3);
    /// by the global mapping only when it has no parent window here.
    private func placePopup(_ panel: PopupPanel) {
        guard let placement else { return }
        let info = panel.info
        let frame: CGRect
        if let parent = windows[info.parent] {
            let parentContent = CanvasRect(x: parent.info.rect.x, y: parent.info.rect.y + parent.info.titleBar,
                                           w: parent.info.rect.w, h: parent.info.rect.h - parent.info.titleBar)
            // The picture, not the window: after A refuses a resize it is aspect-fitted at another scale.
            let content = contentTopLeft(parent), fit = parent.pictureFit
            frame = popupFrame(popup: info.rect, parentContent: parentContent,
                               parentPicture: fit.offsetBy(dx: content.x, dy: content.y))
        } else {
            frame = CGRect(origin: placement.toB(CGPoint(x: CGFloat(info.rect.x), y: CGFloat(info.rect.y))),
                           size: CGSize(width: CGFloat(info.rect.w) * zoom, height: CGFloat(info.rect.h) * zoom))
        }
        setFrame(panel, appKitRect(topLeft: frame.origin, size: frame.size))
    }

    private func setFrame(_ window: NSWindow, _ frame: NSRect) {
        guard window.frame != frame else { return }
        placing = true
        window.setFrame(frame, display: true)
        placing = false
    }

    /// Changes the zoom, keeping every window's content top-left where it is (spec §4.2).
    func setZoom(_ newZoom: CGFloat) {
        guard newZoom != zoom else { return }
        if let placement {
            let decorated = table.filter { $0.kind.isDecorated }
            let anchor = decorated.first(where: \.focused) ?? decorated.first
            let kept = anchor.map { contentRect($0).origin } ?? .zero
            self.placement = placement.rezoomed(to: newZoom, keeping: kept)
        }
        zoom = newZoom
        for window in windows.values where !window.isMiniaturized { resizeInPlace(window) }
        for panel in popups.values { placePopup(panel) }
        onStreamMayChange()
    }

    // MARK: Frames (spec §4.4)

    /// Gives every window its part of `image`, a frame covering `region`.
    func show(_ image: CGImage, region: CanvasRect) {
        for info in table {
            guard let view = windows[info.id]?.remoteView ?? popups[info.id]?.remoteView,
                  let crop = cropRect(window: info, region: region, pixelWidth: image.width, pixelHeight: image.height),
                  let visible = visiblePart(window: info, region: region),
                  let part = image.cropping(to: crop) else { continue }
            view.show(part, visible: visible)
        }
    }

    // MARK: What the user does to B windows (spec §4.3)

    static let moveToTopLeftTitle = "把 A 上的这个窗口移到左上角"

    /// The key B window, or the one A last focused.
    var currentWindowID: UInt32? { (NSApp.keyWindow as? RemoteWindow)?.info.id ?? lastFocused }

    /// Moves A's window to the top-left of A's screen, stacked down-right of
    /// windows already there, and raises it; the B window stays put.
    func moveToTopLeft(_ id: UInt32) {
        guard windows[id] != nil else { return }
        moveToTopLeftMessages(window: id, table: table).forEach(send)
    }

    func windowDidResize(_ notification: Notification) {
        // During a drag nothing is sent until the mouse is released.
        guard !placing, let window = notification.object as? RemoteWindow, !window.inLiveResize else { return }
        let id = window.info.id
        pendingResizes.schedule(id, after: 0.3) { [weak self, weak window] in
            guard let self, let window else { return }
            self.runWhenMouseUp(window) { [weak self, weak window] in window.map { self?.sendResize($0) } }
        }
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard let window = notification.object as? RemoteWindow else { return }
        pendingResizes.cancel(window.info.id)
        sendResize(window)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard !applyingFocus, let window = notification.object as? RemoteWindow else { return }
        lastFocused = window.info.id
        send(.focus(window.info.id))
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // The B window closes when A's does, i.e. when the table drops it.
        guard let window = sender as? RemoteWindow else { return true }
        send(.close(window.info.id))
        return false
    }

    func windowWillClose(_ notification: Notification) {
        // Closing the placeholder quits the client.
        if notification.object as? NSWindow === placeholder { NSApp.terminate(nil) }
    }

    func windowDidChangeBackingProperties(_ notification: Notification) {
        onStreamMayChange()
    }

    /// Runs `action` now, or once the left button is up if the user is still
    /// dragging; never for a window already closed.
    private func runWhenMouseUp(_ window: RemoteWindow, _ action: @escaping () -> Void) {
        guard window.delegate === self else { return }
        guard NSEvent.pressedMouseButtons & 1 != 0 else { return action() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self, weak window] in
            window.map { self?.runWhenMouseUp($0, action) }
        }
    }

    private func sendResize(_ window: RemoteWindow) {
        guard window.delegate === self else { return }
        let picture = window.pictureSize
        let width = (picture.width / zoom).rounded(), height = (picture.height / zoom).rounded()
        if width != window.remoteView.remoteSize.width || height != window.remoteView.remoteSize.height {
            send(.resize(window: window.info.id, width: UInt16(clamping: Int(width)), height: UInt16(clamping: Int(height))))
        }
    }
}
