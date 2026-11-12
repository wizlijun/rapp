import AppKit
import Foundation
import RappCore
import RappSession

let usage = """
    usage: rapp-client [connect] "rapp://<host>[:port]/[<bundle-id>][?token=<secret>][&mode=gray4|color8|color16|duogray|duocolor][&fps=30|15|5|1]" [--token-env <VAR>] [--json]
           rapp-client version [--json]
    example: rapp-client "rapp://mac-a.local/com.apple.TextEdit?token=abc"
    """

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let address: RemoteAddress
    private let output: WorkerOutput
    private let connection: Connection
    private let decoder: FrameDecoder
    private let surfaces = WindowSurfaces()
    private let streamMenu: StreamMenu
    private let meter: TrafficMeter
    private let transfers: TransferQueue
    private let history: ClipHistory
    private let historyMenu: ClipHistoryMenu
    private var coordinator: WindowCoordinator!
    private var mirroredMenu: MirroredMenu!
    private var keyMonitor: Any?
    private var ready = false
    private let takeover = TakeoverGate()
    /// The window count last logged.
    private var loggedWindows: Int?

    func raiseWindows() {
        NSApp.activate()
        coordinator?.raiseAll()
    }
    /// The stream settings last sent in Hello or SetStream.
    private var sentStream: (mode: Mode, fps: UInt8, density: Float)?

    private static let zoomLevels: [CGFloat] = [0.5, 0.75, 1, 1.25, 1.5, 2]

    init(address: RemoteAddress, output: WorkerOutput) {
        self.address = address
        self.output = output
        connection = Connection(address: address)
        decoder = FrameDecoder(mode: address.mode)
        streamMenu = StreamMenu(mode: address.mode, fps: address.fps)
        meter = TrafficMeter(streamMenu: streamMenu)
        transfers = TransferQueue(address: address)
        let pasteboard = LocalPasteboard()
        history = ClipHistory(pasteboard: pasteboard, log: { output.log($0) })
        historyMenu = ClipHistoryMenu(history: history, transfers: transfers, pasteboard: pasteboard)
        super.init()
        transfers.log = { output.log($0) }
        streamMenu.makeHistoryItem = { [historyMenu] in historyMenu.makeMenuItem() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        coordinator = WindowCoordinator(meter: meter, transfers: transfers, connectingTo: address.host)
        coordinator.send = { [weak self] message in self?.connection.send(message) }
        coordinator.onStreamMayChange = { [weak self] in self?.sendStreamIfChanged() }
        coordinator.onCancelTransfer = { [transfers] in transfers.cancel() }
        transfers.onStatus = { [weak self] status in self?.coordinator.setTransferStatus(status) }
        history.onClip = { [weak self] in self?.coordinator.clipArrived() }
        historyMenu.onInsert = { [weak self] info, payload in self?.coordinator.insert(payload, info: info) }
        buildMenu()

        connection.onMessage = { [weak self] message in self?.handle(message) }
        connection.onBytes = { [weak self] count in self?.meter.add(bytes: count) }
        streamMenu.onSelect = { [weak self] in self?.sendStreamIfChanged() }
        connection.onClosed = { [output, takeover] reason in
            if takeover.pending { return }  // the 拿回来 prompt is up; its answer decides
            output.finish(ExitCode.runtime, "rapp-client: \(reason)") }

        // Command shortcuts: Command-Q always quits this client. With an empty
        // (or no) composer the others go to the remote app; otherwise they edit it.
        // Command-V always goes to the composer when it has the keyboard focus.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.modifierFlags.contains(.command) else { return event }
            // A sheet (the 📎 file panel) has its own shortcuts.
            if NSApp.keyWindow?.sheetParent != nil { return event }
            if event.charactersIgnoringModifiers?.lowercased() == "q" {
                NSApp.terminate(nil)
                return nil
            }
            if let composer = self.coordinator.keyComposer {
                let plain = event.modifierFlags.intersection([.shift, .control, .option, .command]) == .command
                if plain, event.charactersIgnoringModifiers?.lowercased() == "v",
                   composer.window?.firstResponder === composer { return event }
                if !composer.isEmpty { return event }
            }
            let modifiers = UInt64(event.modifierFlags.intersection([.shift, .control, .option, .command]).rawValue)
            self.connection.send(.key(keyCode: event.keyCode, modifiers: modifiers, down: true))
            self.connection.send(.key(keyCode: event.keyCode, modifiers: modifiers, down: false))
            return nil
        }

        let density = currentDensity()
        connection.density = density
        sentStream = (address.mode, address.fps, density)
        connection.start()
        NSApp.activate()
    }

    /// The placeholder was closed or Command-Q pressed.
    func applicationWillTerminate(_ notification: Notification) {
        output.finish(ExitCode.ok, "quit")
    }

    /// The app menu (spec §4.5): quit, zoom, moving A's window to its top-left and the stream menu, plus hidden
    /// editing items whose shortcuts still work in the composers. The remote
    /// app's menus follow it once the host sends them.
    private func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.delegate = streamMenu
        appMenu.addItem(withTitle: "Quit rapp-client", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenu.addItem(.separator())

        let zoomItem = NSMenuItem(title: "缩放", action: nil, keyEquivalent: "")
        let zoomMenu = NSMenu()
        for (index, level) in Self.zoomLevels.enumerated() {
            let item = NSMenuItem(title: "\(Int(level * 100))%", action: #selector(pickZoom(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.state = level == 1 ? .on : .off
            zoomMenu.addItem(item)
        }
        zoomItem.submenu = zoomMenu
        appMenu.addItem(zoomItem)
        appMenu.addItem(ActionItem(WindowCoordinator.moveToTopLeftTitle) { [weak self] in
            guard let coordinator = self?.coordinator, let id = coordinator.currentWindowID else { return }
            coordinator.moveToTopLeft(id)
        })
        appMenu.addItem(.separator())
        streamMenu.addItems(to: appMenu)

        let edits: [(String, Selector, String, NSEvent.ModifierFlags)] = [
            ("Undo", Selector(("undo:")), "z", [.command]),
            ("Redo", Selector(("redo:")), "z", [.command, .shift]),
            ("Cut", #selector(NSText.cut(_:)), "x", [.command]),
            ("Copy", #selector(NSText.copy(_:)), "c", [.command]),
            ("Paste", #selector(NSText.paste(_:)), "v", [.command]),
            ("Select All", #selector(NSText.selectAll(_:)), "a", [.command]),
        ]
        for (title, action, key, modifiers) in edits {
            let item = appMenu.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.isHidden = true
            item.allowsKeyEquivalentWhenHidden = true
        }
        appItem.submenu = appMenu
        main.addItem(appItem)
        NSApp.mainMenu = main
        mirroredMenu = MirroredMenu(mainMenu: main)
        mirroredMenu.send = { [weak self] message in self?.connection.send(message) }
    }

    @objc private func pickZoom(_ sender: NSMenuItem) {
        for item in sender.menu?.items ?? [] { item.state = item === sender ? .on : .off }
        coordinator.setZoom(Self.zoomLevels[sender.tag])
    }

    // MARK: Messages from the host

    private func handle(_ message: Message) {
        if takeover.pending { return }
        switch message {
        case let .ready(appName, width, height):
            coordinator.ready(appName: appName)
            output.emit(.ready(width: Int(width), height: Int(height), title: appName))
            meter.start()
            ready = true
            sendStreamIfChanged()
        case let .windows(table):
            coordinator.apply(table)
            _ = surfaces.keep(only: Set(table.map(\.id)))
            output.emit(.windows(count: table.count))
            // Logged (stderr with --json) so a hub's log shows it too; the hub does not forward events.
            if table.count != loggedWindows {
                loggedWindows = table.count
                output.log("windows: \(table.count)")
            }
            sendStreamIfChanged()
        case let .frame(region, payload):
            do {
                try decoder.decode(payload)
                // Cropped by the region the frame itself carries, not the table's (spec §4.4).
                let updated = try surfaces.draw(table: coordinator.table, decoder: decoder, region: region)
                coordinator.show(surfaces, updated: updated)
            } catch {
                output.finish(ExitCode.runtime, "rapp-client: cannot decode frame: \(error)")
                return
            }
        case let .menuBar(items):
            mirroredMenu.update(items)
        case let .clip(id, info):
            history.add(id: id, info)
        case let .pasted(seq, error):
            coordinator.pasted(seq: seq, error: error)
        case let .error(reason):
            if !output.json, let notice = takeoverNotice(reason) {
                offerTakeBack(notice, reason: reason)
            } else {
                output.finish(exitCode(forHostError: reason), "rapp-client: host says: \(reason)")
            }
        case let .inputBlocked(by):
            meter.flash(inputBlockedNotice(by: by), for: 1)
        default:
            break
        }
    }

    /// Another device took this window over: tell the user; 「拿回来」 starts this client again and quits.
    private func offerTakeBack(_ notice: String, reason: String) {
        guard takeover.begin() else { return }
        let alert = NSAlert()
        alert.messageText = notice
        alert.addButton(withTitle: "拿回来")
        alert.addButton(withTitle: "关闭")
        if alert.runModal() == .alertFirstButtonReturn {
            let process = Process()
            process.executableURL = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
            process.arguments = Array(CommandLine.arguments.dropFirst())
            process.environment = ProcessInfo.processInfo.environment
            do {
                try process.run()
                output.finish(ExitCode.ok, "rapp-client: \(notice); relaunched")
            } catch {
                output.finish(exitCode(forHostError: reason), "rapp-client: cannot relaunch: \(error)")
            }
        } else {
            output.finish(exitCode(forHostError: reason), "rapp-client: host says: \(reason)")
        }
    }

    // MARK: Stream settings

    private func currentDensity() -> Float {
        captureDensity(zoom: coordinator?.zoom ?? 1, backingScale: coordinator?.backingScale ?? NSScreen.main?.backingScaleFactor ?? 2,
                       choice: streamMenu.density)
    }

    /// Sends SetStream when mode, frame rate or density differ from the last sent.
    private func sendStreamIfChanged() {
        guard ready else { return }
        let next = (mode: streamMenu.mode, fps: streamMenu.fps, density: currentDensity())
        guard streamChanged(from: sentStream, to: next) else { return }
        sentStream = next
        connection.send(.setStream(mode: next.mode, fps: next.fps, density: next.density))
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
            switch command {
            case .quit: DispatchQueue.main.async { output.finish(ExitCode.ok, "quit") }
            case .focus: DispatchQueue.main.async { delegate.raiseWindows() }
            case .kick, .peer, .yield: break
            }
        }, onEOF: { DispatchQueue.main.async { output.finish(ExitCode.ok, "stdin closed") } })
    }
    application.run()
}
