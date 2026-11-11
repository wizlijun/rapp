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

// MARK: - Pure helpers (spec §2.3, §2.5, §4.1, §4.2, §4.5, §6)

public let typeFileURL = "public.file-url"
public let typePNG = "public.png"
public let typeTIFF = "public.tiff"
public let typeUTF8Text = "public.utf8-plain-text"

/// Seconds to wait before re-trying a failed side-connection transfer.
public let retryDelays: [TimeInterval] = [1, 2, 4]

public enum ClipSource: Equatable { case files, image, text, data(uti: String), none }

/// Picks what a pasteboard holds by priority: files, image, text, then the first other type.
public func clipKind(types: [String]) -> ClipSource {
    if types.contains(typeFileURL) { return .files }
    if types.contains(typePNG) || types.contains(typeTIFF) { return .image }
    if types.contains(typeUTF8Text) { return .text }
    if let first = types.first { return .data(uti: first) }
    return .none
}

/// Cuts text to `maxClipText` UTF-8 bytes on a character boundary.
public func clipText(_ s: String) -> (text: String, truncated: Bool) {
    let u = s.utf8
    guard u.count > maxClipText else { return (s, false) }
    var idx = u.index(u.startIndex, offsetBy: maxClipText)
    while idx > u.startIndex, idx.samePosition(in: s.unicodeScalars) == nil { idx = u.index(before: idx) }
    return (String(s[..<idx]), true)
}

public enum PasteDecision: Equatable {
    case files, image, inlineText(String), textChunk(String), data(uti: String), nothing
}

public func pasteDecision(types: [String], text: String?) -> PasteDecision {
    switch clipKind(types: types) {
    case .files: return .files
    case .image: return .image
    case .data(let uti): return .data(uti: uti)
    case .none: return .nothing
    case .text:
        guard let text else { return .nothing }
        return text.count < 800 && lineCount(text) < 10 ? .inlineText(text) : .textChunk(text)
    }
}

public enum ComposerPiece: Equatable { case text(String), chunk(Int) }

public struct ComposerItem: Equatable {
    public enum Content: Equatable { case text(String), chunk(Int) }
    public var content: Content
    /// UTF-16 offset in the editor text where this item ends.
    public var end: Int
    public init(content: Content, end: Int) { self.content = content; self.end = end }
}

/// Splits editor content into trimmed text runs and chunk references (a chunk is 1 UTF-16 unit).
public func composerItems(_ pieces: [ComposerPiece]) -> [ComposerItem] {
    var items: [ComposerItem] = []
    var offset = 0
    var run = ""
    func flush() {
        let t = run.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { items.append(ComposerItem(content: .text(t), end: offset)) }
        run = ""
    }
    for p in pieces {
        switch p {
        case .text(let s):
            run += s
            offset += s.utf16.count
        case .chunk(let n):
            flush()
            offset += 1
            items.append(ComposerItem(content: .chunk(n), end: offset))
        }
    }
    flush()
    return items
}

public func needsUpload(_ text: String) -> Bool { text.utf8.count >= inlinePasteLimit }

public func lineCount(_ text: String) -> Int { text.reduce(1) { $1 == "\n" ? $0 + 1 : $0 } }

/// Keeps only the last path component, without ':' or leading dots; falls back to "file".
public func safeFileName(_ raw: String) -> String {
    let last = raw.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? ""
    var name = last.replacingOccurrences(of: ":", with: "")
    while name.hasPrefix(".") { name.removeFirst() }
    return name.isEmpty ? "file" : name
}

/// "app.log" -> "app (2).log", "app (3).log", … until unused.
public func uniqueName(_ name: String, existing: Set<String>) -> String {
    guard existing.contains(name) else { return name }
    var base = name, ext = ""
    if let dot = name.lastIndex(of: "."), dot != name.startIndex {
        base = String(name[..<dot]); ext = String(name[dot...])
    }
    var n = 2
    while existing.contains("\(base) (\(n))\(ext)") { n += 1 }
    return "\(base) (\(n))\(ext)"
}

public func resumeOffset(partSize: UInt64, total: UInt64) -> UInt64 { partSize > total ? 0 : partSize }

public func formatSize(_ bytes: UInt64) -> String {
    if bytes < 1024 { return "\(bytes) B" }
    var value = Double(bytes) / 1024
    var unit = 1
    let units = ["B", "KB", "MB", "GB"]
    while value >= 1024, unit < 3 { value /= 1024; unit += 1 }
    if unit >= 2, value < 9.95 { return String(format: "%.1f %@", value, units[unit]) }
    return "\(Int(value.rounded())) \(units[unit])"
}

public func historyTitle(_ info: ClipInfo) -> String {
    switch info {
    case .text(let s, _):
        let flat = String(s.map { $0 == "\n" || $0 == "\r" || $0 == "\t" ? " " : $0 })
        return "文字 · " + String(flat.prefix(30)) + (flat.count > 30 ? "…" : "")
    case .image(let w, let h, let bytes):
        return "图片 \(w)×\(h) · \(formatSize(bytes))"
    case .files(let files):
        if files.count == 1 { return "文件 \(files[0].name) · \(formatSize(files[0].bytes))" }
        return "\(files.count) 个文件 · \(formatSize(files.reduce(0) { $0 + $1.bytes }))"
    case .data(let uti, let bytes):
        return "数据 \(uti) · \(formatSize(bytes))"
    case .unsupported(let label):
        return label
    }
}

public enum Chip: Equatable {
    case text(n: Int, lines: Int), image(n: Int, width: Int, height: Int)
    case data(n: Int, uti: String, bytes: UInt64), file(name: String, bytes: UInt64)
}

public func chipLabel(_ chip: Chip) -> String {
    switch chip {
    case .text(let n, let lines): return "[贴入文字 #\(n) +\(lines) 行]"
    case .image(let n, let w, let h): return "[图片 #\(n) \(w)×\(h)]"
    case .data(let n, let uti, let bytes): return "[数据 #\(n) \(uti) \(formatSize(bytes))]"
    case .file(let name, let bytes): return "[文件 \(name) \(formatSize(bytes))]"
    }
}

/// Tracks one burst of pastes on A: save the clipboard once, restore 2 s after the last paste.
public struct PasteSession {
    public static let restoreDelay: TimeInterval = 2
    private var saved = false
    private var inFlight = 0
    private var lastFinish: TimeInterval = 0
    public init() {}

    /// True when the caller must save the clipboard first.
    public mutating func pasteStarted(now: TimeInterval) -> Bool {
        inFlight += 1
        guard !saved else { return false }
        saved = true
        return true
    }
    public mutating func pasteFinished(now: TimeInterval) {
        inFlight = max(0, inFlight - 1)
        lastFinish = now
    }
    public func restoreDue(now: TimeInterval) -> Bool {
        saved && inFlight == 0 && now - lastFinish >= Self.restoreDelay
    }
    public mutating func restored() { saved = false; inFlight = 0 }
}
