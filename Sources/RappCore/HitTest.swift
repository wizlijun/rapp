import CoreGraphics
import Foundation

/// One on-screen window as the window server lists it, front to back.
public struct ScreenWindow: Equatable {
    public var pid: Int32
    public var name: String
    public var layer: Int
    public var alpha: Double
    public var frame: CGRect
    public init(pid: Int32, name: String, layer: Int, alpha: Double, frame: CGRect) {
        self.pid = pid; self.name = name; self.layer = layer; self.alpha = alpha; self.frame = frame
    }
}

/// The owner of the frontmost window containing `point` (spec §3.4), skipping invisible ones and the
/// screen-saver/cursor levels.
///
/// Some windows of other processes are see-through overlays rather than something on top: the Dock keeps
/// a transparent full-screen window above all app windows (macOS 27), and other agents put up full-screen
/// or translucent layers around a global prompt. Those count only where the Accessibility hit test
/// (`hitTestPID`, nil when it fails, asked at most once) finds their process at the point:
/// - a Dock window counts only on a hit (an icon of the Dock bar); a failed test looks through it;
/// - any other overlay (translucent, or covering most of the display in `displays` that holds the point)
///   counts on a hit or a failed test, since a real prompt must not be clicked through.
/// Ordinary opaque windows always count, without asking Accessibility.
public func topWindowOwner(at point: CGPoint, windows: [ScreenWindow], dockPID: Int32?, displays: [CGRect] = [],
                           hitTestPID: () -> Int32?) -> (pid: Int32, name: String) {
    var hit: Int32??
    func hitPID() -> Int32? {
        if hit == nil { hit = .some(hitTestPID()) }
        return hit!
    }
    let display = displays.first { $0.contains(point) }
    for window in windows where window.alpha > 0 && window.layer < 1000 && window.frame.contains(point) {
        if let dockPID, window.pid == dockPID {
            if hitPID() != dockPID { continue }
        } else if mayBeOverlay(window, display: display) {
            if let pid = hitPID(), pid != window.pid { continue }
        }
        return (window.pid, window.name)
    }
    return (0, "nothing")
}

/// Share of the display a window must cover to be taken for a possible overlay.
public let overlayCoverage = 0.85

/// Whether `window` may be a see-through overlay: translucent, or covering most of `display`.
func mayBeOverlay(_ window: ScreenWindow, display: CGRect?) -> Bool {
    if window.alpha < 1 { return true }
    guard let display, display.width > 0, display.height > 0 else { return false }
    let covered = window.frame.intersection(display)
    guard !covered.isNull else { return false }
    return Double(covered.width * covered.height) >= overlayCoverage * Double(display.width * display.height)
}
