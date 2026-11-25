import Foundation

public enum RuleError: Error, Equatable {
    case tooLarge, badJSON, unsupportedFormat(String), notAPack(String)
}

public let ruleBytesLimit = 65536

/// A JSON value. Rule packs and patches are kept in this form until decoded, so that
/// merging (inheritance, variants, user patches) works on the raw document.
public indirect enum RuleValue: Equatable {
    case null, bool(Bool), number(Double), string(String), array([RuleValue]), object([String: RuleValue])

    /// Top level must be an object; anything else is `RuleError.badJSON`.
    public static func parse(_ data: Data) throws -> RuleValue {
        guard let any = try? JSONSerialization.jsonObject(with: data, options: []),
              any is [String: Any] else { throw RuleError.badJSON }
        return convert(any)
    }

    private static func convert(_ any: Any) -> RuleValue {
        switch any {
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return .bool(n.boolValue) }
            return .number(n.doubleValue)
        case let s as String: return .string(s)
        case let a as [Any]: return .array(a.map(convert))
        case let o as [String: Any]: return .object(o.mapValues(convert))
        default: return .null
        }
    }

    /// Spec §5.3: objects merge by key, `null` deletes, arrays and scalars replace.
    public func merged(with patch: RuleValue) -> RuleValue {
        guard case .object(let p) = patch else { return patch }
        guard case .object(var base) = self else { return patch.strippingNulls() }
        for (k, pv) in p {
            if case .null = pv { base[k] = nil }
            else if let old = base[k] { base[k] = old.merged(with: pv) }
            else { base[k] = pv.strippingNulls() }
        }
        return .object(base)
    }

    private func strippingNulls() -> RuleValue {
        guard case .object(let o) = self else { return self }
        var out: [String: RuleValue] = [:]
        for (k, v) in o { if case .null = v { continue }; out[k] = v.strippingNulls() }
        return .object(out)
    }

    public subscript(key: String) -> RuleValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    // Decoding helpers (module-internal).
    var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    var numberValue: Double? { if case .number(let n) = self { return n }; return nil }
    var boolValue: Bool? { if case .bool(let b) = self { return b }; return nil }
    var arrayValue: [RuleValue]? { if case .array(let a) = self { return a }; return nil }
    var objectValue: [String: RuleValue]? { if case .object(let o) = self { return o }; return nil }
}
