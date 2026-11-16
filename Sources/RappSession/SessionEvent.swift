import CoreGraphics
import Foundation
import RappCore

/// One A window as the GUI shows it: its table entry and the part of its content the latest picture covers.
public struct SessionWindow: Equatable {
    public let info: WindowInfo
    public let visible: CGRect
    public init(info: WindowInfo, visible: CGRect) {
        self.info = info
        self.visible = visible
    }
}

/// One entry of A's clipboard history, as the GUI lists it.
public struct ClipRow: Equatable {
    public let id: UInt32
    public let title: String
    public let pickable: Bool
    /// `text|image|files|data|unsupported`.
    public let kind: String
    public init(id: UInt32, title: String, pickable: Bool, kind: String) {
        self.id = id; self.title = title; self.pickable = pickable; self.kind = kind
    }
}

/// A composer block the runner holds (pasted image, long text, file…), as the GUI shows it.
public struct BlockChip: Equatable {
    public let n: Int
    public let label: String
    /// `text`, `image`, `data` or `file`.
    public let kind: String
    /// Size of the content: UTF-8 length for text, the PNG/data length, the file size.
    public let bytes: Int
    /// The full text; only for pasted long text (images, data and files never carry content).
    public let text: String?
    /// The file name without path; only for files.
    public let name: String?
    public init(n: Int, label: String, kind: String = "data", bytes: Int = 0, text: String? = nil, name: String? = nil) {
        self.n = n; self.label = label; self.kind = kind; self.bytes = bytes; self.text = text; self.name = name
    }
}

/// What a paste, attach or clipboard insert produced: text for the editor, new blocks, a line to show, or nothing.
public enum PasteResult: Equatable {
    case text(String), blocks([BlockChip]), status(String), nothing
}

/// What the composer tells the GUI.
public enum ComposerEvent: Equatable {
    /// A send round started or ended.
    case sending(Bool)
    /// The round ended: `sent` leading pieces went into A; `failure` is nil when all went, else the line to
    /// show ("" = the transfer status already says why).
    case done(sent: Int, failure: String?)
    /// Something for the editor that the GUI did not ask for (a clip's 「插入」).
    case insert(PasteResult)
}

/// What an `EmbeddedSession` tells its runner. Delivered on the session's queue.
public enum SessionEvent: Equatable {
    case ready(appName: String)
    case windows([SessionWindow])
    case surfaces([UInt32])
    case traffic(bytesPerSecond: Int, frames: Int)
    case clips([ClipRow])
    case menu([MenuItem])
    case transferStatus(String?)
    case transferProgress(TransferProgress)
    case composer(ComposerEvent)
    /// A refused a key, click or paste because another device is operating it; the link stays up.
    case inputBlocked(by: String)
    /// A's traffic-saving level changed (0 = B's own pick; v9 hosts send 1 and 2, v7 and v8 only 2).
    case saving(level: Int)
    /// The whole path's round trip, from a `ping` B sent to A.
    case rtt(ms: Int)
    /// Two pings in a row went unanswered with nothing else from A (true), or A is heard again (false).
    case stalled(Bool)
    /// A's selected input source (v8 hosts); `ascii`: a plain keyboard layout, not an input method.
    case inputSource(id: String, name: String, ascii: Bool)
    /// A's screen is locked (v10): input reaches only the lock screen.
    case screenLocked(Bool)
    /// Which parts of a window have focus (v12); no rects means the whole window.
    case focusRegion(window: UInt32, rects: [CanvasRect])
    /// A press was dropped under another process's window on A (v13); `dismissable`: B may ask A to close it.
    case covered(id: UInt32, name: String, bundleID: String, dismissable: Bool)
    /// Another app came to the front on A right after this session's input (v13).
    case appOpened(bundleID: String, name: String)
    /// A's keyboard focus is (true) or is no longer (false) in a password field (v13).
    case secureFocus(Bool)
    /// The link dropped (or A sent garbage): the last pictures stay; `closed` follows when the GUI ends the session.
    case disconnected(reason: String)
    /// The session ended and its pictures are released.
    case closed(reason: String)
}
