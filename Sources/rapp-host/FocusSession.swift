import CoreGraphics
import Foundation
import RappCore

/// The focus pane of one session (spec 2026-11-16-rapp-focus-pane-rules): feeds `FocusTracker` with input,
/// window-table changes, lock state and encoded-frame reports, asks `FocusReader` for AX answers and sends
/// `focusRegion`. Exists only while B has the focus bit on. Lives on the session queue.
final class FocusSession {
    private let display: CGRect
    private let queue: DispatchQueue
    private let send: (Message) -> Void
    private let log: (String) -> Void
    private let tracker = FocusTracker()
    private var reader: FocusReader?
    private var timer: DispatchSourceTimer?
    private var stopped = false

    private var window: WindowInfo?
    private var seen = Set<UInt32>()
    private var appeared: [UInt32: TimeInterval] = [:]

    /// What the latest query found, for the log line.
    private struct Found { var start = "-", picked = "-", depth = 0, share = 0.0, ms = 0 }
    private var found = Found()

    init(pid: pid_t, display: CGRect, queue: DispatchQueue, send: @escaping (Message) -> Void,
         log: @escaping (String) -> Void) {
        self.display = display
        self.queue = queue
        self.send = send
        self.log = log
        reader = FocusReader(pid: pid, onKeyboardChanged: { [weak self] in
            guard let self else { return }
            self.queue.async { [weak self] in
                guard let self, !self.stopped else { return }
                self.dispatch(self.tracker.keyboardChanged(now: uptimeSeconds()))
            }
        }, log: log)
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.1, repeating: 0.1)
        t.setEventHandler { [weak self] in
            guard let self, !self.stopped else { return }
            self.dispatch(self.tracker.tick(now: uptimeSeconds()))
        }
        t.resume()
        timer = t
    }

    /// Call once after the first `windows` and `locked`.
    func start() { dispatch(tracker.start(now: uptimeSeconds())) }

    func input(_ m: Message) {
        guard !stopped else { return }
        let now = uptimeSeconds()
        switch m {
        case let .mouse(kind, _, id, x, y, _):
            guard id == window?.id else { return }
            let p = CGPoint(x: CGFloat(x), y: CGFloat(y))
            switch kind {
            case .down: dispatch(tracker.pointer(.click, at: p, now: now))
            case .drag: dispatch(tracker.pointer(.drag, at: p, now: now))
            case .move: dispatch(tracker.pointer(.move, at: p, now: now))
            case .up: break
            }
        case let .scroll(id, x, y, _, _):
            guard id == window?.id else { return }
            dispatch(tracker.pointer(.scroll, at: CGPoint(x: CGFloat(x), y: CGFloat(y)), now: now))
        case .key, .text, .paste:
            dispatch(tracker.key(now: now))
        default:
            break
        }
    }

    func windows(_ table: [WindowInfo]) {
        guard !stopped else { return }
        let now = uptimeSeconds()
        let focused = table.first(where: \.focused)
        window = focused
        if let f = focused, seen.insert(f.id).inserted { appeared[f.id] = now }
        let size = focused.map { CGSize(width: CGFloat($0.rect.w), height: CGFloat($0.rect.h)) } ?? .zero
        dispatch(tracker.window(id: focused?.id, size: size, appeared: focused.flatMap { appeared[$0.id] }, now: now))
    }

    func locked(_ on: Bool) {
        guard !stopped else { return }
        dispatch(tracker.locked(on, now: uptimeSeconds()))
    }

    func encoded(_ r: EncodeReport) {
        guard !stopped, let w = window else { return }
        dispatch(tracker.frame(FocusPane.windowTiles(r, window: w.rect), now: uptimeSeconds()))
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        timer?.cancel()
        timer = nil
        reader?.stop()
        reader = nil
    }

    // MARK: actions

    private func dispatch(_ actions: [FocusTracker.Action]) {
        for action in actions {
            switch action {
            case let .query(q, generation): ask(q, generation: generation)
            case let .send(out): emit(out)
            }
        }
    }

    private func ask(_ q: FocusTracker.Query, generation: Int) {
        guard let reader, let w = window else { return }
        reader.query(q, window: w, display: display) { [weak self] reading in
            self?.queue.async { [weak self] in self?.answered(q, generation: generation, reading) }
        }
    }

    private func answered(_ q: FocusTracker.Query, generation: Int, _ reading: FocusReader.Reading) {
        guard !stopped, let w = window else { return }
        let size = CGSize(width: CGFloat(w.rect.w), height: CGFloat(w.rect.h))
        let picked: Result<PanelPick, PanelMiss>
        // depth= is the layers walked, for a pick, a miss and a block alike.
        switch reading.result {
        case .failure(let miss):
            picked = .failure(miss)
            found = Found(start: "-", picked: miss.rawValue, depth: reading.walked, share: 0, ms: reading.ms)
        case .success(let chain):
            picked = FocusPane.panel(chain: chain.rects, window: size)
            let start = chain.roles.first ?? "-"
            switch picked {
            case .success(let p):
                found = Found(start: start, picked: chain.roles[min(p.depth, chain.roles.count - 1)],
                              depth: reading.walked, share: p.share, ms: reading.ms)
            case .failure(let miss):
                found = Found(start: start, picked: miss.rawValue, depth: reading.walked, share: 0, ms: reading.ms)
            }
        }
        dispatch(tracker.result(q, generation: generation, picked, now: uptimeSeconds()))
    }

    private func emit(_ out: FocusTracker.Output) {
        send(.focusRegion(window: out.window, rects: out.rects.map {
            CanvasRect(x: Float($0.minX), y: Float($0.minY), w: Float($0.width), h: Float($0.height))
        }))
        let outText = out.rects.isEmpty ? "whole" : out.rects.map(Self.text).joined(separator: " ")
        log("[focus] win=\(out.window) cause=\(out.cause.rawValue) start=\(found.start) depth=\(found.depth)"
            + " picked=\(found.picked) share=\(String(format: "%.2f", found.share))"
            + " kb=\(tracker.keyboardPanel.map(Self.text) ?? tracker.keyboardMiss?.rawValue ?? "-")"
            + " ptr=\(tracker.pointerPanel.map(Self.text) ?? tracker.pointerMiss?.rawValue ?? "-")"
            + " follow=\(tracker.followPanel.map(Self.text) ?? "-") out=\(outText) axMs=\(found.ms)")
    }

    private static func text(_ r: CGRect) -> String {
        "\(Int(r.minX.rounded())),\(Int(r.minY.rounded())),\(Int(r.width.rounded()))x\(Int(r.height.rounded()))"
    }
}
