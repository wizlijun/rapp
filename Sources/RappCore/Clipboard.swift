import Foundation

/// What a clipboard entry holds (spec §2.2). `put` only accepts 0...3.
public enum ClipKind: UInt8, Sendable { case text = 0, image = 1, files = 2, data = 3, unsupported = 4 }

public struct ClipFile: Equatable, Sendable {
    public var name: String
    public var bytes: UInt64
    public init(name: String, bytes: UInt64) { self.name = name; self.bytes = bytes }
}

/// One clipboard entry as announced by A.
public enum ClipInfo: Equatable, Sendable {
    case text(String, truncated: Bool)
    case image(width: UInt16, height: UInt16, bytes: UInt64)
    case files([ClipFile])
    case data(uti: String, bytes: UInt64)
    case unsupported(String)
}

/// Where a `paste` takes its content from: text carried in the message, or an uploaded item.
public enum PasteSource: Equatable, Sendable { case text(String), item(UInt32) }

public let maxClipText = 1 << 20
public let maxClipFiles = 100
/// A `paste` carries text inline only below this many UTF-8 bytes.
public let inlinePasteLimit = 60_000
public let chunkSize = 256 * 1024
public let maxSideConnections = 4
