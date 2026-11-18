import RappCore
#if canImport(AppKit)
import AppKit

/// B's own clipboard. NSPasteboard is not thread-safe, and every session runs on its own queue:
/// two sessions taking a clip at once crashed inside AppKit (2026-11-18). So every touch of the
/// board runs on the main thread. Nothing on main ever waits for a session queue, so `sync` is safe.
public final class LocalPasteboard {
    private let board: NSPasteboard

    public init(board: NSPasteboard = .general) { self.board = board }

    private func onMain<T>(_ body: () -> T) -> T {
        Thread.isMainThread ? body() : DispatchQueue.main.sync(execute: body)
    }

    public func write(text: String) {
        onMain {
            board.clearContents()
            board.setString(text, forType: .string)
        }
    }

    /// Writes `text` unless the board already holds it, in one step on main.
    public func follow(text: String) {
        onMain {
            if board.string(forType: .string) != text {
                board.clearContents()
                board.setString(text, forType: .string)
            }
        }
    }

    public func write(png: [UInt8]) { write(uti: typePNG, data: png) }

    public func write(uti: String, data: [UInt8]) {
        onMain {
            board.clearContents()
            board.setData(Data(data), forType: NSPasteboard.PasteboardType(uti))
        }
    }

    public func write(files: [URL]) {
        onMain {
            board.clearContents()
            board.writeObjects(files as [NSURL])
        }
    }

    public var types: [String] { onMain { board.types?.map(\.rawValue) ?? [] } }

    public var string: String? { onMain { board.string(forType: .string) } }

    public func fileURLs() -> [URL] {
        onMain { board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? [] }
    }

    /// The image as PNG with its pixel size, from PNG data or by converting TIFF.
    public func imagePNG() -> (png: [UInt8], width: Int, height: Int)? {
        let (png0, tiff) = onMain { () -> (Data?, Data?) in
            let png = board.data(forType: NSPasteboard.PasteboardType(typePNG))
            return (png, png == nil ? board.data(forType: NSPasteboard.PasteboardType(typeTIFF)) : nil)
        }
        var png = png0
        if png == nil, let tiff {
            png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        }
        guard let png, let rep = NSBitmapImageRep(data: png) else { return nil }
        return ([UInt8](png), rep.pixelsWide, rep.pixelsHigh)
    }

    public func data(uti: String) -> [UInt8]? {
        onMain { board.data(forType: NSPasteboard.PasteboardType(uti)).map { [UInt8]($0) } }
    }
}
#else
import UIKit

/// B's own clipboard (iOS). Reading it from code shows the system's paste prompt (spec 2026-11-17 §8.6).
public final class LocalPasteboard {
    private let board: UIPasteboard

    public init(board: UIPasteboard = .general) { self.board = board }

    public func write(text: String) { board.string = text }

    /// Writes `text` unless the board already holds it.
    public func follow(text: String) { if board.string != text { board.string = text } }

    public func write(png: [UInt8]) { write(uti: typePNG, data: png) }

    public func write(uti: String, data: [UInt8]) { board.setData(Data(data), forPasteboardType: uti) }

    public func write(files: [URL]) { board.urls = files }

    public var types: [String] { board.types }

    public var string: String? { board.string }

    public func fileURLs() -> [URL] { (board.urls ?? []).filter(\.isFileURL) }

    /// The image as PNG with its pixel size.
    public func imagePNG() -> (png: [UInt8], width: Int, height: Int)? {
        guard let image = board.image, let png = image.pngData(), let cg = image.cgImage else { return nil }
        return ([UInt8](png), cg.width, cg.height)
    }

    public func data(uti: String) -> [UInt8]? { board.data(forPasteboardType: uti).map { [UInt8]($0) } }
}
#endif
