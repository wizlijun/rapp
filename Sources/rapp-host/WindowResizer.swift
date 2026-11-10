import ApplicationServices
import CoreGraphics
import RappCore

/// Window operations done through the Accessibility API. They work on any
/// app's standard windows, whatever the app is built with.
enum WindowResizer {
    private static func frame(of window: AXUIElement) -> CGRect? {
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let positionValue = positionRef, let sizeValue = sizeRef,
              CFGetTypeID(positionValue) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: position, size: size)
    }

    /// The app's accessibility window whose position and size are within 2
    /// points of `currentFrame`; the app's first window if none matches.
    private static func window(pid: pid_t, currentFrame: CGRect) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement], !windows.isEmpty else { return nil }
        for candidate in windows {
            guard let f = frame(of: candidate) else { continue }
            if abs(f.minX - currentFrame.minX) <= 2, abs(f.minY - currentFrame.minY) <= 2,
               abs(f.width - currentFrame.width) <= 2, abs(f.height - currentFrame.height) <= 2 {
                return candidate
            }
        }
        return windows.first
    }

    /// Changes only the window's size; its top-left corner stays where it is.
    static func resize(pid: pid_t, currentFrame: CGRect, to size: CGSize) -> Bool {
        guard let target = window(pid: pid, currentFrame: currentFrame) else { return false }
        var newSize = size
        guard let value = AXValueCreate(.cgSize, &newSize) else { return false }
        return AXUIElementSetAttributeValue(target, kAXSizeAttribute as CFString, value) == .success
    }

    /// Height of the window's title row in points (0 in full screen, or when
    /// it cannot be measured). See `titleRowHeight(closeButtonFrame:windowFrame:)`.
    static func titleRowHeight(pid: pid_t, currentFrame: CGRect) -> CGFloat {
        guard let target = window(pid: pid, currentFrame: currentFrame) else { return 0 }
        var full: CFTypeRef?
        if AXUIElementCopyAttributeValue(target, "AXFullScreen" as CFString, &full) == .success,
           let isFull = full as? Bool, isFull { return 0 }
        var button: CFTypeRef?
        guard AXUIElementCopyAttributeValue(target, kAXCloseButtonAttribute as CFString, &button) == .success,
              let buttonRef = button, CFGetTypeID(buttonRef) == AXUIElementGetTypeID() else { return 0 }
        let buttonFrame = frame(of: buttonRef as! AXUIElement)
        return RappCore.titleRowHeight(closeButtonFrame: buttonFrame, windowFrame: currentFrame)
    }

    /// The window's title as the app reports it, or nil.
    static func title(pid: pid_t, currentFrame: CGRect) -> String? {
        guard let target = window(pid: pid, currentFrame: currentFrame) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(target, kAXTitleAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    /// Makes the app frontmost and raises the window above the app's other windows.
    static func bringToFront(pid: pid_t, currentFrame: CGRect) {
        let app = AXUIElementCreateApplication(pid)
        _ = AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        if let target = window(pid: pid, currentFrame: currentFrame) {
            _ = AXUIElementPerformAction(target, kAXRaiseAction as CFString)
        }
    }
}
