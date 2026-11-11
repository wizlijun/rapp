import ApplicationServices
import RappCore

/// The app's menu bar through the Accessibility API (spec §3.5): read as a
/// `MenuItem` tree, and items pressed by path. Both skip the Apple menu, so
/// index 0 at the top is the app menu.
enum MenuBarReader {
    /// Read per item in one call.
    private static let names = [kAXTitleAttribute, kAXEnabledAttribute, "AXMenuItemMarkChar", "AXMenuItemCmdChar",
                                "AXMenuItemCmdModifiers", kAXChildrenAttribute] as CFArray

    /// The menu tree, cut to what the protocol carries. Empty when the app has no menu bar.
    static func read(pid: pid_t) -> [MenuItem] {
        var budget = maxMenuItems
        return limitMenu(items(topLevel(pid: pid), depth: 1, budget: &budget))
    }

    /// Presses the item at `path` if the live titles along it are `titles`;
    /// false when the path leads nowhere, an item moved, or the press fails.
    static func press(pid: pid_t, path: [UInt16], titles: [String]) -> Bool {
        guard titles.count == path.count else { return false }
        var level = topLevel(pid: pid)
        for (step, index) in path.enumerated() {
            guard Int(index) < level.count else { return false }
            let element = level[Int(index)]
            var title: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &title)
            guard (title as? String ?? "") == titles[step] else { return false }
            if step == path.count - 1 {
                return AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
            }
            level = submenuItems(of: element)
        }
        return false
    }

    private static func topLevel(pid: pid_t) -> [AXUIElement] {
        var bar: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXMenuBarAttribute as CFString, &bar)
                == .success, let bar, CFGetTypeID(bar) == AXUIElementGetTypeID() else { return [] }
        return Array(children(of: bar as! AXUIElement).dropFirst())
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }

    /// A menu item's (or menu-bar item's) submenu items: the children of its one AXMenu child.
    private static func submenuItems(of element: AXUIElement) -> [AXUIElement] {
        children(of: element).first.map(children(of:)) ?? []
    }

    /// Reads `elements` and, depth and budget allowing, their submenus. Stops
    /// early the way `limitMenu` cuts, so huge menus are not read in full.
    private static func items(_ elements: [AXUIElement], depth: Int, budget: inout Int) -> [MenuItem] {
        guard depth <= maxMenuDepth, budget > 0 else { return [] }
        let kept = elements.prefix(budget)
        budget -= kept.count
        return kept.map { element in
            var values: CFArray?
            AXUIElementCopyMultipleAttributeValues(element, names, AXCopyMultipleAttributeOptions(rawValue: 0), &values)
            // Missing attributes come back as AXValue errors; the casts below turn them into defaults.
            let list = values as? [Any] ?? []
            func value(_ i: Int) -> Any? { i < list.count ? list[i] : nil }
            let title = value(0) as? String ?? ""
            let mark = value(2) as? String ?? ""
            let key = value(3) as? String ?? ""
            let submenu = (value(5) as? [AXUIElement])?.first.map(children(of:)) ?? []
            var item = MenuItem(title: title, enabled: value(1) as? Bool ?? false, checked: !mark.isEmpty,
                                separator: title.isEmpty && key.isEmpty && submenu.isEmpty,
                                key: key, modifiers: key.isEmpty ? 0 : menuModifiers(fromAX: value(4) as? Int ?? 0))
            item.children = items(submenu, depth: depth + 1, budget: &budget)
            return item
        }
    }
}
