import ApplicationServices
import Foundation
import RappCore

/// Tells whether A's keyboard focus is in a password field (protocol v13 `secureFocus`), so B keeps the
/// writing panel out of it: keys go straight through and nothing is recorded.
///
/// Privacy (as FocusReader): only the focused element's role and subrole are read. Never its value,
/// title, description or any text attribute.
///
/// An app session watches its app's focus changes (AXObserver on the main run loop) and is also checked
/// by `check()` on the session's 1 s tick, in case a change was missed; a desktop session (`pid` nil) has
/// only the tick, against the system-wide focus. `onChange` runs on the watcher's own queue, only when
/// the answer changes (it starts at false, as B assumes).
final class SecureFocusWatcher {
    private let pid: pid_t?
    private let onChange: (Bool) -> Void
    private let queue = DispatchQueue(label: "rapp.secure-focus")
    private let lock = NSLock()
    private var stopped = false
    private var last = false
    private var observer: AXObserver?
    private var observerBox: Unmanaged<Box>?
    private let trusted = AXIsProcessTrusted()

    private final class Box { let fire: () -> Void; init(_ f: @escaping () -> Void) { fire = f } }

    init(pid: pid_t?, onChange: @escaping (Bool) -> Void) {
        self.pid = pid
        self.onChange = onChange
        guard trusted, let pid else { return }
        // AXObserver callouts need a run loop: the main one runs (application.run()).
        DispatchQueue.main.async { [self] in installObserver(pid) }
        check()
    }

    /// Reads the focus again and reports a change.
    func check() {
        guard trusted else { return }
        queue.async { [self] in
            guard !isStopped else { return }
            let secure = readSecure()
            guard secure != last, !isStopped else { return }
            last = secure
            onChange(secure)
        }
    }

    func stop() {
        lock.lock()
        stopped = true
        let observer = self.observer, box = observerBox
        self.observer = nil
        observerBox = nil
        lock.unlock()
        DispatchQueue.main.async {
            if let observer {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
            }
            box?.release()
        }
    }

    private var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }

    private func readSecure() -> Bool {
        let root = pid.map(AXUIElementCreateApplication) ?? AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(root, 1)
        guard let focused = attribute(root, kAXFocusedUIElementAttribute),
              CFGetTypeID(focused) == AXUIElementGetTypeID() else { return false }
        let element = focused as! AXUIElement
        return isSecureField(role: attribute(element, kAXRoleAttribute) as? String,
                             subrole: attribute(element, kAXSubroleAttribute) as? String)
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    /// On the main thread.
    private func installObserver(_ pid: pid_t) {
        guard !isStopped else { return }
        var obs: AXObserver?
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            Unmanaged<Box>.fromOpaque(refcon).takeUnretainedValue().fire()
        }
        guard AXObserverCreate(pid, callback, &obs) == .success, let obs else { return }
        let box = Unmanaged.passRetained(Box { [weak self] in self?.check() })
        guard AXObserverAddNotification(obs, AXUIElementCreateApplication(pid),
                                        kAXFocusedUIElementChangedNotification as CFString, box.toOpaque()) == .success
        else {
            box.release()
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        lock.lock()
        if stopped {
            lock.unlock()
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
            box.release()
            return
        }
        observer = obs
        observerBox = box
        lock.unlock()
    }
}
