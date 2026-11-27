//! A rule pack decoded from its `RuleValue` tree (`StateRules/RulePack.swift`). Decoding is
//! tolerant (spec §5.4): only a bad `format`, a missing `id` or a bad `rev` rejects the pack;
//! everything else that cannot be read becomes `unknown` / unusable / `never`.

use std::collections::{BTreeMap, BTreeSet};

use super::rule_value::{swift_double, RuleError, RuleValue, RULE_BYTES_LIMIT};
use crate::geometry::{swift_max, swift_min};

// MARK: - Regions (spec §4.2)

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Side {
    Left,
    Right,
    Top,
    Bottom,
}

impl Side {
    pub fn from_raw(s: &str) -> Option<Side> {
        match s {
            "left" => Some(Side::Left),
            "right" => Some(Side::Right),
            "top" => Some(Side::Top),
            "bottom" => Some(Side::Bottom),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Pick {
    Rightmost,
    Leftmost,
    Topmost,
    Bottommost,
    Largest,
    All,
}

impl Pick {
    pub fn from_raw(s: &str) -> Option<Pick> {
        match s {
            "rightmost" => Some(Pick::Rightmost),
            "leftmost" => Some(Pick::Leftmost),
            "topmost" => Some(Pick::Topmost),
            "bottommost" => Some(Pick::Bottommost),
            "largest" => Some(Pick::Largest),
            "all" => Some(Pick::All),
            _ => None,
        }
    }
}

/// `160` or `"40%"`.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Length {
    Points(f64),
    Percent(f64),
}

#[derive(Debug, Clone, PartialEq)]
pub enum RegionRef {
    Named(String),
    Inline(Box<RegionSpec>),
}

#[derive(Debug, Clone, PartialEq)]
pub enum RegionSpec {
    Box(BoxSpec),
    Edge(EdgeSpec),
    Blob(BlobSpec),
    Strip(StripSpec),
    Unknown,
}

#[derive(Debug, Clone, PartialEq, Default)]
pub struct BoxSpec {
    /// JSON `in`.
    pub inside: Option<RegionRef>,
    pub right_of: Option<String>,
    pub left_of: Option<String>,
    pub above: Option<String>,
    pub below: Option<String>,
    pub top: Option<Length>,
    pub bottom: Option<Length>,
    pub left: Option<Length>,
    pub right: Option<Length>,
    pub width: Option<Length>,
    pub height: Option<Length>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct EdgeSpec {
    pub inside: Option<RegionRef>,
    pub from: Side,
    pub min: f64,
    pub max: f64,
}

/// `size` is Swift's `ClosedRange<Double>`, kept as `(lower, upper)` with `lower <= upper`.
#[derive(Debug, Clone, PartialEq)]
pub struct BlobSpec {
    pub inside: RegionRef,
    pub round: bool,
    pub size: (f64, f64),
    pub pick: Pick,
}

#[derive(Debug, Clone, PartialEq)]
pub struct StripSpec {
    pub of: RegionRef,
    pub side: Side,
    pub width: f64,
}

/// `ClosedRange.contains`: `lower <= x && x <= upper`.
pub(crate) fn range_contains(r: (f64, f64), x: f64) -> bool {
    r.0 <= x && x <= r.1
}

// MARK: - Signals (spec §4.3)

/// A hue range that crosses 0 (e.g. `[340, 20]`) is stored as the sorted range plus
/// `h_wraps`: the accepted hues are then *outside* `h`.
#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub struct ColorRange {
    pub h: Option<(f64, f64)>,
    pub h_wraps: bool,
    pub s: Option<(f64, f64)>,
    pub l: Option<(f64, f64)>,
}

impl ColorRange {
    pub fn hue_contains(&self, hue: f64) -> bool {
        let Some(h) = self.h else { return true };
        if self.h_wraps {
            !(h.0 < hue && hue < h.1)
        } else {
            range_contains(h, hue)
        }
    }

    /// Colour names (brief Task 5). Hue in degrees, s/l in percent.
    pub fn named(name: &str) -> Option<ColorRange> {
        let c = |h: Option<(f64, f64)>, w: bool, s: (f64, f64), l: (f64, f64)| ColorRange {
            h,
            h_wraps: w,
            s: Some(s),
            l: Some(l),
        };
        match name {
            "green" => Some(c(Some((90.0, 170.0)), false, (25.0, 100.0), (20.0, 80.0))),
            "red" => Some(c(Some((15.0, 345.0)), true, (30.0, 100.0), (20.0, 80.0))),
            "orange" => Some(c(Some((15.0, 45.0)), false, (40.0, 100.0), (25.0, 80.0))),
            "blue" => Some(c(Some((190.0, 250.0)), false, (25.0, 100.0), (20.0, 80.0))),
            "gray" | "grey" => Some(c(None, false, (0.0, 12.0), (25.0, 85.0))),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub enum Detect {
    Shape(String, f64),
    Color(ColorRange),
    Motion { window: f64, min: f64 },
    Text(Vec<String>),
    Present,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub enum SignalStatus {
    Tested,
    Seen,
    Reported,
    #[default]
    Untested,
}

impl SignalStatus {
    pub fn from_raw(s: &str) -> Option<SignalStatus> {
        match s {
            "tested" => Some(SignalStatus::Tested),
            "seen" => Some(SignalStatus::Seen),
            "reported" => Some(SignalStatus::Reported),
            "untested" => Some(SignalStatus::Untested),
            _ => None,
        }
    }
    pub fn raw(&self) -> &'static str {
        match self {
            SignalStatus::Tested => "tested",
            SignalStatus::Seen => "seen",
            SignalStatus::Reported => "reported",
            SignalStatus::Untested => "untested",
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct SignalSpec {
    pub region: Option<RegionRef>,
    pub detects: Vec<Detect>,
    pub count: bool,
    pub needs: BTreeSet<String>,
    pub status: SignalStatus,
    pub usable: bool,
}

impl Default for SignalSpec {
    fn default() -> Self {
        SignalSpec {
            region: None,
            detects: Vec::new(),
            count: false,
            needs: BTreeSet::new(),
            status: SignalStatus::Untested,
            usable: true,
        }
    }
}

// MARK: - States (spec §4.4)

#[derive(Debug, Clone, PartialEq)]
pub enum Condition {
    Signal(String),
    Any(Vec<Condition>),
    All(Vec<Condition>),
    Not(Box<Condition>),
    Never,
}

impl Condition {
    /// `.never` only comes from an unreadable form, so any `.never` inside poisons the
    /// condition.
    fn has_never(&self) -> bool {
        match self {
            Condition::Never => true,
            Condition::Signal(_) => false,
            Condition::Not(c) => c.has_never(),
            Condition::Any(cs) | Condition::All(cs) => cs.iter().any(|c| c.has_never()),
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct StateRow {
    pub state: String,
    pub kind: Option<String>,
    pub when: Option<Condition>,
    pub hold: f64,
    pub release: f64,
}

impl StateRow {
    pub fn new(state: &str) -> StateRow {
        StateRow { state: state.to_string(), kind: None, when: None, hold: 0.0, release: 0.0 }
    }
}

/// `when` is kept raw; the engine judges it.
#[derive(Debug, Clone, PartialEq)]
pub struct VariantSpec {
    pub name: String,
    pub when: RuleValue,
    pub patch: RuleValue,
}

// MARK: - Pack

/// Equality as Swift's synthesized `Equatable`: a NaN anywhere makes two packs unequal.
#[derive(Debug, Clone, PartialEq)]
pub struct RulePack {
    pub id: String,
    pub name: String,
    pub rev: i64,
    pub regions: BTreeMap<String, RegionSpec>,
    pub signals: BTreeMap<String, SignalSpec>,
    pub states: Vec<StateRow>,
    pub require: Vec<String>,
    pub variants: Vec<VariantSpec>,
}

const STATE_WORDS: [&str; 4] = ["working", "done", "blocked", "idle"];

impl RulePack {
    /// Size check, then `RuleValue::parse`.
    pub fn parse(data: &[u8]) -> Result<RuleValue, RuleError> {
        if data.len() > RULE_BYTES_LIMIT {
            return Err(RuleError::TooLarge);
        }
        RuleValue::parse(data)
    }

    /// Tolerant decode (spec §5.4): only a bad `format` or missing `id` rejects the pack.
    pub fn decode(v: &RuleValue) -> Result<RulePack, RuleError> {
        let Some(format) = v.get("format").and_then(|f| f.as_str()) else {
            return Err(RuleError::UnsupportedFormat(String::new()));
        };
        // `split(separator:omittingEmptySubsequences: false).first` is the text before the
        // first ".", possibly empty; Swift's `Int(_:)` takes an optional sign and digits.
        let major = format.split('.').next().unwrap_or("");
        if swift_int(major) != Some(1) {
            return Err(RuleError::UnsupportedFormat(format.to_string()));
        }
        let id = match v.get("id").and_then(|i| i.as_str()) {
            Some(id) if !id.is_empty() => id.to_string(),
            _ => return Err(RuleError::NotAPack("id".into())),
        };
        // rev is absent (0) or an integer in 0...Int32.max; anything else rejects the pack
        // (the GUI does the same).
        let mut rev = 0i64;
        if let Some(raw) = v.get("rev") {
            match raw.as_number() {
                Some(n) if n == n.trunc() && (0.0..=2147483647.0).contains(&n) => rev = n as i64,
                _ => return Err(RuleError::NotAPack("rev".into())),
            }
        }
        let mut regions = BTreeMap::new();
        if let Some(o) = v.get("regions").and_then(|r| r.as_object()) {
            for (k, r) in o {
                regions.insert(k.clone(), decode_region(r));
            }
        }
        let mut signals = BTreeMap::new();
        if let Some(o) = v.get("signals").and_then(|s| s.as_object()) {
            for (k, s) in o {
                signals.insert(k.clone(), decode_signal(s));
            }
        }
        let mut states = Vec::new();
        for row in v.get("states").and_then(|s| s.as_array()).map(|a| a.as_slice()).unwrap_or(&[]) {
            let Some(state) = row.get("state").and_then(|s| s.as_str()) else { continue };
            if !STATE_WORDS.contains(&state) {
                continue;
            }
            states.push(StateRow {
                state: state.to_string(),
                kind: row.get("kind").and_then(|k| k.as_str()).map(str::to_string),
                when: row.get("when").map(decode_condition),
                hold: row.get("hold").and_then(|h| h.as_number()).unwrap_or(0.0),
                release: row.get("release").and_then(|r| r.as_number()).unwrap_or(0.0),
            });
        }
        let mut variants = Vec::new();
        let items = v.get("variants").and_then(|a| a.as_array()).map(|a| a.as_slice()).unwrap_or(&[]);
        for (i, item) in items.iter().enumerate() {
            if item.as_object().is_none() {
                continue;
            }
            let Some(when) = item.get("when") else { continue };
            variants.push(VariantSpec {
                name: item.get("name").and_then(|n| n.as_str()).map(str::to_string).unwrap_or_else(|| format!("#{i}")),
                when: when.clone(),
                patch: item.get("patch").cloned().unwrap_or(RuleValue::Object(BTreeMap::new())),
            });
        }
        let require = v
            .get("require")
            .and_then(|a| a.as_array())
            .map(|a| a.iter().filter_map(|x| x.as_str().map(str::to_string)).collect())
            .unwrap_or_default();
        Ok(RulePack {
            name: v.get("name").and_then(|n| n.as_str()).map(str::to_string).unwrap_or_else(|| id.clone()),
            id,
            rev,
            regions,
            signals,
            states,
            require,
            variants,
        })
    }
}

/// Swift's `Int(String)`: an optional `+`/`-`, then one or more ASCII digits, within `Int`.
pub(crate) fn swift_int(s: &str) -> Option<i64> {
    let digits = s.strip_prefix(['+', '-']).unwrap_or(s);
    if digits.is_empty() || !digits.bytes().all(|c| c.is_ascii_digit()) {
        return None;
    }
    s.parse::<i64>().ok()
}

// MARK: regions

fn decode_ref(v: Option<&RuleValue>) -> Option<RegionRef> {
    match v {
        Some(RuleValue::String(s)) => Some(RegionRef::Named(s.clone())),
        Some(o @ RuleValue::Object(_)) => Some(RegionRef::Inline(Box::new(decode_region(o)))),
        _ => None,
    }
}

fn decode_length(v: &RuleValue) -> Option<Length> {
    if let Some(n) = v.as_number() {
        return Some(Length::Points(n));
    }
    if let Some(s) = v.as_str() {
        if let Some(rest) = s.strip_suffix('%') {
            // Swift's `hasSuffix("%")` + `dropLast()` work on Characters; a string whose last
            // Character is exactly "%" ends in the byte '%', so stripping it is the same.
            if let Some(n) = swift_double(rest) {
                return Some(Length::Percent(n));
            }
        }
    }
    None
}

fn decode_region(v: &RuleValue) -> RegionSpec {
    if v.as_object().is_none() {
        return RegionSpec::Unknown;
    }
    for kind in ["box", "edge", "blob", "strip"] {
        let Some(body) = v.get(kind) else { continue };
        return decode_region_body(kind, body).unwrap_or(RegionSpec::Unknown);
    }
    RegionSpec::Unknown
}

fn decode_region_body(kind: &str, b: &RuleValue) -> Option<RegionSpec> {
    b.as_object()?;
    // A present but malformed region reference makes the whole region unusable.
    let mut inside = None;
    if let Some(raw) = b.get("in") {
        inside = Some(decode_ref(Some(raw))?);
    }
    match kind {
        "box" => {
            let mut bx = BoxSpec { inside, ..BoxSpec::default() };
            for key in ["rightOf", "leftOf", "above", "below"] {
                if let Some(raw) = b.get(key) {
                    let s = raw.as_str()?.to_string();
                    match key {
                        "rightOf" => bx.right_of = Some(s),
                        "leftOf" => bx.left_of = Some(s),
                        "above" => bx.above = Some(s),
                        _ => bx.below = Some(s),
                    }
                }
            }
            for key in ["top", "bottom", "left", "right", "width", "height"] {
                if let Some(raw) = b.get(key) {
                    let l = decode_length(raw)?;
                    match key {
                        "top" => bx.top = Some(l),
                        "bottom" => bx.bottom = Some(l),
                        "left" => bx.left = Some(l),
                        "right" => bx.right = Some(l),
                        "width" => bx.width = Some(l),
                        _ => bx.height = Some(l),
                    }
                }
            }
            Some(RegionSpec::Box(bx))
        }
        "edge" => {
            let from = b.get("from").and_then(|f| f.as_str()).and_then(Side::from_raw)?;
            let lo = b.get("min").and_then(|n| n.as_number())?;
            let hi = b.get("max").and_then(|n| n.as_number())?;
            Some(RegionSpec::Edge(EdgeSpec { inside, from, min: lo, max: hi }))
        }
        "blob" => {
            let inside = inside?;
            let size = b.get("size").and_then(|s| s.as_array())?;
            if size.len() != 2 {
                return None;
            }
            let lo = size[0].as_number()?;
            let hi = size[1].as_number()?;
            if !(lo <= hi) {
                return None;
            }
            let mut pick = Pick::Largest;
            if let Some(raw) = b.get("pick") {
                pick = raw.as_str().and_then(Pick::from_raw)?;
            }
            let round = b.get("round").and_then(|r| r.as_bool()).unwrap_or(false);
            Some(RegionSpec::Blob(BlobSpec { inside, round, size: (lo, hi), pick }))
        }
        "strip" => {
            let of = decode_ref(b.get("of"))?;
            let side = b.get("side").and_then(|s| s.as_str()).and_then(Side::from_raw)?;
            let w = b.get("width").and_then(|w| w.as_number())?;
            Some(RegionSpec::Strip(StripSpec { of, side, width: w }))
        }
        _ => None,
    }
}

// MARK: signals

fn decode_signal(v: &RuleValue) -> SignalSpec {
    let mut sig = SignalSpec {
        region: decode_ref(v.get("in")),
        count: v.get("count").and_then(|c| c.as_bool()).unwrap_or(false),
        status: v.get("status").and_then(|s| s.as_str()).and_then(SignalStatus::from_raw).unwrap_or_default(),
        needs: v
            .get("needs")
            .and_then(|n| n.as_array())
            .map(|a| a.iter().filter_map(|x| x.as_str().map(str::to_string)).collect())
            .unwrap_or_default(),
        ..SignalSpec::default()
    };
    let detect = match v.get("detect").and_then(|d| d.as_object()) {
        Some(d) if !d.is_empty() => d,
        _ => {
            sig.usable = false;
            return sig;
        }
    };
    const KNOWN: [&str; 5] = ["shape", "color", "motion", "text", "present"];
    if !detect.keys().all(|k| KNOWN.contains(&k.as_str())) {
        sig.usable = false;
    }
    if let Some(s) = detect.get("shape") {
        if let Some(name) = s.as_str() {
            sig.detects.push(Detect::Shape(name.to_string(), 0.0));
            sig.needs.insert("pixels".into());
        } else if let Some(name) = s.get("is").and_then(|n| n.as_str()) {
            let min = s.get("min").and_then(|m| m.as_number()).unwrap_or(0.0);
            sig.detects.push(Detect::Shape(name.to_string(), min));
            sig.needs.insert("pixels".into());
        } else {
            sig.usable = false;
        }
    }
    if let Some(c) = detect.get("color") {
        if let Some(range) = decode_color(c) {
            sig.detects.push(Detect::Color(range));
            sig.needs.insert("pixels".into());
        } else {
            sig.usable = false;
        }
    }
    if let Some(m) = detect.get("motion") {
        if m.as_object().is_some() {
            sig.detects.push(Detect::Motion {
                window: m.get("window").and_then(|w| w.as_number()).unwrap_or(0.4),
                min: m.get("min").and_then(|w| w.as_number()).unwrap_or(0.02),
            });
        } else {
            sig.usable = false;
        }
    }
    if let Some(t) = detect.get("text") {
        match t.as_array() {
            Some(a) if a.iter().all(|x| x.as_str().is_some()) => {
                sig.detects.push(Detect::Text(a.iter().filter_map(|x| x.as_str().map(str::to_string)).collect()));
                sig.needs.insert("text".into());
            }
            _ => sig.usable = false,
        }
    }
    if let Some(p) = detect.get("present") {
        if p.as_bool() == Some(true) {
            sig.detects.push(Detect::Present);
            sig.needs.insert("pixels".into());
        } else {
            sig.usable = false;
        }
    }
    sig
}

fn decode_color(v: &RuleValue) -> Option<ColorRange> {
    if let Some(name) = v.as_str() {
        return ColorRange::named(name);
    }
    v.as_object()?;
    // `Some(None)`: absent (fine); `None`: present but malformed (the colour fails).
    let pair = |key: &str| -> Option<Option<(f64, f64)>> {
        let Some(raw) = v.get(key) else { return Some(None) };
        let a = raw.as_array()?;
        if a.len() != 2 {
            return None;
        }
        Some(Some((a[0].as_number()?, a[1].as_number()?)))
    };
    let h = pair("h")?;
    let s = pair("s")?;
    let l = pair("l")?;
    let sorted = |p: (f64, f64)| (swift_min(p.0, p.1), swift_max(p.0, p.1));
    let mut out = ColorRange::default();
    if let Some(h) = h {
        out.h_wraps = h.0 > h.1;
        out.h = Some(sorted(h));
    }
    if let Some(s) = s {
        out.s = Some(sorted(s));
    }
    if let Some(l) = l {
        out.l = Some(sorted(l));
    }
    Some(out)
}

// MARK: conditions

fn decode_condition(v: &RuleValue) -> Condition {
    if let Some(s) = v.as_str() {
        return Condition::Signal(s.to_string());
    }
    let Some(o) = v.as_object() else { return Condition::Never };
    if o.len() != 1 {
        return Condition::Never;
    }
    let Some((key, arg)) = o.iter().next() else { return Condition::Never };
    match key.as_str() {
        "any" | "all" => {
            let items = match arg.as_array() {
                Some(a) if !a.is_empty() => a,
                _ => return Condition::Never,
            };
            let subs: Vec<Condition> = items.iter().map(decode_condition).collect();
            // An unreadable form anywhere makes the whole condition never match (even under
            // `not`/`any`).
            if subs.iter().any(|c| c.has_never()) {
                return Condition::Never;
            }
            if key == "any" {
                Condition::Any(subs)
            } else {
                Condition::All(subs)
            }
        }
        "not" => {
            let sub = decode_condition(arg);
            if sub.has_never() {
                Condition::Never
            } else {
                Condition::Not(Box::new(sub))
            }
        }
        _ => Condition::Never,
    }
}
