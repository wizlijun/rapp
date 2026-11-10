import AppKit
import Foundation
import RappCore

let usage = """
    usage: rapp-client [connect] "rapp://<host>[:port]/[<bundle-id>][?token=<secret>][&mode=gray4|color8|color16|duogray|duocolor][&fps=15|5]" [--token-env <VAR>] [--json]
           rapp-client version [--json]
    example: rapp-client "rapp://mac-a.local/com.apple.TextEdit?token=abc"
    """

let inputBarHeight: CGFloat = 28

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let address: RemoteAddress
    private let output: WorkerOutput
    private let connection: Connection
    private let decoder: FrameDecoder
    private let remoteView = RemoteView(frame: .zero)
    private let inputBar = InputBar(frame: .zero)
    private let traffic: TrafficLabel
    private var window: NSWindow!
    private var keyMonitor: Any?
    private var applyingRemoteSize = false

    // Client zoom (spec §7). `remoteSize` is A's content size in points;
    // `zoom` is picture points per A point.
    private var ready = false
    private var remoteSize = CGSize.zero
    private var zoom: CGFloat = 1
    /// The handle of the live resize in progress, decided when it starts.
    private var liveHandle: ResizeHandle?
    /// What the next debounced `Resize` asks for, and at which zoom.
    private var pendingResize: (handle: ResizeHandle, zoom: CGFloat)?
    /// The stream settings last sent in Hello or SetStream.
    private var sentStream: (mode: Mode, fps: UInt8, density: Float)?

    init(address: RemoteAddress, output: WorkerOutput) {
        self.address = address
        self.output = output
        connection = Connection(address: address)
        decoder = FrameDecoder(mode: address.mode)
        traffic = TrafficLabel(mode: address.mode, fps: address.fps)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        buildWindow()

        remoteView.onMouse = { [weak self] message in self?.connection.send(message) }
        inputBar.onSend = { [weak self] message in self?.connection.send(message) }
        connection.onMessage = { [weak self] message in self?.handle(message) }
        connection.onBytes = { [weak self] count in self?.traffic.add(bytes: count) }
        traffic.onSelect = { [weak self] in self?.sendStreamIfChanged() }
        connection.onClosed = { [output] reason in output.finish(ExitCode.runtime, "rapp-client: \(reason)") }

        // Command shortcuts: Command-Q always quits this client. With an empty
        // input bar the others go to the remote app; otherwise they edit the bar.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.modifierFlags.contains(.command) else { return event }
            if event.charactersIgnoringModifiers?.lowercased() == "q" {
                NSApp.terminate(nil)
                return nil
            }
            guard self.inputBar.isEmpty else { return event }
            let modifiers = event.modifierFlags.intersection([.shift, .control, .option, .command])
            self.inputBar.sendKey(event.keyCode, modifiers: UInt64(modifiers.rawValue))
            return nil
        }

        let density = currentDensity()
        connection.density = density
        sentStream = (address.mode, address.fps, density)
        connection.start()
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// The window was closed or Command-Q pressed.
    func applicationWillTerminate(_ notification: Notification) {
        output.finish(ExitCode.ok, "quit")
    }

    private func buildWindow() {
        let content = NSRect(x: 0, y: 0, width: 800, height: 600 + inputBarHeight)
        window = NSWindow(contentRect: content, styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "Connecting to \(address.host)…"
        window.contentMinSize = NSSize(width: 200, height: 150 + inputBarHeight)
        window.isReleasedWhenClosed = false
        window.delegate = self

        let container = NSView(frame: content)
        inputBar.frame = NSRect(x: 0, y: 0, width: content.width, height: inputBarHeight)
        inputBar.autoresizingMask = [.width, .maxYMargin]
        remoteView.frame = NSRect(x: 0, y: inputBarHeight, width: content.width, height: content.height - inputBarHeight)
        remoteView.autoresizingMask = [.width, .height]
        container.addSubview(remoteView)
        container.addSubview(inputBar)
        window.contentView = container
        addTrafficLabel()

        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(inputBar)
    }

    /// Puts the traffic label at the right end of the title bar, 8 points in.
    private func addTrafficLabel() {
        // Wide enough for "999.9 KB/s" at 11 points plus the margin, no wider:
        // the centred title gives way to it in narrow windows.
        let holder = NSView(frame: NSRect(x: 0, y: 0, width: 80, height: 28))
        traffic.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(traffic)
        NSLayoutConstraint.activate([
            traffic.trailingAnchor.constraint(equalTo: holder.trailingAnchor, constant: -8),
            traffic.leadingAnchor.constraint(greaterThanOrEqualTo: holder.leadingAnchor),
            traffic.centerYAnchor.constraint(equalTo: holder.centerYAnchor),
        ])
        let accessory = NSTitlebarAccessoryViewController()
        accessory.layoutAttribute = .trailing
        accessory.view = holder
        window.addTitlebarAccessoryViewController(accessory)
    }

    /// A minimal menu so that Quit and the usual editing shortcuts work in the input bar.
    private func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit rapp-client", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    // MARK: Messages from the host

    private func handle(_ message: Message) {
        switch message {
        case let .ready(title, width, height):
            window.title = title
            output.emit(.ready(width: Int(width), height: Int(height), title: title))
            traffic.start()
            // Open at the remote window's size so the picture starts 1:1.
            applyingRemoteSize = true
            window.setContentSize(NSSize(width: CGFloat(width), height: CGFloat(height) + inputBarHeight))
            applyingRemoteSize = false
            ready = true
            remoteSize = CGSize(width: CGFloat(width), height: CGFloat(height))
            // 1 unless the screen kept the window smaller than A's.
            zoom = fittedZoom() ?? 1
            sendStreamIfChanged()
        case let .size(width, height):
            remoteSize = CGSize(width: CGFloat(width), height: CGFloat(height))
            // A may not take the size asked for: the picture letterboxes in
            // the window as it is, and the zoom follows what is shown.
            if !window.inLiveResize, let fitted = fittedZoom() {
                zoom = fitted
                sendStreamIfChanged()
            }
        case let .frame(payload):
            do {
                try decoder.decode(payload)
            } catch {
                output.finish(ExitCode.runtime, "rapp-client: cannot decode frame: \(error)")
            }
            let bgra = Quantizer.expand(samples: decoder.samples, width: decoder.width, height: decoder.height,
                                        mode: decoder.mode)
            remoteView.show(bgra: bgra, width: decoder.width, height: decoder.height)
        case let .title(title):
            window.title = title
        case let .error(reason):
            output.finish(exitCode(forHostError: reason), "rapp-client: host says: \(reason)")
        default:
            break
        }
    }

    // MARK: Zoom and window size (spec §7)

    private var pictureArea: CGSize { remoteView.bounds.size }

    /// Picture points per A point as shown now, or nil before A's size is known.
    private func fittedZoom() -> CGFloat? {
        guard remoteSize.width > 0, remoteSize.height > 0 else { return nil }
        let shown = aspectFitRect(imageSize: remoteSize, in: pictureArea)
        return shown.width > 0 ? shown.width / remoteSize.width : nil
    }

    private func currentDensity() -> Float {
        captureDensity(zoom: zoom, backingScale: window.backingScaleFactor, choice: traffic.density)
    }

    /// Sends SetStream when mode, frame rate or density differ from the last sent.
    private func sendStreamIfChanged() {
        guard ready else { return }
        let next = (mode: traffic.mode, fps: traffic.fps, density: currentDensity())
        guard streamChanged(from: sentStream, to: next) else { return }
        sentStream = next
        connection.send(.setStream(mode: next.mode, fps: next.fps, density: next.density))
    }

    func windowWillStartLiveResize(_ notification: Notification) {
        liveHandle = resizeHandle(mouse: NSEvent.mouseLocation, windowFrame: window.frame,
                                  buttonsDown: NSEvent.pressedMouseButtons & 1 != 0)
        // A drag supersedes a resize still waiting to be sent.
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(sendResize), object: nil)
        pendingResize = nil
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        // A corner drag keeps the picture area at A's aspect ratio.
        guard liveHandle == .corner, remoteSize.width > 0, remoteSize.height > 0 else { return frameSize }
        let content = sender.contentRect(forFrameRect: NSRect(origin: .zero, size: frameSize)).size
        let proposed = CGSize(width: content.width, height: content.height - inputBarHeight)
        let locked = lockedAspectSize(proposed: proposed, current: pictureArea, aspect: remoteSize)
        let lockedContent = NSRect(x: 0, y: 0, width: locked.width, height: locked.height + inputBarHeight)
        return sender.frameRect(forContentRect: lockedContent).size
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        let handle = liveHandle ?? .both
        liveHandle = nil
        if handle == .corner {
            // B only: A keeps its size, the capture density follows the picture.
            if let fitted = fittedZoom() { zoom = fitted }
            sendStreamIfChanged()
        } else {
            scheduleResize(handle)
        }
    }

    func windowDidResize(_ notification: Notification) {
        // Zoom button and full screen are not live resizes: both sides follow.
        // During a drag nothing is sent until the mouse is released.
        if !applyingRemoteSize && !window.inLiveResize { scheduleResize(.both) }
    }

    func windowDidChangeBackingProperties(_ notification: Notification) {
        // Moved to a screen with another pixel density.
        sendStreamIfChanged()
    }

    /// Sends a Resize for `handle` once no further resize has happened for 0.3 seconds.
    private func scheduleResize(_ handle: ResizeHandle) {
        guard ready else { return }
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(sendResize), object: nil)
        pendingResize = (handle, zoom)
        perform(#selector(sendResize), with: nil, afterDelay: 0.3)
    }

    @objc private func sendResize() {
        guard let pending = pendingResize else { return }
        pendingResize = nil
        let size = remoteResize(view: pictureArea, zoom: pending.zoom, remote: remoteSize, handle: pending.handle)
        guard size != remoteSize else { return }
        connection.send(.resize(width: UInt16(clamping: Int(size.width)), height: UInt16(clamping: Int(size.height))))
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
let command: ClientCommand
do {
    command = try parseClientArguments(arguments, environment: ProcessInfo.processInfo.environment)
} catch {
    let output = WorkerOutput(json: arguments.contains("--json"))
    output.error(usage)
    output.finish(ExitCode.usage, "rapp-client: \(error)")
}

switch command {
case let .version(json):
    let output = WorkerOutput(json: json)
    output.result(json ? versionJSON() : "rapp-client \(rappVersion) (protocol \(protocolVersion))")
    output.finish(ExitCode.ok, "done")

case let .connect(address, json):
    let output = WorkerOutput(json: json)
    let application = NSApplication.shared
    let delegate = AppDelegate(address: address, output: output)
    application.delegate = delegate
    application.setActivationPolicy(.regular)
    if json {
        output.readCommands(onCommand: { command in
            if command == "quit" {
                DispatchQueue.main.async { output.finish(ExitCode.ok, "quit") }
            } else {
                output.error("unknown command \(command)")
            }
        }, onEOF: { DispatchQueue.main.async { output.finish(ExitCode.ok, "stdin closed") } })
    }
    application.run()
}
