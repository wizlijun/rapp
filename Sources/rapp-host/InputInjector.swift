import AppKit
import CoreGraphics
import RappCore

/// Turns input messages into system-wide events. These are the same events a
/// real mouse and keyboard produce, so the target app needs no cooperation;
/// the price is that the Mac's real pointer and focus are used.
final class InputInjector {
    private let app: NSRunningApplication
    /// The one window input is for; input naming another window is dropped.
    private let windowID: UInt32
    /// The whole window (to find it through Accessibility) and its content
    /// area below the title row (what the client's point coordinates start from).
    private let frameProvider: () -> (window: CGRect, content: CGRect)?
    private let source = CGEventSource(stateID: .hidSystemState)

    init(app: NSRunningApplication, windowID: UInt32,
         frameProvider: @escaping () -> (window: CGRect, content: CGRect)?) {
        self.app = app
        self.windowID = windowID
        self.frameProvider = frameProvider
    }

    /// Handles text, key, mouse and scroll messages; ignores everything else.
    func handle(_ message: Message) {
        switch message {
        case .text, .key: break
        case let .mouse(kind, _, window, _, _, _):
            // Hover is not injected by the single-window host.
            guard window == windowID, kind != .move else { return }
        case let .scroll(window, _, _, _, _):
            guard window == windowID else { return }
        default: return
        }
        // Without the window there is nowhere to send input.
        guard let frames = frameProvider() else { return }
        let frame = frames.content
        if !app.isActive {
            app.activate()
            WindowResizer.bringToFront(pid: app.processIdentifier, currentFrame: frames.window)
            usleep(50_000)
        }

        switch message {
        case let .mouse(kind, button, _, x, y, clickCount):
            let point = globalPoint(points: x, y, content: frame)
            let type: CGEventType
            switch (kind, button) {
            case (.down, .left): type = .leftMouseDown
            case (.up, .left): type = .leftMouseUp
            case (.drag, .left): type = .leftMouseDragged
            case (.down, .right): type = .rightMouseDown
            case (.up, .right): type = .rightMouseUp
            case (.drag, .right): type = .rightMouseDragged
            case (.move, _): return
            }
            let cgButton: CGMouseButton = button == .left ? .left : .right
            if kind == .down {
                // Put the pointer there first so hover-dependent controls are ready.
                CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point,
                        mouseButton: cgButton)?.post(tap: .cghidEventTap)
            }
            guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point,
                                      mouseButton: cgButton) else { return }
            event.setIntegerValueField(.mouseEventClickState, value: Int64(max(1, clickCount)))
            event.post(tap: .cghidEventTap)

        case let .scroll(_, x, y, dx, dy):
            let point = globalPoint(points: x, y, content: frame)
            CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point,
                    mouseButton: .left)?.post(tap: .cghidEventTap)
            let clamp: (Float) -> Int32 = { Int32(max(-10_000, min(10_000, $0.rounded()))) }
            CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                    wheel1: clamp(dy), wheel2: clamp(dx), wheel3: 0)?.post(tap: .cghidEventTap)

        case let .text(text):
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
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: down) else { return }
            event.flags = CGEventFlags(rawValue: modifiers)
            event.post(tap: .cghidEventTap)

        default:
            break
        }
    }
}

/// A point given in A points from the content's top-left, as a global point
/// kept inside the content.
private func globalPoint(points x: Float, _ y: Float, content: CGRect) -> CGPoint {
    guard content.width > 0, content.height > 0 else { return content.origin }
    return globalPoint(x: x / Float(content.width), y: y / Float(content.height), windowFrame: content)
}
