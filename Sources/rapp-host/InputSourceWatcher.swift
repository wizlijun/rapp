import Carbon
import Foundation
import RappCore

/// A's selected keyboard input source, as sent to B.
struct InputSourceState: Equatable {
    var id: String
    var name: String
    /// A plain keyboard layout (ABC, US), not an input method such as Pinyin.
    var ascii: Bool

    var message: Message { .inputSource(id: id, name: name, ascii: ascii) }
}

/// Carbon TIS. TIS asserts that it runs on the main queue, so every call goes through
/// `onMain`. The session queue may wait on main: main never waits on the session queue.
enum InputSources {
    static func onMain<T>(_ body: () -> T) -> T {
        Thread.isMainThread ? body() : DispatchQueue.main.sync(execute: body)
    }

    /// The selected keyboard input source. Any queue.
    static func current() -> InputSourceState? {
        onMain {
            guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
                  let id = string(source, kTISPropertyInputSourceID) else { return nil }
            let name = string(source, kTISPropertyLocalizedName) ?? id
            let type = string(source, kTISPropertyInputSourceType)
            return InputSourceState(id: fitted(id), name: fitted(name), ascii: type == (kTISTypeKeyboardLayout as String))
        }
    }

    /// Selects `id` ("" = the current ASCII-capable layout). Returns the id A should now report
    /// and whether it had to switch; nil if `id` names no enabled, selectable keyboard source
    /// or TIS refused. Any queue.
    static func select(_ id: String) -> (id: String, switched: Bool)? {
        onMain {
            guard let source = id.isEmpty ? TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue()
                                          : enabled(id),
                  let target = string(source, kTISPropertyInputSourceID) else { return nil }
            let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
            if let current, string(current, kTISPropertyInputSourceID) == target { return (fitted(target), false) }
            guard TISSelectInputSource(source) == noErr else { return nil }
            return (fitted(target), true)
        }
    }

    /// Main queue.
    private static func enabled(_ id: String) -> TISInputSource? {
        let filter = [kTISPropertyInputSourceID as String: id,
                      kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource] else { return nil }
        return list.first { flag($0, kTISPropertyInputSourceIsSelectCapable) }
    }

    private static func string(_ source: TISInputSource, _ key: CFString) -> String? {
        guard let raw = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
    }

    private static func flag(_ source: TISInputSource, _ key: CFString) -> Bool {
        guard let raw = TISGetInputSourceProperty(source, key) else { return false }
        return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(raw).takeUnretainedValue())
    }
}

/// Calls `onChange` on the session queue whenever A's selected input source may have changed.
/// The session reads the source itself, in order with its own selects.
final class InputSourceWatcher: NSObject {
    private let queue: DispatchQueue
    private let onChange: () -> Void
    /// Session queue only.
    private var stopped = false

    init(queue: DispatchQueue, onChange: @escaping () -> Void) {
        self.queue = queue
        self.onChange = onChange
    }

    /// Registers on main, whose run loop delivers the notification.
    func start() {
        InputSources.onMain {
            // The host app is never active: without .deliverImmediately the notification could wait.
            DistributedNotificationCenter.default().addObserver(
                self, selector: #selector(changed),
                name: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
                object: nil, suspensionBehavior: .deliverImmediately)
        }
    }

    /// Session queue.
    func stop() {
        stopped = true
        InputSources.onMain { DistributedNotificationCenter.default().removeObserver(self) }
    }

    @objc private func changed() {
        queue.async { [self] in
            guard !stopped else { return }
            onChange()
        }
    }
}
