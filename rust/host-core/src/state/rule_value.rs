//! The raw JSON tree rule packs are kept in until decoded (`StateRules/RuleValue.swift`), so
//! merging (inheritance, variants, user patches) works on the document as written.
//!
//! Read with `serde_json` into the same permissive tree Swift builds with `JSONSerialization`:
//! numbers become `f64`, booleans stay booleans, the top level must be an object.

use std::collections::BTreeMap;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RuleError {
    TooLarge,
    BadJson,
    UnsupportedFormat(String),
    NotAPack(String),
}

impl std::fmt::Display for RuleError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            RuleError::TooLarge => write!(f, "rules too large"),
            RuleError::BadJson => write!(f, "rules are not a JSON object"),
            RuleError::UnsupportedFormat(s) => write!(f, "unsupported format {s:?}"),
            RuleError::NotAPack(s) => write!(f, "not a pack: {s}"),
        }
    }
}

impl std::error::Error for RuleError {}

/// `ruleBytesLimit`: a pack larger than this is rejected before parsing.
pub const RULE_BYTES_LIMIT: usize = 65536;

/// A JSON value. Objects are kept sorted by key (Swift's dictionaries have no order; nothing
/// that reads this tree depends on one).
#[derive(Debug, Clone, PartialEq)]
pub enum RuleValue {
    Null,
    Bool(bool),
    Number(f64),
    String(String),
    Array(Vec<RuleValue>),
    Object(BTreeMap<String, RuleValue>),
}

impl RuleValue {
    /// Top level must be an object; anything else is `RuleError::BadJson`.
    pub fn parse(data: &[u8]) -> Result<RuleValue, RuleError> {
        let v: serde_json::Value = serde_json::from_slice(data).map_err(|_| RuleError::BadJson)?;
        if !v.is_object() {
            return Err(RuleError::BadJson);
        }
        Ok(Self::convert(&v))
    }

    fn convert(v: &serde_json::Value) -> RuleValue {
        match v {
            serde_json::Value::Null => RuleValue::Null,
            serde_json::Value::Bool(b) => RuleValue::Bool(*b),
            // Without `arbitrary_precision` every serde_json number has an f64 value.
            serde_json::Value::Number(n) => RuleValue::Number(n.as_f64().unwrap_or(f64::NAN)),
            serde_json::Value::String(s) => RuleValue::String(s.clone()),
            serde_json::Value::Array(a) => RuleValue::Array(a.iter().map(Self::convert).collect()),
            serde_json::Value::Object(o) => {
                RuleValue::Object(o.iter().map(|(k, v)| (k.clone(), Self::convert(v))).collect())
            }
        }
    }

    /// Spec §5.3: objects merge by key, `null` deletes, arrays and scalars replace.
    pub fn merged(&self, patch: &RuleValue) -> RuleValue {
        let RuleValue::Object(p) = patch else { return patch.clone() };
        let RuleValue::Object(base) = self else { return patch.stripping_nulls() };
        let mut base = base.clone();
        for (k, pv) in p {
            if let RuleValue::Null = pv {
                base.remove(k);
            } else if let Some(old) = base.get(k) {
                let m = old.merged(pv);
                base.insert(k.clone(), m);
            } else {
                base.insert(k.clone(), pv.stripping_nulls());
            }
        }
        RuleValue::Object(base)
    }

    fn stripping_nulls(&self) -> RuleValue {
        let RuleValue::Object(o) = self else { return self.clone() };
        let mut out = BTreeMap::new();
        for (k, v) in o {
            if let RuleValue::Null = v {
                continue;
            }
            out.insert(k.clone(), v.stripping_nulls());
        }
        RuleValue::Object(out)
    }

    /// Swift's `value[key]`: the member of an object, `None` for a missing key or a non-object.
    pub fn get(&self, key: &str) -> Option<&RuleValue> {
        match self {
            RuleValue::Object(o) => o.get(key),
            _ => None,
        }
    }

    pub fn as_str(&self) -> Option<&str> {
        match self {
            RuleValue::String(s) => Some(s),
            _ => None,
        }
    }
    pub fn as_number(&self) -> Option<f64> {
        match self {
            RuleValue::Number(n) => Some(*n),
            _ => None,
        }
    }
    pub fn as_bool(&self) -> Option<bool> {
        match self {
            RuleValue::Bool(b) => Some(*b),
            _ => None,
        }
    }
    pub fn as_array(&self) -> Option<&Vec<RuleValue>> {
        match self {
            RuleValue::Array(a) => Some(a),
            _ => None,
        }
    }
    pub fn as_object(&self) -> Option<&BTreeMap<String, RuleValue>> {
        match self {
            RuleValue::Object(o) => Some(o),
            _ => None,
        }
    }
}

/// Swift's `Double(String)`: `strtod` in the C locale over the whole string, with leading
/// whitespace and the empty string rejected, and a result that overflows to infinity or
/// underflows to zero (`ERANGE`) rejected too. Accepts `inf`, `infinity`, `nan`, `nan(…)`,
/// `snan` and hexadecimal floats (`0x1.8p3`) as `strtod` does.
pub(crate) fn swift_double(s: &str) -> Option<f64> {
    let b = s.as_bytes();
    match b.first() {
        None | Some(9..=13) | Some(32) => return None,
        _ => {}
    }
    // `withCString` stops at an interior NUL; `strtod` then ends there and Swift accepts.
    let s = match s.find('\0') {
        Some(at) => &s[..at],
        None => s,
    };
    if s.is_empty() {
        return None;
    }
    let (neg, body) = match s.as_bytes()[0] {
        b'+' => (false, &s[1..]),
        b'-' => (true, &s[1..]),
        _ => (false, s),
    };
    let sign = |v: f64| if neg { -v } else { v };
    let lower = body.to_ascii_lowercase();
    if lower == "snan" || lower == "nan" {
        return Some(sign(f64::NAN));
    }
    if let Some(rest) = lower.strip_prefix("nan(") {
        let ok = rest.strip_suffix(')').is_some_and(|inner| inner.bytes().all(|c| c.is_ascii_alphanumeric() || c == b'_'));
        return if ok { Some(sign(f64::NAN)) } else { None };
    }
    if lower == "inf" || lower == "infinity" {
        return Some(sign(f64::INFINITY));
    }
    if lower.starts_with("0x") {
        return hex_double(&body[2..]).map(sign);
    }
    // Plain decimal. Rust's parser takes the same forms (`1.`, `.5`, `1e5`) apart from the
    // words handled above; it never fails on range, so ERANGE is checked by hand.
    if !body.bytes().next().is_some_and(|c| c.is_ascii_digit() || c == b'.') {
        return None;
    }
    let v: f64 = body.parse().ok()?;
    if v.is_infinite() {
        return None;
    }
    if v == 0.0 {
        let mantissa = body.split(['e', 'E']).next().unwrap_or("");
        if mantissa.bytes().any(|c| (b'1'..=b'9').contains(&c)) {
            return None;
        }
    }
    Some(sign(v))
}

/// The digits after `0x`: hex digits with an optional point, then an optional binary
/// exponent `p[+-]digits`. At least one hex digit. Mantissas beyond 64 bits keep a sticky
/// bit, so the result may differ from `strtod` in the last place for very long inputs.
fn hex_double(s: &str) -> Option<f64> {
    let (mant, exp) = match s.find(['p', 'P']) {
        Some(at) => (&s[..at], Some(&s[at + 1..])),
        None => (s, None),
    };
    let (int, frac) = match mant.find('.') {
        Some(at) => (&mant[..at], &mant[at + 1..]),
        None => (mant, ""),
    };
    if int.is_empty() && frac.is_empty() {
        return None;
    }
    if !int.bytes().chain(frac.bytes()).all(|c| c.is_ascii_hexdigit()) {
        return None;
    }
    let mut e2: i64 = 0;
    if let Some(e) = exp {
        let (eneg, digits) = match e.as_bytes().first() {
            Some(b'+') => (false, &e[1..]),
            Some(b'-') => (true, &e[1..]),
            _ => (false, e),
        };
        if digits.is_empty() || !digits.bytes().all(|c| c.is_ascii_digit()) {
            return None;
        }
        let mut v: i64 = 0;
        for c in digits.bytes() {
            v = v.saturating_mul(10).saturating_add((c - b'0') as i64);
        }
        e2 = if eneg { -v } else { v };
    }
    let mut m: u64 = 0;
    let mut sticky = false;
    let mut shift: i64 = 0;
    for (i, c) in int.bytes().chain(frac.bytes()).enumerate() {
        let d = (c as char).to_digit(16).unwrap_or(0) as u64;
        if m >> 60 == 0 {
            m = (m << 4) | d;
            if i >= int.len() {
                shift -= 4;
            }
        } else {
            sticky |= d != 0;
            if i < int.len() {
                shift += 4;
            }
        }
    }
    if sticky {
        m |= 1;
    }
    let total = e2.saturating_add(shift);
    let v = (m as f64) * 2f64.powi(total.clamp(-1100, 1100) as i32);
    if m != 0 && (v == 0.0 || v.is_infinite()) {
        return None;
    }
    Some(v)
}

/// Swift's `Double.description` (what `String(n)` gives): the shortest digits that read back
/// as `n`, in decimal when `1e-4 <= |n| < 2^53` (with `.0` added to whole numbers), else in
/// exponential form with a signed exponent of at least two digits (`1e+16`, `1.5e-05`).
pub fn swift_double_description(n: f64) -> String {
    if n.is_nan() {
        return "nan".into();
    }
    if n.is_infinite() {
        return if n < 0.0 { "-inf".into() } else { "inf".into() };
    }
    if n == 0.0 {
        return if n.is_sign_negative() { "-0.0".into() } else { "0.0".into() };
    }
    let a = n.abs();
    if (1e-4..9007199254740992.0).contains(&a) {
        let s = format!("{n}");
        return if s.contains('.') { s } else { s + ".0" };
    }
    let s = format!("{n:e}");
    let (mant, exp) = s.split_once('e').unwrap_or((&s, "0"));
    let e: i32 = exp.parse().unwrap_or(0);
    format!("{}e{}{:02}", mant, if e < 0 { '-' } else { '+' }, e.unsigned_abs())
}
