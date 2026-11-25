import Foundation

// The per-session engine (spec §5.1, §7): picks pack variants, runs detectors and the state table each
// frame, checks that the pack still fits the app, and produces the report. Time is injected.

public struct RuleEnv {
    public var appVersion: String?
    public var os: String               // "macos"
    public var locale: String           // Locale.preferredLanguages.first
    public var caps: Set<String>        // "pixels", "text"
    public var rereadVersion: () -> String?
    public init(appVersion: String?, os: String, locale: String, caps: Set<String>,
                rereadVersion: @escaping () -> String?) {
        self.appVersion = appVersion; self.os = os; self.locale = locale; self.caps = caps
        self.rereadVersion = rereadVersion
    }
}

public let healthRounds = 5
/// At most this many `count` keys go into a report.
public let reportCountKeys = 32

public struct AppStateReport: Equatable {
    public var pack: String?, rev: Int?, state: String?, kind: String?
    public var by: [String], sure: Bool, counts: [String: Int]
    public var health: String          // "ok" | "switched" | "unfit" | "invalid"
    public var variants: [String], appVersion: String?, caps: [String], error: String?

    public init(pack: String? = nil, rev: Int? = nil, state: String? = nil, kind: String? = nil,
                by: [String] = [], sure: Bool = false, counts: [String: Int] = [:], health: String = "ok",
                variants: [String] = [], appVersion: String? = nil, caps: [String] = [], error: String? = nil) {
        self.pack = pack; self.rev = rev; self.state = state; self.kind = kind; self.by = by
        self.sure = sure; self.counts = counts; self.health = health; self.variants = variants
        self.appVersion = appVersion; self.caps = caps; self.error = error
    }

    public static func invalid(_ error: RuleError, caps: [String], appVersion: String?) -> AppStateReport {
        let text: String
        switch error {
        case .tooLarge: text = "too large"
        case .badJSON: text = "bad json"
        case .unsupportedFormat(let f): text = "unsupported format " + String(f.prefix(32))
        case .notAPack(let w): text = "not a pack: " + String(w.prefix(32))
        }
        return AppStateReport(health: "invalid", appVersion: appVersion, caps: caps, error: text)
    }

    /// Sorted keys, `inferred` always true, nil as null. Never more than `appStateLimit` UTF-8 bytes:
    /// when it would be, the lowest-value fields go first (counts, then long text, then lists).
    public func json() -> String {
        func clip(_ s: String?, _ n: Int) -> String? { s.map { String($0.prefix(n)) } }
        let shrinks: [(inout AppStateReport) -> Void] = [
            { r in r.counts = Self.firstCounts(r.counts, 16) },
            { r in r.counts = Self.firstCounts(r.counts, 4) },
            { r in r.counts = [:] },
            { r in r.error = clip(r.error, 200) },
            { r in r.by = Array(r.by.prefix(8)); r.variants = Array(r.variants.prefix(8)); r.caps = Array(r.caps.prefix(8)) },
            { r in
                r.by = r.by.map { String($0.prefix(48)) }; r.variants = r.variants.map { String($0.prefix(48)) }
                r.caps = r.caps.map { String($0.prefix(48)) }
                r.pack = clip(r.pack, 64); r.kind = clip(r.kind, 64); r.appVersion = clip(r.appVersion, 64)
                r.error = clip(r.error, 64)
            },
            { r in r.by = []; r.variants = []; r.caps = []; r.error = clip(r.error, 32) },
            { r in
                r = AppStateReport(state: ["working", "done", "blocked", "idle"].contains(r.state ?? "") ? r.state : nil,
                                   health: r.health)
            },
        ]
        var r = self
        var s = r.encode()
        for shrink in shrinks where s.utf8.count > appStateLimit {
            shrink(&r)
            s = r.encode()
        }
        return s
    }

    private static func firstCounts(_ c: [String: Int], _ n: Int) -> [String: Int] {
        var out: [String: Int] = [:]
        for k in c.keys.sorted().prefix(n) { out[k] = c[k] }
        return out
    }

    private func encode() -> String {
        let null = NSNull()
        var o: [String: Any] = [
            "pack": pack ?? null, "rev": rev ?? null, "state": state ?? null, "kind": kind ?? null,
            "by": by, "sure": sure, "counts": counts, "health": health, "variants": variants,
            "appVersion": appVersion ?? null, "caps": caps, "inferred": true,
        ]
        if health == "invalid" { o["error"] = error ?? null }
        guard let data = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys, .withoutEscapingSlashes]),
              let s = String(data: data, encoding: .utf8) else { return "{\"inferred\":true}" }
        return s
    }
}

/// Dotted numbers compared segment by segment; a missing segment counts as 0; a segment that is not
/// a number compares as a string.
public func compareVersions(_ a: String, _ b: String) -> Int {
    let x = a.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
    let y = b.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
    for i in 0..<max(x.count, y.count) {
        let p = i < x.count ? x[i] : "0", q = i < y.count ? y[i] : "0"
        if let m = Int(p), let n = Int(q) {
            if m != n { return m < n ? -1 : 1 }
        } else if p != q {
            return p < q ? -1 : 1
        }
    }
    return 0
}

public final class StateEngine {
    private let env: RuleEnv
    private let base: RuleValue
    private let basePack: RulePack
    private let evaluator: SignalEvaluator
    private let capsList: [String]
    private var appVersion: String?

    private var packCache: [String: (pack: RulePack, idx: [Int])] = [:]
    private var pack: RulePack
    private var active: [Int] = []
    private var table: StateTable
    private var haveFrame = false

    private var forced: Int?
    private var tried: Set<Int> = []
    private var rereaded = false
    private var switched = false
    private var unfit = false
    private var misses = 0, foundStreak = 0

    public private(set) var report: AppStateReport

    public init(rules: Data, env: RuleEnv, text: TextReader?) throws {
        let value = try RulePack.parse(rules)
        let pack = try RulePack.decode(value)
        self.env = env; self.base = value; self.basePack = pack; self.pack = pack
        self.evaluator = SignalEvaluator(caps: env.caps, text: text)
        self.table = StateTable(pack.states)
        self.appVersion = env.appVersion
        self.capsList = env.caps.sorted()
        self.report = AppStateReport(pack: pack.id, rev: pack.rev, appVersion: env.appVersion, caps: env.caps.sorted())
    }

    /// One round. `image`: the main window at one pixel per point, or nil when no new frame came.
    /// `visible`: the window is on screen (only visible rounds count for the self-check).
    /// Returns the report when it differs from the last one returned. A non-finite `now` is skipped.
    public func tick(image: RuleImage?, visible: Bool, now: TimeInterval) -> AppStateReport? {
        guard now.isFinite else { return nil }
        var frame = image
        if let f = frame, f.width <= 0 || f.height <= 0 || f.pixels.count < f.width * f.height * 4 { frame = nil }
        var regions: [String: [RuleRect]] = [:]
        if let frame {
            haveFrame = true
            let theme = estimateTheme(frame)
            var sel = select(frame, theme: theme)
            if visible, selfCheck(sel.pack, sel.regions, sel.idx) { sel = select(frame, theme: theme) }
            if sel.idx != active || sel.pack != pack {
                active = sel.idx; pack = sel.pack
                evaluator.reset(); table = StateTable(pack.states)
            }
            regions = sel.regions
        }
        guard haveFrame else { return nil }

        var next = AppStateReport(pack: pack.id, rev: pack.rev, appVersion: appVersion, caps: capsList)
        next.variants = active.map { basePack.variants[$0].name }
        next.health = unfit ? "unfit" : (switched ? "switched" : "ok")
        if !unfit {
            let results = evaluator.evaluate(pack, regions: regions, image: frame, now: now)
            let on = Set(results.filter { $0.value.holds }.keys)
            if let row = table.step(on: on, now: now) {
                next.state = row.state; next.kind = row.kind
                let by = (row.when.map(signalsIn) ?? []).intersection(on).sorted()
                next.by = by
                next.sure = !by.isEmpty && by.allSatisfy { pack.signals[$0]?.status == .tested }
            }
            for name in results.keys.sorted() {
                guard next.counts.count < reportCountKeys, let c = results[name]?.count else { continue }
                next.counts[name] = c
            }
        }
        if next == report { return nil }
        report = next
        return next
    }

    // MARK: theme

    /// Median luminance of an 8x8 grid of points between 10% and 90% of the window.
    private func estimateTheme(_ img: RuleImage) -> String {
        var lum: [Double] = []
        for j in 0..<8 { for i in 0..<8 {
            let x = min(img.width - 1, Int(Double(img.width) * (0.1 + 0.8 * Double(i) / 7)))
            let y = min(img.height - 1, Int(Double(img.height) * (0.1 + 0.8 * Double(j) / 7)))
            let p = img.rgb(x, y)
            lum.append((0.299 * Double(p.r) + 0.587 * Double(p.g) + 0.114 * Double(p.b)) / 255)
        } }
        lum.sort()
        return (lum[31] + lum[32]) / 2 < 0.5 ? "dark" : "light"
    }

    // MARK: variants

    private struct Selection { var pack: RulePack; var idx: [Int]; var regions: [String: [RuleRect]] }

    private func hasKey(_ v: VariantSpec, _ keys: Set<String>) -> Bool {
        v.when.objectValue.map { !keys.isDisjoint(with: $0.keys) } ?? false
    }

    private var versioned: [Int] { basePack.variants.indices.filter { hasKey(basePack.variants[$0], ["appVersion"]) } }

    /// The variant with the newest version range, used when the app version is unknown.
    private var newestVersioned: Int? {
        func key(_ v: VariantSpec) -> String {
            let o = v.when["appVersion"]
            return o?["max"]?.stringValue ?? o?["min"]?.stringValue ?? "0"
        }
        var best: Int?
        for i in versioned where best == nil || compareVersions(key(basePack.variants[i]), key(basePack.variants[best!])) > 0 { best = i }
        return best
    }

    private func select(_ img: RuleImage, theme: String) -> Selection {
        let vs = basePack.variants
        let newest = appVersion == nil && forced == nil ? newestVersioned : nil
        func applies(_ i: Int, found: Set<String>?) -> Bool {
            let v = vs[i]
            guard let when = v.when.objectValue else { return false }
            let isVersioned = when["appVersion"] != nil
            var versionOK = false          // appVersion decided from outside (forced / unknown version)
            if isVersioned {
                if let forced { guard i == forced else { return false }; versionOK = true }
                else if appVersion == nil { guard i == newest else { return false }; versionOK = true }
            }
            for (key, arg) in when {
                switch key {
                case "appVersion":
                    if versionOK { continue }
                    guard let ver = appVersion, rangeHolds(arg, compare: { compareVersions(ver, $0) }) else { return false }
                case "os": guard arg.stringValue == env.os else { return false }
                case "theme": guard arg.stringValue == theme else { return false }
                case "locale":
                    guard let l = arg.stringValue, !l.isEmpty else { return false }
                    let have = env.locale.lowercased(), want = l.lowercased()
                    guard have == want || have.hasPrefix(want + "-") || have.hasPrefix(want + "_") else { return false }
                case "windowWidth":
                    let w = Double(img.width)
                    guard rangeHolds(arg, compare: { Double($0).map { w < $0 ? -1 : (w > $0 ? 1 : 0) } ?? 2 }) else { return false }
                case "found", "missing":
                    guard let found, let names = arg.arrayValue else { return false }
                    var all = true
                    for n in names { guard let s = n.stringValue else { return false }; if found.contains(s) != (key == "found") { all = false } }
                    guard all else { return false }
                default: return false
                }
            }
            return true
        }
        let regionKeys: Set<String> = ["found", "missing"]
        let early = vs.indices.filter { !hasKey(vs[$0], regionKeys) && applies($0, found: nil) }
        var (p, idx) = packFor(early)
        var regions = resolveRegions(p, in: img)
        if vs.contains(where: { hasKey($0, regionKeys) }) {
            let names = Set(regions.keys)
            let all = vs.indices.filter { early.contains($0) || (hasKey(vs[$0], regionKeys) && applies($0, found: names)) }
            if all != early { (p, idx) = packFor(all); regions = resolveRegions(p, in: img) }
        }
        return Selection(pack: p, idx: idx, regions: regions)
    }

    /// `{min, max}` both inclusive; `compare` gives the sign of (value - bound), 2 for an unreadable bound.
    private func rangeHolds(_ v: RuleValue, compare: (String) -> Int) -> Bool {
        guard v.objectValue != nil else { return false }
        for (key, sign) in [("min", -1), ("max", 1)] {
            guard let raw = v[key] else { continue }
            let bound: String
            if let s = raw.stringValue { bound = s }
            else if let n = raw.numberValue, n.isFinite { bound = String(n) }
            else { return false }
            let c = compare(bound)
            if c == 2 || c == sign { return false }
        }
        return true
    }

    /// The base pack with the variants' patches laid on in order, and the variants that really went on:
    /// a patch whose merged result no longer decodes is left out (and not reported).
    private func packFor(_ idx: [Int]) -> (RulePack, [Int]) {
        if idx.isEmpty { return (basePack, []) }
        let key = idx.map(String.init).joined(separator: ",")
        if let hit = packCache[key] { return (hit.pack, hit.idx) }
        var v = base, p = basePack, used: [Int] = []
        for i in idx {
            let merged = v.merged(with: basePack.variants[i].patch)
            guard let decoded = try? RulePack.decode(merged) else { continue }
            v = merged; p = decoded; used.append(i)
        }
        if packCache.count >= 32 { packCache = [:] }
        packCache[key] = (p, used)
        return (p, used)
    }

    // MARK: self-check (spec §7)

    /// Counts this visible round. Returns true when the variant choice changed and must be redone.
    private func selfCheck(_ pack: RulePack, _ regions: [String: [RuleRect]], _ idx: [Int]) -> Bool {
        let found = pack.require.allSatisfy { regions[$0] != nil }
        if unfit {
            foundStreak = found ? foundStreak + 1 : 0
            if foundStreak >= healthRounds {
                // Recovered: the whole search may run again later. `switched` is sticky: once the
                // engine changed variant or version by itself, the report keeps saying so.
                unfit = false; foundStreak = 0; misses = 0; rereaded = false; tried = []
                evaluator.reset(); table = StateTable(self.pack.states)
            }
            return false
        }
        if found { misses = 0; return false }
        misses += 1
        guard misses >= healthRounds else { return false }
        misses = 0
        let versionedIdx = versioned
        tried.formUnion(idx.filter(versionedIdx.contains))
        if let next = versionedIdx.first(where: { !tried.contains($0) }) {
            forced = next; tried.insert(next); switched = true
            return true
        }
        if !rereaded {
            rereaded = true
            if let v = env.rereadVersion(), v != appVersion {
                appVersion = v; forced = nil; tried = []; switched = true
                return true
            }
        }
        unfit = true; foundStreak = 0
        return false
    }
}
