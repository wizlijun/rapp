/// Keeps A awake while one session is open: one hold per session, released
/// exactly once. The platform calls are injected so the bookkeeping is
/// testable; rapp-host passes IOKit power assertions.
public final class StayAwake {
    private let hold: () -> UInt32?
    private let release: (UInt32) -> Void
    private var held: UInt32?
    private var begun = false

    /// `hold` returns an id to release later, or nil if the system refused.
    public init(hold: @escaping () -> UInt32?, release: @escaping (UInt32) -> Void) {
        self.hold = hold
        self.release = release
    }

    /// True when a hold is in place after the call.
    @discardableResult
    public func begin() -> Bool {
        guard !begun else { return held != nil }
        begun = true
        held = hold()
        return held != nil
    }

    public func end() {
        guard begun else { return }
        begun = false
        if let id = held { release(id) }
        held = nil
    }
}
