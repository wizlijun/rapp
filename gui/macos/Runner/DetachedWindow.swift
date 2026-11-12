import Cocoa
import RappCore
import RappSession

/// One decorated A window of a detached session: a titled B window whose content is A's picture.
final class DetachedWindow: NSWindow {
  let remoteView = RemoteView(frame: .zero)
  /// The window-table item last applied.
  private(set) var info: WindowInfo

  init(info: WindowInfo) {
    self.info = info
    let content = NSRect(x: 0, y: 0, width: max(CGFloat(info.rect.w), 1),
                         height: max(CGFloat(info.rect.h - info.titleBar), 1))
    super.init(contentRect: content, styleMask: [.titled, .closable, .miniaturizable],
               backing: .buffered, defer: false)
    isReleasedWhenClosed = false
    // rapp places them beside the main window (R20); AppKit must not cascade or restore them.
    isRestorable = false
    tabbingMode = .disallowed
    remoteView.frame = content
    remoteView.autoresizingMask = [.width, .height]
    contentView = remoteView
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

  /// The content size in B points as the window is now.
  var contentSize: CGSize { contentRect(forFrameRect: frame).size }

  /// Where A's content is drawn inside the content (top-left origin), aspect-fitted as `RemoteView` does.
  var pictureFit: CGRect { aspectFitRect(imageSize: remoteView.remoteSize, in: contentSize) }
}

/// A session moved off the GUI's stage into native windows (R20, R21): one `DetachedWindow` per
/// decorated A window, a `PopupPanel` over its owner for every other one. The session itself (its
/// connection, sid and hub entry) is untouched: `close()` only takes the windows away.
///
/// Threading: everything here is main-thread only (it is created, updated and closed by
/// `SessionPlugin` on main, and AppKit calls the delegate methods on main). What goes to the
/// session (`send`, `close(reason:)`) is safe from any thread: it hops onto the session's queue.
/// `WindowSurfaces.latest`/`visible` are locked and safe on main.
final class DetachedSession: NSObject, NSWindowDelegate {
  private let session: EmbeddedSession
  private let onAttach: () -> Void
  /// The main Flutter window the first windows go beside (R20); nil when it is not known.
  private weak var main: NSWindow?
  /// The window that was key last; it becomes the stage's current tab on attach (R21).
  private(set) var lastKey: UInt32?
  private var windows = [UInt32: DetachedWindow]()
  private var popups = [UInt32: PopupPanel]()
  private var table = [WindowInfo]()
  private var pendingResizes = PendingActions<UInt32>()
  /// Set while rapp itself moves or sizes a window: nothing goes back to A for that.
  private var placing = false
  private var closed = false
  private var attachAsked = false

  init(session: EmbeddedSession, windows: [SessionWindow], beside main: NSWindow?, onAttach: @escaping () -> Void) {
    self.session = session
    self.onAttach = onAttach
    self.main = main
    super.init()
    update(windows)
    // The user's own action: the window A has focused (else the first) comes up as key.
    let decorated = table.filter { $0.kind.isDecorated }
    let first = decorated.first(where: \.focused) ?? decorated.first
    first.flatMap { self.windows[$0.id] }?.makeKeyAndOrderFront(nil)
  }

  /// Every window this session shows.
  var allWindows: [NSWindow] { Array(windows.values) + Array(popups.values) }

  /// Whether `window` is one of this session's (for key routing and focus).
  func owns(_ window: NSWindow?) -> Bool {
    guard let window else { return false }
    return allWindows.contains { $0 === window }
  }

  /// A's new window table: windows come and go with it; no decorated window left → `onAttach` (R7).
  func update(_ new: [SessionWindow]) {
    guard !closed else { return }
    table = new.map(\.info)
    let ids = Set(table.map(\.id))
    pendingResizes.keep(only: ids)
    let decorated = table.filter { $0.kind.isDecorated }
    let decoratedIDs = Set(decorated.map(\.id))
    for (id, panel) in popups where !ids.contains(id) || decoratedIDs.contains(id) {
      panel.parent?.removeChildWindow(panel)
      panel.close()
      popups[id] = nil
    }
    for (id, window) in windows where !decoratedIDs.contains(id) {
      window.delegate = nil
      window.close()
      windows[id] = nil
    }
    if let k = lastKey, windows[k] == nil { lastKey = nil }

    var fresh = [DetachedWindow]()
    for info in decorated {
      if let window = windows[info.id] {
        // A's size changes show letterboxed in the window the user sized; the window never
        // follows A on its own, so a resize is never answered with another one.
        window.update(info)
      } else {
        let window = DetachedWindow(info: info)
        window.delegate = self
        window.remoteView.onMouse = { [weak self] in self?.session.send($0) }
        windows[info.id] = window
        fresh.append(window)
      }
    }
    place(fresh)
    for window in fresh { window.orderFront(nil) }

    for info in table where !info.kind.isDecorated {
      let panel = popups[info.id] ?? makePopup(info)
      panel.update(info)
      let owner = popupOwner(info.id, table: table, fallback: lastKey ?? decorated.first?.id).flatMap { windows[$0] }
      if panel.parent !== owner {
        panel.parent?.removeChildWindow(panel)
        owner?.addChildWindow(panel, ordered: .above)
      }
      placePopup(panel, over: owner)
      if !panel.isVisible { panel.orderFront(nil) }
    }
    surfacesUpdated(Array(ids))

    if decorated.isEmpty, !attachAsked {
      attachAsked = true
      // After this table reached Dart: the runner sends it right after this returns.
      DispatchQueue.main.async { [weak self] in
        guard let self, !self.closed else { return }
        self.onAttach()
      }
    }
  }

  /// New pictures for `ids`: straight onto the windows' layers (the IOSurfaces A's frames decode into).
  func surfacesUpdated(_ ids: [UInt32]) {
    guard !closed else { return }
    for id in ids {
      guard let view = windows[id]?.remoteView ?? popups[id]?.remoteView,
            let buffer = session.surfaces.latest(id), let visible = session.surfaces.visible(id) else { continue }
      view.show(buffer, visible: visible)
    }
  }

  /// 「切到窗口」: every window to the front, the last key one as key.
  func raise() {
    guard !closed else { return }
    for window in windows.values { window.orderFront(nil) }
    let key = lastKey.flatMap { windows[$0] } ?? windows.values.first
    key?.makeKeyAndOrderFront(nil)
  }

  /// Takes the windows away; the session goes on (attach) or is already ending (closed).
  func close() {
    guard !closed else { return }
    closed = true
    pendingResizes.keep(only: [])
    for panel in popups.values {
      panel.parent?.removeChildWindow(panel)
      panel.close()
    }
    for window in windows.values {
      window.delegate = nil
      window.close()
    }
    popups = [:]
    windows = [:]
  }

  // MARK: Placement (R20)

  private func makePopup(_ info: WindowInfo) -> PopupPanel {
    let panel = PopupPanel(info: info)
    panel.remoteView.onMouse = { [weak self] in self?.session.send($0) }
    popups[info.id] = panel
    return panel
  }

  /// New windows beside the main window (the first batch) or the key detached one (A opened another).
  private func place(_ fresh: [DetachedWindow]) {
    guard !fresh.isEmpty else { return }
    let others = windows.values.filter { w in !fresh.contains { $0 === w } }
    let anchor = others.isEmpty ? main : (lastKey.flatMap { windows[$0] } ?? others.first)
    let screen = anchor?.screen ?? NSScreen.main
    guard let visible = screen?.visibleFrame else { return }
    let beside = anchor?.frame ?? CGRect(x: visible.midX, y: visible.maxY, width: 0, height: 0)
    let sizes = fresh.map { $0.frameRect(forContentRect: CGRect(origin: .zero, size: $0.contentSize)).size }
    for (window, frame) in zip(fresh, detachedFrames(contents: sizes, screen: visible, beside: beside)) {
      setFrame(window, frame)
    }
  }

  /// AppKit counts y up from the bottom of the primary screen; A's mapping counts it down from the top.
  private var primaryHeight: CGFloat { NSScreen.screens.first?.frame.maxY ?? 0 }

  /// Over its owner's picture wherever that is (`popupFrame`); left where it is with no owner.
  private func placePopup(_ panel: PopupPanel, over owner: DetachedWindow?) {
    guard let owner else { return }
    let info = panel.info, o = owner.info
    let parentContent = CanvasRect(x: o.rect.x, y: o.rect.y + o.titleBar, w: o.rect.w, h: o.rect.h - o.titleBar)
    let content = owner.contentRect(forFrameRect: owner.frame)
    let contentTopLeft = CGPoint(x: content.minX, y: primaryHeight - content.maxY)
    let f = popupFrame(popup: info.rect, parentContent: parentContent,
                       parentPicture: owner.pictureFit.offsetBy(dx: contentTopLeft.x, dy: contentTopLeft.y))
    setFrame(panel, NSRect(x: f.minX, y: primaryHeight - f.minY - f.height, width: f.width, height: f.height))
  }

  private func setFrame(_ window: NSWindow, _ frame: NSRect) {
    guard window.frame != frame else { return }
    placing = true
    window.setFrame(frame, display: true)
    placing = false
  }

  private func replacePopups(over owner: DetachedWindow) {
    for panel in popups.values where panel.parent === owner { placePopup(panel, over: owner) }
  }

  // MARK: What the user does to the windows (main thread, AppKit's delegate calls)

  func windowDidResize(_ notification: Notification) {
    guard let window = notification.object as? DetachedWindow, windows[window.info.id] === window else { return }
    replacePopups(over: window)
    // rapp's own placing, and drags until the mouse is up, send nothing.
    guard !placing, !window.inLiveResize else { return }
    pendingResizes.schedule(window.info.id, after: 0.3) { [weak self, weak window] in
      guard let self, let window else { return }
      self.sendResize(window)
    }
  }

  func windowDidEndLiveResize(_ notification: Notification) {
    guard let window = notification.object as? DetachedWindow else { return }
    pendingResizes.schedule(window.info.id, after: 0.3) { [weak self, weak window] in
      guard let self, let window else { return }
      self.sendResize(window)
    }
  }

  /// R12: only a resizable window, only a size A does not have already.
  private func sendResize(_ window: DetachedWindow) {
    guard !closed, windows[window.info.id] === window else { return }
    if let m = detachedResize(window.info, content: window.contentSize) { session.send(m) }
  }

  func windowDidBecomeKey(_ notification: Notification) {
    guard let window = notification.object as? DetachedWindow, windows[window.info.id] === window else { return }
    lastKey = window.info.id
    session.send(.focus(window.info.id))
  }

  /// The close button ends the session (like the stage's 「结束会话」); the windows go with it.
  func windowShouldClose(_ sender: NSWindow) -> Bool {
    session.close(reason: "quit")
    return false
  }
}
