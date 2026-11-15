import CoreGraphics
import Foundation

public enum LockOutcome: Equatable {
    case locked, already, failed(String)
}

/// Locks the screen through `call` and waits for `isLocked` to turn true.
/// `call` returns nil on success, or the reason it could not call.
public func lockScreen(isLocked: () -> Bool, call: () -> String?, sleep: (TimeInterval) -> Void,
                       timeout: TimeInterval = 2, step: TimeInterval = 0.1) -> LockOutcome {
    if isLocked() { return .already }
    if let reason = call() { return .failed(reason) }
    var waited = 0.0
    while waited < timeout {
        sleep(step)
        waited += step
        if isLocked() { return .locked }
    }
    return .failed("调用后 \(Int(timeout)) 秒内没有锁上")
}

/// After typing the unlock password: waits until `isLocked` turns false (at most `timeout`), so the next
/// typist starts only once the result is settled. Returns at once when A is not locked.
public func waitUntilUnlocked(isLocked: () -> Bool, sleep: (TimeInterval) -> Void,
                              timeout: TimeInterval = 8, step: TimeInterval = 0.1) {
    var waited = 0.0
    while waited < timeout, isLocked() {
        sleep(step)
        waited += step
    }
}

/// The display an app session opened on a locked A announces before the app can be captured (spec §6.4):
/// the one holding the centre of the app's largest window (at least 50 x 50, as the capture's own lookup
/// picks it). `windows` and `displays` are in global display coordinates. nil when no window qualifies or
/// none of the displays holds it: the caller falls back to the main display.
public func lockedStartDisplay(windows: [CGRect], displays: [CGRect]) -> CGRect? {
    let usable = windows.filter { $0.width >= 50 && $0.height >= 50 }
    guard let best = usable.max(by: { $0.width * $0.height < $1.width * $1.height }) else { return nil }
    let centre = CGPoint(x: best.midX, y: best.midY)
    return displays.first { $0.contains(centre) }
}
