import AppKit
import CoreGraphics
import RappCore

/// Lists the target app's windows on the canvas display as a window table
/// (spec §3.2). Not thread-safe: call `poll()` from one queue only. It makes
/// Accessibility calls, which can be slow, so not on the session queue.
final class WindowTracker {
    private struct Known {
        var kind: WindowKind
        var resizable: Bool
        var title = ""
        var titleBar: Float = 0
        var size = CGSize.zero
        /// Classifications made so far; it is classified again while not final.
        var attempts = 1
        var final = true
    }

    private let pid: pid_t
    private let appName: String?
    /// The canvas display in global points; canvas = global - display origin.
    let display: CGRect
    private var known: [UInt32: Known] = [:]
    private var polls = 0

    init(pid: pid_t, appName: String?, display: CGRect) {
        self.pid = pid
        self.appName = appName
        self.display = display
    }

    /// The current table, front to back. A new window is classified once
    /// (level + Accessibility role) and the result kept; titles and title rows
    /// are read again once a second, or when the window's size changes.
    func poll() -> [WindowInfo] {
        defer { polls += 1 }
        let refresh = polls % 10 == 0
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        let menuBarLevels: Set<Int> = [Int(CGWindowLevelForKey(.mainMenuWindow)), Int(CGWindowLevelForKey(.statusWindow))]
        let popUpLevel = Int(CGWindowLevelForKey(.popUpMenuWindow))
        let focused = WindowResizer.focusedWindowFrame(pid: pid)

        var table: [WindowInfo] = []
        var seen = Set<UInt32>()
        for entry in list {
            guard (entry[kCGWindowOwnerPID as String] as? Int).map(pid_t.init) == pid,
                  let number = entry[kCGWindowNumber as String] as? Int, number > 0,
                  let level = entry[kCGWindowLayer as String] as? Int, !menuBarLevels.contains(level),
                  (entry[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let bounds = entry[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  frame.width >= 4, frame.height >= 4, frame.intersects(display) else { continue }
            let id = UInt32(number)
            seen.insert(id)

            var info: Known
            if let cached = known[id], cached.final {
                info = cached
            } else {
                // Menus and tooltips have no Accessibility window (Task 1 probe). A new
                // window's may not exist yet: until it does, the level decides, for a few polls.
                let ax = level < popUpLevel ? WindowResizer.describe(pid: pid, frame: frame) : nil
                let attempts = (known[id]?.attempts ?? 0) + 1
                info = known[id] ?? Known(kind: .normal, resizable: false)
                info.kind = classifyWindow(level: level, role: ax?.role, subrole: ax?.subrole)
                info.resizable = ax?.resizable ?? false
                info.attempts = attempts
                info.final = classificationIsFinal(foundAccessibility: ax != nil, belowPopUp: level < popUpLevel,
                                                   attempts: attempts)
            }
            if info.kind.isDecorated, refresh || known[id] == nil || info.size != frame.size {
                info.title = windowTitle(WindowResizer.title(pid: pid, frame: frame), appName: appName)
                // Always below the window's height (spec §2.2).
                let row = Float(WindowResizer.titleRowHeight(pid: pid, frame: frame))
                info.titleBar = min(max(row, 0), Float(frame.height) - 1)
            }
            info.size = frame.size
            known[id] = info

            let isFocused = info.kind.isDecorated && focused.map {
                abs($0.minX - frame.minX) <= 2 && abs($0.minY - frame.minY) <= 2
                    && abs($0.width - frame.width) <= 2 && abs($0.height - frame.height) <= 2
            } == true
            table.append(WindowInfo(
                id: id, parent: 0, kind: info.kind, resizable: info.resizable && info.kind.isDecorated,
                focused: isFocused,
                rect: CanvasRect(x: Float(frame.minX - display.minX), y: Float(frame.minY - display.minY),
                                 w: Float(frame.width), h: Float(frame.height)),
                titleBar: info.kind.isDecorated ? info.titleBar : 0, title: info.title))
        }
        known = known.filter { seen.contains($0.key) }
        return Array(assignParents(dropTitleBarAccessories(table)).prefix(maxWindows))
    }
}

extension WindowInfo {
    /// The window's frame in global points, given the canvas display's global frame.
    func globalFrame(display: CGRect) -> CGRect {
        CGRect(x: display.minX + CGFloat(rect.x), y: display.minY + CGFloat(rect.y),
               width: CGFloat(rect.w), height: CGFloat(rect.h))
    }
}
