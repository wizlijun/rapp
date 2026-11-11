import CoreGraphics
import Foundation

/// The largest rectangle with the image's aspect ratio that fits in the view, centred.
public func aspectFitRect(imageSize: CGSize, in viewSize: CGSize) -> CGRect {
    guard imageSize.width > 0, imageSize.height > 0, viewSize.width > 0, viewSize.height > 0 else { return .zero }
    let scale = min(viewSize.width / imageSize.width, viewSize.height / imageSize.height)
    let w = imageSize.width * scale, h = imageSize.height * scale
    return CGRect(x: (viewSize.width - w) / 2, y: (viewSize.height - h) / 2, width: w, height: h)
}

/// Maps a point in the view (origin top-left) to 0...1 coordinates inside the
/// aspect-fitted image. Nil when the point is on the empty border.
public func normalizedPoint(_ p: CGPoint, imageSize: CGSize, viewSize: CGSize) -> (x: Float, y: Float)? {
    let rect = aspectFitRect(imageSize: imageSize, in: viewSize)
    guard rect.width > 0, rect.height > 0, rect.contains(p) else { return nil }
    return (Float((p.x - rect.minX) / rect.width), Float((p.y - rect.minY) / rect.height))
}

/// Maps 0...1 window coordinates to a global screen point, kept inside the window.
public func globalPoint(x: Float, y: Float, windowFrame: CGRect) -> CGPoint {
    let nx = CGFloat(min(max(x, 0), 1)), ny = CGFloat(min(max(y, 0), 1))
    return CGPoint(x: min(windowFrame.minX + nx * windowFrame.width, windowFrame.maxX - 1),
                   y: min(windowFrame.minY + ny * windowFrame.height, windowFrame.maxY - 1))
}

/// Limits a requested window size so that a window whose top-left corner stays
/// at `origin` does not extend past the screen, and is at least 100 x 100.
public func clampSize(requested: CGSize, origin: CGPoint, screen: CGRect) -> CGSize {
    CGSize(width: max(100, min(requested.width, screen.maxX - origin.x)),
           height: max(100, min(requested.height, screen.maxY - origin.y)))
}

/// Splits text into runs of at most `max` UTF-16 units without separating a surrogate pair.
public func chunkUTF16(_ s: String, max: Int = 20) -> [[UInt16]] {
    let units = Array(s.utf16)
    var chunks = [[UInt16]]()
    var start = 0
    while start < units.count {
        var end = min(start + max, units.count)
        if end < units.count, end - start > 1, (0xD800...0xDBFF).contains(units[end - 1]) { end -= 1 }
        chunks.append(Array(units[start..<end]))
        start = end
    }
    return chunks
}

/// Height of a window's title row, in points, measured from its close button:
/// the button is centred vertically in that row, so the row is twice the
/// distance from the window's top edge to the button's centre. 0 (do not crop)
/// when there is no button or the result is not plausible.
public func titleRowHeight(closeButtonFrame: CGRect?, windowFrame: CGRect) -> CGFloat {
    guard let button = closeButtonFrame else { return 0 }
    let row = (2 * (button.midY - windowFrame.minY)).rounded()
    guard row > 0, row <= windowFrame.height / 2 else { return 0 }
    return row
}

/// One direct Accessibility child of a window: enough to tell what sits in its title row.
public struct TitleRowChild: Equatable {
    public var role: String
    public var subrole: String?
    public var frame: CGRect
    public init(role: String, subrole: String?, frame: CGRect) { self.role = role; self.subrole = subrole; self.frame = frame }
}

/// The title row to crop, only when it is the system's plain title bar: 20–34 points tall (22, 28 or 32
/// depending on the macOS the app was built for) and holding nothing but the window buttons, the title
/// and a document icon, with the window's content below it. Toolbars, and windows whose own content
/// reaches under the buttons (Electron, Chrome, sidebars), give 0; so does a window with no content
/// elements to judge by.
public func systemTitleRowHeight(closeButtonFrame: CGRect?, windowFrame: CGRect, children: [TitleRowChild]) -> CGFloat {
    let row = titleRowHeight(closeButtonFrame: closeButtonFrame, windowFrame: windowFrame)
    guard (20...34).contains(row) else { return 0 }
    let windowButtons: Set<String> = ["AXCloseButton", "AXMinimizeButton", "AXZoomButton", "AXFullScreenButton"]
    let rowBottom = windowFrame.minY + row - 1
    var hasContent = false
    for child in children where child.frame.height > 0 {
        if child.role == "AXButton", let subrole = child.subrole, windowButtons.contains(subrole) { continue }
        let insideRow = child.frame.maxY <= rowBottom + 1
        if (child.role == "AXStaticText" || child.role == "AXImage"), insideRow { continue }
        if child.frame.minY < rowBottom { return 0 }
        hasContent = true
    }
    return hasContent ? row : 0
}

/// The part of the window below its title row.
public func contentRect(windowFrame: CGRect, titleRow: CGFloat) -> CGRect {
    CGRect(x: windowFrame.minX, y: windowFrame.minY + titleRow,
           width: windowFrame.width, height: windowFrame.height - titleRow)
}

/// The window size that gives the requested content size, kept on screen.
public func windowSize(forContent content: CGSize, titleRow: CGFloat, origin: CGPoint, screen: CGRect) -> CGSize {
    clampSize(requested: CGSize(width: content.width, height: content.height + titleRow), origin: origin, screen: screen)
}

// MARK: Client zoom (revision 2)

/// Which part of the client window a live resize drags.
public enum ResizeHandle: Equatable {
    /// A corner: zoom the picture on B only; A keeps its size.
    case corner
    /// The left or right edge: A's width follows.
    case horizontal
    /// The top or bottom edge: A's height follows.
    case vertical
    /// A size change that is not a drag (zoom button, full screen): both follow.
    case both
}

/// The handle a live resize starting with the mouse at `mouse` drags. A corner
/// when the mouse is within `cornerSize` points of a corner both across and
/// down; otherwise the closer of the side edges and the top/bottom edges.
/// With no mouse button down (zoom button released, full screen, a menu
/// command) nothing is being dragged: `.both`. `mouse` and `windowFrame`
/// share one coordinate space.
public func resizeHandle(mouse: CGPoint, windowFrame: CGRect, buttonsDown: Bool, cornerSize: CGFloat = 16) -> ResizeHandle {
    guard buttonsDown else { return .both }
    let dx = min(abs(mouse.x - windowFrame.minX), abs(mouse.x - windowFrame.maxX))
    let dy = min(abs(mouse.y - windowFrame.minY), abs(mouse.y - windowFrame.maxY))
    if dx <= cornerSize && dy <= cornerSize { return .corner }
    return dx <= dy ? .horizontal : .vertical
}

/// The picture size for a corner drag: the proposed size bent to `aspect`,
/// keeping whichever side changed more relative to `current`. Whole points.
public func lockedAspectSize(proposed: CGSize, current: CGSize, aspect: CGSize) -> CGSize {
    guard aspect.width > 0, aspect.height > 0, current.width > 0, current.height > 0 else { return proposed }
    let rw = abs(proposed.width - current.width) / current.width
    let rh = abs(proposed.height - current.height) / current.height
    if rw >= rh {
        return CGSize(width: proposed.width.rounded(), height: (proposed.width * aspect.height / aspect.width).rounded())
    }
    return CGSize(width: (proposed.height * aspect.width / aspect.height).rounded(), height: proposed.height.rounded())
}

/// The content size to ask A for after a resize of the picture area to `view`
/// at `zoom` (picture points per A point). A corner drag asks for nothing new.
public func remoteResize(view: CGSize, zoom: CGFloat, remote: CGSize, handle: ResizeHandle) -> CGSize {
    guard zoom > 0 else { return remote }
    let w = (view.width / zoom).rounded(), h = (view.height / zoom).rounded()
    switch handle {
    case .corner: return remote
    case .horizontal: return CGSize(width: w, height: remote.height)
    case .vertical: return CGSize(width: remote.width, height: h)
    case .both: return CGSize(width: w, height: h)
    }
}

/// How the client picks the capture density.
public enum DensityChoice: Sendable {
    /// One capture pixel per B point: half the pixels on a Retina B.
    case saver1x
    /// One capture pixel per B display pixel: follows the size shown on B.
    case adaptive
    /// A's own pixels, whatever B shows; the host caps the request there.
    case original
}

/// Capture pixels per A point for `choice`, kept within what the protocol
/// accepts, (0, 8]. `.original` asks for the maximum, which the host lowers
/// to A's own pixels per point.
public func captureDensity(zoom: CGFloat, backingScale: CGFloat, choice: DensityChoice) -> Float {
    let d: Float
    switch choice {
    case .saver1x: d = Float(zoom)
    case .adaptive: d = Float(zoom * backingScale)
    case .original: return 8
    }
    guard d.isFinite else { return 1 }
    return min(8, max(0.01, d))
}

/// A one-click combination of mode, density and frame rate.
public struct StreamPreset: Sendable {
    public let mode: Mode
    public let density: DensityChoice
    public let fps: UInt8

    public static let leastTraffic = StreamPreset(mode: .duogray, density: .adaptive, fps: 1)
    public static let sharpest = StreamPreset(mode: .color16, density: .original, fps: 15)
}

/// Whether the client should send `setStream`: the mode or frame rate differs,
/// or the density moved by more than 1 %. Smaller density drift (rounding while
/// the window settles) is not worth a new capture configuration.
public func streamChanged(from sent: (mode: Mode, fps: UInt8, density: Float)?,
                          to next: (mode: Mode, fps: UInt8, density: Float)) -> Bool {
    guard let sent else { return true }
    return sent.mode != next.mode || sent.fps != next.fps
        || abs(next.density - sent.density) > sent.density * 0.01
}
