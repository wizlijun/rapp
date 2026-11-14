import AppKit
import RappCore
import RappSession

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
    /// The bar's 取消 was pressed: stop the current transfer.
    var onCancelTransfer: () -> Void = {}

    private let meter: TrafficMeter
    private let transfers: TransferQueue
    private let counters = SendCounters()
    private var senders: [UInt32: Sender] = [:]
    private(set) var table: [WindowInfo] = []
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
    /// The transfer strip's text, shown in every window.
    private var transferStatus: String?
    /// The 复制 button of the window last clicked, and whether A's clip is still awaited.
    private weak var copyBar: ComposerBar?
    private var copyPending = false
    private var copyGeneration = 0

    init(meter: TrafficMeter, transfers: TransferQueue, connectingTo host: String) {
        self.meter = meter
        self.transfers = transfers
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

    /// The composer of the key window, nil when the key window has none.
    var keyComposer: Composer? { (NSApp.keyWindow as? RemoteWindow)?.composerBar.composer }

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
            senders[id] = nil
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
                wire(window)
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

    /// Connects a new window's composer bar to the client.
    private func wire(_ window: RemoteWindow) {
        let bar = window.composerBar
        bar.composer.onSend = { [weak self] in self?.send($0) }
        bar.onHeightChange = { [weak self, weak window] height in
            guard let self, let window else { return }
            // The window's own change, not the user's: nothing goes back to A.
            self.placing = true
            window.setBarHeight(height)
            self.placing = false
        }
        let sender = Sender(sink: bar, transfers: transfers, counters: counters, send: { [weak self] in self?.send($0) })
        senders[window.info.id] = sender
        bar.onSendButton = { [weak sender] in sender?.start(pieces: bar.composer.pieces()) }
        bar.composer.onSubmit = { [weak sender] in sender?.start(pieces: bar.composer.pieces()) }
        bar.onCancel = { [weak self] in self?.onCancelTransfer() }
        bar.onCopy = { [weak self, weak bar] in bar.map { self?.copy(from: $0) } }
        bar.onAttach = { [weak window] in window.map(Self.chooseFiles) }
        bar.setStatus(transferStatus)
    }

    /// 📎: the file panel, files only, several at once.
    private static func chooseFiles(for window: RemoteWindow) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.beginSheetModal(for: window) { [weak window] response in
            if response == .OK { window?.composerBar.composer.insertFiles(panel.urls) }
        }
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

    // MARK: Transfers and the clipboard (spec §4.1–§4.5)

    /// Shows the transfer queue's status in every window's bar; nil hides it.
    func setTransferStatus(_ text: String?) {
        transferStatus = text
        for window in windows.values { window.composerBar.setStatus(text) }
    }

    /// Hub `focus`: bring every window forward, the last focused one as key.
    func raiseAll() {
        for window in windows.values { window.orderFront(nil) }
        lastFocused.flatMap { windows[$0] }?.makeKeyAndOrderFront(nil)
    }

    /// Option-click on a history entry: into the key window's composer, else the last focused one's.
    func insert(_ payload: InsertPayload, info: ClipInfo) {
        let window = (NSApp.keyWindow as? RemoteWindow) ?? lastFocused.flatMap { windows[$0] }
        window?.composerBar.composer.insert(payload, info: info)
    }

    /// 复制: ⌘C to A, then "已复制" for 2 s, or "远端没有复制到东西" if no clip came in that time; 2 s later it is restored.
    private func copy(from bar: ComposerBar) {
        let command = UInt64(NSEvent.ModifierFlags.command.rawValue)
        send(.key(keyCode: 8, modifiers: command, down: true))
        send(.key(keyCode: 8, modifiers: command, down: false))
        copyGeneration += 1
        let generation = copyGeneration
        if copyBar !== bar { copyBar?.showCopyFeedback(nil) }
        copyBar = bar
        copyPending = true
        bar.showCopyFeedback("已复制")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.copyGeneration == generation, let bar = self.copyBar else { return }
            guard self.copyPending else { return bar.showCopyFeedback(nil) }
            self.copyPending = false
            bar.showCopyFeedback("远端没有复制到东西")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self, weak bar] in
                if self?.copyGeneration == generation { bar?.showCopyFeedback(nil) }
            }
        }
    }

    /// A's answer to a `paste`, for the window whose send it belongs to.
    func pasted(seq: UInt32, error: String) {
        for sender in senders.values where sender.pasted(seq: seq, error: error) { return }
    }

    /// A clip came from A; it answers a pending 复制 (and is ignored otherwise).
    func clipArrived() {
        copyPending = false
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

    /// Gives each window in `updated` its latest buffer from `surfaces`.
    func show(_ surfaces: WindowSurfaces, updated: [UInt32]) {
        for id in updated {
            guard let view = windows[id]?.remoteView ?? popups[id]?.remoteView,
                  let buffer = surfaces.latest(id), let visible = surfaces.visible(id) else { continue }
            view.show(buffer, visible: visible)
        }
    }

    // MARK: What the user does to B windows (spec §4.3)

    static let moveToTopLeftTitle = "把远端的这个窗口移到左上角"

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
        // B's close button ends the session (like Command-Q); A's windows stay as they are.
        // B windows still close on their own when A's do, i.e. when the table drops them.
        guard sender is RemoteWindow else { return true }
        NSApp.terminate(nil)
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
