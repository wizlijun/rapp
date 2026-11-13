import Foundation

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
}
