import AppKit
import CoreVideo
import QuartzCore
import RappCore

/// Shows one A window's content, scaled to fit at its aspect ratio, and
/// reports mouse and scroll input on it as messages.
public final class RemoteView: NSView {
    /// Called with a `.mouse` or `.scroll` message.
    public var onMouse: ((Message) -> Void)?

    /// The A window this view shows, and its content size in A points:
    /// mouse and scroll positions are sent in those points.
    public var windowID: UInt32 = 0
    public var remoteSize = CGSize.zero {
        didSet { if remoteSize != oldValue { layoutPicture() } }
    }
    /// Height of the window's A title row: positions are sent from the
    /// window's top-left (spec §2.3), and the picture starts below the row.
    public var titleBar: Float = 0

    /// Whether pointer moves with no button down are sent. Menus need them to
    /// highlight items and open submenus; windows do not, and moving A's
    /// pointer for every hover is not worth it.
    public var sendsHover = false {
        didSet { updateTrackingAreas() }
    }

    private var pressed = Set<MouseButton>()
    private var hoverArea: NSTrackingArea?
    /// The picture, drawn over `visible` of the content (fractions, top-left origin).
    private let picture = CALayer()
    private var visible = CGRect(x: 0, y: 0, width: 1, height: 1)

    override public init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // Layer-hosting: the layer is ours, so AppKit never replaces its contents.
        let hosted = CALayer()
        hosted.backgroundColor = NSColor.black.cgColor
        hosted.isGeometryFlipped = true      // top-left origin, like the view
        layer = hosted
        wantsLayer = true
        picture.contentsGravity = .resize
        picture.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        hosted.addSublayer(picture)
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override public var isFlipped: Bool { true }

    override public func layout() {
        super.layout()
        layoutPicture()
    }
    override public var acceptsFirstResponder: Bool { false }
    override public func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Where the whole content is drawn: fitted at A's aspect ratio.
    private var fitRect: CGRect { aspectFitRect(imageSize: remoteSize, in: bounds.size) }

    /// Shows `buffer`, the part `visible` of the window's content (see `visiblePart`).
    public func show(_ buffer: CVPixelBuffer, visible part: CGRect) {
        visible = part
        picture.contents = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue()
        layoutPicture()
    }

    private func layoutPicture() {
        let fit = fitRect
        let frame = CGRect(x: fit.minX + visible.minX * fit.width, y: fit.minY + visible.minY * fit.height,
                           width: visible.width * fit.width, height: visible.height * fit.height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        picture.frame = frame
        CATransaction.commit()
    }

    // MARK: Mouse

    /// Position inside the picture in A points from the window's top-left
    /// (title row included). Outside the picture this is nil, unless `clamped`, which pins
    /// it to the nearest edge.
    private func position(of event: NSEvent, clamped: Bool) -> (x: Float, y: Float)? {
        let point = convert(event.locationInWindow, from: nil)
        let normalized: (x: Float, y: Float)
        if let inside = normalizedPoint(point, imageSize: remoteSize, viewSize: bounds.size) {
            normalized = inside
        } else {
            guard clamped else { return nil }
            let rect = fitRect
            guard rect.width > 0, rect.height > 0 else { return nil }
            normalized = (Float(min(max((point.x - rect.minX) / rect.width, 0), 1)),
                          Float(min(max((point.y - rect.minY) / rect.height, 0), 1)))
        }
        return (normalized.x * Float(remoteSize.width), normalized.y * Float(remoteSize.height) + titleBar)
    }

    private func mouse(_ kind: MouseKind, _ button: MouseButton, _ event: NSEvent) {
        switch kind {
        case .down:
            // A press on the empty border around the picture is not sent.
            guard let p = position(of: event, clamped: false) else { return }
            pressed.insert(button)
            onMouse?(.mouse(kind: .down, button: button, window: windowID, x: p.x, y: p.y,
                            clickCount: UInt8(clamping: event.clickCount)))
        case .move:
            guard sendsHover, pressed.isEmpty, let p = position(of: event, clamped: false) else { return }
            onMouse?(.mouse(kind: .move, button: .left, window: windowID, x: p.x, y: p.y, clickCount: 0))
        case .drag, .up:
            // Once a press was sent, its drags and release always follow,
            // even when the pointer has left the picture.
            guard pressed.contains(button), let p = position(of: event, clamped: true) else { return }
            if kind == .up { pressed.remove(button) }
            onMouse?(.mouse(kind: kind, button: button, window: windowID, x: p.x, y: p.y,
                            clickCount: UInt8(clamping: event.clickCount)))
        }
    }

    override public func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        hoverArea = nil
        guard sendsHover else { return }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override public func mouseMoved(with event: NSEvent) { mouse(.move, .left, event) }
    override public func mouseDown(with event: NSEvent) { mouse(.down, .left, event) }
    override public func mouseDragged(with event: NSEvent) { mouse(.drag, .left, event) }
    override public func mouseUp(with event: NSEvent) { mouse(.up, .left, event) }
    override public func rightMouseDown(with event: NSEvent) { mouse(.down, .right, event) }
    override public func rightMouseDragged(with event: NSEvent) { mouse(.drag, .right, event) }
    override public func rightMouseUp(with event: NSEvent) { mouse(.up, .right, event) }

    override public func scrollWheel(with event: NSEvent) {
        guard let p = position(of: event, clamped: false) else { return }
        var dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
        if !event.hasPreciseScrollingDeltas {
            dx *= 10
            dy *= 10
        }
        guard dx != 0 || dy != 0 else { return }
        onMouse?(.scroll(window: windowID, x: p.x, y: p.y, dx: Float(dx), dy: Float(dy)))
    }
}
