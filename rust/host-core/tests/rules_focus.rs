//! Focus pane, focus tracker and query rules against the Swift reference. Fixtures are
//! written by `Tests/RappCoreTests/HostCoreFixtures/FocusFixtures.swift`. Tracker cases are
//! traces: each step is replayed on one `FocusTracker`, and the actions it returns and the
//! public state after it must equal what Swift recorded.

mod common;
mod rules_common;

use common::raw_cases;
use rapp_host_core::focus::{
    self, Action, Cause, FocusTracker, PanelMiss, PanelPick, Pointer, Query, WindowTiles,
};
use rapp_host_core::query::{QueryCoalescer, QueryDeadline, QueryKind};
use rapp_host_core::{EncodeReport, Point, Rect, Size};
use rules_common::*;
use serde::Deserialize;

// MARK: shapes

#[derive(Debug, Clone, Copy, PartialEq, Deserialize)]
struct JPick {
    rect: Rect,
    depth: i64,
    share: f64,
}

/// `{"pick": …, "miss": …}`: one of the two is null.
#[derive(Debug, Clone, PartialEq, Deserialize)]
struct JResult {
    pick: Option<JPick>,
    miss: Option<String>,
}

impl JResult {
    fn result(&self) -> Result<PanelPick, PanelMiss> {
        match (&self.pick, &self.miss) {
            (Some(p), None) => Ok(PanelPick { rect: p.rect, depth: p.depth, share: p.share }),
            (None, Some(m)) => Err(PanelMiss::from_name(m).unwrap_or_else(|| panic!("miss {m}"))),
            other => panic!("result {other:?}"),
        }
    }
    fn of(r: &Result<PanelPick, PanelMiss>) -> JResult {
        match r {
            Ok(p) => JResult { pick: Some(JPick { rect: p.rect, depth: p.depth, share: p.share }), miss: None },
            Err(m) => JResult { pick: None, miss: Some(m.name().to_string()) },
        }
    }
}

#[derive(Debug, Clone, PartialEq, Deserialize)]
struct JQuery {
    kind: String,
    at: Option<Point>,
}

impl JQuery {
    fn query(&self) -> Query {
        match (self.kind.as_str(), self.at) {
            ("keyboard", None) => Query::Keyboard,
            ("pointer", Some(p)) => Query::Pointer(p),
            ("follow", Some(p)) => Query::Follow(p),
            other => panic!("query {other:?}"),
        }
    }
    fn of(q: &Query) -> JQuery {
        match q {
            Query::Keyboard => JQuery { kind: "keyboard".into(), at: None },
            Query::Pointer(p) => JQuery { kind: "pointer".into(), at: Some(*p) },
            Query::Follow(p) => JQuery { kind: "follow".into(), at: Some(*p) },
        }
    }
}

#[derive(Debug, Clone, PartialEq, Deserialize)]
#[serde(tag = "op", rename_all = "snake_case")]
enum JAction {
    Query { query: JQuery, generation: i64 },
    Send { window: u32, rects: Vec<Rect>, cause: String },
}

fn jaction(a: &Action) -> JAction {
    match a {
        Action::Query(q, g) => JAction::Query { query: JQuery::of(q), generation: *g },
        Action::Send(o) => JAction::Send { window: o.window, rects: o.rects.clone(), cause: o.cause.name().into() },
    }
}

#[derive(Debug, Clone, PartialEq, Deserialize)]
struct JTiles {
    changed: Vec<Rect>,
    total: i64,
    copy_bounds: Option<Rect>,
    full: bool,
}

impl JTiles {
    fn tiles(&self) -> WindowTiles {
        WindowTiles { changed: self.changed.clone(), total: self.total, copy_bounds: self.copy_bounds, full: self.full }
    }
    fn of(t: &WindowTiles) -> JTiles {
        JTiles { changed: t.changed.clone(), total: t.total, copy_bounds: t.copy_bounds, full: t.full }
    }
}

#[derive(Debug, Clone, PartialEq, Deserialize)]
struct JState {
    generation: i64,
    keyboard_panel: Option<Rect>,
    keyboard_miss: Option<String>,
    pointer_panel: Option<Rect>,
    pointer_miss: Option<String>,
    follow_panel: Option<Rect>,
}

impl JState {
    fn of(t: &FocusTracker) -> JState {
        JState {
            generation: t.generation(),
            keyboard_panel: t.keyboard_panel(),
            keyboard_miss: t.keyboard_miss().map(|m| m.name().to_string()),
            pointer_panel: t.pointer_panel(),
            pointer_miss: t.pointer_miss().map(|m| m.name().to_string()),
            follow_panel: t.follow_panel(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Deserialize)]
struct JStepOut {
    actions: Vec<JAction>,
    state: JState,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(tag = "op", rename_all = "snake_case")]
enum Step {
    Start { now: f64 },
    Window { id: Option<u32>, size: Size, appeared: Option<f64>, now: f64 },
    Locked { on: bool, now: f64 },
    Pointer { kind: String, at: Point, now: f64 },
    Key { now: f64 },
    KeyboardChanged { now: f64 },
    Result { query: JQuery, generation: i64, pick: Option<JPick>, miss: Option<String>, now: f64 },
    Frame { tiles: JTiles, now: f64 },
    Tick { now: f64 },
}

fn pointer_kind(name: &str) -> Pointer {
    match name {
        "click" => Pointer::Click,
        "drag" => Pointer::Drag,
        "scroll" => Pointer::Scroll,
        "move" => Pointer::Move,
        _ => panic!("pointer kind {name}"),
    }
}

fn run(t: &mut FocusTracker, step: &Step) -> Vec<Action> {
    match step {
        Step::Start { now } => t.start(*now),
        Step::Window { id, size, appeared, now } => t.window(*id, *size, *appeared, *now),
        Step::Locked { on, now } => t.locked(*on, *now),
        Step::Pointer { kind, at, now } => t.pointer(pointer_kind(kind), *at, *now),
        Step::Key { now } => t.key(*now),
        Step::KeyboardChanged { now } => t.keyboard_changed(*now),
        Step::Result { query, generation, pick, miss, now } => {
            let r = JResult { pick: *pick, miss: miss.clone() }.result();
            t.result(query.query(), *generation, r, *now)
        }
        Step::Frame { tiles, now } => t.frame(&tiles.tiles(), *now),
        Step::Tick { now } => t.tick(*now),
    }
}

// MARK: focus-pane.json

#[derive(Debug, Deserialize)]
struct JReport {
    region: JRect,
    width: usize,
    height: usize,
    full: bool,
    changed: Vec<usize>,
    copy_bounds: Option<Rect>,
}

#[test]
fn focus_pane_matches_swift() {
    let cases = raw_cases("focus-pane.json");
    assert!(!cases.is_empty());
    for c in cases {
        let i = &c.input;
        match func(i) {
            "panel" => {
                let chain: Vec<Rect> = arg(&i["chain"]);
                let got = focus::panel(&chain, arg(&i["window"]));
                assert_eq!(JResult::of(&got), arg::<JResult>(&c.out), "{}", c.name);
            }
            "window_rect" => {
                let w: JRect = arg(&i["window"]);
                let got = focus::window_rect(arg(&i["global"]), arg(&i["display"]), w.canvas());
                assert_eq!(got, arg::<Rect>(&c.out), "{}", c.name);
            }
            "window_tiles" => {
                let r: JReport = arg(&i["report"]);
                let w: JRect = arg(&i["window"]);
                let rep = EncodeReport {
                    region: r.region.canvas(),
                    width: r.width,
                    height: r.height,
                    full: r.full,
                    changed: r.changed,
                    copy_bounds: r.copy_bounds,
                };
                let got = focus::window_tiles(&rep, w.canvas());
                assert_eq!(JTiles::of(&got), arg::<JTiles>(&c.out), "{}", c.name);
            }
            other => panic!("unknown fn {other} in {}", c.name),
        }
    }
}

// MARK: focus-tracker.json

#[test]
fn focus_tracker_matches_swift() {
    let cases = raw_cases("focus-tracker.json");
    assert!(!cases.is_empty());
    for c in cases {
        assert_eq!(func(&c.input), "trace", "{}", c.name);
        let steps: Vec<Step> = arg(&c.input["steps"]);
        let outs: Vec<JStepOut> = arg(&c.out);
        assert_eq!(steps.len(), outs.len(), "{}", c.name);
        let mut t = FocusTracker::new();
        for (n, (step, want)) in steps.iter().zip(&outs).enumerate() {
            let actions = run(&mut t, step);
            let got = JStepOut { actions: actions.iter().map(jaction).collect(), state: JState::of(&t) };
            assert_eq!(&got, want, "{} step {n}: {step:?}", c.name);
        }
    }
}

/// Every cause name is Swift's raw value; the fixtures only reach the ones a trace sends.
#[test]
fn cause_names_are_swift_raw_values() {
    let all = [
        (Cause::On, "on"),
        (Cause::Key, "key"),
        (Cause::Click, "click"),
        (Cause::Scroll, "scroll"),
        (Cause::Hover, "hover"),
        (Cause::Follow, "follow"),
        (Cause::Notify, "notify"),
        (Cause::Resize, "resize"),
        (Cause::Window, "window"),
        (Cause::Lock, "lock"),
    ];
    for (c, name) in all {
        assert_eq!(c.name(), name);
    }
}

// MARK: query.json

#[derive(Debug, Deserialize)]
#[serde(tag = "op", rename_all = "snake_case")]
enum CoalescerStep {
    Submit { kind: String, job: String },
    Finish,
}

fn query_kind(name: &str) -> QueryKind {
    match name {
        "keyboard" => QueryKind::Keyboard,
        "pointer" => QueryKind::Pointer,
        "follow" => QueryKind::Follow,
        _ => panic!("query kind {name}"),
    }
}

fn kind_name(k: QueryKind) -> &'static str {
    match k {
        QueryKind::Keyboard => "keyboard",
        QueryKind::Pointer => "pointer",
        QueryKind::Follow => "follow",
    }
}

#[derive(Debug, PartialEq, Deserialize)]
struct JDeadline {
    remaining: Option<f64>,
    expired: bool,
}

#[test]
fn query_rules_match_swift() {
    let cases = raw_cases("query.json");
    assert!(!cases.is_empty());
    for c in cases {
        let i = &c.input;
        match func(i) {
            "coalescer" => {
                let steps: Vec<CoalescerStep> = arg(&i["steps"]);
                let outs: Vec<Option<String>> = arg(&c.out);
                assert_eq!(steps.len(), outs.len(), "{}", c.name);
                let mut q = QueryCoalescer::<String>::new();
                for (n, (step, want)) in steps.iter().zip(&outs).enumerate() {
                    let got = match step {
                        CoalescerStep::Submit { kind, job } => q.submit(query_kind(kind), job.clone()),
                        CoalescerStep::Finish => q.finish(),
                    };
                    assert_eq!(&got, want, "{} step {n}", c.name);
                }
            }
            "deadline" => {
                let d = QueryDeadline::new(arg(&i["start"]), arg(&i["budget"]));
                let now: f64 = arg(&i["now"]);
                let got = JDeadline { remaining: d.remaining(now), expired: d.expired(now) };
                assert_eq!(got, arg::<JDeadline>(&c.out), "{}", c.name);
            }
            "kind" => {
                let q: JQuery = arg(&i["query"]);
                assert_eq!(kind_name(q.query().kind()), arg::<String>(&c.out), "{}", c.name);
            }
            other => panic!("unknown fn {other} in {}", c.name),
        }
    }
}
