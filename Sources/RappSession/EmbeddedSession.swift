import CoreGraphics
import Foundation
import RappCore

/// All of one embedded session's non-UI logic: the connection's messages become pictures in
/// `surfaces` and events for the runner. Everything runs on `queue`; bad data from the remote
/// ends this session only.
public final class EmbeddedSession {
    public let surfaces = WindowSurfaces()
    /// Called on `queue`.
    public var onEvent: ((SessionEvent) -> Void)?
    public var backingScale: CGFloat {
        didSet { if backingScale != oldValue { run { self.sendStreamIfChanged() } } }
    }

    private let address: RemoteAddress
    private let link: MessageLink
    private let queue: DispatchQueue
    private let history: ClipHistory
    private let decoder: FrameDecoder
    private let queueKey = DispatchSpecificKey<Void>()

    private var table = [WindowInfo]()
    /// The `visible` of each window as last sent in a `.windows` event.
    private var emittedVisible = [UInt32: CGRect]()
    private var mode: Mode
    private var fps: UInt8
    private var choice: DensityChoice
    private var sentStream: (mode: Mode, fps: UInt8, density: Float)?
    private var bytes = 0
    private var closed = false

    public init(address: RemoteAddress, choice: DensityChoice, backingScale: CGFloat, link: MessageLink,
                pasteboard: LocalPasteboard, queue: DispatchQueue) {
        self.address = address
        self.choice = choice
        self.backingScale = backingScale
        self.link = link
        self.queue = queue
        self.mode = address.mode
        self.fps = address.fps
        self.decoder = FrameDecoder(mode: address.mode)
        self.history = ClipHistory(pasteboard: pasteboard, log: { _ in })
        queue.setSpecific(key: queueKey, value: ())
        link.density = captureDensity(zoom: 1, backingScale: backingScale, choice: choice)
    }

    public func start() {
        run {
            self.link.onMessage = { [weak self] in self?.handle($0) }
            self.link.onClosed = { [weak self] in self?.close(reason: $0) }
            self.link.onBytes = { [weak self] in self?.bytes += $0 }
            self.link.start()
        }
    }

    public func send(_ m: Message) {
        run { if !self.closed { self.link.send(m) } }
    }

    public func setStream(mode: Mode, fps: UInt8, choice: DensityChoice) {
        run {
            self.mode = mode; self.fps = fps; self.choice = choice
            self.sendStreamIfChanged()
        }
    }

    /// Once a second from the runner: reports the bytes received since the last call.
    public func tickTraffic() {
        run {
            let n = self.bytes
            self.bytes = 0
            if !self.closed { self.onEvent?(.traffic(bytesPerSecond: n)) }
        }
    }

    /// Ends the session; only the first call does anything.
    public func close(reason: String = "quit") {
        run {
            guard !self.closed else { return }
            self.closed = true
            self.link.cancel()
            _ = self.surfaces.keep(only: [])
            self.onEvent?(.closed(reason: reason))
        }
    }

    /// Runs `body` on the queue (now if already there).
    private func run(_ body: @escaping () -> Void) {
        if DispatchQueue.getSpecific(key: queueKey) != nil { body() } else { queue.async(execute: body) }
    }

    private func handle(_ message: Message) {
        guard !closed else { return }
        switch message {
        case let .ready(appName, _, _):
            onEvent?(.ready(appName: appName))
            sendStreamIfChanged()
        case let .windows(newTable):
            table = newTable
            _ = surfaces.keep(only: Set(newTable.map(\.id)))
            emitWindows()
            sendStreamIfChanged()
        case let .frame(region, payload):
            do {
                try decoder.decode(payload)
                let ids = try surfaces.draw(table: table, decoder: decoder, region: region)
                onEvent?(.surfaces(ids))
                if table.contains(where: { info in surfaces.visible(info.id).map { $0 != emittedVisible[info.id] } ?? false }) {
                    emitWindows()
                }
            } catch {
                close(reason: "cannot decode frame: \(error)")
            }
        case let .menuBar(items):
            onEvent?(.menu(items))
        case let .clip(id, info):
            history.add(id: id, info)
            onEvent?(.clips(history.entries.map { entry in
                var pickable = true
                if case .unsupported = entry.info { pickable = false }
                return ClipRow(id: entry.id, title: historyTitle(entry.info), pickable: pickable)
            }))
        case let .error(reason):
            close(reason: "host says: \(reason)")
        default:
            break
        }
    }

    private func emitWindows() {
        let windows = sessionWindows()
        emittedVisible = Dictionary(windows.map { ($0.info.id, $0.visible) }, uniquingKeysWith: { $1 })
        onEvent?(.windows(windows))
    }

    private func sessionWindows() -> [SessionWindow] {
        table.map { SessionWindow(info: $0, visible: surfaces.visible($0.id) ?? CGRect(x: 0, y: 0, width: 1, height: 1)) }
    }

    private func sendStreamIfChanged() {
        guard !closed else { return }
        let next = (mode: mode, fps: fps, density: captureDensity(zoom: 1, backingScale: backingScale, choice: choice))
        guard streamChanged(from: sentStream, to: next) else { return }
        sentStream = next
        link.send(.setStream(mode: next.mode, fps: next.fps, density: next.density))
    }
}
