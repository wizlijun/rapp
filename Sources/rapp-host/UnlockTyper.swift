import CoreGraphics
import Foundation
import RappCore

/// Types a password into macOS's lock screen, as RustDesk does: a click on the display's
/// centre wakes the password field, then the text goes as unicode key events and Return.
/// The password is never logged or kept.
enum UnlockTyper {
    /// Blocking (about 1.2 s): call it off the session queue.
    static func type(_ password: String, display: CGRect) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let centre = CGPoint(x: display.midX, y: display.midY)
        func mouse(_ type: CGEventType) {
            guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: centre,
                                      mouseButton: .left) else { return }
            event.flags = []
            event.post(tap: .cghidEventTap)
        }
        mouse(.mouseMoved)
        mouse(.leftMouseDown)
        mouse(.leftMouseUp)
        // The lock screen fades the password field in after the click.
        usleep(1_000_000)
        for chunk in chunkUTF16(password) {
            for down in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { continue }
                event.flags = []
                chunk.withUnsafeBufferPointer {
                    event.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress)
                }
                event.post(tap: .cghidEventTap)
            }
            usleep(5_000)
        }
        usleep(50_000)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: down) else { continue }
            event.flags = []
            event.post(tap: .cghidEventTap)
        }
    }
}
