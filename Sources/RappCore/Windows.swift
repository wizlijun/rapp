import CoreGraphics
import Foundation

// Window-table logic shared by the host and the client (multi-window spec §5).
// Canvas coordinates are A points with the origin at the display's top-left.

/// The kind of an A window, from its window level and, at the normal level,
/// its Accessibility role and subrole (spec §3.3).
public func classifyWindow(level: Int, role: String?, subrole: String?) -> WindowKind {
    func key(_ k: CGWindowLevelKey) -> Int { Int(CGWindowLevelForKey(k)) }
    let normal = key(.normalWindow), modal = key(.modalPanelWindow), popUp = key(.popUpMenuWindow)
    if level > popUp { return .tooltip }
    if level == popUp { return .menu }
    if level == modal { return .dialog }
    if level > normal { return .floating }
    switch (role, subrole) {
    case ("AXSheet", _): return .sheet
    case ("AXPopover", _): return .popover
    case (_, "AXDialog"), (_, "AXSystemDialog"): return .dialog
    case (_, "AXFloatingWindow"), (_, "AXSystemFloatingWindow"): return .floating
    default: return .normal
    }
}

private func overlapArea(_ a: CanvasRect, _ b: CanvasRect) -> Float {
    let w = min(a.x + a.w, b.x + b.w) - max(a.x, b.x)
    let h = min(a.y + a.h, b.y + b.h) - max(a.y, b.y)
    return w > 0 && h > 0 ? w * h : 0
}

/// Sets each window's parent (spec §3.2). Decorated windows have none. A popup
/// belongs to the decorated window it overlaps most (the frontmost one on a
/// tie), or to the frontmost decorated window if it overlaps none; with no
/// decorated window at all its parent is 0. `windows` is front to back.
public func assignParents(_ windows: [WindowInfo]) -> [WindowInfo] {
    let decorated = windows.filter { $0.kind.isDecorated }
    return windows.map { window in
        var out = window
        if window.kind.isDecorated {
            out.parent = 0
            return out
        }
        var best: (id: UInt32, area: Float)?
        for candidate in decorated {
            let area = overlapArea(window.rect, candidate.rect)
            if area > (best?.area ?? 0) { best = (candidate.id, area) }
        }
        out.parent = best?.id ?? decorated.first?.id ?? 0
        return out
    }
}

/// Removes windows lying wholly inside a decorated window's title row, such as
/// the screen-recording indicator macOS adds to captured windows (spec §3.2).
/// A title row that could not be measured (0) counts as 28 points.
public func dropTitleBarAccessories(_ windows: [WindowInfo]) -> [WindowInfo] {
    let bands = windows.filter { $0.kind.isDecorated }.map { d in
        (id: d.id, rect: CanvasRect(x: d.rect.x, y: d.rect.y, w: d.rect.w, h: d.titleBar > 0 ? d.titleBar : 28))
    }
    return windows.filter { w in
        !bands.contains { band in
            band.id != w.id && w.rect.x >= band.rect.x && w.rect.y >= band.rect.y
                && w.rect.x + w.rect.w <= band.rect.x + band.rect.w && w.rect.y + w.rect.h <= band.rect.y + band.rect.h
        }
    }
}

/// The capture region: the union of all windows, clipped to the display,
/// rounded out to multiples of 8 points and clipped again (spec §1.1). Nil
/// when there are no windows or none is on the display.
public func captureRegion(windows: [WindowInfo], display: CGSize) -> CanvasRect? {
    guard let first = windows.first else { return nil }
    var minX = first.rect.x, minY = first.rect.y
    var maxX = first.rect.x + first.rect.w, maxY = first.rect.y + first.rect.h
    for w in windows.dropFirst() {
        minX = min(minX, w.rect.x)
        minY = min(minY, w.rect.y)
        maxX = max(maxX, w.rect.x + w.rect.w)
        maxY = max(maxY, w.rect.y + w.rect.h)
    }
    let width = Float(display.width), height = Float(display.height)
    minX = max(minX, 0)
    minY = max(minY, 0)
    maxX = min(maxX, width)
    maxY = min(maxY, height)
    guard maxX > minX, maxY > minY else { return nil }
    minX = (minX / 8).rounded(.down) * 8
    minY = (minY / 8).rounded(.down) * 8
    maxX = min((maxX / 8).rounded(.up) * 8, width)
    maxY = min((maxY / 8).rounded(.up) * 8, height)
    return CanvasRect(x: minX, y: minY, w: maxX - minX, h: maxY - minY)
}

/// Where a window's content (below its A title row) is in a frame of
/// `pixelWidth` x `pixelHeight` pixels covering `region`, in whole pixels
/// from the frame's top-left (spec §4.4). Only the part inside the region;
/// nil if none of it is.
public func cropRect(window: WindowInfo, region: CanvasRect, pixelWidth: Int, pixelHeight: Int) -> CGRect? {
    guard region.w > 0, region.h > 0, pixelWidth > 0, pixelHeight > 0 else { return nil }
    let r = window.rect
    let minX = max(r.x, region.x), minY = max(r.y + window.titleBar, region.y)
    let maxX = min(r.x + r.w, region.x + region.w), maxY = min(r.y + r.h, region.y + region.h)
    guard maxX > minX, maxY > minY else { return nil }
    let sx = Float(pixelWidth) / region.w, sy = Float(pixelHeight) / region.h
    let x0 = ((minX - region.x) * sx).rounded(), y0 = ((minY - region.y) * sy).rounded()
    let x1 = min(((maxX - region.x) * sx).rounded(), Float(pixelWidth))
    let y1 = min(((maxY - region.y) * sy).rounded(), Float(pixelHeight))
    guard x1 > x0, y1 > y0 else { return nil }
    return CGRect(x: CGFloat(x0), y: CGFloat(y0), width: CGFloat(x1 - x0), height: CGFloat(y1 - y0))
}

/// Which part of a window's content (below its A title row) a frame covering
/// `region` shows, as fractions of the content's width and height from its
/// top-left. The B window draws the crop there, so a window hanging off A's
/// display is not stretched. Nil if none of the content is in the region.
public func visiblePart(window: WindowInfo, region: CanvasRect) -> CGRect? {
    let r = window.rect
    let top = r.y + window.titleBar, height = r.h - window.titleBar
    guard r.w > 0, height > 0 else { return nil }
    let minX = max(r.x, region.x), minY = max(top, region.y)
    let maxX = min(r.x + r.w, region.x + region.w), maxY = min(top + height, region.y + region.h)
    guard maxX > minX, maxY > minY else { return nil }
    return CGRect(x: CGFloat((minX - r.x) / r.w), y: CGFloat((minY - top) / height),
                  width: CGFloat((maxX - minX) / r.w), height: CGFloat((maxY - minY) / height))
}

/// Canvas <-> B mapping: B point = origin + zoom x canvas point (spec §4.2).
/// B coordinates here have a top-left origin; the client flips them.
public struct WindowPlacement: Equatable {
    public var origin: CGPoint
    public var zoom: CGFloat

    public init(origin: CGPoint, zoom: CGFloat) {
        self.origin = origin
        self.zoom = zoom
    }

    public func toB(_ canvas: CGPoint) -> CGPoint {
        CGPoint(x: origin.x + zoom * canvas.x, y: origin.y + zoom * canvas.y)
    }

    public func toCanvas(_ b: CGPoint) -> CGPoint {
        CGPoint(x: (b.x - origin.x) / zoom, y: (b.y - origin.y) / zoom)
    }

    /// The placement that puts the center of `content` (canvas) at the center of `screen` (B).
    public static func centering(content: CGRect, on screen: CGRect, zoom: CGFloat) -> WindowPlacement {
        WindowPlacement(origin: CGPoint(x: screen.midX - zoom * content.midX, y: screen.midY - zoom * content.midY),
                        zoom: zoom)
    }

    /// Where a decorated window's content (below its A title row) starts in B.
    public func contentTopLeftInB(_ window: WindowInfo) -> CGPoint {
        toB(CGPoint(x: CGFloat(window.rect.x), y: CGFloat(window.rect.y + window.titleBar)))
    }

    /// The A window top-left (canvas) that puts its content at `contentTopLeftInB`
    /// in B: what a `move` sends after the user moved the B window (spec §4.3).
    public func windowOrigin(contentTopLeftInB b: CGPoint, titleBar: Float) -> CGPoint {
        let c = toCanvas(b)
        return CGPoint(x: c.x, y: c.y - CGFloat(titleBar))
    }

    /// The same mapping at a new zoom, with `canvas` staying where it is in B.
    public func rezoomed(to newZoom: CGFloat, keeping canvas: CGPoint) -> WindowPlacement {
        let b = toB(canvas)
        return WindowPlacement(origin: CGPoint(x: b.x - newZoom * canvas.x, y: b.y - newZoom * canvas.y), zoom: newZoom)
    }
}

/// Where a popup goes in B (top-left origin): attached to its parent's
/// picture wherever that is in B, at the picture's scale (spec §1.3). The
/// picture's scale is the zoom unless A refused a resize and the picture is
/// aspect-fitted smaller.
public func popupFrame(popup: CanvasRect, parentContent: CanvasRect, parentPicture: CGRect) -> CGRect {
    let scale = parentContent.w > 0 ? parentPicture.width / CGFloat(parentContent.w) : 1
    return CGRect(x: parentPicture.minX + scale * CGFloat(popup.x - parentContent.x),
                  y: parentPicture.minY + scale * CGFloat(popup.y - parentContent.y),
                  width: scale * CGFloat(popup.w), height: scale * CGFloat(popup.h))
}

/// A move target (canvas, window top-left) pulled back so the window's
/// title row stays on A's display: a window moved off it would leave the
/// window table and could not be moved back from B. At least 40 points of
/// width and the title row (20 points if it has none) stay on the canvas.
public func clampedWindowOrigin(_ origin: CGPoint, size: CGSize, titleBar: CGFloat, canvas: CGSize) -> CGPoint {
    let keep = min(size.width, 40), grab = titleBar > 0 ? titleBar : 20
    return CGPoint(x: min(max(origin.x, keep - size.width), canvas.width - keep),
                   y: min(max(origin.y, 0), max(canvas.height - grab, 0)))
}

/// Step between stacked top-left slots: about a title bar, so every stacked title stays visible.
public let stackStep: Float = 28

/// What B's 「把 A 上的这个窗口移到左上角」 sends: a move to the first free
/// slot of the top-left stack (0,0), (28,28), (56,56)…, then a focus so the
/// window comes out from under whatever covers it. A slot is taken when
/// another decorated window of `table` already sits on it. macOS keeps
/// windows below the menu bar (one asked for y 0 lands near y 30), so tops
/// above `menuBarAllowance` count as that line. A clamps the move onto the display.
public func moveToTopLeftMessages(window: UInt32, table: [WindowInfo]) -> [Message] {
    let menuBarAllowance: Float = 40, near = stackStep / 2
    let top = { (y: Float) in max(y, menuBarAllowance) }
    let others = table.filter { $0.id != window && $0.kind.isDecorated }
    var slot: Float = 0
    while others.contains(where: { abs($0.rect.x - slot) < near && abs(top($0.rect.y) - top(slot)) < near }) {
        slot += stackStep
    }
    return [.move(window: window, x: slot, y: slot), .focus(window)]
}

/// How many polls a new window below menu level may go without an
/// Accessibility window before its level-only classification is kept.
public let classificationAttempts = 10

/// Whether a window's classification can be kept: it was made with the
/// window's Accessibility element, or the window is a menu or tooltip (which
/// never has one), or the element did not show up in `classificationAttempts` polls.
public func classificationIsFinal(foundAccessibility: Bool, belowPopUp: Bool, attempts: Int) -> Bool {
    foundAccessibility || !belowPopUp || attempts >= classificationAttempts
}

/// The menu item a menuPick path names, or nil if the path is empty or leaves the tree.
public func menuItem(at path: [UInt16], in items: [MenuItem]) -> MenuItem? {
    guard let first = path.first, Int(first) < items.count else { return nil }
    let item = items[Int(first)]
    return path.count == 1 ? item : menuItem(at: Array(path.dropFirst()), in: item.children)
}
