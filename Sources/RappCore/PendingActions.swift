import Foundation

/// At most one delayed main-queue action per key: scheduling again replaces
/// the earlier one, and `keep(only:)` cancels and forgets the rest, so a
/// closed window's action neither runs nor keeps the window alive.
public struct PendingActions<Key: Hashable> {
    private var items: [Key: DispatchWorkItem] = [:]

    public init() {}

    public var count: Int { items.count }

    public mutating func schedule(_ key: Key, after delay: TimeInterval, _ action: @escaping () -> Void) {
        items[key]?.cancel()
        let item = DispatchWorkItem(block: action)
        items[key] = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    public mutating func cancel(_ key: Key) {
        items.removeValue(forKey: key)?.cancel()
    }

    public mutating func keep(only keys: Set<Key>) {
        for (key, item) in items where !keys.contains(key) {
            item.cancel()
            items[key] = nil
        }
    }
}
