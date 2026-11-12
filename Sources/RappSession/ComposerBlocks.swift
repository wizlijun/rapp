import Foundation
import RappCore

/// What a block (chip) in the composer stands for.
public enum ChipPayload {
    case text(String)
    case image(png: [UInt8], width: Int, height: Int)
    case data(uti: String, [UInt8])
    case file(URL, bytes: UInt64)
}

/// The numbers of items uploaded and pastes sent, one counter each per client process (starting at 1).
public final class SendCounters {
    private var item: UInt32 = 0
    private var seq: UInt32 = 0

    public init() {}

    public func nextItem() -> UInt32 { item += 1; return item }
    public func nextSeq() -> UInt32 { seq += 1; return seq }
}

/// The blocks of one composer: what each stands for, its block number (from 1, in the order added; labels count per kind)
/// and the A-side item number once uploaded.
public final class ComposerBlocks {
    private var payloads: [Int: ChipPayload] = [:]
    private var uploaded: [Int: UInt32] = [:]
    private var next = 0
    /// Each block's number among the blocks of its kind (text, image, data), from 1; they never go down.
    private var kindNumbers: [Int: Int] = [:]
    private var textCount = 0, imageCount = 0, dataCount = 0

    public init() {}

    /// Stores the payload; returns its block number.
    public func add(_ p: ChipPayload) -> Int {
        next += 1
        payloads[next] = p
        switch p {
        case .text: textCount += 1; kindNumbers[next] = textCount
        case .image: imageCount += 1; kindNumbers[next] = imageCount
        case .data: dataCount += 1; kindNumbers[next] = dataCount
        case .file: break
        }
        return next
    }

    public func payload(_ n: Int) -> ChipPayload? { payloads[n] }

    public func remove(_ n: Int) {
        payloads[n] = nil
        uploaded[n] = nil
        kindNumbers[n] = nil
    }

    /// Forgets every block not in `numbers`.
    public func keep(only numbers: Set<Int>) {
        payloads = payloads.filter { numbers.contains($0.key) }
        uploaded = uploaded.filter { numbers.contains($0.key) }
        kindNumbers = kindNumbers.filter { numbers.contains($0.key) }
    }

    public func uploadedItem(_ n: Int) -> UInt32? { uploaded[n] }

    public func setUploadedItem(_ item: UInt32, for n: Int) { uploaded[n] = item }

    /// The text shown on the block.
    public func label(_ n: Int) -> String? {
        guard let payload = payloads[n] else { return nil }
        let k = kindNumbers[n] ?? n
        switch payload {
        case let .text(text): return chipLabel(.text(n: k, lines: lineCount(text)))
        case let .image(_, width, height): return chipLabel(.image(n: k, width: width, height: height))
        case let .data(uti, bytes): return chipLabel(.data(n: k, uti: uti, bytes: UInt64(bytes.count)))
        case let .file(url, bytes): return chipLabel(.file(name: url.lastPathComponent, bytes: bytes))
        }
    }
}
