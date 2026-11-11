import Foundation

public struct FileRef: Equatable {
    public var url: URL
    public var size: UInt64
    public var modified: Date
    public init(url: URL, size: UInt64, modified: Date) { self.url = url; self.size = size; self.modified = modified }
}

public enum ClipPayload: Equatable { case inline, bytes([UInt8]), files([FileRef]) }

public struct StoredClip: Equatable {
    public let id: UInt32
    public let info: ClipInfo
    public let payload: ClipPayload
}

/// A's per-session clipboard history: numbered from 1, newest 50 kept.
public final class ClipStore {
    public static let capacity = 50
    private var lastChange: Int
    private var nextID: UInt32 = 1
    private var clips: [StoredClip] = []

    public init(changeCount: Int) { lastChange = changeCount }

    /// True when this change should be recorded. Always remembers `changeCount` as seen.
    public func changed(changeCount: Int, targetFrontmost: Bool) -> Bool {
        let isNew = changeCount != lastChange
        lastChange = changeCount
        return isNew && targetFrontmost
    }

    public func noteOwnWrite(changeCount: Int) { lastChange = changeCount }

    @discardableResult
    public func add(_ info: ClipInfo, payload: ClipPayload) -> StoredClip {
        let clip = StoredClip(id: nextID, info: info, payload: payload)
        nextID += 1
        clips.append(clip)
        if clips.count > Self.capacity { clips.removeFirst(clips.count - Self.capacity) }
        return clip
    }

    public func clip(_ id: UInt32) -> StoredClip? { clips.first { $0.id == id } }
}

public struct TransferError: Error, Equatable {
    public let reason: String
    public init(_ reason: String) { self.reason = reason }
}

/// Reads one clip file (or in-memory item) in chunks of at most `chunkSize`.
public final class FetchSource {
    public let total: UInt64
    private var bytes: [UInt8]?
    private var handle: FileHandle?
    private var position: UInt64

    init(bytes: [UInt8], offset: UInt64) {
        self.bytes = bytes; total = UInt64(bytes.count); position = offset
    }
    init(handle: FileHandle, total: UInt64, offset: UInt64) throws {
        self.handle = handle; self.total = total; position = offset
        try handle.seek(toOffset: offset)
    }
    deinit { try? handle?.close() }

    /// Next chunk, or nil at the end.
    public func next() throws -> [UInt8]? {
        guard position < total else { return nil }
        let n = Int(min(UInt64(chunkSize), total - position))
        let chunk: [UInt8]
        if let bytes {
            chunk = Array(bytes[Int(position)..<Int(position) + n])
        } else {
            guard let handle, let data = try handle.read(upToCount: n), !data.isEmpty else { throw TransferError("file changed") }
            chunk = [UInt8](data)
        }
        position += UInt64(chunk.count)
        return chunk
    }
}

public enum ReceivedItem: Equatable { case text(String), image([UInt8]), data(uti: String, [UInt8]), file(URL) }

/// Receives one uploaded item: in memory for text/image/data, a `.rapp-part` file for files.
public final class PutSink {
    public private(set) var have: UInt64 = 0
    public let total: UInt64
    let kind: ClipKind
    let uti: String
    let name: String
    private let memory: Bool
    private var buffer: [UInt8] = []
    private var handle: FileHandle?
    private let partURL: URL?
    private let uploads: URL
    private let safeName: String
    private(set) var finalURL: URL?

    init(kind: ClipKind, uti: String, name: String, total: UInt64, uploads: URL) throws {
        self.kind = kind; self.uti = uti; self.name = name; self.total = total; self.uploads = uploads
        safeName = safeFileName(name)
        memory = kind != .files
        if memory {
            partURL = nil
        } else {
            try Self.ensureDir(uploads)
            let part = uploads.appendingPathComponent(uniqueName(safeName, existing: Self.existing(uploads)) + ".rapp-part")
            guard FileManager.default.createFile(atPath: part.path, contents: nil),
                  let h = try? FileHandle(forWritingTo: part) else { throw TransferError("write failed") }
            partURL = part; handle = h
            if total == 0 {
                do { try finish() } catch { discard(); throw error }
            }
        }
    }
    deinit { try? handle?.close() }

    static func ensureDir(_ dir: URL) throws {
        do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        catch { throw TransferError("write failed") }
    }
    /// Names in `dir`; a "<name>.rapp-part" also reserves "<name>". `excluding` is one part file's own name.
    static func existing(_ dir: URL, excluding own: String? = nil) -> Set<String> {
        var names = Set<String>()
        for n in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] where n != own {
            names.insert(n)
            if n.hasSuffix(".rapp-part") { names.insert(String(n.dropLast(".rapp-part".count))) }
        }
        return names
    }

    var isComplete: Bool { have == total }

    var received: ReceivedItem? {
        guard isComplete else { return nil }
        switch kind {
        case .text: return .text(String(decoding: buffer, as: UTF8.self))
        case .image: return .image(buffer)
        case .data: return .data(uti: uti, buffer)
        case .files: return finalURL.map { .file($0) }
        case .unsupported: return nil
        }
    }

    /// Appends bytes; true once everything has arrived (a file is then renamed to its final name).
    public func write(_ bytes: [UInt8]) throws -> Bool {
        let newHave = have + UInt64(bytes.count)
        guard newHave <= total else { throw TransferError("too large") }
        if memory {
            buffer += bytes
        } else if let handle {
            do {
                try handle.seek(toOffset: have)   // the file position is `have`, whatever a failed write left behind
                try handle.write(contentsOf: Data(bytes))
                if newHave == total { try handle.truncate(atOffset: total) }
            } catch { throw Self.writeError(error) }
            if newHave == total { try finish() }   // not complete until renamed; a retry rewrites this chunk
        }
        have = newHave
        return have == total
    }

    private func finish() throws {
        guard let partURL else { return }
        let final = uploads.appendingPathComponent(uniqueName(safeName, existing: Self.existing(uploads, excluding: partURL.lastPathComponent)))
        do { try FileManager.default.moveItem(at: partURL, to: final) }
        catch { throw TransferError("write failed") }
        try? handle?.close(); handle = nil
        finalURL = final
    }

    func discard() {
        try? handle?.close(); handle = nil
        if let partURL, finalURL == nil { try? FileManager.default.removeItem(at: partURL) }
    }

    static func writeError(_ error: Error) -> TransferError {
        let ns = error as NSError
        let full = (ns.domain == NSPOSIXErrorDomain && ns.code == Int(ENOSPC))
            || (ns.domain == NSCocoaErrorDomain && ns.code == NSFileWriteOutOfSpaceError)
        return TransferError(full ? "disk full" : "write failed")
    }
}

/// Serves fetches from the clip store and collects uploads. Use from one queue only.
public final class TransferStore {
    public let clips: ClipStore
    private let uploads: URL
    private let memoryLimit: Int
    private var sinks: [UInt32: PutSink] = [:]

    public init(clips: ClipStore, uploads: URL, memoryLimit: Int = 256 << 20) {
        self.clips = clips; self.uploads = uploads; self.memoryLimit = memoryLimit
    }

    public func fetch(clip: UInt32, file: UInt16, offset: UInt64) throws -> FetchSource {
        guard let stored = clips.clip(clip) else { throw TransferError("unknown clip") }
        switch (stored.info, stored.payload) {
        case (.image, .bytes(let b)), (.data, .bytes(let b)):
            guard file == 0, offset <= UInt64(b.count) else { throw TransferError("unknown clip") }
            return FetchSource(bytes: b, offset: offset)
        case (.files, .files(let refs)):
            guard Int(file) < refs.count else { throw TransferError("unknown clip") }
            let ref = refs[Int(file)]
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: ref.url.path),
                  (attrs[.size] as? NSNumber)?.uint64Value == ref.size,
                  (attrs[.modificationDate] as? Date) == ref.modified else { throw TransferError("file changed") }
            guard offset <= ref.size else { throw TransferError("unknown clip") }
            guard let h = try? FileHandle(forReadingFrom: ref.url) else { throw TransferError("file changed") }
            return try FetchSource(handle: h, total: ref.size, offset: offset)
        default:
            throw TransferError("unknown clip")
        }
    }

    public func put(item: UInt32, kind: ClipKind, uti: String, name: String, total: UInt64) throws -> PutSink {
        if kind == .unsupported { throw TransferError("not supported") }
        if let old = sinks[item] {
            if old.kind == kind, old.name == name, old.total == total { return old }
            old.discard()
            sinks[item] = nil
        }
        if kind != .files, total > UInt64(memoryLimit) { throw TransferError("too large") }
        let sink = try PutSink(kind: kind, uti: uti, name: name, total: total, uploads: uploads)
        sinks[item] = sink
        return sink
    }

    public func received(_ item: UInt32) -> ReceivedItem? { sinks[item]?.received }
}

/// Counts concurrent side connections.
public final class SideSlots {
    private let limit: Int
    private var used = 0
    public init(limit: Int = maxSideConnections) { self.limit = limit }
    public func take() -> Bool {
        guard used < limit else { return false }
        used += 1
        return true
    }
    public func release() { used = max(0, used - 1) }
}
