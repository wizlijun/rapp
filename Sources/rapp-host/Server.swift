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

/// Listens for one client at a time.
final class Server {
    private let options: HostServeOptions
    private let output: WorkerOutput
    private let queue = DispatchQueue(label: "rapp.server")
    private var listener: NWListener?
    private var session: Session?

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

    private func accept(_ connection: NWConnection) {
        if session != nil {
            output.log("rejected a connection: busy")
            output.emit(.rejected(reason: "busy"))
            connection.start(queue: queue)
            connection.send(content: Data(Message.error("busy").encoded()),
                            completion: .contentProcessed { _ in connection.cancel() })
            return
        }
        let newSession = Session(connection: connection, token: options.token, boundApp: options.app,
                                 output: output, queue: queue) { [weak self] reason, started in
            guard let self else { return }
            if started {
                self.output.log("session ended: \(reason)")
                self.output.emit(.sessionEnded(reason: reason))
            } else {
                self.output.log("rejected a connection: \(reason)")
                self.output.emit(.rejected(reason: reason))
            }
            self.session = nil
        }
        session = newSession
        newSession.start()
    }
}

/// One connected client. All state is touched only on `queue`, except the
/// pixel conversion, which runs on the capture queue.
final class Session {
    private let connection: NWConnection
    private let token: String
    private let boundApp: String?
    private let output: WorkerOutput
    private let queue: DispatchQueue
    /// Called once with the reason, and whether the session had started (a valid Hello).
    private let onEnd: (String, Bool) -> Void

    private var parser = MessageParser()
    private var greeted = false
    private var started = false
    private var ended = false
    /// Guards `sampleMode`, `latestBuffer` and `latestSeq`, which the capture
    /// queue reads; everything else in a session lives on `queue`.
    private let sampleLock = NSLock()
    private var sampleMode = Mode.gray4
    /// The newest captured picture, kept so a mode switch can redraw at once:
    /// ScreenCaptureKit sends nothing new while the window is still.
    private var latestBuffer: CVPixelBuffer?
    private var latestSeq = 0
    private var newestSubmittedSeq = 0
    private var fps = 15
    private var density: Float = 2
    private var encoder: FrameEncoder?
    private var capture: WindowCapture?
    private var app: NSRunningApplication?
    private var injector: InputInjector?
    private var timer: DispatchSourceTimer?

    private var sendInFlight = false
    private var pending: (samples: [UInt8], width: Int, height: Int)?
    private var bytesThisSecond = 0
    private var framesThisSecond = 0
    private var lastWidth = 0
    private var lastHeight = 0
    private var lastTitle = ""

    init(connection: NWConnection, token: String, boundApp: String?, output: WorkerOutput, queue: DispatchQueue,
         onEnd: @escaping (String, Bool) -> Void) {
        self.connection = connection
        self.token = token
        self.boundApp = boundApp
        self.output = output
        self.queue = queue
        self.onEnd = onEnd
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case let .failed(error): self?.end("connection failed: \(error.localizedDescription)")
            case .cancelled: self?.end("connection closed")
            default: break
            }
        }
        connection.start(queue: queue)
        receive()
        // A client that connects and says nothing must not block the only slot.
        queue.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, !self.greeted else { return }
            self.fail("no hello received")
        }
    }

    // MARK: Receiving

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, !self.ended else { return }
            if let data, !data.isEmpty {
                self.parser.append([UInt8](data))
                do {
                    while let message = try self.parser.next() {
                        self.handle(message)
                        if self.ended { return }
                    }
                } catch let mismatch as ProtocolVersionMismatch {
                    self.fail(mismatch.description)
                    return
                } catch {
                    self.fail("bad data from client: \(describe(error))")
                    return
                }
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
        switch message {
        case let .hello(clientToken, bundleID, mode, fps, density):
            guard !greeted else { fail("unexpected hello"); return }
            greeted = true
            guard constantTimeEquals(clientToken, token) else { fail("bad token"); return }
            let app: String
            switch resolveHelloApp(requested: bundleID, bound: boundApp) {
            case let .success(resolved): app = resolved
            case let .failure(error): fail(error.description); return
            }
            sampleLock.withLock { sampleMode = mode }
            self.fps = Int(fps)
            self.density = density
            encoder = FrameEncoder(mode: mode)
            started = true
            output.log("client connected: \(app), \(streamDescription(mode))")
            output.emit(.sessionStarted(client: clientDescription, mode: mode, fps: Int(fps)))
            startCapture(bundleID: app)
        case .text, .key, .mouse, .scroll:
            injector?.handle(message)
        case let .resize(width, height):
            resizeWindow(width: Int(width), height: Int(height))
        case let .setStream(mode, fps, density):
            setStream(mode, fps: Int(fps), density: density)
        case .ready, .error, .frame, .title, .size:
            fail("unexpected message from client")
        }
    }

    /// The client's address as `ip:port`.
    private var clientDescription: String {
        if case let .hostPort(host, port) = connection.endpoint { return "\(host):\(port)" }
        return "\(connection.endpoint)"
    }

    // MARK: Capture

    private func startCapture(bundleID: String) {
        let (fps, density) = (self.fps, Double(self.density))
        Task { [weak self] in
            do {
                let found = try await WindowCapture.find(bundleID: bundleID)
                guard let self else { return }
                let capture = WindowCapture(
                    window: found.window, fps: fps, density: density,
                    onFrame: { [weak self] pixelBuffer in self?.frameArrived(pixelBuffer) },
                    onStopped: { [weak self] reason in
                        self?.queue.async { self?.fail("capture stopped: \(reason)") }
                    })
                guard let content = capture.contentFrame else { throw HostError("the window was closed") }
                // Announce the window before the first frame can be sent.
                self.queue.async { self.captureReady(capture, app: found.app, content: content) }
                try await capture.start()
            } catch {
                guard let self else { return }
                self.queue.async { self.fail(describe(error)) }
            }
        }
    }

    private func captureReady(_ capture: WindowCapture, app: NSRunningApplication, content: CGRect) {
        guard !ended else {
            capture.stop()
            return
        }
        self.capture = capture
        self.app = app
        // A SetStream that arrived while the window was being found is applied now.
        let (fps, density) = (self.fps, Double(self.density))
        Task { await capture.setStream(fps: fps, density: density) }
        injector = InputInjector(app: app, frameProvider: { [weak capture] in
            guard let capture, let window = capture.currentFrame else { return nil }
            return (window, contentRect(windowFrame: window, titleRow: capture.titleRow))
        })
        lastTitle = currentTitle(capture, app: app) ?? windowTitle(capture.window.title, appName: app.localizedName)
        send(.ready(title: lastTitle,
                    width: UInt16(clamping: Int(content.width.rounded())),
                    height: UInt16(clamping: Int(content.height.rounded()))))

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1.0)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    /// Runs on the capture queue.
    private func frameArrived(_ pixelBuffer: CVPixelBuffer) {
        let (mode, seq): (Mode, Int) = sampleLock.withLock {
            latestSeq += 1
            latestBuffer = pixelBuffer
            return (sampleMode, latestSeq)
        }
        quantizeAndSubmit(pixelBuffer, mode: mode, seq: seq)
    }

    /// Quantizes on the calling (non-session) queue, then hands the samples,
    /// tagged with the mode and capture sequence number they came from, to `queue`.
    private func quantizeAndSubmit(_ pixelBuffer: CVPixelBuffer, mode: Mode, seq: Int) {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
        let width = CVPixelBufferGetWidth(pixelBuffer), height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard width > 0, height > 0, width <= 0xFFFF, height <= 0xFFFF, bytesPerRow >= width * 4,
              ((width + tileSize - 1) / tileSize) * ((height + tileSize - 1) / tileSize) <= 0xFFFF else { return }
        let samples = Quantizer.quantize(bgra: UnsafeRawBufferPointer(start: base, count: bytesPerRow * height),
                                         width: width, height: height, bytesPerRow: bytesPerRow, mode: mode)
        queue.async { [weak self] in self?.submit(samples: samples, width: width, height: height, mode: mode, seq: seq) }
    }

    /// While a frame is still being sent, newer frames replace each other and
    /// only the latest is encoded once the send finishes. The encoder compares
    /// against the last frame it actually produced, so skipped frames cost nothing.
    ///
    /// Samples quantized for a mode that has since been switched away from are
    /// dropped (the encoder would reject their size), and so are samples older
    /// than ones already submitted (a redraw racing a newer frame).
    private func submit(samples: [UInt8], width: Int, height: Int, mode: Mode, seq: Int) {
        guard !ended, capture != nil else { return }
        guard mode == sampleLock.withLock({ sampleMode }), seq >= newestSubmittedSeq else { return }
        newestSubmittedSeq = seq
        if sendInFlight {
            pending = (samples, width, height)
        } else {
            encodeAndSend(samples: samples, width: width, height: height)
        }
    }

    private func encodeAndSend(samples: [UInt8], width: Int, height: Int) {
        guard let payload = encoder?.encode(samples: samples, width: width, height: height) else { return }
        let bytes = Message.frame(payload).encoded()
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
                self.encodeAndSend(samples: next.samples, width: next.width, height: next.height)
            }
        })
    }

    private func tick() {
        guard !ended, let capture else { return }
        let kbps = Double(bytesThisSecond) * 8 / 1000
        if output.json {
            output.emit(.stats(kbps: kbps, fps: framesThisSecond, width: lastWidth, height: lastHeight))
        } else {
            output.log(String(format: "[stats] %.1f kbps %d fps %dx%d", kbps, framesThisSecond, lastWidth, lastHeight))
        }
        bytesThisSecond = 0
        framesThisSecond = 0
        if capture.currentFrame == nil {
            fail("the window was closed")
            return
        }
        refreshSize(of: capture)
        if let app, let title = currentTitle(capture, app: app), title != lastTitle {
            lastTitle = title
            send(.title(title))
        }
    }

    /// The window's title as Accessibility reports it now, by the client rule
    /// (app name when empty, at most 200 characters); nil if the window is gone.
    private func currentTitle(_ capture: WindowCapture, app: NSRunningApplication) -> String? {
        guard let frame = capture.currentFrame else { return nil }
        let raw = WindowResizer.title(pid: app.processIdentifier, currentFrame: frame) ?? capture.window.title
        return windowTitle(raw, appName: app.localizedName)
    }

    private func refreshSize(of capture: WindowCapture) {
        Task { [weak self] in
            if await capture.refreshIfNeeded() {
                self?.queue.async {
                    guard let self, !self.ended else { return }
                    self.encoder?.reset()
                    // Tell the client A's real content size: the app may not have taken the requested one.
                    if let content = capture.contentFrame {
                        self.send(.size(width: UInt16(clamping: Int(content.width.rounded())),
                                        height: UInt16(clamping: Int(content.height.rounded()))))
                    }
                }
            }
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
        let buffer: (CVPixelBuffer, Int)? = sampleLock.withLock {
            sampleMode = newMode
            return latestBuffer.map { ($0, latestSeq) }
        }
        encoder = FrameEncoder(mode: newMode)
        pending = nil
        if let (pixelBuffer, seq) = buffer {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.quantizeAndSubmit(pixelBuffer, mode: newMode, seq: seq)
            }
        }
    }

    // MARK: Remote resize

    private func resizeWindow(width: Int, height: Int) {
        guard let capture, let app, let frame = capture.currentFrame else { return }
        // The display holding the window's top-left corner, in the same
        // top-left-origin coordinates as the window frame.
        var display = CGMainDisplayID()
        var count: UInt32 = 0
        var found = [CGDirectDisplayID](repeating: 0, count: 1)
        if CGGetDisplaysWithPoint(frame.origin, 1, &found, &count) == .success, count > 0 { display = found[0] }
        let size = windowSize(forContent: CGSize(width: width, height: height), titleRow: capture.titleRow,
                              origin: frame.origin, screen: CGDisplayBounds(display))
        guard WindowResizer.resize(pid: app.processIdentifier, currentFrame: frame, to: size) else {
            output.log("could not resize the window (the app may not allow it)")
            return
        }
        queue.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, !self.ended else { return }
            self.refreshSize(of: capture)
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

    func end(_ reason: String) {
        guard !ended else { return }
        ended = true
        timer?.cancel()
        timer = nil
        capture?.stop()
        capture = nil
        injector = nil
        pending = nil
        connection.cancel()
        onEnd(reason, started)
    }
}
