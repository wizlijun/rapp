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
                              timeout: TimeInterval = 3, step: TimeInterval = 0.1) {
    var waited = 0.0
    while waited < timeout, isLocked() {
        sleep(step)
        waited += step
    }
}
