public enum QueryKind: CaseIterable { case keyboard, pointer, follow }

/// Bookkeeping for a reader that runs one query at a time: while one runs, at most one more waits per
/// query kind, and a newer one replaces the waiting one of its kind. A pointer query therefore never
/// pushes out a waiting keyboard query, and a burst of scroll events leaves one pointer query behind.
public struct QueryCoalescer<Job> {
    private var running = false
    private var pending: [QueryKind: Job] = [:]

    public init() {}

    /// Returns the job to start now, or nil when one is running (the job then waits in its slot).
    public mutating func submit(_ kind: QueryKind, _ job: Job) -> Job? {
        if running { pending[kind] = job; return nil }
        running = true
        return job
    }

    /// The running job is done: returns the next waiting job (keyboard, pointer, follow), or nil when idle.
    public mutating func finish() -> Job? {
        for kind in QueryKind.allCases {
            if let job = pending.removeValue(forKey: kind) { return job }
        }
        running = false
        return nil
    }
}

extension FocusTracker.Query {
    public var kind: QueryKind {
        switch self {
        case .keyboard: return .keyboard
        case .pointer: return .pointer
        case .follow: return .follow
        }
    }
}
