import AppKit
import RappCore

/// Pastes B's items into the target app (spec §3.3): writes A's clipboard, sends ⌘V, then
/// restores what the clipboard held. Pastes run one at a time, in order. Session state
/// (`pending`, `session`, `saved`) lives on `queue`; pasteboard work and `snapshot` live on main.
final class Paster {
    private static let maxSnapshotBytes = 64 << 20

    private let app: NSRunningApplication
    private let queue: DispatchQueue
    private let transfers: () -> TransferStore?
    private let watcher: () -> ClipboardWatcher?
    private let log: (String) -> Void
    private let reply: (UInt32, String) -> Void

    // Session queue.
    private var pending: [(seq: UInt32, source: PasteSource)] = []
    private var busy = false
    private var ended = false
    private var session = PasteSession()
    private var saved = false

    // Main queue.
    private var cancelled = false
    private var lastPasteSent: TimeInterval?
    /// Main queue: pasteboard changeCount after the last write this Paster made.
    private var lastOwnChange = Int.min
    private var snapshot: [[(NSPasteboard.PasteboardType, Data)]]?

    init(app: NSRunningApplication, queue: DispatchQueue, transfers: @escaping () -> TransferStore?,
         watcher: @escaping () -> ClipboardWatcher?, log: @escaping (String) -> Void,
         reply: @escaping (UInt32, String) -> Void) {
        self.app = app
        self.queue = queue
        self.transfers = transfers
        self.watcher = watcher
        self.log = log
        self.reply = reply
    }

    private func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// Session queue.
    func paste(seq: UInt32, _ source: PasteSource) {
        guard !ended else { return }
        pending.append((seq, source))
        next()
    }

    /// Session queue: the session is over; put the clipboard back at once.
    func end() {
        guard !ended else { return }
        ended = true
        pending = []
        if saved {
            saved = false
            session.restored()
        }
        // Same main-queue block: stop in-flight pastes, then restore (FIFO keeps this after any queued write).
        DispatchQueue.main.async {
            self.cancelled = true
            // The target reads the pasteboard shortly after ⌘V; let it, before restoring.
            let wait = self.lastPasteSent.map { $0 + 0.15 - ProcessInfo.processInfo.systemUptime } ?? 0
            if wait > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + wait) { self.restoreOnMain(noteWrite: false) }
            } else {
                self.restoreOnMain(noteWrite: false)
            }
        }
    }

    // MARK: Session queue

    private func next() {
        guard !busy, !ended, !pending.isEmpty else { return }
        let (seq, source) = pending.removeFirst()
        let item: ReceivedItem
        switch source {
        case let .text(text):
            item = .text(text)
        case let .item(id):
            guard let received = transfers()?.received(id) else {
                reply(seq, "not uploaded")
                return next()
            }
            item = received
        }
        busy = true
        let save = session.pasteStarted(now: now())
        if save { saved = true }
        DispatchQueue.main.async { self.write(item, save: save, seq: seq) }
    }

    private func finish(seq: UInt32, error: String) {
        guard !ended else { return }
        session.pasteFinished(now: now())
        busy = false
        reply(seq, error)
        queue.asyncAfter(deadline: .now() + PasteSession.restoreDelay + 0.05) { [self] in
            guard !ended, session.restoreDue(now: now()) else { return }
            saved = false
            session.restored()
            DispatchQueue.main.async { self.restoreOnMain(noteWrite: true) }
        }
        next()
    }

    private func noteOwnWrite(_ count: Int) {
        queue.async { [self] in if !ended { watcher()?.noteOwnWrite(changeCount: count) } }
    }

    // MARK: Main queue

    private func write(_ item: ReceivedItem, save: Bool, seq: UInt32) {
        guard !cancelled else { return }
        let pb = NSPasteboard.general
        if save { snapshot = takeSnapshot(pb) }
        pb.clearContents()
        switch item {
        case let .text(text): pb.setString(text, forType: .string)
        case let .image(bytes): pb.setData(Data(bytes), forType: NSPasteboard.PasteboardType(typePNG))
        case let .data(uti, bytes): pb.setData(Data(bytes), forType: NSPasteboard.PasteboardType(uti))
        case let .file(url): pb.writeObjects([url as NSURL])
        }
        lastOwnChange = pb.changeCount
        noteOwnWrite(pb.changeCount)
        app.activate()
        waitFrontmost(tries: 10, seq: seq)
    }

    private func waitFrontmost(tries: Int, seq: UInt32) {
        guard !cancelled else { return }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier {
            sendPaste()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                self.queue.async { self.finish(seq: seq, error: "") }
            }
        } else if tries > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self.waitFrontmost(tries: tries - 1, seq: seq) }
        } else {
            queue.async { self.finish(seq: seq, error: "target not frontmost") }
        }
    }

    private func sendPaste() {
        guard !cancelled else { return }
        lastPasteSent = now()
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: down) else { continue }
            event.flags = .maskCommand
            event.post(tap: .cghidEventTap)
        }
    }

    private func takeSnapshot(_ pb: NSPasteboard) -> [[(NSPasteboard.PasteboardType, Data)]]? {
        var total = 0
        var items: [[(NSPasteboard.PasteboardType, Data)]] = []
        for item in pb.pasteboardItems ?? [] {
            var entries: [(NSPasteboard.PasteboardType, Data)] = []
            for type in item.types {
                guard let data = item.data(forType: type) else { continue }
                total += data.count
                if total > Self.maxSnapshotBytes {
                    log("clipboard too large to save; it will not be restored")
                    return nil
                }
                entries.append((type, data))
            }
            items.append(entries)
        }
        return items
    }

    private func restoreOnMain(noteWrite: Bool) {
        guard let items = snapshot else { return }
        snapshot = nil
        let pb = NSPasteboard.general
        // Something else (a copy on A) wrote since our paste: leave it alone.
        guard shouldRestore(lastOwnChange: lastOwnChange, current: pb.changeCount) else { return }
        pb.clearContents()
        let objects: [NSPasteboardItem] = items.map { entries in
            let item = NSPasteboardItem()
            for (type, data) in entries { item.setData(data, forType: type) }
            return item
        }
        if !objects.isEmpty { pb.writeObjects(objects) }
        lastOwnChange = pb.changeCount
        if noteWrite { noteOwnWrite(pb.changeCount) }
    }
}
