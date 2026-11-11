import ApplicationServices
import CoreGraphics
import RappCore

/// Window operations done through the Accessibility API. They work on any
/// app's standard windows, whatever the app is built with. A window is found
/// by its frame (global points, top-left origin), as CGWindowList reports it.
enum WindowResizer {
    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        guard let positionValue = attribute(element, kAXPositionAttribute),
              let sizeValue = attribute(element, kAXSizeAttribute),
              CFGetTypeID(positionValue) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: position, size: size)
    }

    private static func matches(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= 2 && abs(a.minY - b.minY) <= 2 && abs(a.width - b.width) <= 2 && abs(a.height - b.height) <= 2
    }

    /// The app's accessibility window, or sheet (a child of a window, spec
    /// §3.3), whose position and size are within 2 points of `frame`.
    private static func element(pid: pid_t, frame target: CGRect) -> AXUIElement? {
        guard let windows = attribute(AXUIElementCreateApplication(pid), kAXWindowsAttribute) as? [AXUIElement] else { return nil }
        for window in windows {
            if let f = frame(of: window), matches(f, target) { return window }
        }
        for window in windows {
            for child in attribute(window, kAXChildrenAttribute) as? [AXUIElement] ?? []
            where attribute(child, kAXRoleAttribute) as? String == kAXSheetRole {
                if let f = frame(of: child), matches(f, target) { return child }
            }
        }
        return nil
    }

    /// Role, subrole and whether the size can be set; nil if Accessibility has no such window.
    static func describe(pid: pid_t, frame: CGRect) -> (role: String?, subrole: String?, resizable: Bool)? {
        guard let target = element(pid: pid, frame: frame) else { return nil }
        var settable: DarwinBoolean = false
        _ = AXUIElementIsAttributeSettable(target, kAXSizeAttribute as CFString, &settable)
        return (attribute(target, kAXRoleAttribute) as? String, attribute(target, kAXSubroleAttribute) as? String,
                settable.boolValue)
    }

    /// The frame of the app's focused window, or nil.
    static func focusedWindowFrame(pid: pid_t) -> CGRect? {
        guard let value = attribute(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return frame(of: value as! AXUIElement)
    }

    /// Changes only the window's size; its top-left corner stays where it is.
    static func resize(pid: pid_t, frame: CGRect, to size: CGSize) -> Bool {
        guard let target = element(pid: pid, frame: frame) else { return false }
        var newSize = size
        guard let value = AXValueCreate(.cgSize, &newSize) else { return false }
        return AXUIElementSetAttributeValue(target, kAXSizeAttribute as CFString, value) == .success
    }

    /// Moves the window's top-left corner to `origin` (global points).
    static func move(pid: pid_t, frame: CGRect, to origin: CGPoint) -> Bool {
        guard let target = element(pid: pid, frame: frame) else { return false }
        var point = origin
        guard let value = AXValueCreate(.cgPoint, &point) else { return false }
        return AXUIElementSetAttributeValue(target, kAXPositionAttribute as CFString, value) == .success
    }

    /// Presses the window's close button; false if it has none.
    static func close(pid: pid_t, frame: CGRect) -> Bool {
        guard let target = element(pid: pid, frame: frame),
              let button = attribute(target, kAXCloseButtonAttribute),
              CFGetTypeID(button) == AXUIElementGetTypeID() else { return false }
        return AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString) == .success
    }

    /// Height of the system title bar to crop, in points: 0 in full screen, when it cannot be
    /// measured, or when the window draws its own title area. See `systemTitleRowHeight`.
    static func titleRowHeight(pid: pid_t, frame windowFrame: CGRect) -> CGFloat {
        guard let target = element(pid: pid, frame: windowFrame) else { return 0 }
        if let isFull = attribute(target, "AXFullScreen") as? Bool, isFull { return 0 }
        guard let button = attribute(target, kAXCloseButtonAttribute),
              CFGetTypeID(button) == AXUIElementGetTypeID() else { return 0 }
        let children = (attribute(target, kAXChildrenAttribute) as? [AXUIElement] ?? []).compactMap { child in
            frame(of: child).map { TitleRowChild(role: attribute(child, kAXRoleAttribute) as? String ?? "",
                                                 subrole: attribute(child, kAXSubroleAttribute) as? String, frame: $0) }
        }
        return systemTitleRowHeight(closeButtonFrame: frame(of: button as! AXUIElement), windowFrame: windowFrame,
                                    children: children)
    }

    /// The window's title as the app reports it, or nil.
    static func title(pid: pid_t, frame: CGRect) -> String? {
        guard let target = element(pid: pid, frame: frame) else { return nil }
        return attribute(target, kAXTitleAttribute) as? String
    }

    /// Makes the app frontmost and, if `frame` is given, raises that window
    /// above the app's others and makes it the main window.
    static func bringToFront(pid: pid_t, frame: CGRect?) {
        let app = AXUIElementCreateApplication(pid)
        _ = AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        guard let frame, let target = element(pid: pid, frame: frame) else { return }
        _ = AXUIElementPerformAction(target, kAXRaiseAction as CFString)
        _ = AXUIElementSetAttributeValue(target, kAXMainAttribute as CFString, kCFBooleanTrue)
    }
}
