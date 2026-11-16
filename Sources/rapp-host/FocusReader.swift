import ApplicationServices
import CoreGraphics
import Foundation
import RappCore

/// Reads the controlled app's Accessibility tree for the focus pane (spec 2026-11-16-rapp-focus-pane-rules).
///
/// Privacy: only role, position, size and parent are read, plus the focused element and the element at a
/// point. Never a title, value, description or any text attribute.
///
/// Runs on its own serial queue, one query at a time; waiting queries are coalesced (`QueryCoalescer`).
/// Every failure (an AX error, a missed deadline, no Accessibility permission) is `.blocked`; whether a
/// chain is too small or too large is `FocusPane.panel`'s call.
final class FocusReader {
    struct Chain {
        let roles: [String]
        /// Window points, the start element first, each parent after it, the AXWindow last when reached.
        let rects: [CGRect]
        let ms: Int
    }

    /// A whole query, with its reply.
    private struct Job {
        let query: FocusTracker.Query
        let window: WindowInfo
        let display: CGRect
        let done: (Result<Chain, PanelMiss>) -> Void
    }

    static let budget: TimeInterval = 0.05

    private let pid: pid_t
    private let log: (String) -> Void
    private let onKeyboardChanged: () -> Void
    private let queue = DispatchQueue(label: "rapp.focus-reader")
    private let lock = NSLock()
    private var coalescer = QueryCoalescer<Job>()
    private var stopped = false
    private let trusted: Bool
    private var observer: AXObserver?
    private var observerBox: Unmanaged<Box>?

    private final class Box { let fire: () -> Void; init(_ f: @escaping () -> Void) { fire = f } }

    init(pid: pid_t, onKeyboardChanged: @escaping () -> Void, log: @escaping (String) -> Void = { _ in }) {
        self.pid = pid
        self.onKeyboardChanged = onKeyboardChanged
        self.log = log
        trusted = AXIsProcessTrusted()
        if trusted {
            installObserver()
        } else {
            log("focus: no Accessibility permission, the whole window stays colour")
        }
    }

    func query(_ q: FocusTracker.Query, window: WindowInfo, display: CGRect,
               done: @escaping (Result<Chain, PanelMiss>) -> Void) {
        guard trusted else { done(.failure(.blocked)); return }
        let job = Job(query: q, window: window, display: display, done: done)
        lock.lock()
        let now = stopped ? nil : coalescer.submit(q.kind, job)
        lock.unlock()
        if let now { run(now) }
    }

    func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
            self.observer = nil
        }
        observerBox?.release()
        observerBox = nil
    }

    private func run(_ job: Job) {
        queue.async { [self] in
            let result = read(job)
            job.done(result)
            lock.lock()
            let next = stopped ? nil : coalescer.finish()
            lock.unlock()
            if let next { run(next) }
        }
    }

    // MARK: Accessibility

    private func read(_ job: Job) -> Result<Chain, PanelMiss> {
        let started = uptimeSeconds()
        let deadline = started + Self.budget
        let app = AXUIElementCreateApplication(pid)
        func remaining() -> Float? {
            let left = deadline - uptimeSeconds()
            return left > 0.001 ? Float(left) : nil
        }

        var start: AXUIElement?
        switch job.query {
        case .keyboard:
            guard let t = remaining() else { return .failure(.blocked) }
            AXUIElementSetMessagingTimeout(app, t)
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &value) == .success,
                  let v = value, CFGetTypeID(v) == AXUIElementGetTypeID() else { return .failure(.blocked) }
            start = (v as! AXUIElement)
        case .pointer(let p), .follow(let p):
            // Window points -> global points.
            let gx = job.display.minX + CGFloat(job.window.rect.x) + p.x
            let gy = job.display.minY + CGFloat(job.window.rect.y) + p.y
            guard let t = remaining() else { return .failure(.blocked) }
            AXUIElementSetMessagingTimeout(app, t)
            var el: AXUIElement?
            guard AXUIElementCopyElementAtPosition(app, Float(gx), Float(gy), &el) == .success, let e = el
            else { return .failure(.blocked) }
            start = e
        }

        var roles: [String] = []
        var rects: [CGRect] = []
        var element = start
        while let current = element, roles.count < FocusPane.maxDepth {
            guard let t = remaining() else { return .failure(.blocked) }
            AXUIElementSetMessagingTimeout(current, t)
            guard let role = stringAttribute(current, kAXRoleAttribute),
                  let global = frame(of: current) else { return .failure(.blocked) }
            roles.append(role)
            rects.append(FocusPane.windowRect(global: global, display: job.display, window: job.window.rect))
            if role == kAXWindowRole as String { break }
            // A missing parent ends the chain; any other error is a block.
            var parent: CFTypeRef?
            let err = AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parent)
            if err == .noValue || err == .attributeUnsupported { break }
            guard err == .success, let p = parent, CFGetTypeID(p) == AXUIElementGetTypeID() else {
                return .failure(.blocked)
            }
            element = (p as! AXUIElement)
        }
        guard !rects.isEmpty else { return .failure(.blocked) }
        return .success(Chain(roles: roles, rects: rects, ms: Int(((uptimeSeconds() - started) * 1000).rounded())))
    }

    /// Role only (never a title or text).
    private func stringAttribute(_ e: AXUIElement, _ name: String) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success else { return nil }
        return v as? String
    }

    private func frame(of e: AXUIElement) -> CGRect? {
        var pv: CFTypeRef?, sv: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, kAXPositionAttribute as CFString, &pv) == .success,
              AXUIElementCopyAttributeValue(e, kAXSizeAttribute as CFString, &sv) == .success,
              let pv, let sv, CFGetTypeID(pv) == AXValueGetTypeID(), CFGetTypeID(sv) == AXValueGetTypeID()
        else { return nil }
        var origin = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(pv as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sv as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    // MARK: notification

    private func installObserver() {
        var obs: AXObserver?
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            Unmanaged<Box>.fromOpaque(refcon).takeUnretainedValue().fire()
        }
        guard AXObserverCreate(pid, callback, &obs) == .success, let obs else {
            log("focus: could not watch focus changes")
            return
        }
        let box = Unmanaged.passRetained(Box { [weak self] in self?.onKeyboardChanged() })
        let app = AXUIElementCreateApplication(pid)
        guard AXObserverAddNotification(obs, app, kAXFocusedUIElementChangedNotification as CFString,
                                        box.toOpaque()) == .success else {
            box.release()
            log("focus: could not watch focus changes")
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        observer = obs
        observerBox = box
    }
}
