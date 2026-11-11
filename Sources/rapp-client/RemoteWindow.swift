import AppKit
import RappCore

/// The B window for one decorated A window (spec §4.1): B's title bar, A's
/// content below it, the composer bar at the bottom and the traffic label at the
/// right of the title bar. Its delegate is the `WindowCoordinator`.
final class RemoteWindow: NSWindow {
    let remoteView = RemoteView(frame: .zero)
    let composerBar = ComposerBar(frame: .zero)
    /// The composer bar's height now (one to eight lines of text, and the transfer strip).
    private(set) var barHeight: CGFloat
    /// The window-table item last applied.
    private(set) var info: WindowInfo

    init(info: WindowInfo, label: TrafficLabel) {
        self.info = info
        barHeight = composerBar.barHeight
        let content = NSRect(x: 0, y: 0, width: 400, height: 300 + barHeight)
        super.init(contentRect: content, styleMask: [.titled, .closable, .miniaturizable],
                   backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        // B places the windows where A has them; AppKit must not cascade them.
        isRestorable = false
        tabbingMode = .disallowed

        let container = NSView(frame: content)
        composerBar.frame = NSRect(x: 0, y: 0, width: content.width, height: barHeight)
        composerBar.autoresizingMask = [.width, .maxYMargin]
        remoteView.frame = NSRect(x: 0, y: barHeight, width: content.width, height: content.height - barHeight)
        remoteView.autoresizingMask = [.width, .height]
        container.addSubview(remoteView)
        container.addSubview(composerBar)
        contentView = container
        label.attach(to: self)
        makeFirstResponder(composerBar.composer)
        update(info)
    }

    func update(_ new: WindowInfo) {
        info = new
        title = new.title
        if new.resizable { styleMask.insert(.resizable) } else { styleMask.remove(.resizable) }
        remoteView.windowID = new.id
        remoteView.titleBar = new.titleBar
        remoteView.remoteSize = CGSize(width: CGFloat(new.rect.w), height: CGFloat(new.rect.h - new.titleBar))
    }

    /// Makes the bar `height` tall: the window grows or shrinks with it, keeping
    /// the picture's size and the window's top edge where they are.
    func setBarHeight(_ height: CGFloat) {
        guard height != barHeight else { return }
        let delta = height - barHeight
        barHeight = height
        let content = contentRect(forFrameRect: frame)
        let grown = NSRect(x: content.minX, y: content.maxY - (content.height + delta),
                           width: content.width, height: content.height + delta)
        composerBar.frame.size.height = height
        setFrame(frameRect(forContentRect: grown), display: true)
        remoteView.frame = NSRect(x: 0, y: height, width: grown.width, height: grown.height - height)
        composerBar.frame = NSRect(x: 0, y: 0, width: grown.width, height: height)
    }

    /// The content (picture + composer bar) size for A's content at `zoom`.
    func contentSize(zoom: CGFloat) -> CGSize {
        CGSize(width: remoteView.remoteSize.width * zoom, height: remoteView.remoteSize.height * zoom + barHeight)
    }

    /// The picture's size in B points as the window is now.
    var pictureSize: CGSize {
        let content = contentRect(forFrameRect: frame)
        return CGSize(width: content.width, height: content.height - barHeight)
    }

    /// Where A's content is drawn inside the picture area (top-left origin),
    /// aspect-fitted as `RemoteView` draws it.
    var pictureFit: CGRect { aspectFitRect(imageSize: remoteView.remoteSize, in: pictureSize) }
}
