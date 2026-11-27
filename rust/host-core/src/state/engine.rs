//! The per-session engine (spec §5.1, §7; `StateRules/StateEngine.swift`): picks pack
//! variants, runs detectors and the state table each frame, checks that the pack still fits
//! the app, and produces the report. Time is injected.

use std::collections::{BTreeMap, BTreeSet, HashMap};

use unicode_segmentation::UnicodeSegmentation;

use super::detectors::{swift_lowercased, SignalEvaluator, TextReader};
use super::regions::resolve_regions;
use super::rule_image::{RuleImage, RuleRect};
use super::rule_pack::{swift_int, RulePack, SignalStatus, VariantSpec};
use super::rule_value::{swift_double, swift_double_description, RuleError, RuleValue};
use super::table::{signals_in, StateTable};
use crate::geometry::{swift_max, swift_min};
use crate::protocol::APP_STATE_LIMIT;

pub struct RuleEnv {
    pub app_version: Option<String>,
    /// `"macos"`, `"windows"`.
    pub os: String,
    /// The first preferred language.
    pub locale: String,
    /// `"pixels"`, `"text"`.
    pub caps: BTreeSet<String>,
    pub reread_version: Box<dyn FnMut() -> Option<String> + Send>,
}

pub const HEALTH_ROUNDS: i64 = 5;
/// At most this many `count` keys go into a report.
pub const REPORT_COUNT_KEYS: usize = 32;

/// Swift's `String(s.prefix(n))`: the first `n` Characters.
fn prefix(s: &str, n: usize) -> String {
    s.graphemes(true).take(n).collect()
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AppStateReport {
    pub pack: Option<String>,
    pub rev: Option<i64>,
    pub state: Option<String>,
    pub kind: Option<String>,
    pub by: Vec<String>,
    pub sure: bool,
    pub counts: BTreeMap<String, i64>,
    /// `"ok"` | `"switched"` | `"unfit"` | `"invalid"`
    pub health: String,
    pub variants: Vec<String>,
    pub app_version: Option<String>,
    pub caps: Vec<String>,
    pub error: Option<String>,
}

impl Default for AppStateReport {
    fn default() -> Self {
        AppStateReport {
            pack: None,
            rev: None,
            state: None,
            kind: None,
            by: Vec::new(),
            sure: false,
            counts: BTreeMap::new(),
            health: "ok".to_string(),
            variants: Vec::new(),
            app_version: None,
            caps: Vec::new(),
            error: None,
        }
    }
}

fn clip(s: &Option<String>, n: usize) -> Option<String> {
    s.as_ref().map(|s| prefix(s, n))
}

type Shrink = fn(&mut AppStateReport);

impl AppStateReport {
    pub fn invalid(error: &RuleError, caps: Vec<String>, app_version: Option<String>) -> AppStateReport {
        let text = match error {
            RuleError::TooLarge => "too large".to_string(),
            RuleError::BadJson => "bad json".to_string(),
            RuleError::UnsupportedFormat(f) => "unsupported format ".to_string() + &prefix(f, 32),
            RuleError::NotAPack(w) => "not a pack: ".to_string() + &prefix(w, 32),
        };
        AppStateReport {
            health: "invalid".to_string(),
            app_version,
            caps,
            error: Some(text),
            ..AppStateReport::default()
        }
    }

    /// Sorted keys, `inferred` always true, `None` as null. Never more than `APP_STATE_LIMIT`
    /// UTF-8 bytes: when it would be, the lowest-value fields go first (counts, then long
    /// text, then lists).
    pub fn json(&self) -> String {
        let shrinks: [Shrink; 8] = [
            |r| r.counts = Self::first_counts(&r.counts, 16),
            |r| r.counts = Self::first_counts(&r.counts, 4),
            |r| r.counts = BTreeMap::new(),
            |r| r.error = clip(&r.error, 200),
            |r| {
                r.by.truncate(8);
                r.variants.truncate(8);
                r.caps.truncate(8);
            },
            |r| {
                r.by = r.by.iter().map(|s| prefix(s, 48)).collect();
                r.variants = r.variants.iter().map(|s| prefix(s, 48)).collect();
                r.caps = r.caps.iter().map(|s| prefix(s, 48)).collect();
                r.pack = clip(&r.pack, 64);
                r.kind = clip(&r.kind, 64);
                r.app_version = clip(&r.app_version, 64);
                r.error = clip(&r.error, 64);
            },
            |r| {
                r.by = Vec::new();
                r.variants = Vec::new();
                r.caps = Vec::new();
                r.error = clip(&r.error, 32);
            },
            |r| {
                let keep = ["working", "done", "blocked", "idle"].contains(&r.state.as_deref().unwrap_or(""));
                *r = AppStateReport {
                    state: if keep { r.state.clone() } else { None },
                    health: r.health.clone(),
                    ..AppStateReport::default()
                };
            },
        ];
        let mut r = self.clone();
        let mut s = r.encode();
        // `for shrink in shrinks where s.utf8.count > appStateLimit`: the condition is checked
        // before each step with the latest `s`.
        for shrink in shrinks {
            if s.len() <= APP_STATE_LIMIT {
                continue;
            }
            shrink(&mut r);
            s = r.encode();
        }
        s
    }

    fn first_counts(c: &BTreeMap<String, i64>, n: usize) -> BTreeMap<String, i64> {
        c.iter().take(n).map(|(k, v)| (k.clone(), *v)).collect()
    }

    /// `JSONSerialization` with `.sortedKeys, .withoutEscapingSlashes`. Keys are written in
    /// byte order (see the notes: Foundation's sorted-key order can differ for non-ASCII or
    /// mixed-case `counts` keys; the byte length cannot).
    fn encode(&self) -> String {
        use serde_json::Value;
        let opt = |s: &Option<String>| s.clone().map(Value::String).unwrap_or(Value::Null);
        let list = |l: &Vec<String>| Value::Array(l.iter().cloned().map(Value::String).collect());
        let mut counts = serde_json::Map::new();
        // Inserted in key order, so the output is sorted whether or not `preserve_order` is on.
        for (k, v) in &self.counts {
            counts.insert(k.clone(), Value::from(*v));
        }
        let mut o: BTreeMap<&str, Value> = BTreeMap::new();
        o.insert("pack", opt(&self.pack));
        o.insert("rev", self.rev.map(Value::from).unwrap_or(Value::Null));
        o.insert("state", opt(&self.state));
        o.insert("kind", opt(&self.kind));
        o.insert("by", list(&self.by));
        o.insert("sure", Value::Bool(self.sure));
        o.insert("counts", Value::Object(counts));
        o.insert("health", Value::String(self.health.clone()));
        o.insert("variants", list(&self.variants));
        o.insert("appVersion", opt(&self.app_version));
        o.insert("caps", list(&self.caps));
        o.insert("inferred", Value::Bool(true));
        if self.health == "invalid" {
            o.insert("error", opt(&self.error));
        }
        serde_json::to_string(&o).unwrap_or_else(|_| "{\"inferred\":true}".to_string())
    }
}

/// Swift's `split(separator: ".", omittingEmptySubsequences: false)`: it splits at Characters,
/// so a "." carrying a combining mark is not a separator.
fn dotted(s: &str) -> Vec<&str> {
    let mut out = Vec::new();
    let mut start = 0;
    for (i, g) in s.grapheme_indices(true) {
        if g == "." {
            out.push(&s[start..i]);
            start = i + 1;
        }
    }
    out.push(&s[start..]);
    out
}

/// Dotted numbers compared segment by segment; a missing segment counts as 0; a segment that
/// is not a number compares as a string.
pub fn compare_versions(a: &str, b: &str) -> i64 {
    let x = dotted(a);
    let y = dotted(b);
    for i in 0..swift_max(x.len(), y.len()) {
        let p = if i < x.len() { x[i] } else { "0" };
        let q = if i < y.len() { y[i] } else { "0" };
        if let (Some(m), Some(n)) = (swift_int(p), swift_int(q)) {
            if m != n {
                return if m < n { -1 } else { 1 };
            }
        } else {
            // Swift orders strings by their NFC scalars, and equivalent ones are equal.
            let (p, q) = (super::detectors::nfc(p), super::detectors::nfc(q));
            if p != q {
                return if p < q { -1 } else { 1 };
            }
        }
    }
    0
}

struct Selection {
    pack: RulePack,
    idx: Vec<usize>,
    regions: BTreeMap<String, Vec<RuleRect>>,
}

fn has_key(v: &VariantSpec, keys: &[&str]) -> bool {
    v.when.as_object().map(|o| keys.iter().any(|k| o.contains_key(*k))).unwrap_or(false)
}

/// `{min, max}` both inclusive; `compare` gives the sign of (value - bound), 2 for an
/// unreadable bound.
fn range_holds(v: &RuleValue, compare: impl Fn(&str) -> i64) -> bool {
    if v.as_object().is_none() {
        return false;
    }
    for (key, sign) in [("min", -1i64), ("max", 1i64)] {
        let Some(raw) = v.get(key) else { continue };
        let bound: String = if let Some(s) = raw.as_str() {
            s.to_string()
        } else if let Some(n) = raw.as_number().filter(|n| n.is_finite()) {
            swift_double_description(n)
        } else {
            return false;
        };
        let c = compare(&bound);
        if c == 2 || c == sign {
            return false;
        }
    }
    true
}

pub struct StateEngine {
    env: RuleEnv,
    base: RuleValue,
    base_pack: RulePack,
    evaluator: SignalEvaluator,
    caps_list: Vec<String>,
    app_version: Option<String>,

    pack_cache: HashMap<String, (RulePack, Vec<usize>)>,
    pack: RulePack,
    active: Vec<usize>,
    table: StateTable,
    have_frame: bool,

    forced: Option<usize>,
    tried: BTreeSet<usize>,
    rereaded: bool,
    switched: bool,
    unfit: bool,
    misses: i64,
    found_streak: i64,

    report: AppStateReport,
}

impl StateEngine {
    pub fn new(rules: &[u8], env: RuleEnv, text: Option<Box<dyn TextReader>>) -> Result<StateEngine, RuleError> {
        let value = RulePack::parse(rules)?;
        let pack = RulePack::decode(&value)?;
        let caps_list: Vec<String> = env.caps.iter().cloned().collect();
        let report = AppStateReport {
            pack: Some(pack.id.clone()),
            rev: Some(pack.rev),
            app_version: env.app_version.clone(),
            caps: caps_list.clone(),
            ..AppStateReport::default()
        };
        Ok(StateEngine {
            evaluator: SignalEvaluator::new(env.caps.clone(), text),
            table: StateTable::new(pack.states.clone()),
            app_version: env.app_version.clone(),
            caps_list,
            base: value,
            base_pack: pack.clone(),
            pack,
            env,
            pack_cache: HashMap::new(),
            active: Vec::new(),
            have_frame: false,
            forced: None,
            tried: BTreeSet::new(),
            rereaded: false,
            switched: false,
            unfit: false,
            misses: 0,
            found_streak: 0,
            report,
        })
    }

    /// The last report returned by `tick` (or the initial one).
    pub fn report(&self) -> &AppStateReport {
        &self.report
    }

    /// One round. `image`: the main window at one pixel per point, or `None` when no new frame
    /// came. `visible`: the window is on screen (only visible rounds count for the
    /// self-check). Returns the report when it differs from the last one returned. A
    /// non-finite `now` is skipped.
    pub fn tick(&mut self, image: Option<&RuleImage>, visible: bool, now: f64) -> Option<AppStateReport> {
        if !now.is_finite() {
            return None;
        }
        let mut frame = image;
        if let Some(f) = frame {
            // Swift's `width * height * 4` traps on overflow; an overflowing size is dropped here.
            let need = f.width.checked_mul(f.height).and_then(|n| n.checked_mul(4));
            if f.width == 0 || f.height == 0 || need.is_none_or(|n| f.pixels.len() < n) {
                frame = None;
            }
        }
        let mut regions: BTreeMap<String, Vec<RuleRect>> = BTreeMap::new();
        if let Some(frame) = frame {
            self.have_frame = true;
            let theme = estimate_theme(frame);
            let mut sel = self.select(frame, theme);
            if visible && self.self_check(&sel.regions, &sel.pack, &sel.idx) {
                sel = self.select(frame, theme);
            }
            if sel.idx != self.active || sel.pack != self.pack {
                self.active = sel.idx;
                self.pack = sel.pack;
                self.evaluator.reset();
                self.table = StateTable::new(self.pack.states.clone());
            }
            regions = sel.regions;
        }
        if !self.have_frame {
            return None;
        }

        let mut next = AppStateReport {
            pack: Some(self.pack.id.clone()),
            rev: Some(self.pack.rev),
            app_version: self.app_version.clone(),
            caps: self.caps_list.clone(),
            ..AppStateReport::default()
        };
        next.variants = self.active.iter().map(|&i| self.base_pack.variants[i].name.clone()).collect();
        next.health = if self.unfit {
            "unfit".to_string()
        } else if self.switched {
            "switched".to_string()
        } else {
            "ok".to_string()
        };
        if !self.unfit {
            let results = self.evaluator.evaluate(&self.pack, &regions, frame, now);
            let on: BTreeSet<String> = results.iter().filter(|(_, r)| r.holds).map(|(k, _)| k.clone()).collect();
            if let Some(row) = self.table.step(&on, now) {
                next.state = Some(row.state.clone());
                next.kind = row.kind.clone();
                let mentioned = row.when.as_ref().map(signals_in).unwrap_or_default();
                // A `BTreeSet` intersection iterates in sorted order.
                let by: Vec<String> = mentioned.intersection(&on).cloned().collect();
                next.sure = !by.is_empty()
                    && by.iter().all(|n| self.pack.signals.get(n).map(|s| s.status) == Some(SignalStatus::Tested));
                next.by = by;
            }
            for (name, r) in &results {
                if next.counts.len() >= REPORT_COUNT_KEYS {
                    continue;
                }
                let Some(c) = r.count else { continue };
                next.counts.insert(name.clone(), c);
            }
        }
        if next == self.report {
            return None;
        }
        self.report = next.clone();
        Some(next)
    }

    // MARK: variants

    fn versioned(&self) -> Vec<usize> {
        (0..self.base_pack.variants.len()).filter(|&i| has_key(&self.base_pack.variants[i], &["appVersion"])).collect()
    }

    /// The variant with the newest version range, used when the app version is unknown.
    fn newest_versioned(&self) -> Option<usize> {
        fn key(v: &VariantSpec) -> String {
            let o = v.when.get("appVersion");
            o.and_then(|o| o.get("max")).and_then(|m| m.as_str())
                .or_else(|| o.and_then(|o| o.get("min")).and_then(|m| m.as_str()))
                .unwrap_or("0")
                .to_string()
        }
        let mut best: Option<usize> = None;
        for i in self.versioned() {
            if best.is_none_or(|b| compare_versions(&key(&self.base_pack.variants[i]), &key(&self.base_pack.variants[b])) > 0) {
                best = Some(i);
            }
        }
        best
    }

    fn applies(&self, i: usize, found: Option<&BTreeSet<String>>, img: &RuleImage, theme: &str, newest: Option<usize>) -> bool {
        let v = &self.base_pack.variants[i];
        let Some(when) = v.when.as_object() else { return false };
        let is_versioned = when.contains_key("appVersion");
        // appVersion decided from outside (forced / unknown version)
        let mut version_ok = false;
        if is_versioned {
            if let Some(forced) = self.forced {
                if i != forced {
                    return false;
                }
                version_ok = true;
            } else if self.app_version.is_none() {
                if Some(i) != newest {
                    return false;
                }
                version_ok = true;
            }
        }
        for (key, arg) in when {
            match key.as_str() {
                "appVersion" => {
                    if version_ok {
                        continue;
                    }
                    let Some(ver) = &self.app_version else { return false };
                    if !range_holds(arg, |b| compare_versions(ver, b)) {
                        return false;
                    }
                }
                "os" => {
                    if arg.as_str() != Some(self.env.os.as_str()) {
                        return false;
                    }
                }
                "theme" => {
                    if arg.as_str() != Some(theme) {
                        return false;
                    }
                }
                "locale" => {
                    let Some(l) = arg.as_str().filter(|l| !l.is_empty()) else { return false };
                    let have = swift_lowercased(&self.env.locale);
                    let want = swift_lowercased(l);
                    if !(have == want
                        || have.starts_with(&(want.clone() + "-"))
                        || have.starts_with(&(want.clone() + "_")))
                    {
                        return false;
                    }
                }
                "windowWidth" => {
                    let w = img.width as f64;
                    let ok = range_holds(arg, |b| match swift_double(b) {
                        Some(n) => {
                            if w < n {
                                -1
                            } else if w > n {
                                1
                            } else {
                                0
                            }
                        }
                        None => 2,
                    });
                    if !ok {
                        return false;
                    }
                }
                "found" | "missing" => {
                    let Some(found) = found else { return false };
                    let Some(names) = arg.as_array() else { return false };
                    let mut all = true;
                    for n in names {
                        let Some(s) = n.as_str() else { return false };
                        if found.contains(s) != (key == "found") {
                            all = false;
                        }
                    }
                    if !all {
                        return false;
                    }
                }
                _ => return false,
            }
        }
        true
    }

    fn select(&mut self, img: &RuleImage, theme: &str) -> Selection {
        let region_keys = ["found", "missing"];
        let newest = if self.app_version.is_none() && self.forced.is_none() { self.newest_versioned() } else { None };
        let count = self.base_pack.variants.len();
        let early: Vec<usize> = (0..count)
            .filter(|&i| !has_key(&self.base_pack.variants[i], &region_keys) && self.applies(i, None, img, theme, newest))
            .collect();
        let (mut p, mut idx) = self.pack_for(&early);
        let mut regions = resolve_regions(&p, img);
        if self.base_pack.variants.iter().any(|v| has_key(v, &region_keys)) {
            let names: BTreeSet<String> = regions.keys().cloned().collect();
            let all: Vec<usize> = (0..count)
                .filter(|&i| {
                    early.contains(&i)
                        || (has_key(&self.base_pack.variants[i], &region_keys)
                            && self.applies(i, Some(&names), img, theme, newest))
                })
                .collect();
            if all != early {
                (p, idx) = self.pack_for(&all);
                regions = resolve_regions(&p, img);
            }
        }
        Selection { pack: p, idx, regions }
    }

    /// The base pack with the variants' patches laid on in order, and the variants that really
    /// went on: a patch whose merged result no longer decodes is left out (and not reported).
    fn pack_for(&mut self, idx: &[usize]) -> (RulePack, Vec<usize>) {
        if idx.is_empty() {
            return (self.base_pack.clone(), Vec::new());
        }
        let key = idx.iter().map(|i| i.to_string()).collect::<Vec<_>>().join(",");
        if let Some(hit) = self.pack_cache.get(&key) {
            return hit.clone();
        }
        let mut v = self.base.clone();
        let mut p = self.base_pack.clone();
        let mut used = Vec::new();
        for &i in idx {
            let merged = v.merged(&self.base_pack.variants[i].patch);
            let Ok(decoded) = RulePack::decode(&merged) else { continue };
            v = merged;
            p = decoded;
            used.push(i);
        }
        if self.pack_cache.len() >= 32 {
            self.pack_cache.clear();
        }
        self.pack_cache.insert(key, (p.clone(), used.clone()));
        (p, used)
    }

    // MARK: self-check (spec §7)

    /// Counts this visible round. Returns true when the variant choice changed and must be
    /// redone.
    fn self_check(&mut self, regions: &BTreeMap<String, Vec<RuleRect>>, pack: &RulePack, idx: &[usize]) -> bool {
        let found = pack.require.iter().all(|r| regions.contains_key(r));
        if self.unfit {
            self.found_streak = if found { self.found_streak + 1 } else { 0 };
            if self.found_streak >= HEALTH_ROUNDS {
                // Recovered: the whole search may run again later. `switched` is sticky: once
                // the engine changed variant or version by itself, the report keeps saying so.
                self.unfit = false;
                self.found_streak = 0;
                self.misses = 0;
                self.rereaded = false;
                self.tried.clear();
                self.evaluator.reset();
                self.table = StateTable::new(self.pack.states.clone());
            }
            return false;
        }
        if found {
            self.misses = 0;
            return false;
        }
        self.misses += 1;
        if self.misses < HEALTH_ROUNDS {
            return false;
        }
        self.misses = 0;
        let versioned_idx = self.versioned();
        self.tried.extend(idx.iter().copied().filter(|i| versioned_idx.contains(i)));
        if let Some(next) = versioned_idx.iter().copied().find(|i| !self.tried.contains(i)) {
            self.forced = Some(next);
            self.tried.insert(next);
            self.switched = true;
            return true;
        }
        if !self.rereaded {
            self.rereaded = true;
            if let Some(v) = (self.env.reread_version)() {
                if Some(&v) != self.app_version.as_ref() {
                    self.app_version = Some(v);
                    self.forced = None;
                    self.tried.clear();
                    self.switched = true;
                    return true;
                }
            }
        }
        self.unfit = true;
        self.found_streak = 0;
        false
    }
}

// MARK: theme

/// Median luminance of an 8x8 grid of points between 10% and 90% of the window.
fn estimate_theme(img: &RuleImage) -> &'static str {
    let mut lum: Vec<f64> = Vec::with_capacity(64);
    let (w, h) = (img.width as i64, img.height as i64);
    for j in 0..8 {
        for i in 0..8 {
            let x = swift_min(w - 1, (img.width as f64 * (0.1 + 0.8 * i as f64 / 7.0)) as i64);
            let y = swift_min(h - 1, (img.height as f64 * (0.1 + 0.8 * j as f64 / 7.0)) as i64);
            let p = img.rgb(x, y);
            lum.push((0.299 * p.0 as f64 + 0.587 * p.1 as f64 + 0.114 * p.2 as f64) / 255.0);
        }
    }
    lum.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
    if (lum[31] + lum[32]) / 2.0 < 0.5 {
        "dark"
    } else {
        "light"
    }
}
