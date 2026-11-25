import Foundation

// State rows with hold / release timing (spec §4.4). Time is injected; nothing here sleeps.

/// Whether `c` is true given the signals that hold. `.never` is false.
public func holds(_ c: Condition, _ on: Set<String>) -> Bool {
    switch c {
    case .signal(let s): return on.contains(s)
    case .any(let cs): return cs.contains { holds($0, on) }
    case .all(let cs): return cs.allSatisfy { holds($0, on) }
    case .not(let c): return !holds(c, on)
    case .never: return false
    }
}

/// Every signal name a condition mentions.
public func signalsIn(_ c: Condition) -> Set<String> {
    switch c {
    case .signal(let s): return [s]
    case .any(let cs), .all(let cs): return cs.reduce(into: Set<String>()) { $0.formUnion(signalsIn($1)) }
    case .not(let c): return signalsIn(c)
    case .never: return []
    }
}

/// Ordered rows; the first row (top down) that is in force wins.
/// A row not currently in force is entered once its condition has held for `hold` seconds.
/// The row in force is left only after its condition has been false for `release` seconds,
/// and a lower row cannot cut that short; a higher row preempts at once (once past its own hold).
public struct StateTable {
    /// Pack values are Doubles: NaN and negatives count as 0; anything above this is capped.
    public static let maxSeconds: TimeInterval = 3600

    private let rows: [StateRow]
    private var trueSince: [TimeInterval?]
    private var falseSince: [TimeInterval?]
    private var current: Int?   // nil: no table row in force (the idle fallback)

    public init(_ rows: [StateRow]) {
        self.rows = rows
        trueSince = Array(repeating: nil, count: rows.count)
        falseSince = Array(repeating: nil, count: rows.count)
    }

    private static func seconds(_ x: Double) -> TimeInterval {
        x.isNaN || x < 0 ? 0 : min(x, maxSeconds)
    }

    /// The row in force at `now`, given the signals that hold; nil only when the table has no rows.
    /// With rows but none in force the result is a bare `idle` row.
    public mutating func step(on: Set<String>, now: TimeInterval) -> StateRow? {
        if rows.isEmpty { return nil }
        for i in rows.indices {
            let on = rows[i].when.map { holds($0, on) } ?? true
            if on {
                if trueSince[i] == nil { trueSince[i] = now }
                falseSince[i] = nil
            } else {
                if falseSince[i] == nil { falseSince[i] = now }
                trueSince[i] = nil
            }
        }
        for i in rows.indices {
            let satisfied: Bool
            if i == current {
                satisfied = trueSince[i] != nil
                    || now - (falseSince[i] ?? now) < Self.seconds(rows[i].release)
            } else {
                satisfied = trueSince[i].map { now - $0 >= Self.seconds(rows[i].hold) } ?? false
            }
            if satisfied { current = i; return rows[i] }
        }
        current = nil
        return StateRow(state: "idle", kind: nil, when: nil, hold: 0, release: 0)
    }
}
