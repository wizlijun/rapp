import CoreGraphics
import Foundation
import RappCore

/// Locks A's screen with the private `SACLockScreenImmediate` (the call behind the menu's Lock Screen).
enum ScreenLocker {
    static func lock() -> LockOutcome {
        lockScreen(
            isLocked: { screenLocked(CGSessionCopyCurrentDictionary() as? [String: Any]) },
            call: {
                guard let handle = dlopen("/System/Library/PrivateFrameworks/login.framework/login", RTLD_NOW) else {
                    return "打不开 login.framework"
                }
                guard let symbol = dlsym(handle, "SACLockScreenImmediate") else {
                    return "找不到 SACLockScreenImmediate"
                }
                _ = unsafeBitCast(symbol, to: (@convention(c) () -> Int32).self)()
                return nil
            },
            sleep: { Thread.sleep(forTimeInterval: $0) })
    }
}
