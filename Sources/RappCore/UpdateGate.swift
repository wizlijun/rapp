import Foundation

/// Runs one piece of async work (re-applying whatever state is wanted now)
/// never more than once at a time. Requests that arrive while it runs are
/// folded into one more run, which reads the state as it is by then, so a
/// stale update can never finish last. Requests made before `open` wait for
/// it; once `close` is called nothing runs again.
public final class UpdateGate: @unchecked Sendable {
    private let lock = NSLock()
    private var work: (() async -> Void)?
    private var pending = false
    private var running = false
    private var closed = false

    public init() {}

    /// Installs the work and runs it if a request is already waiting.
    /// Returns false, without installing anything, if the gate was closed.
    public func open(_ work: @escaping () async -> Void) async -> Bool {
        let opened: Bool = lock.withLock {
            guard !closed else { return false }
            self.work = work
            return true
        }
        if opened { await drain() }
        return opened
    }

    /// Asks for the work to run. Returns once it ran, or at once if another
    /// caller's run will pick this request up.
    public func request() async {
        lock.withLock { if !closed { pending = true } }
        await drain()
    }

    public func close() {
        lock.withLock {
            closed = true
            pending = false
            work = nil
        }
    }

    public var isClosed: Bool { lock.withLock { closed } }

    private func drain() async {
        while true {
            let next: (() async -> Void)? = lock.withLock {
                guard !running, !closed, pending, let work else { return nil }
                running = true
                pending = false
                return work
            }
            guard let next else { return }
            await next()
            lock.withLock { running = false }
        }
    }
}
