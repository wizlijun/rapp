import AppKit
import CoreGraphics
import RappCore

/// Turns input messages into system-wide events. These are the same events a
/// real mouse and keyboard produce, so the target app needs no cooperation;
/// the price is that the Mac's real pointer and focus are used.
final class InputInjector {
    private let app: NSRunningApplication
    /// The canvas display in global points.
    private let display: CGRect
    private let log: (String) -> Void
    private let source = CGEventSource(stateID: .hidSystemState)
    /// Buttons whose down was dropped by the top-window check: their drags and
    /// up are dropped too, so the app never sees half a click.
    private var droppedButtons = Set<MouseButton>()

    init(app: NSRunningApplication, display: CGRect, log: @escaping (String) -> Void) {
        self.app = app
        self.display = display
        self.log = log
    }

    /// Handles text, key, mouse and scroll messages against the window table
    /// last sent (spec §3.4); ignores everything else. Input naming a window
    /// that is not in the table is dropped.
    func handle(_ message: Message, table: [WindowInfo]) {
        switch message {
        case let .mouse(kind, button, window, x, y, clickCount):
            guard let target = table.first(where: { $0.id == window }) else { return }
            let point = globalPoint(target, x, y)
            mouse(kind: kind, button: button, at: point, window: target, table: table, clickCount: clickCount)

        case let .scroll(window, x, y, dx, dy):
            guard let target = table.first(where: { $0.id == window }) else { return }
            let point = globalPoint(target, x, y)
            post(.mouseMoved, at: point, button: .left)
            let clamp: (Float) -> Int32 = { Int32(max(-10_000, min(10_000, $0.rounded()))) }
            CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                    wheel1: clamp(dy), wheel2: clamp(dx), wheel3: 0)?.post(tap: .cghidEventTap)

        case let .text(text):
            activateIfNeeded()
            for chunk in chunkUTF16(text) {
                for keyDown in [true, false] {
                    guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: keyDown) else { continue }
                    event.flags = []
                    chunk.withUnsafeBufferPointer {
                        event.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress)
                    }
                    event.post(tap: .cghidEventTap)
                }
                usleep(5_000)
            }

        case let .key(keyCode, modifiers, down):
            activateIfNeeded()
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: down) else { return }
            event.flags = CGEventFlags(rawValue: modifiers)
            event.post(tap: .cghidEventTap)

        default:
            break
        }
    }

    private func mouse(kind: MouseKind, button: MouseButton, at point: CGPoint, window: WindowInfo,
                       table: [WindowInfo], clickCount: UInt8) {
        let cgButton: CGMouseButton = button == .left ? .left : .right
        let type: CGEventType
        switch (kind, button) {
        case (.move, _):
            post(.mouseMoved, at: point, button: cgButton)
            return
        case (.down, .left): type = .leftMouseDown
        case (.up, .left): type = .leftMouseUp
        case (.drag, .left): type = .leftMouseDragged
        case (.down, .right): type = .rightMouseDown
        case (.up, .right): type = .rightMouseUp
        case (.drag, .right): type = .rightMouseDragged
        }
        switch kind {
        case .down:
            guard clearToClick(at: point, window: window, table: table) else {
                droppedButtons.insert(button)
                return
            }
            droppedButtons.remove(button)
            // Put the pointer there first so hover-dependent controls are ready.
            post(.mouseMoved, at: point, button: cgButton)
        case .up:
            if droppedButtons.remove(button) != nil { return }
        default:
            if droppedButtons.contains(button) { return }
        }
        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point,
                                  mouseButton: cgButton) else { return }
        event.setIntegerValueField(.mouseEventClickState, value: Int64(max(1, clickCount)))
        event.post(tap: .cghidEventTap)
    }

    /// The top-window check before a press (spec §3.4): the window on top at
    /// `point` must be the app's. If not, brings the app and the window to
    /// the front, waits 50 ms and looks again; still covered drops the press.
    private func clearToClick(at point: CGPoint, window: WindowInfo, table: [WindowInfo]) -> Bool {
        if topOwner(at: point).pid == app.processIdentifier { return true }
        // Only decorated windows are raised (a popup has no AX window).
        WindowResizer.bringToFront(pid: app.processIdentifier,
                                   frame: window.kind.isDecorated ? window.globalFrame(display: display) : nil)
        usleep(50_000)
        let top = topOwner(at: point)
        if top.pid == app.processIdentifier { return true }
        log("click dropped: covered by \(top.name)")
        return false
    }

    /// The owner of the frontmost on-screen window containing `point` (global
    /// points), skipping invisible ones and the screen-saver/cursor levels.
    private func topOwner(at point: CGPoint) -> (pid: pid_t, name: String) {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        for entry in list {
            guard (entry[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  (entry[kCGWindowLayer as String] as? Int ?? 0) < 1000,
                  let bounds = entry[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  frame.contains(point) else { continue }
            let pid = (entry[kCGWindowOwnerPID as String] as? Int).map(pid_t.init) ?? 0
            return (pid, entry[kCGWindowOwnerName as String] as? String ?? "pid \(pid)")
        }
        return (0, "nothing")
    }

    private func activateIfNeeded() {
        guard !app.isActive else { return }
        app.activate()
        usleep(50_000)
    }

    private func post(_ type: CGEventType, at point: CGPoint, button: CGMouseButton) {
        CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: button)?
            .post(tap: .cghidEventTap)
    }

    /// Display origin + window top-left + (x, y), kept on the display (spec §3.4).
    private func globalPoint(_ window: WindowInfo, _ x: Float, _ y: Float) -> CGPoint {
        let px = display.minX + CGFloat(window.rect.x) + CGFloat(x)
        let py = display.minY + CGFloat(window.rect.y) + CGFloat(y)
        return CGPoint(x: min(max(px, display.minX), display.maxX - 1), y: min(max(py, display.minY), display.maxY - 1))
    }
}
