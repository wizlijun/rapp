import AppKit
import Foundation
import RappCore

/// Cuts `s` to at most `limit` UTF-8 bytes on a character boundary, so a
/// strange pasteboard can never trip the wire format's string limit.
func fitted(_ s: String, limit: Int = 1024) -> String {
    guard s.utf8.count > limit else { return s }
    var out = ""
    var used = 0
    for ch in s {
        let n = String(ch).utf8.count
        if used + n > limit { break }
        out.append(ch)
        used += n
    }
    return out
}

/// Records what is copied on A while the session's app is in front (spec §3.1).
/// The pasteboard is read on the main queue every 0.3 s; the store and the
/// callback belong to the session queue.
final class ClipboardWatcher {
    private static let memoryLimit = 64 << 20

    private let pid: pid_t
    private let store: ClipStore
    private let queue: DispatchQueue
    private let log: (String) -> Void
    private let onClip: (UInt32, ClipInfo) -> Void
    private var timer: DispatchSourceTimer?
    /// Session queue only.
    private var stopped = false

    init(pid: pid_t, store: ClipStore, queue: DispatchQueue, log: @escaping (String) -> Void,
         onClip: @escaping (UInt32, ClipInfo) -> Void) {
        self.pid = pid
        self.store = store
        self.queue = queue
        self.log = log
        self.onClip = onClip
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.3, repeating: 0.3)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    /// Session queue.
    func stop() {
        stopped = true
        timer?.cancel()
        timer = nil
    }

    /// Session queue: A itself changed the pasteboard (a paste), so that change is not a copy.
    func noteOwnWrite(changeCount: Int) { store.noteOwnWrite(changeCount: changeCount) }

    // MARK: Main queue

    private func tick() {
        let count = NSPasteboard.general.changeCount
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
        queue.async { [self] in
            guard !stopped, store.changed(changeCount: count, targetFrontmost: frontmost) else { return }
            DispatchQueue.main.async { [self] in read(changeCount: count) }
        }
    }

    private func read(changeCount: Int) {
        let pb = NSPasteboard.general
        guard !isConcealedClip(types: (pb.types ?? []).map(\.rawValue)),
              let (info, payload) = capture(pb), pb.changeCount == changeCount else { return }
        queue.async { [self] in
            guard !stopped else { return }
            let clip = store.add(info, payload: payload)
            onClip(clip.id, info)
        }
    }

    private func capture(_ pb: NSPasteboard) -> (ClipInfo, ClipPayload)? {
        let types = (pb.types ?? []).map(\.rawValue)
        switch clipKind(types: types) {
        case .none:
            return nil
        case .files:
            return captureFiles(pb)
        case .image:
            return captureImage(pb)
        case .text:
            guard let s = pb.string(forType: NSPasteboard.PasteboardType(typeUTF8Text)), !s.isEmpty else { return nil }
            let (text, truncated) = clipText(s)
            return (.text(text, truncated: truncated), .inline)
        case let .data(uti):
            guard let data = pb.data(forType: NSPasteboard.PasteboardType(uti)) else { return nil }
            guard data.count < Self.memoryLimit else {
                log("clipboard data \(uti) is too large to keep (\(data.count) bytes)")
                return nil
            }
            return (.data(uti: fitted(uti), bytes: UInt64(data.count)), .bytes([UInt8](data)))
        }
    }

    private func captureFiles(_ pb: NSPasteboard) -> (ClipInfo, ClipPayload)? {
        let urls = (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        guard !urls.isEmpty else { return nil }
        if urls.count > maxClipFiles { return (.unsupported("文件太多（不支持）"), .inline) }
        var refs: [FileRef] = []
        for url in urls {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let modified = attrs[.modificationDate] as? Date else { return nil }
            if (attrs[.type] as? FileAttributeType) == .typeDirectory { return (.unsupported("文件夹（不支持）"), .inline) }
            let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
            refs.append(FileRef(url: url, size: size, modified: modified))
        }
        let files = refs.map { ClipFile(name: fitted($0.url.lastPathComponent), bytes: $0.size) }
        return (.files(files), .files(refs))
    }

    private func captureImage(_ pb: NSPasteboard) -> (ClipInfo, ClipPayload)? {
        let tiff = pb.data(forType: NSPasteboard.PasteboardType(typeTIFF))
        guard let source = pb.data(forType: NSPasteboard.PasteboardType(typePNG)) ?? tiff,
              let rep = NSBitmapImageRep(data: source) else { return nil }
        let png: Data
        if pb.data(forType: NSPasteboard.PasteboardType(typePNG)) != nil {
            png = source
        } else if let converted = rep.representation(using: .png, properties: [:]) {
            png = converted
        } else {
            return nil
        }
        guard png.count < Self.memoryLimit else {
            log("clipboard image is too large to keep (\(png.count) bytes)")
            return nil
        }
        let info = ClipInfo.image(width: UInt16(clamping: rep.pixelsWide), height: UInt16(clamping: rep.pixelsHigh),
                                  bytes: UInt64(png.count))
        return (info, .bytes([UInt8](png)))
    }
}
