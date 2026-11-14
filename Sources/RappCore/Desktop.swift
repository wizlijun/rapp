import CoreGraphics
import Foundation

// Desktop sessions (desktop sessions spec §4.1, §4.2): a whole display of A instead of one app.

/// The app-list entry and the main display's session; `desktop:<CGDirectDisplayID>` is any other display.
public let desktopApp = "desktop:"

/// The name the app list gives the desktop entry.
public let desktopAppName = "桌面"

/// Which display a desktop session shows.
public enum DesktopTarget: Equatable {
    case main
    case display(UInt32)
}

/// `desktop:` → the main display, `desktop:<decimal id>` → that display; anything else is not a desktop id.
public func desktopTarget(_ app: String) -> DesktopTarget? {
    guard app.hasPrefix(desktopApp) else { return nil }
    let rest = app.dropFirst(desktopApp.count)
    if rest.isEmpty { return .main }
    guard rest.allSatisfy(\.isASCII), let id = UInt32(rest) else { return nil }
    return .display(id)
}

public func isDesktopApp(_ app: String) -> Bool { desktopTarget(app) != nil }

/// One of A's displays as the app list reports it. `frame` is in global points (top-left origin).
public struct DesktopDisplay: Equatable {
    public var id: UInt32
    public var name: String
    public var main: Bool
    public var frame: CGRect
    public init(id: UInt32, name: String, main: Bool, frame: CGRect) {
        self.id = id
        self.name = name
        self.main = main
        self.frame = frame
    }
    public var width: Int { Int(frame.width.rounded()) }
    public var height: Int { Int(frame.height.rounded()) }
}

/// The main display first, then left to right, then top to bottom; a display's number is its index + 1.
public func orderedDisplays(_ displays: [DesktopDisplay]) -> [DesktopDisplay] {
    displays.sorted { a, b in
        if a.main != b.main { return a.main }
        if a.frame.minX != b.frame.minX { return a.frame.minX < b.frame.minX }
        if a.frame.minY != b.frame.minY { return a.frame.minY < b.frame.minY }
        return a.id < b.id
    }
}

/// The single window's title, e.g. `Mac mini · 屏幕 2`.
public func desktopTitle(computer: String, number: Int) -> String {
    let screen = "屏幕 \(number)"
    let name = computer.trimmingCharacters(in: .whitespacesAndNewlines)
    return name.isEmpty ? screen : "\(name) · \(screen)"
}

/// The fixed window table of a desktop session: one undecorated full-display window that cannot be
/// moved, sized or closed. A's own windows are never tracked (spec DK3).
public func desktopTable(width: Double, height: Double, title: String) -> [WindowInfo] {
    [WindowInfo(id: 1, parent: 0, kind: .normal, resizable: false, focused: true,
                rect: CanvasRect(x: 0, y: 0, w: Float(width), h: Float(height)), titleBar: 0, title: title)]
}

/// The `apps` entry for the desktop, nil when A reports no display.
func desktopEntry(_ displays: [DesktopDisplay]) -> [String: Any]? {
    guard !displays.isEmpty else { return nil }
    return ["app": desktopApp, "name": desktopAppName,
            "displays": orderedDisplays(displays).map {
                ["id": String($0.id), "name": $0.name, "main": $0.main, "width": $0.width, "height": $0.height] as [String: Any]
            }]
}
