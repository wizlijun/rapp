import Foundation

// MARK: - Regions (spec §4.2)

public enum Side: String { case left, right, top, bottom }
public enum Pick: String { case rightmost, leftmost, topmost, bottommost, largest, all }
public enum Length: Equatable { case points(Double), percent(Double) }   // 160 or "40%"

public enum RegionRef: Equatable { case named(String), inline(RegionSpec) }

public indirect enum RegionSpec: Equatable {
    case box(BoxSpec), edge(EdgeSpec), blob(BlobSpec), strip(StripSpec), unknown
}

public struct BoxSpec: Equatable {
    public var inside: RegionRef?   // JSON "in"
    public var rightOf, leftOf, above, below: String?
    public var top, bottom, left, right, width, height: Length?
    public init(inside: RegionRef? = nil, rightOf: String? = nil, leftOf: String? = nil,
                above: String? = nil, below: String? = nil, top: Length? = nil, bottom: Length? = nil,
                left: Length? = nil, right: Length? = nil, width: Length? = nil, height: Length? = nil) {
        self.inside = inside; self.rightOf = rightOf; self.leftOf = leftOf; self.above = above
        self.below = below; self.top = top; self.bottom = bottom; self.left = left
        self.right = right; self.width = width; self.height = height
    }
}

public struct EdgeSpec: Equatable {
    public var inside: RegionRef?
    public var from: Side
    public var min, max: Double
    public init(inside: RegionRef? = nil, from: Side, min: Double, max: Double) {
        self.inside = inside; self.from = from; self.min = min; self.max = max
    }
}

public struct BlobSpec: Equatable {
    public var inside: RegionRef
    public var round: Bool
    public var size: ClosedRange<Double>
    public var pick: Pick
    public init(inside: RegionRef, round: Bool = false, size: ClosedRange<Double>, pick: Pick = .largest) {
        self.inside = inside; self.round = round; self.size = size; self.pick = pick
    }
}

public struct StripSpec: Equatable {
    public var of: RegionRef
    public var side: Side
    public var width: Double
    public init(of: RegionRef, side: Side, width: Double) { self.of = of; self.side = side; self.width = width }
}

// MARK: - Signals (spec §4.3)

/// `ClosedRange` cannot have lower > upper, so a hue range that crosses 0 (e.g. [340, 20])
/// is stored as the sorted range plus `hWraps`: the accepted hues are then *outside* `h`.
public struct ColorRange: Equatable {
    public var h: ClosedRange<Double>?
    public var hWraps: Bool
    public var s, l: ClosedRange<Double>?
    public init(h: ClosedRange<Double>? = nil, hWraps: Bool = false,
                s: ClosedRange<Double>? = nil, l: ClosedRange<Double>? = nil) {
        self.h = h; self.hWraps = hWraps; self.s = s; self.l = l
    }
    public func hueContains(_ hue: Double) -> Bool {
        guard let h else { return true }
        return hWraps ? !(h.lowerBound < hue && hue < h.upperBound) : h.contains(hue)
    }

    /// Colour names (brief Task 5). Hue in degrees, s/l in percent.
    public static func named(_ name: String) -> ColorRange? {
        switch name {
        case "green": return ColorRange(h: 90...170, s: 25...100, l: 20...80)
        case "red": return ColorRange(h: 15...345, hWraps: true, s: 30...100, l: 20...80)
        case "orange": return ColorRange(h: 15...45, s: 40...100, l: 25...80)
        case "blue": return ColorRange(h: 190...250, s: 25...100, l: 20...80)
        case "gray", "grey": return ColorRange(s: 0...12, l: 25...85)
        default: return nil
        }
    }
}

public enum Detect: Equatable {
    case shape(String, min: Double), color(ColorRange), motion(window: Double, min: Double), text([String]), present
}

public enum SignalStatus: String { case tested, seen, reported, untested }

public struct SignalSpec: Equatable {
    public var region: RegionRef?
    public var detects: [Detect]
    public var count: Bool
    public var needs: Set<String>
    public var status: SignalStatus
    public var usable: Bool
    public init(region: RegionRef? = nil, detects: [Detect] = [], count: Bool = false,
                needs: Set<String> = [], status: SignalStatus = .untested, usable: Bool = true) {
        self.region = region; self.detects = detects; self.count = count
        self.needs = needs; self.status = status; self.usable = usable
    }
}

// MARK: - States (spec §4.4)

public indirect enum Condition: Equatable { case signal(String), any([Condition]), all([Condition]), not(Condition), never }

public struct StateRow: Equatable {
    public var state: String
    public var kind: String?
    public var when: Condition?
    public var hold, release: Double
    public init(state: String, kind: String? = nil, when: Condition? = nil, hold: Double = 0, release: Double = 0) {
        self.state = state; self.kind = kind; self.when = when; self.hold = hold; self.release = release
    }
}

/// `when` is kept raw; the engine (Task 7) judges it.
public struct VariantSpec: Equatable {
    public var name: String
    public var when: RuleValue
    public var patch: RuleValue
    public init(name: String, when: RuleValue, patch: RuleValue) { self.name = name; self.when = when; self.patch = patch }
}

// MARK: - Pack

public struct RulePack: Equatable {
    public var id: String, name: String, rev: Int
    public var regions: [String: RegionSpec], signals: [String: SignalSpec]
    public var states: [StateRow], require: [String], variants: [VariantSpec]

    /// Size check, then `RuleValue.parse`.
    public static func parse(_ data: Data) throws -> RuleValue {
        if data.count > ruleBytesLimit { throw RuleError.tooLarge }
        return try RuleValue.parse(data)
    }

    /// Tolerant decode (spec §5.4): only a bad `format` or missing `id` rejects the pack.
    public static func decode(_ v: RuleValue) throws -> RulePack {
        guard let format = v["format"]?.stringValue else { throw RuleError.unsupportedFormat("") }
        guard Int(format.split(separator: ".", omittingEmptySubsequences: false).first ?? "") == 1 else {
            throw RuleError.unsupportedFormat(format)
        }
        guard let id = v["id"]?.stringValue, !id.isEmpty else { throw RuleError.notAPack("id") }
        // rev is absent (0) or an integer in 0...Int32.max; anything else rejects the pack (the GUI does the same).
        var rev = 0
        if let raw = v["rev"] {
            guard let n = raw.numberValue, n == n.rounded(.towardZero), n >= 0, n <= 2147483647 else { throw RuleError.notAPack("rev") }
            rev = Int(n)
        }
        var regions: [String: RegionSpec] = [:]
        for (k, r) in v["regions"]?.objectValue ?? [:] { regions[k] = decodeRegion(r) }
        var signals: [String: SignalSpec] = [:]
        for (k, s) in v["signals"]?.objectValue ?? [:] { signals[k] = decodeSignal(s) }
        var states: [StateRow] = []
        for row in v["states"]?.arrayValue ?? [] {
            guard let state = row["state"]?.stringValue, stateWords.contains(state) else { continue }
            states.append(StateRow(state: state, kind: row["kind"]?.stringValue,
                                   when: row["when"].map(decodeCondition),
                                   hold: row["hold"]?.numberValue ?? 0, release: row["release"]?.numberValue ?? 0))
        }
        var variants: [VariantSpec] = []
        for (i, item) in (v["variants"]?.arrayValue ?? []).enumerated() {
            guard item.objectValue != nil, let when = item["when"] else { continue }
            variants.append(VariantSpec(name: item["name"]?.stringValue ?? "#\(i)", when: when,
                                        patch: item["patch"] ?? .object([:])))
        }
        return RulePack(id: id, name: v["name"]?.stringValue ?? id, rev: rev,
                        regions: regions, signals: signals, states: states,
                        require: (v["require"]?.arrayValue ?? []).compactMap(\.stringValue), variants: variants)
    }

    private static let stateWords: Set<String> = ["working", "done", "blocked", "idle"]

    // MARK: regions

    private static func decodeRef(_ v: RuleValue?) -> RegionRef? {
        switch v {
        case .string(let s): return .named(s)
        case .object: return v.map { .inline(decodeRegion($0)) }
        default: return nil
        }
    }

    private static func decodeLength(_ v: RuleValue) -> Length? {
        if let n = v.numberValue { return .points(n) }
        if let s = v.stringValue, s.hasSuffix("%"), let n = Double(s.dropLast()) { return .percent(n) }
        return nil
    }

    private static func decodeRegion(_ v: RuleValue) -> RegionSpec {
        guard v.objectValue != nil else { return .unknown }
        for kind in ["box", "edge", "blob", "strip"] {
            guard let body = v[kind] else { continue }
            return decodeRegionBody(kind, body) ?? .unknown
        }
        return .unknown
    }

    private static func decodeRegionBody(_ kind: String, _ b: RuleValue) -> RegionSpec? {
        guard b.objectValue != nil else { return nil }
        // A present but malformed region reference makes the whole region unusable.
        var inside: RegionRef?
        if let raw = b["in"] { guard let r = decodeRef(raw) else { return nil }; inside = r }
        switch kind {
        case "box":
            var box = BoxSpec(inside: inside)
            for (key, set) in [("rightOf", \BoxSpec.rightOf), ("leftOf", \.leftOf), ("above", \.above), ("below", \.below)] {
                if let raw = b[key] { guard let s = raw.stringValue else { return nil }; box[keyPath: set] = s }
            }
            for (key, set) in [("top", \BoxSpec.top), ("bottom", \.bottom), ("left", \.left),
                               ("right", \.right), ("width", \.width), ("height", \.height)] {
                if let raw = b[key] { guard let l = decodeLength(raw) else { return nil }; box[keyPath: set] = l }
            }
            return .box(box)
        case "edge":
            guard let from = b["from"]?.stringValue.flatMap(Side.init(rawValue:)),
                  let lo = b["min"]?.numberValue, let hi = b["max"]?.numberValue else { return nil }
            return .edge(EdgeSpec(inside: inside, from: from, min: lo, max: hi))
        case "blob":
            guard let inside, let size = b["size"]?.arrayValue, size.count == 2,
                  let lo = size[0].numberValue, let hi = size[1].numberValue, lo <= hi else { return nil }
            var pick = Pick.largest
            if let raw = b["pick"] { guard let p = raw.stringValue.flatMap(Pick.init(rawValue:)) else { return nil }; pick = p }
            return .blob(BlobSpec(inside: inside, round: b["round"]?.boolValue ?? false, size: lo...hi, pick: pick))
        case "strip":
            guard let of = decodeRef(b["of"]), let side = b["side"]?.stringValue.flatMap(Side.init(rawValue:)),
                  let w = b["width"]?.numberValue else { return nil }
            return .strip(StripSpec(of: of, side: side, width: w))
        default: return nil
        }
    }

    // MARK: signals

    private static func decodeSignal(_ v: RuleValue) -> SignalSpec {
        var sig = SignalSpec()
        sig.region = decodeRef(v["in"])
        sig.count = v["count"]?.boolValue ?? false
        sig.status = v["status"]?.stringValue.flatMap(SignalStatus.init(rawValue:)) ?? .untested
        sig.needs = Set((v["needs"]?.arrayValue ?? []).compactMap(\.stringValue))
        guard let detect = v["detect"]?.objectValue, !detect.isEmpty else { sig.usable = false; return sig }
        let known: Set<String> = ["shape", "color", "motion", "text", "present"]
        if !Set(detect.keys).isSubset(of: known) { sig.usable = false }
        func fail() { sig.usable = false }
        if let s = detect["shape"] {
            if let name = s.stringValue { sig.detects.append(.shape(name, min: 0)); sig.needs.insert("pixels") }
            else if let name = s["is"]?.stringValue { sig.detects.append(.shape(name, min: s["min"]?.numberValue ?? 0)); sig.needs.insert("pixels") }
            else { fail() }
        }
        if let c = detect["color"] {
            if let range = decodeColor(c) { sig.detects.append(.color(range)); sig.needs.insert("pixels") } else { fail() }
        }
        if let m = detect["motion"] {
            if m.objectValue != nil {
                sig.detects.append(.motion(window: m["window"]?.numberValue ?? 0.4, min: m["min"]?.numberValue ?? 0.02))
            } else { fail() }
        }
        if let t = detect["text"] {
            if let words = t.arrayValue?.compactMap(\.stringValue), words.count == t.arrayValue?.count {
                sig.detects.append(.text(words)); sig.needs.insert("text")
            } else { fail() }
        }
        if let p = detect["present"] {
            if p.boolValue == true { sig.detects.append(.present); sig.needs.insert("pixels") } else { fail() }
        }
        return sig
    }

    private static func decodeColor(_ v: RuleValue) -> ColorRange? {
        if let name = v.stringValue { return ColorRange.named(name) }
        guard v.objectValue != nil else { return nil }
        func pair(_ key: String) -> (Double, Double)?? {
            guard let raw = v[key] else { return .some(nil) }
            guard let a = raw.arrayValue, a.count == 2, let x = a[0].numberValue, let y = a[1].numberValue else { return nil }
            return .some((x, y))
        }
        guard let h = pair("h"), let s = pair("s"), let l = pair("l") else { return nil }
        var out = ColorRange()
        if let h { out.hWraps = h.0 > h.1; out.h = min(h.0, h.1)...max(h.0, h.1) }
        if let s { out.s = min(s.0, s.1)...max(s.0, s.1) }
        if let l { out.l = min(l.0, l.1)...max(l.0, l.1) }
        return out
    }

    // MARK: conditions

    private static func decodeCondition(_ v: RuleValue) -> Condition {
        if let s = v.stringValue { return .signal(s) }
        guard let o = v.objectValue, o.count == 1, let (key, arg) = o.first else { return .never }
        switch key {
        case "any", "all":
            guard let items = arg.arrayValue, !items.isEmpty else { return .never }
            let subs = items.map(decodeCondition)
            // An unreadable form anywhere makes the whole condition never match (even under `not`/`any`).
            if subs.contains(where: { $0.hasNever }) { return .never }
            return key == "any" ? .any(subs) : .all(subs)
        case "not":
            let sub = decodeCondition(arg)
            return sub.hasNever ? .never : .not(sub)
        default: return .never
        }
    }
}

extension Condition {
    /// `.never` only comes from an unreadable form, so any `.never` inside poisons the condition.
    fileprivate var hasNever: Bool {
        switch self {
        case .never: return true
        case .signal: return false
        case .not(let c): return c.hasNever
        case .any(let cs), .all(let cs): return cs.contains { $0.hasNever }
        }
    }
}
