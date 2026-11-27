import CoreGraphics
import Foundation
import XCTest
@testable import RappCore

/// Lock and unlock rules for `rust/host-core/tests/rules_lock.rs`. The injected closures are
/// scripted from `in` and record every call they get, in order, into `out.events`.
///
/// - `lock.json`:
///   - `lock_screen {locked, call, timeout, step}`: `isLocked` returns `locked[i]` on its
///     i-th call (the last value once the list is spent); `call` returns `call` (null = success).
///     Out: `{outcome, events}`, outcome `{"kind": "locked"|"already"|"failed", "reason"}`.
///   - `wait_until_unlocked {locked, timeout, step}`: out `{events}`.
///   - `locked_start_display {windows, displays}`: out the display rect or null.
///   - `stay_awake {granted, steps}`: steps `begin` / `end`; `hold` returns 1, 2, … (or nil when
///     not granted). Out `{events}`: `{"op":"hold","id"}`, `{"op":"release","id"}`.
/// - `unlock-sequence.json`: `type_unlock_password {password, locked, unlock_after}`. A is
///   locked as `locked` says, and turns unlocked right after the `unlock_after.n`-th call of
///   `unlock_after.op` (`wake`, `wait`, `type`), or never when null. Out `{events}`:
///   `is_locked {v}`, `wake`, `wait {us}`, `type {units}`, `return`.
///
/// Covers every scenario of ScreenLockTests, UnlockSequenceTests and StayAwakeTests, plus the
/// plan's extras (a 1024-unit password, unlocking after the 3rd chunk, already unlocked at
/// entry), a surrogate pair at a chunk edge, ties between equal windows, and a negative-size rect.
final class LockFixtures: XCTestCase {
    private typealias F = HostFixture

    private static func r(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> CGRect {
        CGRect(x: x, y: y, width: w, height: h)
    }

    /// The rect as written, not standardised: Rust reads back the same four numbers.
    private static func j(_ r: CGRect) -> [String: Any] {
        F.rect(x: Double(r.origin.x), y: Double(r.origin.y), width: Double(r.size.width), height: Double(r.size.height))
    }

    // MARK: - lock.json

    private static func lockCase(_ name: String, locked: [Bool], call: String?,
                                 timeout: Double = 2, step: Double = 0.1) -> [String: Any] {
        var events: [[String: Any]] = []
        var i = 0
        let outcome = lockScreen(isLocked: {
            let v = locked.isEmpty ? false : locked[min(i, locked.count - 1)]
            i += 1
            events.append(["op": "is_locked", "v": v])
            return v
        }, call: {
            events.append(["op": "call"])
            return call
        }, sleep: { events.append(["op": "sleep", "s": $0]) }, timeout: timeout, step: step)
        let o: [String: Any]
        switch outcome {
        case .locked: o = ["kind": "locked", "reason": NSNull()]
        case .already: o = ["kind": "already", "reason": NSNull()]
        case .failed(let reason): o = ["kind": "failed", "reason": reason]
        }
        return ["name": name,
                "in": ["fn": "lock_screen", "locked": locked, "call": F.opt(call), "timeout": timeout, "step": step],
                "out": ["outcome": o, "events": events]]
    }

    private static func waitCase(_ name: String, locked: [Bool], timeout: Double = 8, step: Double = 0.1) -> [String: Any] {
        var events: [[String: Any]] = []
        var i = 0
        waitUntilUnlocked(isLocked: {
            let v = locked.isEmpty ? false : locked[min(i, locked.count - 1)]
            i += 1
            events.append(["op": "is_locked", "v": v])
            return v
        }, sleep: { events.append(["op": "sleep", "s": $0]) }, timeout: timeout, step: step)
        return ["name": name,
                "in": ["fn": "wait_until_unlocked", "locked": locked, "timeout": timeout, "step": step],
                "out": ["events": events]]
    }

    private static func displayCase(_ name: String, _ windows: [CGRect], _ displays: [CGRect]) -> [String: Any] {
        let got = lockedStartDisplay(windows: windows, displays: displays)
        return ["name": name,
                "in": ["fn": "locked_start_display", "windows": windows.map(j), "displays": displays.map(j)],
                "out": F.opt(got.map(j))]
    }

    private static func awakeCase(_ name: String, granted: Bool, _ steps: [String]) -> [String: Any] {
        var events: [[String: Any]] = []
        var holds: UInt32 = 0
        let awake = StayAwake(hold: {
            holds += 1
            let id: UInt32? = granted ? holds : nil
            events.append(["op": "hold", "id": F.opt(id.map { Int($0) })])
            return id
        }, release: { events.append(["op": "release", "id": Int($0)]) })
        for s in steps {
            if s == "begin" { awake.begin() } else { awake.end() }
        }
        return ["name": name, "in": ["fn": "stay_awake", "granted": granted, "steps": steps], "out": ["events": events]]
    }

    func testLock() {
        let main = Self.r(0, 0, 1512, 982)
        let side = Self.r(1512, -200, 2560, 1440)
        let small = Self.r(100, 100, 400, 300)
        let large = Self.r(1700, 0, 1200, 900)
        let cases: [[String: Any]] = [
            // ScreenLockTests
            Self.lockCase("already locked calls nothing", locked: [true], call: nil),
            Self.lockCase("locked once state flips", locked: [false, false, false, true], call: nil),
            Self.lockCase("never locked fails after timeout", locked: [false], call: nil),
            Self.lockCase("missing symbol fails", locked: [false], call: "找不到 SACLockScreenImmediate"),
            Self.lockCase("locks on the last poll", locked: Array(repeating: false, count: 21) + [true], call: nil),
            Self.lockCase("odd timeout truncates in the text", locked: [false], call: nil, timeout: 0.35, step: 0.1),
            Self.lockCase("zero timeout never sleeps", locked: [false], call: nil, timeout: 0, step: 0.1),
            Self.waitCase("returns at once when not locked", locked: [false]),
            Self.waitCase("polls until state flips", locked: [true, true, true, true, true, false]),
            Self.waitCase("gives up after timeout", locked: [true]),
            Self.waitCase("short timeout", locked: [true], timeout: 0.25, step: 0.1),
            Self.displayCase("follows the largest window", [small, large], [main, side]),
            Self.displayCase("follows the largest window, moved",
                             [large.offsetBy(dx: -1600, dy: 0), small.offsetBy(dx: 1600, dy: 0)], [main, side]),
            Self.displayCase("uses the window centre", [Self.r(1300, 100, 800, 600)], [main, side]),
            Self.displayCase("no windows", [], [main, side]),
            Self.displayCase("tiny window ignored", [Self.r(1700, 0, 40, 900)], [main, side]),
            Self.displayCase("window off every display", [Self.r(9000, 9000, 400, 400)], [main, side]),
            Self.displayCase("tiny ignored, the next qualifies",
                             [Self.r(1700, 0, 40, 900), Self.r(1800, 100, 300, 200)], [main, side]),
            Self.displayCase("equal areas: the first wins",
                             [Self.r(100, 100, 300, 200), Self.r(1800, 100, 200, 300)], [main, side]),
            Self.displayCase("exactly 50 x 50 qualifies", [Self.r(1600, 0, 50, 50)], [main, side]),
            Self.displayCase("centre on the shared edge goes right", [Self.r(1412, 100, 200, 200)], [main, side]),
            Self.displayCase("negative size is standardised", [Self.r(2000, 600, -400, -300)], [main, side]),
            Self.displayCase("no displays", [large], []),
            // StayAwakeTests
            Self.awakeCase("begin holds once, end releases that hold", granted: true, ["begin", "begin", "end", "end"]),
            Self.awakeCase("end without begin releases nothing", granted: true, ["end"]),
            Self.awakeCase("refused hold releases nothing", granted: false, ["begin", "end"]),
            Self.awakeCase("a new session holds again", granted: true, ["begin", "end", "begin", "end"]),
            Self.awakeCase("refused then granted", granted: false, ["begin", "end", "begin", "begin", "end"]),
        ]
        F.check("lock.json", F.cases(cases))
    }

    // MARK: - unlock-sequence.json

    private static func unlockCase(_ name: String, _ password: String, locked: Bool = true,
                                   after: (op: String, n: Int)? = nil) -> [String: Any] {
        var events: [[String: Any]] = []
        var isLocked = locked
        var counts: [String: Int] = [:]
        func did(_ op: String) {
            counts[op, default: 0] += 1
            if let a = after, a.op == op, counts[op] == a.n { isLocked = false }
        }
        typeUnlockPassword(password, isLocked: {
            events.append(["op": "is_locked", "v": isLocked])
            return isLocked
        }, wake: {
            events.append(["op": "wake"])
            did("wake")
        }, wait: {
            events.append(["op": "wait", "us": Int($0)])
            did("wait")
        }, typeChunk: {
            events.append(["op": "type", "units": $0.map { Int($0) }])
            did("type")
        }, pressReturn: {
            events.append(["op": "return"])
        })
        var unlockAfter: Any = NSNull()
        if let a = after { unlockAfter = ["op": a.op, "n": a.n] as [String: Any] }
        return ["name": name,
                "in": ["fn": "type_unlock_password", "password": password, "locked": locked, "unlock_after": unlockAfter],
                "out": ["events": events]]
    }

    func testUnlockSequence() {
        // 1024 units: letters, a two-unit emoji every 37 characters, so pairs land near chunk edges.
        var long = ""
        var rng = HostRNG(seed: 1024)
        while long.utf16.count < 1024 {
            if long.utf16.count % 37 == 36, long.utf16.count + 2 <= 1024 {
                long += "🔑"
            } else {
                long += String(Character(UnicodeScalar(UInt8(0x61 + rng.int(0...25)))))
            }
        }
        let cases: [[String: Any]] = [
            // UnlockSequenceTests
            Self.unlockCase("unlocked screen receives no input", "secret", locked: false),
            Self.unlockCase("unlock while waking stops before the password", "secret", after: ("wait", 1)),
            Self.unlockCase("unlock during typing stops the rest and return",
                            String(repeating: "x", count: 50), after: ("type", 1)),
            Self.unlockCase("unicode then return after the delays", "pässword🔑" + String(repeating: "密", count: 30)),
            // The plan's extras
            Self.unlockCase("1024-unit password", long),
            Self.unlockCase("unlocked locally after the 3rd chunk", String(repeating: "y", count: 100), after: ("type", 3)),
            Self.unlockCase("already unlocked at entry", String(repeating: "z", count: 30), locked: false),
            // More boundaries
            Self.unlockCase("surrogate pair at the chunk edge", String(repeating: "a", count: 19) + "🔑" + "bc"),
            Self.unlockCase("unlocked during the return wait", "secret", after: ("wait", 3)),
            Self.unlockCase("unlocked during the last chunk wait", String(repeating: "q", count: 40), after: ("wait", 3)),
            Self.unlockCase("empty password still presses return", ""),
            Self.unlockCase("exactly 20 units", String(repeating: "w", count: 20)),
            Self.unlockCase("unlocked by the wake itself", "secret", after: ("wake", 1)),
        ]
        F.check("unlock-sequence.json", F.cases(cases))
    }
}
