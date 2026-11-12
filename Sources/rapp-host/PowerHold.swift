import Foundation
import IOKit.pwr_mgt
import RappCore

/// While a session is open, A must not idle into display sleep, the screen saver or the lock
/// screen: once locked, the login window covers the app and B's input can't reach it.
/// The display assertion stops display sleep; declaring user activity every 30 s resets the
/// idle timer that starts the screen saver (and with it the lock).
enum PowerHold {
    private static let reason = "rapp: a remote session is open" as CFString

    static func stayAwake(log: @escaping (String) -> Void) -> StayAwake {
        let queue = DispatchQueue(label: "rapp.power")
        var timer: DispatchSourceTimer?
        var activity: IOPMAssertionID = 0
        return StayAwake(hold: {
            var id: IOPMAssertionID = 0
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn), reason, &id)
            guard result == kIOReturnSuccess else {
                log("could not keep A awake (IOKit \(result))")
                return nil
            }
            queue.sync {
                let tick = DispatchSource.makeTimerSource(queue: queue)
                tick.schedule(deadline: .now(), repeating: 30)
                tick.setEventHandler { _ = IOPMAssertionDeclareUserActivity(reason, kIOPMUserActiveLocal, &activity) }
                tick.resume()
                timer = tick
            }
            log("keeping A awake while the session is open")
            return id
        }, release: { id in
            queue.sync {
                timer?.cancel()
                timer = nil
                if activity != 0 { IOPMAssertionRelease(activity) }
                activity = 0
            }
            IOPMAssertionRelease(id)
            log("A may idle again")
        })
    }
}
