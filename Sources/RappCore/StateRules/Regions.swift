import Foundation

/// Every region the pack names, resolved; a missing region has no entry. Single regions have one rect.
/// Never traps: numbers from a hostile pack are clamped to the image before they become pixel indices.
public func resolveRegions(_ pack: RulePack, in image: RuleImage) -> [String: [RuleRect]] {
    let resolver = RegionResolver(pack: pack, image: image)
    var out: [String: [RuleRect]] = [:]
    for name in pack.regions.keys {
        if let rects = resolver.named(name), !rects.isEmpty { out[name] = rects }
    }
    return out
}

private final class RegionResolver {
    let pack: RulePack, image: RuleImage
    var cache: [String: [RuleRect]?] = [:]
    var visiting: Set<String> = []
    let blobLimit = 512

    init(pack: RulePack, image: RuleImage) { self.pack = pack; self.image = image }

    var whole: RuleRect { RuleRect(x: 0, y: 0, w: image.width, h: image.height) }

    func named(_ name: String) -> [RuleRect]? {
        if let hit = cache[name] { return hit }
        guard let spec = pack.regions[name], !visiting.contains(name) else { return nil }
        visiting.insert(name)
        let r = resolve(spec)
        visiting.remove(name)
        cache[name] = .some(r)
        return r
    }

    func resolve(_ ref: RegionRef) -> [RuleRect]? {
        switch ref {
        case .named(let n): return named(n)
        case .inline(let s): return resolve(s)
        }
    }

    /// The container is the first rect of a reference; a missing `in` is the whole image.
    func container(_ ref: RegionRef?) -> RuleRect? {
        guard let ref else { return whole }
        guard let r = resolve(ref)?.first, r.w > 0, r.h > 0 else { return nil }
        return r
    }

    func resolve(_ spec: RegionSpec) -> [RuleRect]? {
        let rects: [RuleRect]?
        switch spec {
        case .box(let b): rects = box(b).map { [$0] }
        case .edge(let e): rects = edge(e).map { [$0] }
        case .blob(let b): rects = blob(b)
        case .strip(let s): rects = strip(s).map { [$0] }
        case .unknown: rects = nil
        }
        guard let rects, !rects.isEmpty else { return nil }
        return rects
    }

    // MARK: box

    func box(_ b: BoxSpec) -> RuleRect? {
        guard let c = container(b.inside) else { return nil }
        var minX = Double(c.x), maxX = Double(c.maxX), minY = Double(c.y), maxY = Double(c.maxY)
        var hugX = Hug.low, hugY = Hug.low
        // A constraint pointing at a region that cannot be found does not count (spec §6.1).
        if let n = b.rightOf, let r = named(n)?.first { minX = max(minX, Double(r.maxX)); hugX = .low }
        if let n = b.leftOf, let r = named(n)?.first { maxX = min(maxX, Double(r.x)); hugX = .high }
        if let n = b.below, let r = named(n)?.first { minY = max(minY, Double(r.maxY)); hugY = .low }
        if let n = b.above, let r = named(n)?.first { maxY = min(maxY, Double(r.y)); hugY = .high }
        guard maxX > minX, maxY > minY else { return nil }
        guard let xs = solve(lo: minX, hi: maxX, near: b.left, far: b.right, size: b.width, hug: hugX),
              let ys = solve(lo: minY, hi: maxY, near: b.top, far: b.bottom, size: b.height, hug: hugY)
        else { return nil }
        let x0 = max(xs.0, minX), x1 = min(xs.1, maxX), y0 = max(ys.0, minY), y1 = min(ys.1, maxY)
        guard x1 > x0, y1 > y0 else { return nil }
        // x0...x1 are within the container, so the conversions are in range.
        let rx0 = Int(x0.rounded()), rx1 = Int(x1.rounded()), ry0 = Int(y0.rounded()), ry1 = Int(y1.rounded())
        guard rx1 > rx0, ry1 > ry0 else { return nil }
        return RuleRect(x: rx0, y: ry0, w: rx1 - rx0, h: ry1 - ry0)
    }

    enum Hug { case low, high }

    /// One axis of a box. Returns nil on NaN. Infinite numbers pass through and are clipped by the caller.
    func solve(lo: Double, hi: Double, near: Length?, far: Length?, size: Length?, hug: Hug) -> (Double, Double)? {
        let span = hi - lo
        func v(_ l: Length?) -> Double? {
            switch l {
            case .points(let p): return p
            case .percent(let p): return p * span / 100
            case nil: return nil
            }
        }
        let n = v(near), f = v(far), s = v(size)
        if [n, f, s].contains(where: { $0?.isNaN == true }) { return nil }
        switch (n, f, s) {
        case let (n?, f?, _): return (lo + n, hi - f)
        case let (n?, nil, s?): return (lo + n, lo + n + s)
        case let (nil, f?, s?): return (hi - f - s, hi - f)
        case let (nil, nil, s?): return hug == .low ? (lo, lo + s) : (hi - s, hi)
        case let (n?, nil, nil): return (lo + n, hi)
        case let (nil, f?, nil): return (lo, hi - f)
        case (nil, nil, nil): return (lo, hi)
        }
    }

    // MARK: edge

    func edge(_ e: EdgeSpec) -> RuleRect? {
        guard let c = container(e.inside), !e.min.isNaN, !e.max.isNaN, e.min <= e.max else { return nil }
        let horizontal = e.from == .left || e.from == .right
        let length = horizontal ? c.w : c.h          // how far we can scan
        guard e.max >= 0, e.min < Double(length) else { return nil }
        let lo = Int(Swift.max(0, e.min).rounded(.down))
        let hi = Int(Swift.min(Double(length - 1), e.max).rounded(.down))
        guard hi > lo else { return nil }
        // `d` is the distance from the starting side.
        func position(_ d: Int) -> Int {
            switch e.from {
            case .left: return c.x + d
            case .right: return c.maxX - 1 - d
            case .top: return c.y + d
            case .bottom: return c.maxY - 1 - d
            }
        }
        let reference = signature(c, horizontal: horizontal, at: position(lo))
        for d in (lo + 1)...hi {
            if colorDistance(signature(c, horizontal: horizontal, at: position(d)), reference) >= regionContrast {
                switch e.from {
                case .left: return RuleRect(x: c.x, y: c.y, w: d, h: c.h)
                case .right: return RuleRect(x: c.maxX - d, y: c.y, w: d, h: c.h)
                case .top: return RuleRect(x: c.x, y: c.y, w: c.w, h: d)
                case .bottom: return RuleRect(x: c.x, y: c.maxY - d, w: c.w, h: d)
                }
            }
        }
        return nil
    }

    /// Per-channel median of the pixels of one column (or row) between 10% and 90% of its length, every 4th.
    func signature(_ c: RuleRect, horizontal: Bool, at pos: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
        let len = horizontal ? c.h : c.w
        let start = horizontal ? c.y : c.x
        let from = len / 10, to = max(from, len * 9 / 10)
        var rs: [UInt8] = [], gs: [UInt8] = [], bs: [UInt8] = []
        var i = from
        repeat {
            let p = start + min(i, len - 1)
            let px = horizontal ? image.rgb(pos, p) : image.rgb(p, pos)
            rs.append(px.r); gs.append(px.g); bs.append(px.b)
            i += 4
        } while i <= to
        func median(_ a: [UInt8]) -> UInt8 { a.sorted()[a.count / 2] }
        return (median(rs), median(gs), median(bs))
    }

    // MARK: blob

    func blob(_ b: BlobSpec) -> [RuleRect]? {
        guard let c = container(b.inside) else { return nil }
        // Background: the most common colour at 4 bits per channel (mean of that bin).
        var count = [Int](repeating: 0, count: 4096)
        var sum = [(Int, Int, Int)](repeating: (0, 0, 0), count: 4096)
        for y in c.y..<c.maxY {
            for x in c.x..<c.maxX {
                let p = image.rgb(x, y)
                let k = Int(p.r >> 4) << 8 | Int(p.g >> 4) << 4 | Int(p.b >> 4)
                count[k] += 1
                sum[k].0 += Int(p.r); sum[k].1 += Int(p.g); sum[k].2 += Int(p.b)
            }
        }
        var best = 0
        for k in 1..<4096 where count[k] > count[best] { best = k }
        let n = count[best]
        let bg = (r: UInt8(sum[best].0 / n), g: UInt8(sum[best].1 / n), b: UInt8(sum[best].2 / n))

        var seen = [Bool](repeating: false, count: c.w * c.h)
        var found: [RuleRect] = []
        var stack: [Int] = []
        var blobs = 0
        scan: for y in 0..<c.h {
            for x in 0..<c.w {
                let idx = y * c.w + x
                if seen[idx] { continue }
                let p = image.rgb(c.x + x, c.y + y)
                if colorDistance(p, bg) < blobContrast { seen[idx] = true; continue }
                if blobs >= blobLimit { break scan }
                blobs += 1
                var x0 = x, x1 = x, y0 = y, y1 = y
                seen[idx] = true; stack.append(idx)
                while let i = stack.popLast() {
                    let cx = i % c.w, cy = i / c.w
                    x0 = min(x0, cx); x1 = max(x1, cx); y0 = min(y0, cy); y1 = max(y1, cy)
                    for (nx, ny) in [(cx - 1, cy), (cx + 1, cy), (cx, cy - 1), (cx, cy + 1)] {
                        guard nx >= 0, ny >= 0, nx < c.w, ny < c.h else { continue }
                        let j = ny * c.w + nx
                        if seen[j] { continue }
                        seen[j] = true
                        if colorDistance(image.rgb(c.x + nx, c.y + ny), bg) >= blobContrast { stack.append(j) }
                    }
                }
                let w = x1 - x0 + 1, h = y1 - y0 + 1
                guard b.size.contains(Double(w)), b.size.contains(Double(h)) else { continue }
                if b.round { let r = Double(w) / Double(h); guard r >= 0.75, r <= 1.33 else { continue } }
                found.append(RuleRect(x: c.x + x0, y: c.y + y0, w: w, h: h))
            }
        }
        guard !found.isEmpty else { return nil }
        switch b.pick {
        case .all: return found.sorted { ($0.y, $0.x) < ($1.y, $1.x) }
        case .rightmost: return found.max { ($0.maxX, -$0.y) < ($1.maxX, -$1.y) }.map { [$0] }
        case .leftmost: return found.min { ($0.x, $0.y) < ($1.x, $1.y) }.map { [$0] }
        case .topmost: return found.min { ($0.y, $0.x) < ($1.y, $1.x) }.map { [$0] }
        case .bottommost: return found.max { ($0.maxY, -$0.x) < ($1.maxY, -$1.x) }.map { [$0] }
        case .largest: return found.max { $0.w * $0.h < $1.w * $1.h }.map { [$0] }
        }
    }

    // MARK: strip

    func strip(_ s: StripSpec) -> RuleRect? {
        guard let c = container(.some(s.of)), s.width > 0 else { return nil }   // NaN fails `> 0`
        let horizontal = s.side == .left || s.side == .right
        let w = Int(Swift.min(s.width, Double(horizontal ? c.w : c.h)).rounded())
        guard w > 0 else { return nil }
        switch s.side {
        case .left: return RuleRect(x: c.x, y: c.y, w: w, h: c.h)
        case .right: return RuleRect(x: c.maxX - w, y: c.y, w: w, h: c.h)
        case .top: return RuleRect(x: c.x, y: c.y, w: c.w, h: w)
        case .bottom: return RuleRect(x: c.x, y: c.maxY - w, w: c.w, h: w)
        }
    }
}
