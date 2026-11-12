/// What the host has posted as pressed and not yet released. Pure bookkeeping,
/// so a session teardown can release exactly these and nothing else.
public struct HeldInput {
    private var keys = Set<UInt16>()
    private var buttons = Set<MouseButton>()

    public init() {}

    public mutating func pressKey(_ code: UInt16) { keys.insert(code) }
    public mutating func releaseKey(_ code: UInt16) { keys.remove(code) }
    /// Call only for a down that was actually posted.
    public mutating func pressButton(_ button: MouseButton) { buttons.insert(button) }
    public mutating func releaseButton(_ button: MouseButton) { buttons.remove(button) }

    /// Everything still held (keys ascending, left button first), then forgets it.
    public mutating func drain() -> (keys: [UInt16], buttons: [MouseButton]) {
        defer { keys.removeAll(); buttons.removeAll() }
        return (keys.sorted(), buttons.sorted { $0.rawValue < $1.rawValue })
    }
}
