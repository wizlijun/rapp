import AppKit
import RappCore

let inputBarHeight: CGFloat = 28

/// The B window for one decorated A window (spec §4.1): B's title bar, A's
/// content below it, the input bar at the bottom and the traffic label at the
/// right of the title bar. Its delegate is the `WindowCoordinator`.
final class RemoteWindow: NSWindow {
    let remoteView = RemoteView(frame: .zero)
    let inputBar = InputBar(frame: .zero)
    /// The window-table item last applied.
    private(set) var info: WindowInfo

    init(info: WindowInfo, label: TrafficLabel) {
        self.info = info
        let content = NSRect(x: 0, y: 0, width: 400, height: 300 + inputBarHeight)
        super.init(contentRect: content, styleMask: [.titled, .closable, .miniaturizable],
                   backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        // B places the windows where A has them; AppKit must not cascade them.
        isRestorable = false
        tabbingMode = .disallowed

        let container = NSView(frame: content)
        inputBar.frame = NSRect(x: 0, y: 0, width: content.width, height: inputBarHeight)
        inputBar.autoresizingMask = [.width, .maxYMargin]
        remoteView.frame = NSRect(x: 0, y: inputBarHeight, width: content.width, height: content.height - inputBarHeight)
        remoteView.autoresizingMask = [.width, .height]
        container.addSubview(remoteView)
        container.addSubview(inputBar)
        contentView = container
        label.attach(to: self)
        makeFirstResponder(inputBar)
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

    /// The content (picture + input bar) size for A's content at `zoom`.
    func contentSize(zoom: CGFloat) -> CGSize {
        CGSize(width: remoteView.remoteSize.width * zoom, height: remoteView.remoteSize.height * zoom + inputBarHeight)
    }

    /// The picture's size in B points as the window is now.
    var pictureSize: CGSize {
        let content = contentRect(forFrameRect: frame)
        return CGSize(width: content.width, height: content.height - inputBarHeight)
    }
}
