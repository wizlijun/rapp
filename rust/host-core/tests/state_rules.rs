//! App-state rules against the Swift reference. Fixtures are written by
//! `Tests/RappCoreTests/HostCoreFixtures/StateRuleFixtures.swift`: `rule-pack.json`,
//! `rule-regions.json`, `rule-detectors.json`, `state-table.json`, `state-engine.json`, and the
//! frames they refer to by index in `rule-image.bin`.
//!
//! Frames are recipes for `Tests/RappCoreTests/RuleCanvas.swift`, ported below. Small frames also
//! carry their pixels (tag 1), big ones the SHA-256 of their pixels (tag 3); either way the port is
//! checked against Swift's drawing before any rule runs on it.

mod common;
mod rules_common;

use std::collections::{BTreeMap, BTreeSet};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering::SeqCst};
use std::sync::{Arc, OnceLock};

use common::{fixture_records, raw_cases, Reader};
use rapp_host_core::state::*;
use rules_common::func;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};

/// JSON equality where numbers compare as f64: Swift writes `2` for the Double 2.0.
fn same(a: &Value, b: &Value) -> bool {
    match (a, b) {
        (Value::Number(x), Value::Number(y)) => x.as_f64() == y.as_f64(),
        (Value::Array(x), Value::Array(y)) => x.len() == y.len() && x.iter().zip(y).all(|(p, q)| same(p, q)),
        (Value::Object(x), Value::Object(y)) => {
            x.len() == y.len() && x.iter().all(|(k, v)| y.get(k).is_some_and(|w| same(v, w)))
        }
        _ => a == b,
    }
}

fn check(name: &str, got: &Value, want: &Value) {
    assert!(same(got, want), "{name}:\n got  {got}\n want {want}");
}

// MARK: - Plain values

/// Numbers JSON cannot carry are the strings `nan`, `inf`, `-inf`.
fn num(v: &Value) -> f64 {
    match v {
        Value::String(s) => match s.as_str() {
            "nan" => f64::NAN,
            "inf" => f64::INFINITY,
            "-inf" => f64::NEG_INFINITY,
            other => panic!("not a number: {other}"),
        },
        _ => v.as_f64().unwrap_or_else(|| panic!("not a number: {v}")),
    }
}

fn jnum(x: f64) -> Value {
    if x.is_nan() {
        json!("nan")
    } else if x == f64::INFINITY {
        json!("inf")
    } else if x == f64::NEG_INFINITY {
        json!("-inf")
    } else {
        json!(x)
    }
}

fn s(v: &Value) -> String {
    v.as_str().unwrap_or_else(|| panic!("not a string: {v}")).to_string()
}

fn opt_s(v: &Value) -> Option<String> {
    v.as_str().map(str::to_string)
}

fn int(v: &Value) -> i64 {
    v.as_i64().unwrap_or_else(|| panic!("not an int: {v}"))
}

fn idx(v: &Value) -> usize {
    v.as_u64().unwrap_or_else(|| panic!("not an index: {v}")) as usize
}

fn strs(v: &Value) -> Vec<String> {
    v.as_array().unwrap_or_else(|| panic!("not an array: {v}")).iter().map(s).collect()
}

fn set(v: &Value) -> BTreeSet<String> {
    strs(v).into_iter().collect()
}

fn rect(r: &RuleRect) -> Value {
    json!({"x": r.x, "y": r.y, "w": r.w, "h": r.h})
}

fn dec_rect(v: &Value) -> RuleRect {
    RuleRect::new(int(&v["x"]), int(&v["y"]), int(&v["w"]), int(&v["h"]))
}

fn quad(v: &Value) -> RuleRect {
    let q = v.as_array().expect("[x, y, w, h]");
    RuleRect::new(int(&q[0]), int(&q[1]), int(&q[2]), int(&q[3]))
}

// MARK: - RuleCanvas.swift

type Rgb = (u8, u8, u8);
const WHITE: Rgb = (255, 255, 255);
const BLACK: Rgb = (0, 0, 0);

fn rgb(v: &Value) -> Rgb {
    let a = v.as_array().expect("[r, g, b]");
    (a[0].as_u64().unwrap() as u8, a[1].as_u64().unwrap() as u8, a[2].as_u64().unwrap() as u8)
}

/// Swift traps on an inverted range; Rust's empty range just draws nothing. The fixtures draw
/// none (the generator would have crashed).
fn fill(img: &mut RuleImage, r: RuleRect, c: Rgb) {
    let (x0, x1) = (r.x.max(0), (img.width as i64).min(r.x + r.w));
    let (y0, y1) = (r.y.max(0), (img.height as i64).min(r.y + r.h));
    for y in y0..y1 {
        for x in x0..x1 {
            let i = (y as usize * img.width + x as usize) * 4;
            img.pixels[i] = c.2;
            img.pixels[i + 1] = c.1;
            img.pixels[i + 2] = c.0;
            img.pixels[i + 3] = 255;
        }
    }
}

fn solid(width: usize, height: usize, c: Rgb) -> RuleImage {
    let mut img = RuleImage::new(width, height, vec![255; width * height * 4]);
    fill(&mut img, RuleRect::new(0, 0, width as i64, height as i64), c);
    img
}

fn disc(img: &mut RuleImage, x: i64, y: i64, size: i64, c: Rgb) {
    let r = size as f64 / 2.0;
    for py in 0..size {
        for px in 0..size {
            let dx = px as f64 + 0.5 - r;
            let dy = py as f64 + 0.5 - r;
            if !(dx * dx + dy * dy < r * r)
                || x + px < 0
                || y + py < 0
                || x + px >= img.width as i64
                || y + py >= img.height as i64
            {
                continue;
            }
            fill(img, RuleRect::new(x + px, y + py, 1, 1), c);
        }
    }
}

fn ring(img: &mut RuleImage, x: i64, y: i64, size: i64, thickness: i64, c: Rgb, hole: Rgb) {
    disc(img, x, y, size, c);
    disc(img, x + thickness, y + thickness, size - 2 * thickness, hole);
}

fn button(icon: &str) -> RuleImage {
    let mut img = solid(64, 64, WHITE);
    disc(&mut img, 16, 16, 32, BLACK);
    match icon {
        "square" => fill(&mut img, RuleRect::new(26, 26, 12, 12), WHITE),
        "arrow" => {
            fill(&mut img, RuleRect::new(30, 25, 4, 14), WHITE);
            for row in 0..7 {
                fill(&mut img, RuleRect::new(32 - (row + 1), 25 + row, 2 * (row + 1), 1), WHITE);
            }
        }
        _ => {}
    }
    img
}

struct Chat {
    width: i64,
    height: i64,
    sidebar: bool,
    dark: bool,
    dots: Option<Vec<String>>,
    spinner_phase: i64,
    tail_text: bool,
    button: String,
}

fn chat_window(c: &Chat) -> RuleImage {
    let g = |l: u8, d: u8| if c.dark { (d, d, d) } else { (l, l, l) };
    let (side, main, bx_c, ink, paper) = (g(240, 32), g(255, 18), g(244, 26), g(0, 240), g(255, 18));
    let (width, height) = (c.width, c.height);
    let mut img = solid(width as usize, height as usize, main);
    let left = if c.sidebar { 240 } else { 0 };
    if c.sidebar {
        fill(&mut img, RuleRect::new(0, 0, 240, height), side);
        let shown: Vec<Rgb> = match &c.dots {
            Some(d) => d.iter().map(|x| if x == "green" { (52, 199, 89) } else { (150, 150, 150) }).collect(),
            None => vec![ink, ink, ink],
        };
        for (i, col) in shown.iter().take(3).enumerate() {
            let lift: i64 = if c.spinner_phase == 0 { 0 } else { 30 };
            let up = |v: u8| (255i64.min(v as i64 + lift)) as u8;
            disc(&mut img, 210, 100 + 40 * i as i64, 12, (up(col.0), up(col.1), up(col.2)));
        }
    }
    if c.tail_text {
        fill(&mut img, RuleRect::new(left + 40, 300, 200, 14), (60, 60, 60));
    }
    fill(&mut img, RuleRect::new(left + 20, 500, width - left - 40, 80), bx_c);
    disc(&mut img, width - 60, 520, 32, ink);
    let (bx, by) = (width - 60, 520);
    match c.button.as_str() {
        "square" => fill(&mut img, RuleRect::new(width - 50, 530, 12, 12), paper),
        "arrow" => {
            fill(&mut img, RuleRect::new(bx + 14, by + 9, 4, 14), paper);
            for row in 0..7 {
                fill(&mut img, RuleRect::new(bx + 16 - (row + 1), by + 9 + row, 2 * (row + 1), 1), paper);
            }
        }
        _ => {}
    }
    img
}

/// Draws a recipe the way `StateRuleFixtures.render` does.
fn render(r: &Value) -> RuleImage {
    let usize_of = |k: &str| idx(&r[k]);
    let mut img = match r["canvas"].as_str().expect("canvas") {
        "solid" => solid(usize_of("width"), usize_of("height"), if r["color"].is_null() { WHITE } else { rgb(&r["color"]) }),
        "chatWindow" => chat_window(&Chat {
            width: r["width"].as_i64().unwrap_or(800),
            height: r["height"].as_i64().unwrap_or(600),
            sidebar: r["sidebar"].as_bool().unwrap_or(true),
            dark: r["dark"].as_bool().unwrap_or(false),
            dots: r.get("dots").map(strs),
            spinner_phase: r["spinnerPhase"].as_i64().unwrap_or(0),
            tail_text: r["tailText"].as_bool().unwrap_or(false),
            button: r["button"].as_str().unwrap_or("square").to_string(),
        }),
        "button" => button(r["icon"].as_str().unwrap()),
        "bareSquare" => {
            let mut img = solid(64, 64, WHITE);
            fill(&mut img, RuleRect::new(16, 16, 32, 32), BLACK);
            img
        }
        "ring" => {
            let mut img = solid(64, 64, WHITE);
            ring(&mut img, 16, 16, 32, 6, BLACK, WHITE);
            img
        }
        "dot" => {
            let mut img = solid(64, 64, rgb(&r["on"]));
            disc(&mut img, 26, 26, 12, rgb(&r["color"]));
            img
        }
        "broken" => RuleImage::new(usize_of("width"), usize_of("height"), vec![]),
        other => panic!("unknown canvas {other}"),
    };
    for op in r.get("ops").and_then(Value::as_array).into_iter().flatten() {
        let c = rgb(&op["color"]);
        match op["op"].as_str().unwrap() {
            "fill" => fill(&mut img, quad(&op["rect"]), c),
            "disc" => disc(&mut img, int(&op["x"]), int(&op["y"]), int(&op["size"]), c),
            "ring" => ring(
                &mut img,
                int(&op["x"]),
                int(&op["y"]),
                int(&op["size"]),
                int(&op["thickness"]),
                c,
                rgb(&op["hole"]),
            ),
            other => panic!("unknown op {other}"),
        }
    }
    img
}

struct Frames {
    images: Vec<RuleImage>,
    samples: Vec<RuleImage>,
}

fn frames() -> &'static Frames {
    static FRAMES: OnceLock<Frames> = OnceLock::new();
    FRAMES.get_or_init(|| {
        let mut images = Vec::new();
        let mut samples = Vec::new();
        let mut recipe: Option<Value> = None;
        for (tag, payload) in fixture_records("rule-image.bin") {
            let mut r = Reader::new(&payload);
            match tag {
                4 => recipe = Some(serde_json::from_slice(&payload).expect("recipe json")),
                1 | 3 => {
                    let (w, h) = (r.u16() as usize, r.u16() as usize);
                    let rest = r.rest();
                    let rc = recipe.take().expect("a tag 4 recipe before each image");
                    let raw = rc["canvas"] == "raw";
                    let img = if tag == 1 {
                        let img = RuleImage::new(w, h, rest.to_vec());
                        if !raw {
                            assert!(render(&rc) == img, "the canvas port draws {rc} differently");
                        }
                        img
                    } else {
                        assert!(!raw, "a raw image must carry its pixels");
                        let img = render(&rc);
                        assert_eq!((img.width, img.height), (w, h), "{rc}");
                        assert_eq!(Sha256::digest(&img.pixels).as_slice(), rest, "the canvas port draws {rc} differently");
                        img
                    };
                    images.push(img);
                }
                2 => {
                    let (w, h) = (r.u16() as usize, r.u16() as usize);
                    samples.push(RuleImage::new(w, h, r.rest().to_vec()));
                }
                t => panic!("unknown record tag {t}"),
            }
        }
        Frames { images, samples }
    })
}

fn image(v: &Value) -> &'static RuleImage {
    &frames().images[idx(v)]
}

// MARK: - Encodings (mirror the generator)

fn rv(v: &RuleValue) -> Value {
    match v {
        RuleValue::Null => Value::Null,
        RuleValue::Bool(b) => json!(b),
        RuleValue::Number(n) => jnum(*n),
        RuleValue::String(s) => json!(s),
        RuleValue::Array(a) => Value::Array(a.iter().map(rv).collect()),
        RuleValue::Object(o) => Value::Object(o.iter().map(|(k, v)| (k.clone(), rv(v))).collect()),
    }
}

fn obj<T>(m: &BTreeMap<String, T>, f: impl Fn(&T) -> Value) -> Value {
    Value::Object(m.iter().map(|(k, v)| (k.clone(), f(v))).collect())
}

fn len(l: Option<&Length>) -> Value {
    match l {
        None => Value::Null,
        Some(Length::Points(v)) => json!({"points": jnum(*v)}),
        Some(Length::Percent(v)) => json!({"percent": jnum(*v)}),
    }
}

fn rref(r: Option<&RegionRef>) -> Value {
    match r {
        None => Value::Null,
        Some(RegionRef::Named(n)) => json!({"named": n}),
        Some(RegionRef::Inline(s)) => json!({"inline": region(s)}),
    }
}

fn range(r: Option<(f64, f64)>) -> Value {
    r.map(|(a, b)| json!([jnum(a), jnum(b)])).unwrap_or(Value::Null)
}

fn side_raw(s: Side) -> &'static str {
    match s {
        Side::Left => "left",
        Side::Right => "right",
        Side::Top => "top",
        Side::Bottom => "bottom",
    }
}

fn pick_raw(p: Pick) -> &'static str {
    match p {
        Pick::Rightmost => "rightmost",
        Pick::Leftmost => "leftmost",
        Pick::Topmost => "topmost",
        Pick::Bottommost => "bottommost",
        Pick::Largest => "largest",
        Pick::All => "all",
    }
}

fn region(r: &RegionSpec) -> Value {
    match r {
        RegionSpec::Box(b) => json!({"box": {
            "in": rref(b.inside.as_ref()), "rightOf": b.right_of, "leftOf": b.left_of, "above": b.above,
            "below": b.below, "top": len(b.top.as_ref()), "bottom": len(b.bottom.as_ref()),
            "left": len(b.left.as_ref()), "right": len(b.right.as_ref()), "width": len(b.width.as_ref()),
            "height": len(b.height.as_ref()),
        }}),
        RegionSpec::Edge(e) => json!({"edge": {
            "in": rref(e.inside.as_ref()), "from": side_raw(e.from), "min": jnum(e.min), "max": jnum(e.max),
        }}),
        RegionSpec::Blob(b) => json!({"blob": {
            "in": rref(Some(&b.inside)), "round": b.round, "size": range(Some(b.size)), "pick": pick_raw(b.pick),
        }}),
        RegionSpec::Strip(s) => json!({"strip": {
            "of": rref(Some(&s.of)), "side": side_raw(s.side), "width": jnum(s.width),
        }}),
        RegionSpec::Unknown => json!("unknown"),
    }
}

fn color(c: &ColorRange) -> Value {
    json!({"h": range(c.h), "hWraps": c.h_wraps, "s": range(c.s), "l": range(c.l)})
}

fn detect(d: &Detect) -> Value {
    match d {
        Detect::Shape(n, m) => json!({"shape": {"is": n, "min": jnum(*m)}}),
        Detect::Color(c) => json!({"color": color(c)}),
        Detect::Motion { window, min } => json!({"motion": {"window": jnum(*window), "min": jnum(*min)}}),
        Detect::Text(t) => json!({"text": t}),
        Detect::Present => json!("present"),
    }
}

fn signal(s: &SignalSpec) -> Value {
    json!({
        "region": rref(s.region.as_ref()), "detects": s.detects.iter().map(detect).collect::<Vec<_>>(),
        "count": s.count, "needs": s.needs, "status": s.status.raw(), "usable": s.usable,
    })
}

fn cond(c: &Condition) -> Value {
    match c {
        Condition::Signal(s) => json!({"signal": s}),
        Condition::Any(cs) => json!({"any": cs.iter().map(cond).collect::<Vec<_>>()}),
        Condition::All(cs) => json!({"all": cs.iter().map(cond).collect::<Vec<_>>()}),
        Condition::Not(c) => json!({"not": cond(c)}),
        Condition::Never => json!("never"),
    }
}

fn row(r: &StateRow) -> Value {
    json!({
        "state": r.state, "kind": r.kind, "when": r.when.as_ref().map(cond).unwrap_or(Value::Null),
        "hold": jnum(r.hold), "release": jnum(r.release),
    })
}

fn pack(p: &RulePack) -> Value {
    json!({
        "id": p.id, "name": p.name, "rev": p.rev, "regions": obj(&p.regions, region),
        "signals": obj(&p.signals, signal), "states": p.states.iter().map(row).collect::<Vec<_>>(),
        "require": p.require,
        "variants": p.variants.iter()
            .map(|v| json!({"name": v.name, "when": rv(&v.when), "patch": rv(&v.patch)}))
            .collect::<Vec<_>>(),
    })
}

fn err(e: &RuleError) -> String {
    match e {
        RuleError::TooLarge => "tooLarge".into(),
        RuleError::BadJson => "badJSON".into(),
        RuleError::UnsupportedFormat(f) => format!("unsupportedFormat:{f}"),
        RuleError::NotAPack(w) => format!("notAPack:{w}"),
    }
}

fn dec_err(v: &Value) -> RuleError {
    let t = s(v);
    match t.as_str() {
        "tooLarge" => RuleError::TooLarge,
        "badJSON" => RuleError::BadJson,
        _ => {
            if let Some(f) = t.strip_prefix("unsupportedFormat:") {
                RuleError::UnsupportedFormat(f.to_string())
            } else if let Some(w) = t.strip_prefix("notAPack:") {
                RuleError::NotAPack(w.to_string())
            } else {
                panic!("unknown error {t}")
            }
        }
    }
}

fn decoded(text: &str) -> Value {
    match RulePack::parse(text.as_bytes()).and_then(|v| RulePack::decode(&v)) {
        Ok(p) => json!({"ok": pack(&p)}),
        Err(e) => json!({"error": err(&e)}),
    }
}

/// Packs given to `resolve` and `evaluate` are known good: decoded without the size check, as
/// the Swift tests do.
fn known_pack(text: &str) -> RulePack {
    RulePack::decode(&RuleValue::parse(text.as_bytes()).expect("fixture pack parses")).expect("fixture pack decodes")
}

fn hsl_json(h: &Hsl) -> Value {
    json!({"h": jnum(h.h), "s": jnum(h.s), "l": jnum(h.l)})
}

fn dec_hsl(v: &Value) -> Hsl {
    Hsl { h: num(&v["h"]), s: num(&v["s"]), l: num(&v["l"]) }
}

fn dec_range(v: &Value) -> Option<(f64, f64)> {
    v.as_array().map(|a| (num(&a[0]), num(&a[1])))
}

fn dec_color(v: &Value) -> ColorRange {
    ColorRange { h: dec_range(&v["h"]), h_wraps: v["hWraps"].as_bool().unwrap(), s: dec_range(&v["s"]), l: dec_range(&v["l"]) }
}

fn dec_cond(v: &Value) -> Condition {
    if v == "never" {
        return Condition::Never;
    }
    let o = v.as_object().unwrap_or_else(|| panic!("not a condition: {v}"));
    let list = |a: &Value| a.as_array().unwrap().iter().map(dec_cond).collect::<Vec<_>>();
    if let Some(n) = o.get("signal") {
        Condition::Signal(s(n))
    } else if let Some(a) = o.get("any") {
        Condition::Any(list(a))
    } else if let Some(a) = o.get("all") {
        Condition::All(list(a))
    } else if let Some(c) = o.get("not") {
        Condition::Not(Box::new(dec_cond(c)))
    } else {
        panic!("not a condition: {v}")
    }
}

fn dec_row(v: &Value) -> StateRow {
    StateRow {
        state: s(&v["state"]),
        kind: opt_s(&v["kind"]),
        when: if v["when"].is_null() { None } else { Some(dec_cond(&v["when"])) },
        hold: num(&v["hold"]),
        release: num(&v["release"]),
    }
}

fn report(r: &AppStateReport) -> Value {
    json!({
        "pack": r.pack, "rev": r.rev, "state": r.state, "kind": r.kind, "by": r.by, "sure": r.sure,
        "counts": r.counts, "health": r.health, "variants": r.variants, "appVersion": r.app_version,
        "caps": r.caps, "error": r.error,
    })
}

fn dec_report(v: &Value) -> AppStateReport {
    AppStateReport {
        pack: opt_s(&v["pack"]),
        rev: v["rev"].as_i64(),
        state: opt_s(&v["state"]),
        kind: opt_s(&v["kind"]),
        by: strs(&v["by"]),
        sure: v["sure"].as_bool().unwrap(),
        counts: v["counts"].as_object().unwrap().iter().map(|(k, n)| (k.clone(), int(n))).collect(),
        health: s(&v["health"]),
        variants: strs(&v["variants"]),
        app_version: opt_s(&v["appVersion"]),
        caps: strs(&v["caps"]),
        error: opt_s(&v["error"]),
    }
}

fn parsed_json(text: &str) -> Value {
    serde_json::from_str(text).unwrap_or_else(|e| panic!("report json does not parse ({e}): {text}"))
}

// MARK: - Readers

/// `FakeReader` (RuleDetectTests.swift): the same lines every call, a call count, a ready flag.
/// The counters are shared because the evaluator owns the reader.
struct Scripted {
    say: Vec<String>,
    calls: Arc<AtomicUsize>,
    ready: Arc<AtomicBool>,
}

impl TextReader for Scripted {
    fn lines(&mut self, _image: &RuleImage, _rect: RuleRect) -> Vec<String> {
        self.calls.fetch_add(1, SeqCst);
        self.say.clone()
    }
    fn ready(&self) -> bool {
        self.ready.load(SeqCst)
    }
}

/// `reader` null: none. Otherwise a `Scripted` reader and its counters.
fn reader(v: &Value) -> (Option<Box<dyn TextReader>>, Arc<AtomicUsize>, Arc<AtomicBool>) {
    let calls = Arc::new(AtomicUsize::new(0));
    let ready = Arc::new(AtomicBool::new(true));
    let r: Option<Box<dyn TextReader>> = if v.is_null() {
        None
    } else {
        Some(Box::new(Scripted { say: strs(v), calls: calls.clone(), ready: ready.clone() }))
    };
    (r, calls, ready)
}

/// RuleDetectTests' NaN-threshold pack: JSON cannot write NaN, so it is built here as there.
fn nan_pack() -> RulePack {
    let regions = BTreeMap::from([(
        "a".to_string(),
        RegionSpec::Box(BoxSpec {
            left: Some(Length::Points(0.0)),
            width: Some(Length::Points(12.0)),
            height: Some(Length::Points(12.0)),
            ..Default::default()
        }),
    )]);
    let spec = SignalSpec {
        region: Some(RegionRef::Named("a".into())),
        detects: vec![Detect::Shape("dot".into(), f64::NAN), Detect::Motion { window: f64::NAN, min: f64::NAN }],
        needs: BTreeSet::from(["pixels".to_string()]),
        usable: true,
        ..Default::default()
    };
    RulePack {
        id: "t".into(),
        name: "t".into(),
        rev: 0,
        regions,
        signals: BTreeMap::from([("s".to_string(), spec)]),
        states: vec![],
        require: vec![],
        variants: vec![],
    }
}

// MARK: - Tests

#[test]
fn frames_match_the_swift_canvas() {
    let f = frames();
    assert!(!f.images.is_empty() && !f.samples.is_empty());
}

#[test]
fn rule_pack() {
    for c in raw_cases("rule-pack.json") {
        let i = &c.input;
        let got = match func(i) {
            "merge" => {
                let base = RuleValue::parse(s(&i["base"]).as_bytes()).unwrap();
                let patch = RuleValue::parse(s(&i["patch"]).as_bytes()).unwrap();
                rv(&base.merged(&patch))
            }
            "decode" => decoded(&s(&i["text"])),
            "named" => ColorRange::named(&s(&i["name"])).map(|c| color(&c)).unwrap_or(Value::Null),
            "hue_contains" => json!(dec_color(&i["color"]).hue_contains(num(&i["hue"]))),
            f => panic!("unknown fn {f}"),
        };
        check(&c.name, &got, &c.out);
    }
}

#[test]
fn rule_regions() {
    let f = frames();
    for c in raw_cases("rule-regions.json") {
        let i = &c.input;
        let got = match func(i) {
            "resolve" => {
                let p = known_pack(&s(&i["pack"]));
                let r = resolve_regions(&p.regions, image(&i["image"]));
                obj(&r, |rs| Value::Array(rs.iter().map(rect).collect()))
            }
            "sample" => {
                let src = image(&i["src"]);
                let trim = idx(&i["trim"]);
                let bytes = &src.pixels[..src.pixels.len() - trim];
                let out = RuleImage::sample(
                    bytes,
                    idx(&i["width"]),
                    idx(&i["height"]),
                    idx(&i["bytesPerRow"]),
                    dec_rect(&i["crop"]),
                    num(&i["scale"]),
                );
                match out {
                    None => Value::Null,
                    Some(img) => {
                        let k = c.out.get("image").map(idx);
                        if let Some(k) = k {
                            assert!(img == f.samples[k], "{}: sampled pixels differ", c.name);
                        }
                        json!({"image": k, "width": img.width, "height": img.height})
                    }
                }
            }
            f => panic!("unknown fn {f}"),
        };
        check(&c.name, &got, &c.out);
    }
}

#[test]
fn rule_detectors() {
    for c in raw_cases("rule-detectors.json") {
        let i = &c.input;
        let got = match func(i) {
            "shape" => {
                let (n, score) = shape(image(&i["image"]), dec_rect(&i["rect"]));
                json!({"name": n.raw(), "score": jnum(score)})
            }
            "foreground_color" => foreground_color(image(&i["image"]), dec_rect(&i["rect"]))
                .map(|h| hsl_json(&h))
                .unwrap_or(Value::Null),
            "contains" => json!(dec_color(&i["color"]).contains(dec_hsl(&i["hsl"]))),
            "hsl" => {
                let (r, g, b) = rgb(&i["rgb"]);
                hsl_json(&hsl(r, g, b))
            }
            "distance" => json!(color_distance(rgb(&i["a"]), rgb(&i["b"]))),
            "text_matches" => json!(text_matches(&strs(&i["patterns"]), &strs(&i["lines"]))),
            "evaluate" => evaluate(i),
            f => panic!("unknown fn {f}"),
        };
        check(&c.name, &got, &c.out);
    }
}

fn evaluate(i: &Value) -> Value {
    let pack = match i.get("pack") {
        Some(t) => known_pack(&s(t)),
        None => {
            assert_eq!(i["builtin"], "nan");
            nan_pack()
        }
    };
    let (text, calls, ready) = reader(&i["reader"]);
    let mut ev = SignalEvaluator::new(set(&i["caps"]), text);
    let (mut results, mut seen) = (Vec::new(), Vec::new());
    for st in i["steps"].as_array().unwrap() {
        if let Some(b) = st["ready"].as_bool() {
            ready.store(b, SeqCst);
        }
        let regions: BTreeMap<String, Vec<RuleRect>> = match st["regions"].get("rects") {
            Some(rects) => rects
                .as_object()
                .unwrap()
                .iter()
                .map(|(k, v)| (k.clone(), v.as_array().unwrap().iter().map(quad).collect()))
                .collect(),
            None => resolve_regions(&pack.regions, image(&st["regions"]["resolve"])),
        };
        let img = if st["image"].is_null() { None } else { Some(image(&st["image"])) };
        let r = ev.evaluate(&pack, &regions, img, num(&st["now"]));
        results.push(obj(&r, |v| json!({"holds": v.holds, "count": v.count})));
        seen.push(json!(calls.load(SeqCst)));
    }
    json!({"results": results, "calls": seen})
}

#[test]
fn state_table() {
    for c in raw_cases("state-table.json") {
        let i = &c.input;
        let got = match func(i) {
            "step" => {
                let rows = i["rows"].as_array().unwrap().iter().map(dec_row).collect();
                let mut t = StateTable::new(rows);
                let out: Vec<Value> = i["steps"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .map(|st| t.step(&set(&st["on"]), num(&st["now"])).map(|r| row(&r)).unwrap_or(Value::Null))
                    .collect();
                Value::Array(out)
            }
            "holds" => json!(holds(&dec_cond(&i["cond"]), &set(&i["on"]))),
            "signals_in" => json!(signals_in(&dec_cond(&i["cond"]))),
            f => panic!("unknown fn {f}"),
        };
        check(&c.name, &got, &c.out);
    }
}

#[test]
fn state_engine() {
    for c in raw_cases("state-engine.json") {
        let i = &c.input;
        let got = match func(i) {
            "engine" => engine(i),
            "report_json" => {
                let j = dec_report(&i["report"]).json();
                let mut o = json!({"json": parsed_json(&j), "bytes": j.len()});
                if c.out.get("text").is_some() {
                    o["text"] = json!(j);
                }
                o
            }
            "invalid" => {
                let r = AppStateReport::invalid(&dec_err(&i["error"]), strs(&i["caps"]), opt_s(&i["appVersion"]));
                let j = r.json();
                json!({"report": report(&r), "json": parsed_json(&j), "bytes": j.len()})
            }
            "compare_versions" => json!(compare_versions(&s(&i["a"]), &s(&i["b"]))),
            f => panic!("unknown fn {f}"),
        };
        check(&c.name, &got, &c.out);
    }
}

fn engine(i: &Value) -> Value {
    let e = &i["env"];
    let rereads = Arc::new(AtomicUsize::new(0));
    let counter = rereads.clone();
    let answer = opt_s(&e["reread"]);
    let env = RuleEnv {
        app_version: opt_s(&e["appVersion"]),
        os: s(&e["os"]),
        locale: s(&e["locale"]),
        caps: set(&e["caps"]),
        reread_version: Box::new(move || {
            counter.fetch_add(1, SeqCst);
            answer.clone()
        }),
    };
    let (text, calls, _ready) = reader(&i["reader"]);
    let mut eng = match StateEngine::new(s(&i["rules"]).as_bytes(), env, text) {
        Ok(eng) => eng,
        Err(err_) => return json!({"error": err(&err_)}),
    };
    let mut ticks = Vec::new();
    for t in i["ticks"].as_array().unwrap() {
        let img = if t["image"].is_null() { None } else { Some(image(&t["image"])) };
        let ret = eng.tick(img, t["visible"].as_bool().unwrap(), num(&t["now"]));
        ticks.push(json!({
            "ret": ret.as_ref().map(report).unwrap_or(Value::Null),
            "report": report(eng.report()),
        }));
    }
    let j = eng.report().json();
    json!({
        "ticks": ticks, "rereads": rereads.load(SeqCst), "readerCalls": calls.load(SeqCst),
        "json": parsed_json(&j), "bytes": j.len(),
    })
}

/// The wire limit is the protocol's (Task 2); a report never exceeds it, whatever it holds.
#[test]
fn reports_fit_the_wire_limit() {
    for c in raw_cases("state-engine.json") {
        if let Some(b) = c.out.get("bytes") {
            assert!(idx(b) <= 4096, "{}: Swift wrote {} bytes", c.name, b);
        }
    }
}
