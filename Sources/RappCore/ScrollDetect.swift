import Foundation

/// Finds likely vertical scroll offsets between the old picture (after the
/// canvas move) and the new frame, for `FrameEncoder` to try as copy sources.
///
/// Rows are fingerprinted per 64 px column strip (the tile columns), so a
/// fixed side bar or scroll bar in some strips does not hide the scroll in the
/// others. Only strips with a changed tile that lie wholly inside the old
/// picture's columns are looked at. In each, every new row of a changed tile
/// whose fingerprint occurs in at most `maxRepeats` old rows votes for
/// `dy = oldRow - newRow` (`dy != 0`); rows of one colour do not vote. The
/// votes of all strips are added up. The offsets are only guesses: the
/// encoder checks every copy exactly.
struct ScrollDetector {
    /// A fingerprint seen in more old rows than this (repeated content) does not vote.
    static let maxRepeats = 4

    // Open-addressing table from fingerprint to the old rows that have it.
    private var keys = [UInt64]()
    private var counts = [Int32]()
    private var rows = [Int32]()
    private var votes = [Int32]()

    /// Up to `limit` offsets with the most votes, most first.
    ///
    /// `cur` and `old` are planes of `width` x `height` pixels of `bpp` bytes
    /// with rows `width * bpp` bytes apart. `changed[ty * cols + tx]` says
    /// which tiles changed; `cover` is the part of the canvas the old picture
    /// covers (old rows outside it do not count).
    mutating func candidates(cur: UnsafeBufferPointer<UInt8>, old: UnsafeBufferPointer<UInt8>, bpp: Int,
                             width: Int, height: Int, changed: [Bool],
                             cover: (x0: Int, y0: Int, x1: Int, y1: Int), limit: Int) -> [Int] {
        guard let curBase = cur.baseAddress, let oldBase = old.baseAddress,
              cover.y1 > cover.y0, cover.x1 > cover.x0 else { return [] }
        let cols = (width + tileSize - 1) / tileSize, tileRows = (height + tileSize - 1) / tileSize
        let stride = width * bpp
        var capacity = 1
        while capacity < 2 * height { capacity <<= 1 }
        if keys.count != capacity {
            keys = [UInt64](repeating: 0, count: capacity)
            counts = [Int32](repeating: 0, count: capacity)
            rows = [Int32](repeating: 0, count: capacity * ScrollDetector.maxRepeats)
        }
        votes = [Int32](repeating: 0, count: 2 * height + 1)
        let mask = capacity - 1

        for tx in 0..<cols {
            let x0 = tx * tileSize, tw = min(tileSize, width - x0)
            guard x0 >= cover.x0, x0 + tw <= cover.x1 else { continue }
            guard (0..<tileRows).contains(where: { changed[$0 * cols + tx] }) else { continue }
            let n = tw * bpp

            // The old rows of the strip, into the table.
            for i in 0..<capacity { counts[i] = 0 }
            for y in cover.y0..<cover.y1 {
                let f = ScrollDetector.fingerprint(oldBase + y * stride + x0 * bpp, n: n, bpp: bpp)
                guard f != 0 else { continue }
                var slot = Int(truncatingIfNeeded: f) & mask
                while counts[slot] != 0 && keys[slot] != f { slot = (slot + 1) & mask }
                let c = Int(counts[slot])
                keys[slot] = f
                counts[slot] = Int32(min(c + 1, ScrollDetector.maxRepeats + 1))
                if c < ScrollDetector.maxRepeats { rows[slot * ScrollDetector.maxRepeats + c] = Int32(y) }
            }

            // The new rows of the strip's changed tiles vote.
            for ty in 0..<tileRows where changed[ty * cols + tx] {
                let y0 = ty * tileSize
                for y in y0..<min(height, y0 + tileSize) {
                    let f = ScrollDetector.fingerprint(curBase + y * stride + x0 * bpp, n: n, bpp: bpp)
                    guard f != 0 else { continue }
                    var slot = Int(truncatingIfNeeded: f) & mask
                    while counts[slot] != 0 && keys[slot] != f { slot = (slot + 1) & mask }
                    let c = Int(counts[slot])
                    guard c > 0, c <= ScrollDetector.maxRepeats else { continue }
                    for k in 0..<c {
                        let dy = Int(rows[slot * ScrollDetector.maxRepeats + k]) - y
                        if dy != 0 { votes[dy + height] += 1 }
                    }
                }
            }
        }

        // The `limit` best offsets.
        var best = [(dy: Int, votes: Int32)]()
        for (i, v) in votes.enumerated() where v > 0 {
            if best.count == limit && v <= best[limit - 1].votes { continue }
            let at = best.firstIndex { v > $0.votes } ?? best.count
            best.insert((i - height, v), at: at)
            if best.count > limit { best.removeLast() }
        }
        return best.map(\.dy)
    }

    /// A 64-bit fingerprint of the `n` bytes at `p`, never 0; 0 when every
    /// pixel (`bpp` bytes, `bpp` dividing 8) is the same.
    @inline(__always)
    static func fingerprint(_ p: UnsafePointer<UInt8>, n: Int, bpp: Int) -> UInt64 {
        let raw = UnsafeRawPointer(p)
        let k: UInt64 = 0x9E37_79B9_7F4A_7C15
        var first: UInt64 = 0
        for i in 0..<bpp { first |= UInt64(p[i]) << UInt64(8 * i) }
        let pattern = bpp == 1 ? first &* 0x0101_0101_0101_0101 : bpp == 2 ? first &* 0x0001_0001_0001_0001
            : first &* 0x0000_0001_0000_0001
        var a: UInt64 = 0x243F_6A88_85A3_08D3, b: UInt64 = 0x1319_8A2E_0370_7344
        var c: UInt64 = 0xA409_3822_299F_31D0, d: UInt64 = 0x082E_FA98_EC4E_6C89
        var diff: UInt64 = 0
        var i = 0
        while i + 32 <= n {
            let w0 = raw.loadUnaligned(fromByteOffset: i, as: UInt64.self)
            let w1 = raw.loadUnaligned(fromByteOffset: i + 8, as: UInt64.self)
            let w2 = raw.loadUnaligned(fromByteOffset: i + 16, as: UInt64.self)
            let w3 = raw.loadUnaligned(fromByteOffset: i + 24, as: UInt64.self)
            a = (a ^ w0) &* k
            b = (b ^ w1) &* k
            c = (c ^ w2) &* k
            d = (d ^ w3) &* k
            diff |= (w0 ^ pattern) | (w1 ^ pattern) | (w2 ^ pattern) | (w3 ^ pattern)
            i += 32
        }
        while i + 8 <= n {
            let w = raw.loadUnaligned(fromByteOffset: i, as: UInt64.self)
            a = (a ^ w) &* k
            diff |= w ^ pattern
            i += 8
        }
        while i < n {
            // `i` is a multiple of 8 here plus whole pixels, so i % bpp is the byte within the pixel.
            let v = UInt64(p[i])
            b = (b ^ v) &* k
            diff |= v ^ (pattern >> UInt64(8 * (i % bpp)) & 0xFF)
            i += 1
        }
        if diff == 0 { return 0 }
        var h = a ^ (b << 17 | b >> 47) ^ (c << 31 | c >> 33) ^ (d << 47 | d >> 17) ^ UInt64(n)
        h = (h ^ (h >> 33)) &* 0xFF51_AFD7_ED55_8CCD
        h = (h ^ (h >> 33)) &* 0xC4CE_B9FE_1A85_EC53
        h ^= h >> 33
        return h | 1
    }
}
