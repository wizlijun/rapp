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
/// screen-saver/cursor levels. The Dock keeps a transparent full-screen window above all app windows
/// (macOS 27), so a Dock window only counts when the Accessibility hit test (`hitTestPID`, nil when it
/// fails) says the Dock itself is at the point — an icon of the Dock bar.
public func topWindowOwner(at point: CGPoint, windows: [ScreenWindow], dockPID: Int32?,
                           hitTestPID: () -> Int32?) -> (pid: Int32, name: String) {
    var dockHit: Bool?
    for window in windows where window.alpha > 0 && window.layer < 1000 && window.frame.contains(point) {
        if let dockPID, window.pid == dockPID {
            if dockHit == nil { dockHit = hitTestPID() == dockPID }
            if dockHit == false { continue }
        }
        return (window.pid, window.name)
    }
    return (0, "nothing")
}
