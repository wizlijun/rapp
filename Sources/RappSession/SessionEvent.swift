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
    public init(id: UInt32, title: String, pickable: Bool) {
        self.id = id; self.title = title; self.pickable = pickable
    }
}

/// What the composer is doing (filled in by the composer task).
public enum ComposerEvent: Equatable {
    case sending(Bool)
}

/// What an `EmbeddedSession` tells its runner. Delivered on the session's queue.
public enum SessionEvent: Equatable {
    case ready(appName: String)
    case windows([SessionWindow])
    case surfaces([UInt32])
    case traffic(bytesPerSecond: Int)
    case clips([ClipRow])
    case menu([MenuItem])
    case transfer(String?)
    case composer(ComposerEvent)
    case closed(reason: String)
}
