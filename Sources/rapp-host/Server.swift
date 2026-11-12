import AppKit
import CoreGraphics
import CoreVideo
import Foundation
import Network
import RappCore

private func describe(_ error: Error) -> String {
    if let e = error as? HostError { return e.description }
    if let e = error as? CodecError { return e.description }
    return error.localizedDescription
}

/// Runs one session at a time; a second valid hello takes it over.
final class Server {
    private let options: HostServeOptions
    private let output: WorkerOutput
    private let queue = DispatchQueue(label: "rapp.server")
    private var listener: NWListener?
    private var session: Session?
    private let sideSlots = SideSlots()
    private var sides: [ObjectIdentifier: SideConnection] = [:]
    private var intakes: Set<Intake> = []
    /// Device names from rapp-service, by the peer port of its connection to this worker (R2).
    private var peerNames = PeerNames()

    init(options: HostServeOptions, output: WorkerOutput) {
        self.options = options
        self.output = output
    }

    func start() throws {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.allowLocalEndpointReuse = true
        // Port 0 lets the system pick one; the `listening` line reports it.
        let nwPort = NWEndpoint.Port(rawValue: options.port) ?? .any
        let listener: NWListener
        if let bind = options.bind {
            parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(bind), port: nwPort)
            listener = try NWListener(using: parameters)
        } else {
            listener = try NWListener(using: parameters, on: nwPort)
        }
        let (output, requested) = (self.output, options.port)
        listener.stateUpdateHandler = { [weak listener] state in
            switch state {
            case .ready:
                let port = listener?.port?.rawValue ?? requested
                output.log("listening on \(port)")
                output.emit(.listening(port: port))
            case let .failed(error):
                output.finish(ExitCode.runtime, "cannot listen on port \(requested): \(error.localizedDescription)")
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
        self.listener = listener
    }

    /// Ends the current session, if any; the host keeps listening.
    func kick() {
        queue.async { self.session?.fail("kicked by the host") }
    }

    /// Ends the current session, if any, then exits 0.
    func stop(_ reason: String) {
        queue.async {
            self.session?.end("host stopped")
            self.output.finish(ExitCode.ok, reason)
        }
    }

    /// rapp-service names the device behind its connection from local port `port` (stdin `peer`).
    func peer(port: UInt16, name: String) {
        queue.async { self.peerNames.set(name, for: port) }
    }

    /// Another device just operated A (stdin `yield`): this session's input waits (R7, R8).
    func yieldTo(_ by: String) {
        queue.async { self.session?.yielded(to: by) }
    }

    /// Every new connection first says what it is (spec §1.2): `hello` opens the
    /// session, `fetch` and `put` are side connections of the running session.
    private func accept(_ connection: NWConnection) {
        let intake = Intake(connection: connection, queue: queue)
        intakes.insert(intake)
        intake.start { [weak self, intake] outcome in
            guard let self else { return }
            self.intakes.remove(intake)
            switch outcome {
            case let .rejected(reason, notify):
                self.reject(connection, reason, notify: notify)
            case let .first(message, parser):
                self.route(connection, message, parser)
            }
        }
    }

    private func reject(_ connection: NWConnection, _ reason: String, notify: Bool) {
        output.log("rejected a connection: \(reason)")
        output.emit(.rejected(reason: reason))
        if notify {
            connection.send(content: Data(Message.error(reason).encoded()),
                            completion: .contentProcessed { _ in connection.cancel() })
            queue.asyncAfter(deadline: .now() + 1) { connection.cancel() }
        } else {
            connection.cancel()
        }
    }

    private func route(_ connection: NWConnection, _ message: Message, _ parser: MessageParser) {
        switch message {
        case let .hello(token, bundleID, _, _, _, _):
            let name: String?
            if case let .hostPort(_, port) = connection.endpoint { name = peerNames[port.rawValue] } else { name = nil }
            if let old = session {
                // Only a hello that would itself be accepted takes over; any other leaves the running session alone (R4).
                if case let .failure(error) = checkHello(token: token, bundleID: bundleID, expected: options.token,
                                                         bound: options.app) {
                    reject(connection, "\(error)", notify: true)
                    return
                }
                // Ends now, on this queue: its onEnd clears `session` and its side connections before the new one
                // exists. One whose own hello failed is already ending with that reason; its onEnd leaves the new one be.
                if old.started { old.takeOver(by: name) }
            }
            let newSession = Session(connection: connection, token: options.token, boundApp: options.app,
                                     peerName: name, output: output, queue: queue) { [weak self] ended, reason, started in
                guard let self else { return }
                if started {
                    self.output.log("session ended: \(reason)")
                    self.output.emit(.sessionEnded(reason: reason))
                } else {
                    self.output.log("rejected a connection: \(reason)")
                    self.output.emit(.rejected(reason: reason))
                }
                // A session that is no longer the current one must not clear its successor or cut its side links.
                guard self.session === ended else { return }
                self.session = nil
                // Side connections belong to the session: drop them so their slots and the store are freed.
                for side in Array(self.sides.values) { side.abort() }
            }
            session = newSession
            newSession.start(first: message, parser: parser)
        case .fetch, .put:
            var key: ObjectIdentifier?
            let side = SideConnection(connection: connection, parser: parser, first: message, token: options.token,
                                      slots: sideSlots, transfers: session?.transfers, output: output,
                                      queue: queue) { [weak self] in
                if let key { self?.sides[key] = nil }
            }
            key = ObjectIdentifier(side)
            sides[ObjectIdentifier(side)] = side
            side.start()
        default:
            reject(connection, "first message must be hello, fetch or put", notify: true)
        }
    }
}

/// Reads a new connection's first message; a connection that says nothing for 5 s is dropped.
final class Intake: Hashable {
    enum Outcome {
        case first(Message, MessageParser)
        case rejected(String, notify: Bool)
    }

    private let connection: NWConnection
    private let queue: DispatchQueue
    private var parser = MessageParser()
    private var done = false
    private var onOutcome: ((Outcome) -> Void)?

    init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    static func == (a: Intake, b: Intake) -> Bool { a === b }
    func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }

    func start(_ onOutcome: @escaping (Outcome) -> Void) {
        self.onOutcome = onOutcome
        connection.start(queue: queue)
        receive()
        // A client that connects and says nothing must not hold a connection open.
        queue.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.finish(.rejected("no hello received", notify: true))
        }
    }

    private func finish(_ outcome: Outcome) {
        guard !done else { return }
        done = true
        let callback = onOutcome
        onOutcome = nil
        callback?(outcome)
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, !self.done else { return }
            if let data, !data.isEmpty {
                self.parser.append([UInt8](data))
                do {
                    if let message = try self.parser.next() {
                        self.finish(.first(message, self.parser))
                        return
                    }
                } catch let mismatch as ProtocolVersionMismatch {
                    self.finish(.rejected(mismatch.description, notify: true))
                    return
                } catch {
                    self.finish(.rejected("bad data from client: \(describe(error))", notify: true))
                    return
                }
            }
            if let error {
                self.finish(.rejected("connection error: \(error.localizedDescription)", notify: false))
            } else if isComplete {
                self.finish(.rejected("client disconnected", notify: false))
            } else {
                self.receive()
            }
        }
    }
}

/// One connected client. All state is touched only on `queue`, except the
/// pixel conversion, which runs on the capture queue, and window polling,
/// which runs on `trackerQueue`.
final class Session {
    private let connection: NWConnection
    private let token: String
    private let boundApp: String?
    /// The device name rapp-service announced for this connection, if any.
    private let peerName: String?
    private let output: WorkerOutput
    private let queue: DispatchQueue
    private let trackerQueue = DispatchQueue(label: "rapp.windows")
    /// Menu-bar reads and presses (spec §3.5), so a large menu never delays the window poll.
    private let menuQueue = DispatchQueue(label: "rapp.menus")
    /// Called once with this session, the reason, and whether the session had started (a valid Hello).
    private let onEnd: (Session, String, Bool) -> Void
    /// Held from a valid hello to `end`, so A doesn't idle-lock under B (todo P1).
    private lazy var awake = PowerHold.stayAwake { [output] in output.log($0) }

    private var parser = MessageParser()
    private var greeted = false
    /// The protocol version the client's hello carried; message 26 only goes to clients that understand it.
    private var helloVersion: UInt8 = 0
    /// Holds input back while another device operates A, and paces the `input` reports (R7, R8).
    private var yield = InputYield()
    /// The device that last made this session wait.
    private var yieldedBy = ""
    /// Sends the trailing `input` report the pacing held back.
    private var inputTimer: DispatchSourceTimer?
    private(set) var started = false
    private var ended = false
    /// Guards `sampleMode`, `latest` and `latestSeq`, which the capture
    /// queue reads; everything else in a session lives on `queue`.
    private let sampleLock = NSLock()
    private var sampleMode = Mode.gray4
    /// The newest captured picture and the region it shows, kept so a mode
    /// switch can redraw at once: ScreenCaptureKit sends nothing new while
    /// the windows are still.
    private var latest: (buffer: CVPixelBuffer, region: CanvasRect)?
    private var latestSeq = 0
    private var newestSubmittedSeq = 0
    private var fps = 15
    private var density: Float = 2
    private var encoder: FrameEncoder?
    private var capture: WindowCapture?
    private var app: NSRunningApplication?
    private var injector: InputInjector?
    private var timer: DispatchSourceTimer?
    private var pollTimer: DispatchSourceTimer?
    /// Clipboard history and uploads, from the moment capture is ready until the session ends.
    private(set) var transfers: TransferStore?
    private(set) var clipWatcher: ClipboardWatcher?
    private var paster: Paster?
    /// UTF-8 sizes of inline text pastes not yet answered, by seq (an uploaded item was reported by its put).
    private var inlinePastes: [UInt32: Int] = [:]

    /// The menu bar last sent; picks are checked against it.
    private var menuBar: [MenuItem]?
    private var pendingMenuRead: DispatchWorkItem?
    private var focusedWindow: UInt32?

    /// The window table last sent; input and window commands are checked against it.
    private var table: [WindowInfo] = []
    /// The capture region last asked for (canvas points).
    private var region: CanvasRect?
    /// The canvas display in global points.
    private var display = CGRect.zero

    private var sendInFlight = false
    private var pending: (samples: [UInt8], width: Int, height: Int, region: CanvasRect)?
    private var bytesThisSecond = 0
    private var framesThisSecond = 0
    private var lastWidth = 0
    private var lastHeight = 0

    init(connection: NWConnection, token: String, boundApp: String?, peerName: String?, output: WorkerOutput,
         queue: DispatchQueue, onEnd: @escaping (Session, String, Bool) -> Void) {
        self.connection = connection
        self.token = token
        self.boundApp = boundApp
        self.peerName = peerName
        self.output = output
        self.queue = queue
        self.onEnd = onEnd
    }

    /// Takes over a connection whose first message (a `hello`) and any bytes after it are already read.
    func start(first: Message, parser: MessageParser) {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case let .failed(error): self?.end("connection failed: \(error.localizedDescription)")
            case .cancelled: self?.end("connection closed")
            default: break
            }
        }
        self.parser = parser
        handle(first)
        if ended { return }
        if !drain() { return }
        receive()
    }

    /// Handles every complete message buffered; false when the session ended.
    private func drain() -> Bool {
        do {
            while let message = try parser.next() {
                handle(message)
                if ended { return false }
            }
        } catch let mismatch as ProtocolVersionMismatch {
            fail(mismatch.description)
            return false
        } catch {
            fail("bad data from client: \(describe(error))")
            return false
        }
        return true
    }

    // MARK: Receiving

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, !self.ended else { return }
            if let data, !data.isEmpty {
                self.parser.append([UInt8](data))
                if !self.drain() { return }
            }
            if let error {
                self.end("connection error: \(error.localizedDescription)")
            } else if isComplete {
                self.end("client disconnected")
            } else {
                self.receive()
            }
        }
    }

    private func handle(_ message: Message) {
        // Every command from B passes one gate; only input can be held back (R7).
        switch message {
        case .text, .key, .mouse, .scroll, .paste, .focus, .menuPick, .setStream, .resize, .move, .close:
            guard admit(message) else { return }
        default:
            break
        }
        switch message {
        case let .hello(clientToken, bundleID, mode, fps, density, version):
            guard !greeted else { fail("unexpected hello"); return }
            greeted = true
            let app: String
            switch checkHello(token: clientToken, bundleID: bundleID, expected: token, bound: boundApp) {
            case let .success(resolved): app = resolved
            case let .failure(error): fail(error.description); return
            }
            sampleLock.withLock { sampleMode = mode }
            self.fps = Int(fps)
            self.density = density
            encoder = FrameEncoder(mode: mode)
            helloVersion = version
            started = true
            awake.begin()
            startInputTimer()
            output.log("client connected: \(app), \(streamDescription(mode))" + (peerName.map { ", from \($0)" } ?? ""))
            output.emit(.sessionStarted(client: clientDescription, mode: mode, fps: Int(fps)))
            startCapture(bundleID: app)
        case .text, .key, .mouse, .scroll:
            injector?.handle(message, table: table)
            // Enabled items and check marks follow what the input did (a selection, an edit).
            if message.mayChangeMenus, menuBar != nil { scheduleMenuRead(after: 0.5) }
        case let .setStream(mode, fps, density):
            setStream(mode, fps: Int(fps), density: density)
        // Window commands naming a window no longer in the table are dropped,
        // not errors: B may not have seen the newest table yet (spec §2.4).
        case let .resize(id, width, height):
            guard let window = decoratedWindow(id), window.resizable else { return }
            resize(window, content: CGSize(width: Int(width), height: Int(height)))
        case let .focus(id):
            guard let app, let window = table.first(where: { $0.id == id }) else { return }
            app.activate()
            WindowResizer.bringToFront(pid: app.processIdentifier,
                                       frame: window.kind.isDecorated ? window.globalFrame(display: display) : nil)
        case let .close(id):
            guard let app, let window = decoratedWindow(id) else { return }
            _ = WindowResizer.close(pid: app.processIdentifier, frame: window.globalFrame(display: display))
        case let .move(id, x, y):
            guard let app, let window = decoratedWindow(id) else { return }
            // Never off A's display: the window would leave the table and B could not move it back.
            let canvas = clampedWindowOrigin(CGPoint(x: CGFloat(x), y: CGFloat(y)),
                                             size: CGSize(width: CGFloat(window.rect.w), height: CGFloat(window.rect.h)),
                                             titleBar: CGFloat(window.titleBar), canvas: display.size)
            let origin = CGPoint(x: display.minX + canvas.x, y: display.minY + canvas.y)
            if !WindowResizer.move(pid: app.processIdentifier, frame: window.globalFrame(display: display), to: origin) {
                output.log("could not move a window (the app may not allow it)")
            }
        case let .menuPick(path):
            // A pick of an item B shows but A no longer has is dropped, like a stale window id.
            guard let app, let menuBar, let item = menuItem(at: path, in: menuBar),
                  item.enabled, !item.separator, item.children.isEmpty,
                  let titles = menuTitles(at: path, in: menuBar) else {
                output.log("dropped a pick of a menu item A no longer has")
                return
            }
            let pid = app.processIdentifier
            menuQueue.async { [output] in
                // Pressed only if A's titles along the path are still what B showed.
                if !MenuBarReader.press(pid: pid, path: path, titles: titles) {
                    output.log("could not press a menu item (A's menus changed or the press failed)")
                }
            }
            // Picks usually change the menus (a new window, a toggled check mark).
            scheduleMenuRead(after: 1)
        case let .paste(seq, source):
            if case let .text(text) = source { inlinePastes[seq] = text.utf8.count }
            paster?.paste(seq: seq, source)

        case .ready, .error, .frame, .windows, .menuBar, .clip, .pasted, .fetch, .put, .transferStart, .chunk, .inputBlocked:
            fail("unexpected message from client")
        }
    }

    // MARK: Yielding to other devices

    /// Whether `message` goes ahead; reports this session's input and tells B when its input waits.
    private func admit(_ message: Message) -> Bool {
        switch yield.admit(message, at: ProcessInfo.processInfo.systemUptime) {
        case let .pass(report):
            if report { output.emit(.input) }
            return true
        case let .drop(notify):
            if let by = notify {
                output.emit(.inputBlocked(by: by))
                // A v5 client would drop the connection on an unknown message type (R6).
                if clientUnderstandsInputBlocked(helloVersion) { send(.inputBlocked(by: by)) }
            }
            // B waits for every paste's answer before sending the next piece.
            if case let .paste(seq, _) = message { send(.pasted(seq: seq, error: inputBlockedNotice(by: yieldedBy))) }
            return false
        }
    }

    /// Another device operated A just now.
    func yielded(to by: String) {
        guard !ended else { return }
        yieldedBy = by
        yield.yielded(to: by, at: ProcessInfo.processInfo.systemUptime)
    }

    private func startInputTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + inputReportEvery, repeating: inputReportEvery)
        timer.setEventHandler { [weak self] in
            guard let self, !self.ended else { return }
            if self.yield.tick(at: ProcessInfo.processInfo.systemUptime) { self.output.emit(.input) }
        }
        timer.resume()
        inputTimer = timer
    }

    private func decoratedWindow(_ id: UInt32) -> WindowInfo? {
        table.first { $0.id == id && $0.kind.isDecorated }
    }

    /// The client's address as `ip:port`.
    private var clientDescription: String {
        if case let .hostPort(host, port) = connection.endpoint { return "\(host):\(port)" }
        return "\(connection.endpoint)"
    }

    // MARK: Capture

    private func startCapture(bundleID: String) {
        let (fps, density) = (self.fps, Double(self.density))
        let trackerQueue = self.trackerQueue
        Task { [weak self] in
            do {
                let found = try await WindowCapture.find(bundleID: bundleID)
                let display = found.display.frame
                let tracker = WindowTracker(pid: found.app.processIdentifier, appName: found.app.localizedName,
                                            display: display)
                let table = trackerQueue.sync { tracker.poll() }
                // Before the first poll lists it, the found window alone is the region.
                let start = CanvasRect(x: Float(found.window.frame.minX - display.minX),
                                       y: Float(found.window.frame.minY - display.minY),
                                       w: Float(found.window.frame.width), h: Float(found.window.frame.height))
                let region = captureRegion(windows: table, display: display.size)
                    ?? captureRegion(windows: [WindowInfo(id: 1, parent: 0, kind: .normal, resizable: false, focused: false,
                                                          rect: start, titleBar: 0, title: "")],
                                     display: display.size)
                    ?? CanvasRect(x: 0, y: 0, w: Float(display.width), h: Float(display.height))
                guard let self else { return }
                let capture = WindowCapture(
                    found: found, region: region, fps: fps, density: density,
                    onFrame: { [weak self] pixelBuffer, frameRegion in self?.frameArrived(pixelBuffer, region: frameRegion) },
                    onStopped: { [weak self] reason in
                        self?.queue.async { self?.fail("capture stopped: \(reason)") }
                    })
                // Announce the canvas and the windows before the first frame can be sent.
                self.queue.async {
                    self.captureReady(capture, app: found.app, tracker: tracker, table: table, region: region)
                }
                try await capture.start()
            } catch {
                guard let self else { return }
                self.queue.async { self.fail(describe(error)) }
            }
        }
    }

    private func captureReady(_ capture: WindowCapture, app: NSRunningApplication, tracker: WindowTracker,
                              table: [WindowInfo], region: CanvasRect) {
        guard !ended else {
            capture.stop()
            return
        }
        self.capture = capture
        self.app = app
        self.display = capture.displayFrame
        self.region = region
        // A SetStream that arrived while the window was being found is applied now.
        let (fps, density) = (self.fps, Double(self.density))
        Task { await capture.setStream(fps: fps, density: density) }
        injector = InputInjector(app: app, display: display, log: { [output] in output.log($0) })
        send(.ready(appName: windowTitle("", appName: app.localizedName),
                    width: UInt16(clamping: Int(display.width.rounded())),
                    height: UInt16(clamping: Int(display.height.rounded()))))
        tableChanged(table)
        scheduleMenuRead(after: 0)
        startClipboard(app: app)

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1.0)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer

        // Windows are looked up 10 times a second (spec §3.2), off the session queue.
        let poll = DispatchSource.makeTimerSource(queue: trackerQueue)
        poll.schedule(deadline: .now() + 0.1, repeating: 0.1)
        poll.setEventHandler { [weak self] in
            let next = tracker.poll()
            self?.queue.async { self?.tableChanged(next) }
        }
        poll.resume()
        pollTimer = poll
    }

    private func startClipboard(app: NSRunningApplication) {
        let store = ClipStore(changeCount: NSPasteboard.general.changeCount)
        let uploads = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads/rapp")
        transfers = TransferStore(clips: store, uploads: uploads)
        let watcher = ClipboardWatcher(pid: app.processIdentifier, store: store, queue: queue,
                                       log: { [output] in output.log($0) }) { [weak self] id, info in
            guard let self, !self.ended else { return }
            self.send(.clip(id: id, info))
            // Text goes inline; other kinds are reported when B fetches them.
            if case let .text(text, _) = info {
                self.output.emit(.transfer(dir: .aToB, kind: .text, bytes: UInt64(text.utf8.count), name: nil))
            }
        }
        watcher.start()
        clipWatcher = watcher
        paster = Paster(app: app, queue: queue, transfers: { [weak self] in self?.transfers },
                        watcher: { [weak self] in self?.clipWatcher }, log: { [output] in output.log($0) }) { [weak self] seq, error in
            guard let self, !self.ended else { return }
            self.send(.pasted(seq: seq, error: error))
            if let bytes = self.inlinePastes.removeValue(forKey: seq), error.isEmpty {
                self.output.emit(.transfer(dir: .bToA, kind: .text, bytes: UInt64(bytes), name: nil))
            }
        }
    }

    /// Sends the table if it changed, and follows the windows with the
    /// capture region. An empty table keeps the region (spec §3.2).
    private func tableChanged(_ next: [WindowInfo]) {
        guard !ended, let capture else { return }
        if next != table {
            if next.map(\.id) != table.map(\.id) || next.map(\.kind) != table.map(\.kind) {
                output.log("windows: " + (next.isEmpty ? "none" : next.map { "\($0.kind) \($0.id)" }.joined(separator: ", ")))
            }
            table = next
            send(.windows(next))
            let focused = next.first(where: \.focused)?.id
            if focused != focusedWindow {
                focusedWindow = focused
                // Apps change their menus with the focused window (spec §3.5).
                scheduleMenuRead(after: 0.5)
            }
        }
        if let newRegion = captureRegion(windows: next, display: display.size), newRegion != region {
            region = newRegion
            // No encoder reset: each frame carries its own region and B keeps
            // the decoded picture, so a diff against the previous frame stays
            // correct; a new pixel size already makes the encoder send a full frame.
            Task { await capture.setRegion(newRegion) }
        }
    }

    /// Runs on the capture queue.
    private func frameArrived(_ pixelBuffer: CVPixelBuffer, region: CanvasRect) {
        let (mode, seq): (Mode, Int) = sampleLock.withLock {
            latestSeq += 1
            latest = (pixelBuffer, region)
            return (sampleMode, latestSeq)
        }
        quantizeAndSubmit(pixelBuffer, region: region, mode: mode, seq: seq)
    }

    /// Quantizes on the calling (non-session) queue, then hands the samples,
    /// tagged with the mode and capture sequence number they came from, to `queue`.
    private func quantizeAndSubmit(_ pixelBuffer: CVPixelBuffer, region: CanvasRect, mode: Mode, seq: Int) {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
        let width = CVPixelBufferGetWidth(pixelBuffer), height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard width > 0, height > 0, width <= 0xFFFF, height <= 0xFFFF, bytesPerRow >= width * 4,
              ((width + tileSize - 1) / tileSize) * ((height + tileSize - 1) / tileSize) <= 0xFFFF else { return }
        let samples = Quantizer.quantize(bgra: UnsafeRawBufferPointer(start: base, count: bytesPerRow * height),
                                         width: width, height: height, bytesPerRow: bytesPerRow, mode: mode)
        queue.async { [weak self] in
            self?.submit(samples: samples, width: width, height: height, region: region, mode: mode, seq: seq)
        }
    }

    /// While a frame is still being sent, newer frames replace each other and
    /// only the latest is encoded once the send finishes. The encoder compares
    /// against the last frame it actually produced, so skipped frames cost nothing.
    ///
    /// Samples quantized for a mode that has since been switched away from are
    /// dropped (the encoder would reject their size), and so are samples older
    /// than ones already submitted (a redraw racing a newer frame).
    private func submit(samples: [UInt8], width: Int, height: Int, region: CanvasRect, mode: Mode, seq: Int) {
        guard !ended, capture != nil else { return }
        guard mode == sampleLock.withLock({ sampleMode }), seq >= newestSubmittedSeq else { return }
        newestSubmittedSeq = seq
        if sendInFlight {
            pending = (samples, width, height, region)
        } else {
            encodeAndSend(samples: samples, width: width, height: height, region: region)
        }
    }

    private func encodeAndSend(samples: [UInt8], width: Int, height: Int, region: CanvasRect) {
        guard let payload = encoder?.encode(samples: samples, width: width, height: height) else { return }
        let bytes = Message.frame(region: region, payload).encoded()
        bytesThisSecond += bytes.count
        framesThisSecond += 1
        lastWidth = width
        lastHeight = height
        sendInFlight = true
        connection.send(content: Data(bytes), completion: .contentProcessed { [weak self] error in
            guard let self, !self.ended else { return }
            self.sendInFlight = false
            if let error {
                self.end("send failed: \(error.localizedDescription)")
            } else if let next = self.pending {
                self.pending = nil
                self.encodeAndSend(samples: next.samples, width: next.width, height: next.height, region: next.region)
            }
        })
    }

    private func tick() {
        guard !ended, capture != nil else { return }
        let kbps = Double(bytesThisSecond) * 8 / 1000
        if output.json {
            output.emit(.stats(kbps: kbps, fps: framesThisSecond, width: lastWidth, height: lastHeight))
        } else {
            output.log(String(format: "[stats] %.1f kbps %d fps %dx%d", kbps, framesThisSecond, lastWidth, lastHeight))
        }
        bytesThisSecond = 0
        framesThisSecond = 0
        // Closing every window does not end the session; quitting the app does (spec §2.5).
        if let app, app.isTerminated {
            fail("\(windowTitle("", appName: app.localizedName)) quit")
        }
    }

    // MARK: Mode, frame rate and density switching

    private func streamDescription(_ mode: Mode) -> String {
        "\(mode.name), \(fps) fps, density \(String(format: "%.2f", density))"
    }

    private func setStream(_ newMode: Mode, fps newFps: Int, density newDensity: Float) {
        let oldMode = sampleLock.withLock { sampleMode }
        guard newMode != oldMode || newFps != fps || newDensity != density else { return }
        if newFps != fps || newDensity != density {
            fps = newFps
            density = newDensity
            if let capture {
                // No encoder reset: a density change that alters the picture's
                // pixel size already makes the encoder send a full frame.
                Task { await capture.setStream(fps: newFps, density: Double(newDensity)) }
            }
        }
        output.log("stream -> \(streamDescription(newMode))")
        guard newMode != oldMode else { return }
        // A new encoder starts with a full frame, which also restarts both
        // ends' compression streams. Old-mode samples still queued are dropped.
        let redraw: (CVPixelBuffer, CanvasRect, Int)? = sampleLock.withLock {
            sampleMode = newMode
            return latest.map { ($0.buffer, $0.region, latestSeq) }
        }
        encoder = FrameEncoder(mode: newMode)
        pending = nil
        if let (pixelBuffer, region, seq) = redraw {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.quantizeAndSubmit(pixelBuffer, region: region, mode: newMode, seq: seq)
            }
        }
    }

    // MARK: Remote resize

    /// Content size + title row, kept on the display and at least 100 x 100 (spec §3.4).
    private func resize(_ window: WindowInfo, content: CGSize) {
        guard let app else { return }
        let frame = window.globalFrame(display: display)
        let size = windowSize(forContent: content, titleRow: CGFloat(window.titleBar), origin: frame.origin, screen: display)
        if !WindowResizer.resize(pid: app.processIdentifier, frame: frame, to: size) {
            output.log("could not resize a window (the app may not allow it)")
        }
    }

    // MARK: Sending and ending

    private func send(_ message: Message) {
        connection.send(content: Data(message.encoded()), completion: .contentProcessed { [weak self] error in
            if let error { self?.end("send failed: \(error.localizedDescription)") }
        })
    }

    /// Tells the client why, then ends the session.
    func fail(_ reason: String) {
        guard !ended else { return }
        connection.send(content: Data(Message.error(reason).encoded()),
                        completion: .contentProcessed { [weak self] _ in self?.end(reason) })
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.end(reason) }
    }

    /// Reads the menu bar `delay` seconds from now, replacing a read not yet
    /// started, and sends it if it differs from the last one sent.
    private func scheduleMenuRead(after delay: Double) {
        guard let app else { return }
        pendingMenuRead?.cancel()
        let pid = app.processIdentifier
        let read = DispatchWorkItem { [weak self] in
            let items = MenuBarReader.read(pid: pid)
            self?.queue.async {
                guard let self, !self.ended, items != self.menuBar else { return }
                self.menuBar = items
                self.send(.menuBar(items))
            }
        }
        pendingMenuRead = read
        menuQueue.asyncAfter(deadline: .now() + delay, execute: read)
    }

    /// Another client's valid hello replaced this one: tell B who, then end as usual (R3, R5).
    func takeOver(by name: String?) {
        let reason = takenOverError(by: name)
        end(reason, farewell: .error(reason))
    }

    /// With `farewell`, the connection closes once it is sent, or after 1 s.
    func end(_ reason: String, farewell: Message? = nil) {
        guard !ended else { return }
        ended = true
        inputTimer?.cancel()
        inputTimer = nil
        pendingMenuRead?.cancel()
        pendingMenuRead = nil
        timer?.cancel()
        timer = nil
        pollTimer?.cancel()
        pollTimer = nil
        paster?.end()
        paster = nil
        clipWatcher?.stop()
        clipWatcher = nil
        transfers = nil
        capture?.stop()
        capture = nil
        injector?.releaseAll()
        injector = nil
        awake.end()
        pending = nil
        if let farewell {
            let connection = self.connection
            connection.send(content: Data(farewell.encoded()), completion: .contentProcessed { _ in connection.cancel() })
            queue.asyncAfter(deadline: .now() + 1) { connection.cancel() }
        } else {
            connection.cancel()
        }
        onEnd(self, reason, started)
    }
}
