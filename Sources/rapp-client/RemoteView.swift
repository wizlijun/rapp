import AppKit
import QuartzCore
import RappCore

/// Shows the remote window's picture, scaled to fit, and reports mouse and
/// scroll input on it as messages.
final class RemoteView: NSView {
    /// Called with a `.mouse` or `.scroll` message.
    var onMouse: ((Message) -> Void)?

    /// Pixel size of the picture currently shown.
    private(set) var imageSize = CGSize.zero
    /// The A window this view shows, and its content size in A points:
    /// mouse and scroll positions are sent in those points.
    var windowID: UInt32 = 0
    var remoteSize = CGSize.zero
    /// Height of the window's A title row: positions are sent from the
    /// window's top-left (spec §2.3), and the picture starts below the row.
    var titleBar: Float = 0

    private var pressed = Set<MouseButton>()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // Layer-hosting: the layer is ours, so AppKit never replaces its contents.
        let hosted = CALayer()
        hosted.backgroundColor = NSColor.black.cgColor
        hosted.contentsGravity = .resizeAspect
        layer = hosted
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// `bgra` is B, G, R, X bytes, `width * 4` per row; only `crop` (pixels,
    /// top-left origin) of it is shown.
    func show(bgra: [UInt8], width: Int, height: Int, crop: CGRect) {
        guard width > 0, height > 0, bgra.count >= width * height * 4,
              let provider = CGDataProvider(data: Data(bgra) as CFData),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue
                                            | CGImageAlphaInfo.noneSkipFirst.rawValue),
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent),
              let image = image.cropping(to: crop)
        else { return }
        imageSize = CGSize(width: image.width, height: image.height)
        layer?.contents = image
    }

    // MARK: Mouse

    /// Position inside the picture in A points from the window's top-left
    /// (title row included). Outside the picture this is nil, unless `clamped`, which pins
    /// it to the nearest edge.
    private func position(of event: NSEvent, clamped: Bool) -> (x: Float, y: Float)? {
        let point = convert(event.locationInWindow, from: nil)
        let normalized: (x: Float, y: Float)
        if let inside = normalizedPoint(point, imageSize: imageSize, viewSize: bounds.size) {
            normalized = inside
        } else {
            guard clamped else { return nil }
            let rect = aspectFitRect(imageSize: imageSize, in: bounds.size)
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
            // Hover is not sent by the single-window client.
            return
        case .drag, .up:
            // Once a press was sent, its drags and release always follow,
            // even when the pointer has left the picture.
            guard pressed.contains(button), let p = position(of: event, clamped: true) else { return }
            if kind == .up { pressed.remove(button) }
            onMouse?(.mouse(kind: kind, button: button, window: windowID, x: p.x, y: p.y,
                            clickCount: UInt8(clamping: event.clickCount)))
        }
    }

    override func mouseDown(with event: NSEvent) { mouse(.down, .left, event) }
    override func mouseDragged(with event: NSEvent) { mouse(.drag, .left, event) }
    override func mouseUp(with event: NSEvent) { mouse(.up, .left, event) }
    override func rightMouseDown(with event: NSEvent) { mouse(.down, .right, event) }
    override func rightMouseDragged(with event: NSEvent) { mouse(.drag, .right, event) }
    override func rightMouseUp(with event: NSEvent) { mouse(.up, .right, event) }

    override func scrollWheel(with event: NSEvent) {
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
