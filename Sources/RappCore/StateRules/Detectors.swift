import Foundation

// MARK: - Text

public protocol TextReader: AnyObject {
    /// Lines recognised in `rect` of `image`. Runs on the engine's queue; may take tens of milliseconds.
    func lines(in image: RuleImage, rect: RuleRect) -> [String]
}

/// Text is read at most this often (seconds), and only when the region changed.
public let textEvery: TimeInterval = 2

/// `*` in a pattern is a wildcard and the whole line must match. Without `*`: an all-ASCII pattern must
/// appear as a whole word (neighbours are not letters or digits); anything else (CJK) is a substring.
/// Case-insensitive; lines are trimmed first.
public func textMatches(_ patterns: [String], lines: [String]) -> Bool {
    let ls = lines.map { Array($0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) }
    for p in patterns {
        let pat = Array(p.lowercased())
        if pat.isEmpty { continue }
        for l in ls {
            if pat.contains("*") { if globMatch(pat, l) { return true } }
            else if pat.allSatisfy({ $0.isASCII }) { if containsWord(l, pat) { return true } }
            else if contains(l, pat) { return true }
        }
    }
    return false
}

private func globMatch(_ p: [Character], _ s: [Character]) -> Bool {
    var pi = 0, si = 0, star = -1, mark = 0
    while si < s.count {
        if pi < p.count, p[pi] == "*" { star = pi; mark = si; pi += 1 }
        else if pi < p.count, p[pi] == s[si] { pi += 1; si += 1 }
        else if star >= 0 { pi = star + 1; mark += 1; si = mark }
        else { return false }
    }
    while pi < p.count, p[pi] == "*" { pi += 1 }
    return pi == p.count
}

private func contains(_ s: [Character], _ p: [Character]) -> Bool {
    guard p.count <= s.count else { return false }
    for i in 0...(s.count - p.count) where Array(s[i..<(i + p.count)]) == p { return true }
    return false
}

private func containsWord(_ s: [Character], _ p: [Character]) -> Bool {
    guard p.count <= s.count else { return false }
    for i in 0...(s.count - p.count) where Array(s[i..<(i + p.count)]) == p {
        let before = i == 0 || !(s[i - 1].isLetter || s[i - 1].isNumber)
        let end = i + p.count
        let after = end == s.count || !(s[end].isLetter || s[end].isNumber)
        if before && after { return true }
    }
    return false
}

// MARK: - Colour

extension ColorRange {
    public func contains(_ c: HSL) -> Bool {
        guard hueContains(c.h) else { return false }
        if let s, !s.contains(c.s) { return false }
        if let l, !l.contains(c.l) { return false }
        return !(c.h.isNaN || c.s.isNaN || c.l.isNaN)
    }
}

// MARK: - Shape

public enum ShapeName: String { case square, dot, ring, arrow, other, none }

private typealias RGB = (r: UInt8, g: UInt8, b: UInt8)

private func clip(_ r: RuleRect, _ image: RuleImage) -> RuleRect? {
    let x1 = r.x.addingReportingOverflow(r.w), y1 = r.y.addingReportingOverflow(r.h)
    let x0 = max(0, r.x), y0 = max(0, r.y)
    let ex = min(image.width, x1.overflow ? Int.max : x1.partialValue)
    let ey = min(image.height, y1.overflow ? Int.max : y1.partialValue)
    guard r.w > 0, r.h > 0, ex > x0, ey > y0 else { return nil }
    return RuleRect(x: x0, y: y0, w: ex - x0, h: ey - y0)
}

private func median(_ a: [UInt8]) -> UInt8 { a.sorted()[a.count / 2] }

/// Per-channel median of the 1-point ring around `r` (inside `r` when it touches the image edge).
private func baseColor(_ image: RuleImage, _ r: RuleRect) -> RGB {
    let interior = r.x > 0 && r.y > 0 && r.maxX < image.width && r.maxY < image.height
    let b = interior ? RuleRect(x: r.x - 1, y: r.y - 1, w: r.w + 2, h: r.h + 2) : r
    var rs: [UInt8] = [], gs: [UInt8] = [], bs: [UInt8] = []
    func add(_ x: Int, _ y: Int) { let p = image.rgb(x, y); rs.append(p.r); gs.append(p.g); bs.append(p.b) }
    for x in b.x..<b.maxX { add(x, b.y); add(x, b.maxY - 1) }
    for y in stride(from: b.y + 1, to: b.maxY - 1, by: 1) { add(b.x, y); add(b.maxX - 1, y) }
    return (median(rs), median(gs), median(bs))
}

private struct Block { var points: [Int]; var x0, y0, x1, y1: Int; var w: Int { x1 - x0 + 1 }; var h: Int { y1 - y0 + 1 } }

/// Largest 4-connected block of `mask` (a gw x gh grid); first found wins ties.
private func largestBlock(_ mask: [Bool], gw: Int, gh: Int) -> Block? {
    var seen = [Bool](repeating: false, count: mask.count)
    var best: Block?
    var stack: [Int] = []
    for start in 0..<mask.count where mask[start] && !seen[start] {
        var blk = Block(points: [], x0: start % gw, y0: start / gw, x1: start % gw, y1: start / gw)
        seen[start] = true; stack.append(start)
        while let i = stack.popLast() {
            let x = i % gw, y = i / gw
            blk.points.append(i)
            blk.x0 = min(blk.x0, x); blk.x1 = max(blk.x1, x); blk.y0 = min(blk.y0, y); blk.y1 = max(blk.y1, y)
            if x > 0, mask[i - 1], !seen[i - 1] { seen[i - 1] = true; stack.append(i - 1) }
            if x + 1 < gw, mask[i + 1], !seen[i + 1] { seen[i + 1] = true; stack.append(i + 1) }
            if y > 0, mask[i - gw], !seen[i - gw] { seen[i - gw] = true; stack.append(i - gw) }
            if y + 1 < gh, mask[i + gw], !seen[i + gw] { seen[i + gw] = true; stack.append(i + gw) }
        }
        if best == nil || blk.points.count > best!.points.count { best = blk }
    }
    return best
}

private func medianColor(_ image: RuleImage, points: [Int], gw: Int, ox: Int, oy: Int) -> RGB {
    var rs: [UInt8] = [], gs: [UInt8] = [], bs: [UInt8] = []
    rs.reserveCapacity(points.count); gs.reserveCapacity(points.count); bs.reserveCapacity(points.count)
    for i in points { let p = image.rgb(ox + i % gw, oy + i / gw); rs.append(p.r); gs.append(p.g); bs.append(p.b) }
    return (median(rs), median(gs), median(bs))
}

/// The enclosed hole of `c` is round (aspect 0.7...1.43, fill 0.6..<0.88) and at least half as wide as `c`.
private func isRing(_ c: Block, mask: [Bool], gw: Int) -> Bool {
    let w = c.w, h = c.h
    var inC = [Bool](repeating: false, count: w * h)
    for i in c.points { inC[(i / gw - c.y0) * w + (i % gw - c.x0)] = true }
    var outside = [Bool](repeating: false, count: w * h)
    var stack: [Int] = []
    func push(_ x: Int, _ y: Int) { let i = y * w + x; if !inC[i], !outside[i] { outside[i] = true; stack.append(i) } }
    for x in 0..<w { push(x, 0); push(x, h - 1) }
    for y in 0..<h { push(0, y); push(w - 1, y) }
    while let i = stack.popLast() {
        let x = i % w, y = i / w
        if x > 0 { push(x - 1, y) }; if x + 1 < w { push(x + 1, y) }
        if y > 0 { push(x, y - 1) }; if y + 1 < h { push(x, y + 1) }
    }
    let holes = (0..<w * h).map { !inC[$0] && !outside[$0] }
    guard let hole = largestBlock(holes, gw: w, gh: h) else { return false }
    let aspect = Double(hole.w) / Double(hole.h)
    let fill = Double(hole.points.count) / Double(hole.w * hole.h)
    return aspect >= 0.7 && aspect <= 1.43 && fill >= 0.6 && fill < 0.88 && Double(hole.w) >= 0.5 * Double(w)
}

public func shape(in image: RuleImage, rect: RuleRect) -> (name: ShapeName, score: Double) {
    guard let r = clip(rect, image) else { return (.none, 0) }
    let base = baseColor(image, r)
    var mask = [Bool](repeating: false, count: r.w * r.h)
    for y in 0..<r.h { for x in 0..<r.w where colorDistance(image.rgb(r.x + x, r.y + y), base) >= blobContrast { mask[y * r.w + x] = true } }
    guard let c = largestBlock(mask, gw: r.w, gh: r.h) else { return (.none, 0) }

    var k = c, gw = r.w
    // Container: a big block with a different-coloured thing inside it; judge the inside.
    // A ring (round hole, thin wall) is not a container: its hole is the page showing through.
    let cIsRing = isRing(c, mask: mask, gw: r.w)
    if !cIsRing, Double(c.w) >= 0.75 * Double(r.w), Double(c.h) >= 0.75 * Double(r.h) {
        let ix = Int((0.2 * Double(c.w)).rounded()), iy = Int((0.2 * Double(c.h)).rounded())
        let iw = c.w - 2 * ix, ih = c.h - 2 * iy
        if iw > 0, ih > 0 {
            let bg = medianColor(image, points: c.points, gw: r.w, ox: r.x, oy: r.y)
            var inner = [Bool](repeating: false, count: iw * ih)
            var n = 0
            for y in 0..<ih { for x in 0..<iw
                where colorDistance(image.rgb(r.x + c.x0 + ix + x, r.y + c.y0 + iy + y), bg) >= blobContrast {
                inner[y * iw + x] = true; n += 1
            } }
            if Double(n) >= 0.04 * Double(iw * ih), let b = largestBlock(inner, gw: iw, gh: ih) {
                k = b; gw = iw
            }
        }
    }
    let w = k.w, h = k.h
    let fill = Double(k.points.count) / Double(w * h)
    let aspect = Double(w) / Double(h)
    guard aspect >= 0.7, aspect <= 1.43 else { return (.other, 0) }
    let centre = (k.y0 + h / 2) * gw + (k.x0 + w / 2)
    if fill < 0.6, !k.points.contains(centre) { return (.ring, 1 - fill) }
    if fill >= 0.88 { return (.square, fill) }
    if fill >= 0.6 { return (.dot, 1 - abs(fill - 0.785) / 0.785) }
    return (.arrow, 1 - fill)
}

public func foregroundColor(in image: RuleImage, rect: RuleRect) -> HSL? {
    guard let r = clip(rect, image) else { return nil }
    let base = baseColor(image, r)
    var fr = 0, fg = 0, fb = 0, fn = 0, ar = 0, ag = 0, ab = 0
    for y in r.y..<r.maxY { for x in r.x..<r.maxX {
        let p = image.rgb(x, y)
        ar += Int(p.r); ag += Int(p.g); ab += Int(p.b)
        if colorDistance(p, base) >= blobContrast { fr += Int(p.r); fg += Int(p.g); fb += Int(p.b); fn += 1 }
    } }
    if fn > 0 { return hsl(r: UInt8(fr / fn), g: UInt8(fg / fn), b: UInt8(fb / fn)) }
    let n = r.w * r.h
    return hsl(r: UInt8(ar / n), g: UInt8(ag / n), b: UInt8(ab / n))
}

// MARK: - Thumbnails

/// Box-averaged grey thumbnail of `r` (clipped), at most `maxDim` on a side.
private func thumbnail(_ image: RuleImage, _ r: RuleRect, maxDim: Int) -> (w: Int, h: Int, v: [UInt8]) {
    let tw = min(r.w, maxDim), th = min(r.h, maxDim)
    var sum = [Int](repeating: 0, count: tw * th), cnt = [Int](repeating: 0, count: tw * th)
    for y in 0..<r.h {
        let row = (y * th / r.h) * tw
        var i = ((r.y + y) * image.width + r.x) * 4
        for x in 0..<r.w {
            let cell = row + x * tw / r.w
            sum[cell] += (Int(image.pixels[i + 2]) * 77 + Int(image.pixels[i + 1]) * 150 + Int(image.pixels[i]) * 29) >> 8
            cnt[cell] += 1
            i += 4
        }
    }
    return (tw, th, (0..<tw * th).map { UInt8(sum[$0] / max(1, cnt[$0])) })
}

private func fnv(_ hash: inout UInt64, _ bytes: [UInt8]) { for b in bytes { hash = (hash ^ UInt64(b)) &* 1099511628211 } }

// MARK: - Evaluation

public struct SignalResult: Equatable {
    public var holds: Bool
    public var count: Int?          // only for count signals
    public init(holds: Bool, count: Int? = nil) { self.holds = holds; self.count = count }
}

/// Evaluates every signal of a pack for one frame. Keeps the history motion and text need.
public final class SignalEvaluator {
    private let caps: Set<String>
    private let text: TextReader?
    private var last: [String: SignalResult] = [:]

    private struct Shot { var at: TimeInterval; var rw: Int, rh: Int; var w: Int, h: Int; var v: [UInt8] }
    private var motion: [String: [[Shot]]] = [:]          // signal -> per rect index -> recent thumbnails
    private struct TextState { var digest: UInt64; var lines: [[String]]; var at: TimeInterval }
    private var texts: [String: TextState] = [:]
    /// One round's OCR results by rect: signals reading the same rect with an unchanged digest share a call.
    private var shared: [RuleRect: (digest: UInt64, lines: [String])] = [:]

    private let historySeconds: TimeInterval = 3
    private let motionDiff = 16

    public init(caps: Set<String>, text: TextReader?) { self.caps = caps; self.text = text }

    /// Pack or variants changed.
    public func reset() { last = [:]; motion = [:]; texts = [:] }

    /// `image == nil`: no new frame since the last call, so earlier results stand except `motion`, which is false.
    public func evaluate(_ pack: RulePack, regions: [String: [RuleRect]], image: RuleImage?, now: TimeInterval)
        -> [String: SignalResult] {
        var regions = regions
        var keys: [String: String] = [:]          // signal -> inline region key
        if let image {
            var p = pack
            for (name, s) in pack.signals { if case .inline(let spec)? = s.region { keys[name] = "\u{0}sig:" + name; p.regions[keys[name]!] = spec } }
            if !keys.isEmpty { for (k, v) in resolveRegions(p, in: image) where k.hasPrefix("\u{0}sig:") { regions[k] = v } }
        }
        var out: [String: SignalResult] = [:]
        shared = [:]
        for (name, sig) in pack.signals {
            let usable = sig.usable && sig.needs.isSubset(of: caps)
            let hasMotion = sig.detects.contains { if case .motion = $0 { return true }; return false }
            guard usable else { out[name] = SignalResult(holds: false, count: nil); continue }
            guard let image else {
                if hasMotion { out[name] = SignalResult(holds: false, count: last[name]?.count == nil ? nil : 0) }
                else { out[name] = last[name] ?? SignalResult(holds: false, count: nil) }
                continue
            }
            var rects: [RuleRect] = []
            switch sig.region {
            case .named(let n)?: rects = regions[n] ?? []
            case .inline?: rects = keys[name].flatMap { regions[$0] } ?? []
            case nil: break
            }
            guard !rects.isEmpty else {
                out[name] = SignalResult(holds: false, count: nil)
                motion[name] = nil; texts[name] = nil
                continue
            }
            out[name] = evaluateSignal(name, sig, rects: rects, image: image, now: now)
        }
        last = out
        return out
    }

    private func evaluateSignal(_ name: String, _ sig: SignalSpec, rects: [RuleRect], image: RuleImage, now: TimeInterval)
        -> SignalResult {
        var hit = [Bool](repeating: true, count: rects.count)
        let clipped = rects.map { clip($0, image) }
        for i in 0..<rects.count where clipped[i] == nil { hit[i] = false }
        for d in sig.detects {
            switch d {
            case .present: break
            case .shape(let want, let min):
                for i in 0..<rects.count where hit[i] {
                    let s = shape(in: image, rect: clipped[i]!)
                    hit[i] = s.name.rawValue == want && s.score >= min
                }
            case .color(let range):
                for i in 0..<rects.count where hit[i] {
                    hit[i] = foregroundColor(in: image, rect: clipped[i]!).map(range.contains) ?? false
                }
            case .motion(let window, let min):
                let m = motionHits(name, clipped, image: image, now: now, window: window, min: min)
                for i in 0..<rects.count { hit[i] = hit[i] && m[i] }
            case .text(let patterns):
                let lines = readText(name, clipped, image: image, now: now)
                for i in 0..<rects.count where hit[i] { hit[i] = textMatches(patterns, lines: lines[i]) }
            }
        }
        let n = hit.filter { $0 }.count
        return sig.count ? SignalResult(holds: n >= 1, count: n) : SignalResult(holds: n >= 1, count: nil)
    }

    private func motionHits(_ name: String, _ rects: [RuleRect?], image: RuleImage, now: TimeInterval,
                            window: Double, min: Double) -> [Bool] {
        var hist = motion[name] ?? []
        if hist.count > rects.count { hist.removeLast(hist.count - rects.count) }
        while hist.count < rects.count { hist.append([]) }
        var out = [Bool](repeating: false, count: rects.count)
        for i in 0..<rects.count {
            guard let r = rects[i] else { hist[i] = []; continue }
            let cur = thumbnail(image, r, maxDim: 16)
            var shots = hist[i].filter { now - $0.at <= historySeconds && $0.at <= now }
            if let f = shots.first, f.rw != r.w || f.rh != r.h { shots = [] }
            // Newest shot at least `window` old, else the oldest one.
            let ref = shots.last { now - $0.at >= window } ?? shots.first
            if let ref {
                var changed = 0
                for j in 0..<cur.v.count where abs(Int(cur.v[j]) - Int(ref.v[j])) >= motionDiff { changed += 1 }
                out[i] = changed > 0 && Double(changed) / Double(cur.v.count) >= min
            }
            shots.append(Shot(at: now, rw: r.w, rh: r.h, w: cur.w, h: cur.h, v: cur.v))
            hist[i] = shots
        }
        motion[name] = hist
        return out
    }

    private func readText(_ name: String, _ rects: [RuleRect?], image: RuleImage, now: TimeInterval) -> [[String]] {
        var digest: UInt64 = 14695981039346656037
        fnv(&digest, [UInt8(truncatingIfNeeded: rects.count)])
        for r in rects {
            guard let r else { fnv(&digest, [0]); continue }
            let t = thumbnail(image, r, maxDim: 32)
            fnv(&digest, [UInt8(truncatingIfNeeded: r.w), UInt8(truncatingIfNeeded: r.w >> 8),
                          UInt8(truncatingIfNeeded: r.h), UInt8(truncatingIfNeeded: r.h >> 8)])
            fnv(&digest, t.v)
        }
        let prev = texts[name]
        if let prev, prev.lines.count == rects.count, prev.digest == digest || now - prev.at < textEvery { return prev.lines }
        guard let text else { return [[String]](repeating: [], count: rects.count) }
        let lines: [[String]] = rects.map { r in
            guard let r else { return [] }
            var d: UInt64 = 14695981039346656037
            fnv(&d, [UInt8(truncatingIfNeeded: r.w), UInt8(truncatingIfNeeded: r.w >> 8),
                     UInt8(truncatingIfNeeded: r.h), UInt8(truncatingIfNeeded: r.h >> 8)])
            fnv(&d, thumbnail(image, r, maxDim: 32).v)
            if let hit = shared[r], hit.digest == d { return hit.lines }
            let l = text.lines(in: image, rect: r)
            shared[r] = (d, l)
            return l
        }
        texts[name] = TextState(digest: digest, lines: lines, at: now)
        return lines
    }
}
