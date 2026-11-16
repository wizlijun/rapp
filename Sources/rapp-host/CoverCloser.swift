import ApplicationServices
import CoreGraphics
import Foundation

/// Closes another process's window that covers the session app (protocol v13 `dismissCover`), through
/// the Accessibility API only: no synthetic click or key goes to A. The caller has already checked that
/// the owner may be closed (`coverDismissable`): this never looks at who the owner is.
enum CoverCloser {
    /// Words of an Accessibility action that closes what it is on (a notification banner's 「关闭」).
    private static let closeWords = ["close", "dismiss", "关闭"]

    /// Closes the window of `pid` at `point` (global points, top-left origin): a close or cancel action
    /// on the element there or one of its parents, else the window's close or cancel button. Returns what
    /// was done, or nil when nothing could be.
    static func close(pid: pid_t, at point: CGPoint) -> String? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &hit) == .success,
              var element = hit else { return nil }
        for _ in 0..<16 {
            if let action = closeAction(element), AXUIElementPerformAction(element, action as CFString) == .success {
                return "action \(action)"
            }
            if attribute(element, kAXRoleAttribute) as? String == kAXWindowRole {
                for name in [kAXCloseButtonAttribute, kAXCancelButtonAttribute] {
                    if let button = attribute(element, name), CFGetTypeID(button) == AXUIElementGetTypeID(),
                       AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString) == .success {
                        return "pressed \(name)"
                    }
                }
                return nil
            }
            guard let parent = attribute(element, kAXParentAttribute), CFGetTypeID(parent) == AXUIElementGetTypeID()
            else { return nil }
            element = parent as! AXUIElement
        }
        return nil
    }

    /// AXCancel, or a custom action ("Name:关闭\nTarget:…") that closes.
    private static func closeAction(_ element: AXUIElement) -> String? {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success,
              let actions = names as? [String] else { return nil }
        if actions.contains(kAXCancelAction) { return kAXCancelAction }
        return actions.first { action in
            let name = action.hasPrefix("Name:") ? String(action.dropFirst(5).prefix { $0 != "\n" }) : action
            return closeWords.contains { name.lowercased().contains($0) }
        }
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
}
