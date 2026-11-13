import Foundation
import RappCore
import UniformTypeIdentifiers

/// Copies of A's clips held on B, numbered from 1 and never reused. Process-wide: a copy outlives the
/// session it came from. Main queue only; never logs.
public final class ClipCopies {
    private var items: [Int: ClipCopy] = [:]
    private var next = 1

    public init() {}

    public func add(_ c: ClipCopy) -> Int {
        let n = next
        next += 1
        items[n] = c
        return n
    }

    public func copy(_ n: Int) -> ClipCopy? { items[n] }

    public func drop(_ n: Int) { items[n] = nil }

    /// Puts copy `n` on `board`. False (nothing written) for an unknown number or a files copy with a missing file.
    public func write(_ n: Int, to board: LocalPasteboard) -> Bool {
        guard let c = items[n] else { return false }
        switch c {
        case let .text(t): board.write(text: t)
        case let .image(b): board.write(png: b)
        case let .data(uti, b): board.write(uti: uti, data: b)
        case let .files(urls):
            guard urls.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else { return false }
            board.write(files: urls)
        }
        return true
    }

    /// Writes copy `n` into the data dir (R18): text to `textDir/<stem>.md`; an image, other data or a files copy
    /// to `fileDir` (`<stem>.png`, `<stem>.<ext>`, a folder `<stem>/`). A taken name becomes `<stem>-2`, `-3`, ...
    /// Written under a `.tmp` name, then renamed. Nil for an unknown number. Never logs.
    public func save(_ n: Int, textDir: URL, fileDir: URL, stem: String) throws -> URL? {
        guard let c = items[n] else { return nil }
        let fm = FileManager.default
        let dir: URL, ext: String
        switch c {
        case .text: (dir, ext) = (textDir, "md")
        case .image: (dir, ext) = (fileDir, "png")
        case let .data(uti, _): (dir, ext) = (fileDir, UTType(uti)?.preferredFilenameExtension ?? "bin")
        case .files: (dir, ext) = (fileDir, "")
        }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        func target(_ k: Int) -> URL {
            let name = k == 1 ? stem : "\(stem)-\(k)"
            return dir.appendingPathComponent(ext.isEmpty ? name : "\(name).\(ext)")
        }
        var k = 1
        while fm.fileExists(atPath: target(k).path) { k += 1 }
        let final = target(k)
        let tmp = final.appendingPathExtension("tmp")
        try? fm.removeItem(at: tmp)
        do {
            switch c {
            case let .text(t): try Data(t.utf8).write(to: tmp)
            case let .image(b): try Data(b).write(to: tmp)
            case let .data(_, b): try Data(b).write(to: tmp)
            case let .files(urls):
                try fm.createDirectory(at: tmp, withIntermediateDirectories: false)
                for u in urls { try fm.copyItem(at: u, to: tmp.appendingPathComponent(u.lastPathComponent)) }
            }
            try fm.moveItem(at: tmp, to: final)
        } catch {
            try? fm.removeItem(at: tmp)
            throw error
        }
        return final
    }

    /// Reads a saved copy back as a new numbered copy: `.md` is text, `.png` an image, a folder a files copy
    /// (its entries by name, dot files skipped), anything else data. Nil if it cannot be read. Never logs.
    public func load(_ url: URL) -> (n: Int, kind: String)? {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return nil }
        if isDir.boolValue {
            guard let names = try? fm.contentsOfDirectory(atPath: url.path) else { return nil }
            let urls = names.filter { !$0.hasPrefix(".") }.sorted().map { url.appendingPathComponent($0) }
            return (add(.files(urls)), "files")
        }
        guard let data = try? Data(contentsOf: url) else { return nil }
        switch url.pathExtension.lowercased() {
        case "md":
            guard let t = String(data: data, encoding: .utf8) else { return nil }
            return (add(.text(t)), "text")
        case "png": return (add(.image([UInt8](data))), "image")
        default:
            let uti = UTType(filenameExtension: url.pathExtension)?.identifier ?? "public.data"
            return (add(.data(uti: uti, [UInt8](data))), "data")
        }
    }
}
