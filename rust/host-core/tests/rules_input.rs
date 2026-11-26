//! Input yield, held input and peer names against the Swift reference. Fixtures are written by
//! `Tests/RappCoreTests/HostCoreFixtures/InputFixtures.swift`; every case is a trace replayed on
//! one value, and each step's result must equal what Swift recorded.

mod common;
mod rules_common;

use common::raw_cases;
use rapp_host_core::input::{HeldInput, InputYield, PeerNames, YieldDecision, PEER_NAMES_KEPT};
use rapp_host_core::{Message, Mode, MouseButton, MouseKind, PasteSource};
use rules_common::*;
use serde::Deserialize;
use serde_json::Value;

fn button(name: &str) -> MouseButton {
    match name {
        "left" => MouseButton::Left,
        "right" => MouseButton::Right,
        _ => panic!("button {name}"),
    }
}

fn button_name(b: MouseButton) -> &'static str {
    match b {
        MouseButton::Left => "left",
        MouseButton::Right => "right",
    }
}

// MARK: input-yield.json

/// The message as `InputFixtures.Msg` writes it; the fixed fields are Swift's.
#[derive(Debug, Clone, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
enum JMsg {
    Text,
    Key { code: u16, modifiers: u64, down: bool },
    Mouse { kind: String, button: String },
    Scroll,
    Paste,
    MenuPick,
    Focus,
    SelectInput,
    Resize,
    Move,
    Close,
    SetStream,
    Ping,
    FrameAck,
}

impl JMsg {
    fn message(&self) -> Message {
        match self {
            JMsg::Text => Message::Text("a".into()),
            JMsg::Key { code, modifiers, down } => Message::Key { key_code: *code, modifiers: *modifiers, down: *down },
            JMsg::Mouse { kind, button: b } => Message::Mouse {
                kind: match kind.as_str() {
                    "down" => MouseKind::Down,
                    "up" => MouseKind::Up,
                    "drag" => MouseKind::Drag,
                    "move" => MouseKind::Move,
                    _ => panic!("mouse kind {kind}"),
                },
                button: button(b),
                window: 1,
                x: 0.0,
                y: 0.0,
                click_count: 1,
            },
            JMsg::Scroll => Message::Scroll { window: 1, x: 0.0, y: 0.0, dx: 0.0, dy: 1.0 },
            JMsg::Paste => Message::Paste { seq: 1, source: PasteSource::Text("a".into()) },
            JMsg::MenuPick => Message::MenuPick(vec![0]),
            JMsg::Focus => Message::Focus(1),
            JMsg::SelectInput => Message::SelectInput { id: String::new() },
            JMsg::Resize => Message::Resize { window: 1, width: 10, height: 10 },
            JMsg::Move => Message::Move { window: 1, x: 0.0, y: 0.0 },
            JMsg::Close => Message::Close(1),
            JMsg::SetStream => {
                Message::SetStream { mode: Mode::Gray4, fps: 5, density: 1.0, pinned: false, focus: false }
            }
            JMsg::Ping => Message::Ping(1),
            JMsg::FrameAck => Message::FrameAck { processing_ms: 3 },
        }
    }
}

#[derive(Debug, Clone, Deserialize)]
#[serde(tag = "op", rename_all = "snake_case")]
enum YieldStep {
    Yielded { by: String, now: f64 },
    Tick { now: f64 },
    Admit { msg: JMsg, now: f64 },
}

#[derive(Debug, Clone, PartialEq, Deserialize)]
#[serde(tag = "decision", rename_all = "snake_case")]
enum JDecision {
    Pass { report: bool },
    Drop { notify: Option<String> },
}

fn jdecision(d: &YieldDecision) -> JDecision {
    match d {
        YieldDecision::Pass { report } => JDecision::Pass { report: *report },
        YieldDecision::Drop { notify } => JDecision::Drop { notify: notify.clone() },
    }
}

#[test]
fn input_yield_matches_swift() {
    let cases = raw_cases("input-yield.json");
    assert!(!cases.is_empty());
    for c in cases {
        assert_eq!(func(&c.input), "trace", "{}", c.name);
        let steps: Vec<YieldStep> = arg(&c.input["steps"]);
        let outs: Vec<Value> = arg(&c.out);
        assert_eq!(steps.len(), outs.len(), "{}", c.name);
        let mut y = InputYield::new();
        for (n, (step, want)) in steps.iter().zip(&outs).enumerate() {
            match step {
                YieldStep::Yielded { by, now } => {
                    y.yielded(by, *now);
                    assert!(want.is_null(), "{} step {n}", c.name);
                }
                YieldStep::Tick { now } => {
                    assert_eq!(y.tick(*now), arg::<bool>(want), "{} step {n}: {step:?}", c.name);
                }
                YieldStep::Admit { msg, now } => {
                    let got = jdecision(&y.admit(&msg.message(), *now));
                    assert_eq!(got, arg::<JDecision>(want), "{} step {n}: {step:?}", c.name);
                }
            }
        }
    }
}

// MARK: held-input.json

#[derive(Debug, Clone, Deserialize)]
#[serde(tag = "op", rename_all = "snake_case")]
enum HeldStep {
    PressKey { code: u16 },
    ReleaseKey { code: u16 },
    PressButton { button: String },
    ReleaseButton { button: String },
    Drain,
}

#[derive(Debug, PartialEq, Deserialize)]
struct JDrain {
    keys: Vec<u16>,
    buttons: Vec<String>,
}

#[test]
fn held_input_matches_swift() {
    let cases = raw_cases("held-input.json");
    assert!(!cases.is_empty());
    for c in cases {
        assert_eq!(func(&c.input), "trace", "{}", c.name);
        let steps: Vec<HeldStep> = arg(&c.input["steps"]);
        let outs: Vec<Value> = arg(&c.out);
        assert_eq!(steps.len(), outs.len(), "{}", c.name);
        let mut h = HeldInput::new();
        for (n, (step, want)) in steps.iter().zip(&outs).enumerate() {
            match step {
                HeldStep::PressKey { code } => h.press_key(*code),
                HeldStep::ReleaseKey { code } => h.release_key(*code),
                HeldStep::PressButton { button: b } => h.press_button(button(b)),
                HeldStep::ReleaseButton { button: b } => h.release_button(button(b)),
                HeldStep::Drain => {
                    let (keys, buttons) = h.drain();
                    let got = JDrain { keys, buttons: buttons.into_iter().map(|b| button_name(b).to_string()).collect() };
                    assert_eq!(got, arg::<JDrain>(want), "{} step {n}", c.name);
                    continue;
                }
            }
            assert!(want.is_null(), "{} step {n}", c.name);
        }
    }
}

// MARK: peer-names.json

#[derive(Debug, Clone, Deserialize)]
#[serde(tag = "op", rename_all = "snake_case")]
enum PeerStep {
    Set { name: String, port: u16 },
    Name { port: u16 },
}

#[test]
fn peer_names_match_swift() {
    let cases = raw_cases("peer-names.json");
    assert!(!cases.is_empty());
    for c in cases {
        assert_eq!(func(&c.input), "trace", "{}", c.name);
        let steps: Vec<PeerStep> = arg(&c.input["steps"]);
        let outs: Vec<Value> = arg(&c.out);
        assert_eq!(steps.len(), outs.len(), "{}", c.name);
        let mut p = PeerNames::new();
        for (n, (step, want)) in steps.iter().zip(&outs).enumerate() {
            match step {
                PeerStep::Set { name, port } => {
                    p.set(name, *port);
                    assert_eq!(p.count(), arg::<usize>(want), "{} step {n}", c.name);
                }
                PeerStep::Name { port } => {
                    assert_eq!(p.name(*port).map(str::to_string), arg::<Option<String>>(want), "{} step {n}", c.name);
                }
            }
        }
    }
}

#[test]
fn peer_names_kept_is_swifts() {
    assert_eq!(PEER_NAMES_KEPT, 16);
}
