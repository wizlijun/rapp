import AppKit
import RappCore

/// A borderless B panel for one A popup: menu, tooltip, sheet or popover
/// (spec §4.1). It never takes the focus, the user cannot move it, and it is
/// a child of its parent's B window so it follows that window around.
final class PopupPanel: NSPanel {
    let remoteView = RemoteView(frame: .zero)
    private(set) var info: WindowInfo

    init(info: WindowInfo) {
        self.info = info
        super.init(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        isMovable = false
        hidesOnDeactivate = false
        level = .popUpMenu
        hasShadow = true
        remoteView.autoresizingMask = [.width, .height]
        contentView = remoteView
        update(info)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func update(_ new: WindowInfo) {
        info = new
        remoteView.windowID = new.id
        remoteView.titleBar = 0
        remoteView.remoteSize = CGSize(width: CGFloat(new.rect.w), height: CGFloat(new.rect.h))
        // Menus highlight items and open submenus under the pointer.
        remoteView.sendsHover = new.kind == .menu
    }
}
