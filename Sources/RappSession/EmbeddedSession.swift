import CoreGraphics
import Foundation
import RappCore

/// All of one embedded session's non-UI logic: the connection's messages become pictures in
/// `surfaces` and events for the runner. Everything runs on `queue` except the composer and the
/// transfer queue, which live on the main queue (values hop between the two, never shared state);
/// bad data from the remote ends this session only.
public final class EmbeddedSession {
    public let surfaces = WindowSurfaces()
    /// Called on `queue`.
    public var onEvent: ((SessionEvent) -> Void)?
    public var backingScale: CGFloat {
        didSet { if backingScale != oldValue { run { self.sendStreamIfChanged() } } }
    }

    /// Where a clip taken "into the composer" goes; the composer's `insert` unless replaced. Called on
    /// the main queue; set it on main.
    public var onInsert: ((ClipInfo, InsertPayload) -> Void)?

    /// This session's composer. **Main queue only**, like the transfer queue it sends through: the runner
    /// calls it from the channel handler; `pasted` from A hops here with its value. Its messages to A go
    /// through `send` (onto the session queue); its events come back as `.composer` on the session queue.
    public private(set) lazy var composer = EmbeddedComposer(
        pasteboard: pasteboard, transfers: transfers, counters: counters,
        send: { [weak self] in self?.send($0) },
        emit: { [weak self] in self?.post(.composer($0)) })

    private let address: RemoteAddress
    private let pasteboard: LocalPasteboard
    /// Main queue only.
    private let transfers: TransferQueue
    /// Item and paste numbers for this session's connection; main queue only (the composer's).
    private let counters = SendCounters()
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
        self.pasteboard = pasteboard
        self.transfers = TransferQueue(address: address)
        self.queue = queue
        self.mode = address.mode
        self.fps = address.fps
        self.decoder = FrameDecoder(mode: address.mode)
        self.history = ClipHistory(pasteboard: pasteboard, log: { _ in })
        queue.setSpecific(key: queueKey, value: ())
        link.density = captureDensity(zoom: 1, backingScale: backingScale, choice: choice)
        // The transfer queue reports on main; the runner hears it on the session queue, like every event.
        transfers.onStatus = { [weak self] in self?.post(.transfer($0)) }
        onInsert = { [weak self] info, payload in self?.composer.insert(info, payload) }
    }

    public func start() {
        run { [self] in
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

    /// Presses the A menu item at `path`.
    public func menuPick(_ path: [UInt16]) {
        send(.menuPick(path))
    }

    /// 「放左上角」: moves A's window `window` to the first free top-left slot and raises it.
    public func moveToTopLeft(window: UInt32) {
        run {
            guard !self.closed, self.table.contains(where: { $0.id == window }) else { return }
            moveToTopLeftMessages(window: window, table: self.table).forEach { self.link.send($0) }
        }
    }

    /// Takes clip `id` onto B's clipboard, or (insert) hands it to `onInsert`. Text is immediate;
    /// anything fetched goes through the transfer queue, which lives on the main queue.
    public func pickClip(_ id: UInt32, insert: Bool) {
        run { [self] in
            guard !closed, let info = history.info(id) else { return }
            let hand: (ClipInfo, InsertPayload) -> Void = { [weak self] info, payload in
                DispatchQueue.main.async { self?.onInsert?(info, payload) }
            }
            if case .text = info {
                history.pick(id, info: info, insert: insert, transfers: transfers, pasteboard: pasteboard, onInsert: hand)
            } else {
                DispatchQueue.main.async { [self] in
                    history.pick(id, info: info, insert: insert, transfers: transfers, pasteboard: pasteboard, onInsert: hand)
                }
            }
        }
    }

    /// Main queue (the runner's `cancel_transfer`): stops the running upload or download, drops the queued
    /// ones. A send round waiting on an upload ends with `.done(sent:failure: "")`.
    public func cancelTransfers() {
        transfers.cancel()
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
            // The transfer queue lives on the main queue.
            DispatchQueue.main.async { [transfers = self.transfers] in transfers.cancel() }
            _ = self.surfaces.keep(only: [])
            self.onEvent?(.closed(reason: reason))
        }
    }

    /// From main: delivers `e` on the session queue, unless the session has closed by then.
    private func post(_ e: SessionEvent) {
        run { [weak self] in
            guard let self, !self.closed else { return }
            self.onEvent?(e)
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
        case let .pasted(seq, error):
            // The composer lives on main: hand it the values, not this queue's state.
            DispatchQueue.main.async { [weak self] in _ = self?.composer.pasted(seq: seq, error: error) }
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
