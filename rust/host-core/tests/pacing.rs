//! `SendPacer`, `WeakTier`, the save ladder, `PacedSender` and `PauseOutbox`
//! against Swift (`PacingFixtures.swift`, which documents every fixture's layout).
//!
//! Each trace is replayed call by call on the Rust type, and each call's result
//! is compared with what Swift recorded. Numbers are compared as f64 (Swift's
//! `JSONSerialization` writes 1.0 as `1`), everything else exactly.

mod common;
use common::*;

use rapp_host_core::pacing::{
    save_ladder_steps, save_ladder_stream, PacedSender, SendPacer, SenderOutput, Stats, StreamSpec, WeakTier,
};
use rapp_host_core::pause::PauseOutbox;
use rapp_host_core::protocol::{CanvasRect, Message, MessageParser, Mode};
use rapp_host_core::quantize::quantize;
use serde_json::{json, Value};

/// FNV-1a, as `TileFixtures.fnv`.
fn fnv(bytes: &[u8]) -> u64 {
    let mut h: u64 = 0xCBF2_9CE4_8422_2325;
    for &b in bytes {
        h ^= b as u64;
        h = h.wrapping_mul(0x0000_0100_0000_01B3);
    }
    h
}

fn fnv_hex(bytes: &[u8]) -> String {
    format!("{:016x}", fnv(bytes))
}

/// `got` against `want`, numbers as f64; panics naming the first difference.
fn same(got: &Value, want: &Value, at: &str) {
    match (got, want) {
        (Value::Number(a), Value::Number(b)) => {
            let (x, y) = (a.as_f64().unwrap(), b.as_f64().unwrap());
            assert!(x == y, "{at}: got {x:?}, Swift {y:?}");
        }
        (Value::Array(a), Value::Array(b)) => {
            assert_eq!(a.len(), b.len(), "{at}: got {got}, Swift {want}");
            for (i, (x, y)) in a.iter().zip(b).enumerate() {
                same(x, y, &format!("{at}[{i}]"));
            }
        }
        (Value::Object(a), Value::Object(b)) => {
            let mut ka: Vec<_> = a.keys().collect();
            let mut kb: Vec<_> = b.keys().collect();
            ka.sort();
            kb.sort();
            assert_eq!(ka, kb, "{at}: keys differ: got {got}, Swift {want}");
            for k in ka {
                same(&a[k], &b[k], &format!("{at}.{k}"));
            }
        }
        _ => assert_eq!(got, want, "{at}"),
    }
}

fn op(c: &Value) -> &str {
    c["op"].as_str().expect("call without op")
}
fn num(c: &Value, k: &str) -> f64 {
    c[k].as_f64().unwrap_or_else(|| panic!("call {c} has no number {k}"))
}
fn int(c: &Value, k: &str) -> i64 {
    c[k].as_i64().unwrap_or_else(|| panic!("call {c} has no integer {k}"))
}
fn flag(c: &Value, k: &str) -> bool {
    c[k].as_bool().unwrap_or_else(|| panic!("call {c} has no bool {k}"))
}
fn ints(c: &Value, k: &str) -> Vec<i64> {
    c[k].as_array().unwrap_or_else(|| panic!("call {c} has no list {k}")).iter().map(|v| v.as_i64().unwrap()).collect()
}
fn mode(v: &Value) -> Mode {
    Mode::from_name(v.as_str().expect("mode name")).expect("known mode")
}
fn opt_f(v: Option<f64>) -> Value {
    v.map_or(Value::Null, |x| json!(x))
}
fn opt_i(v: Option<i64>) -> Value {
    v.map_or(Value::Null, |x| json!(x))
}
fn rect_json(r: CanvasRect) -> Value {
    json!({"x": r.x as f64, "y": r.y as f64, "w": r.w as f64, "h": r.h as f64})
}
fn rect_of(v: &Value) -> CanvasRect {
    CanvasRect::new(num(v, "x") as f32, num(v, "y") as f32, num(v, "w") as f32, num(v, "h") as f32)
}

/// Each call of a trace with the result Swift recorded for it.
fn trace(case: &Case<Value, Value>) -> Vec<(&Value, &Value)> {
    let calls = case.input["calls"].as_array().expect("calls");
    let outs = case.out.as_array().expect("out");
    assert_eq!(calls.len(), outs.len(), "{}: calls and results differ in number", case.name);
    calls.iter().zip(outs).collect()
}

// MARK: - SendPacer

#[test]
fn send_pacer_matches_swift() {
    let cases = raw_cases("send-pacer.json");
    assert!(!cases.is_empty());
    for case in &cases {
        let mut p = SendPacer::new(int(&case.input, "fps"));
        for (i, (c, want)) in trace(case).into_iter().enumerate() {
            let got = match op(c) {
                "sent" => {
                    p.sent(num(c, "at"), num(c, "captured"));
                    Value::Null
                }
                "acked" => match p.acked(num(c, "at"), int(c, "ms") as u16) {
                    Some((rtt, latency)) => json!({"rtt": rtt, "latency": latency}),
                    None => Value::Null,
                },
                "base_rtt" => opt_f(p.base_rtt(num(c, "now"))),
                "queueing" => json!(p.queueing(num(c, "now"))),
                "cap" => json!(p.cap(num(c, "now"))),
                "in_flight" => json!(p.in_flight()),
                "last_rtt" => opt_f(p.last_rtt()),
                "reset" => {
                    p.reset();
                    Value::Null
                }
                "fps" => {
                    p.fps = int(c, "fps");
                    Value::Null
                }
                other => panic!("{}: unknown op {other}", case.name),
            };
            same(&got, want, &format!("{} call {i} ({})", case.name, op(c)));
        }
    }
}

// MARK: - WeakTier

#[test]
fn weak_tier_matches_swift() {
    let cases = raw_cases("weak-tier.json");
    assert!(!cases.is_empty());
    for case in &cases {
        let mut t = WeakTier::default();
        for (i, (c, want)) in trace(case).into_iter().enumerate() {
            let r = match op(c) {
                "steps" => {
                    t.steps = ints(c, "steps");
                    None
                }
                "pinned" => {
                    t.set_pinned(flag(c, "on"));
                    None
                }
                "observe" => t.observe(num(c, "now"), flag(c, "queueing"), flag(c, "on_ack")),
                "probe" => t.probe(num(c, "delay")),
                "set_steps" => t.set_steps(ints(c, "steps")),
                other => panic!("{}: unknown op {other}", case.name),
            };
            let got = json!({"r": opt_i(r), "level": t.level(), "weak": t.weak()});
            same(&got, want, &format!("{} call {i} ({})", case.name, op(c)));
        }
    }
}

// MARK: - SaveLadder

fn spec_json(s: StreamSpec) -> Value {
    json!({"mode": s.mode.name(), "fps": s.fps, "density": s.density as f64})
}

#[test]
fn save_ladder_matches_swift() {
    let cases = raw_cases("save-ladder.json");
    assert!(!cases.is_empty());
    for case in &cases {
        let ceiling = StreamSpec {
            mode: mode(&case.input["mode"]),
            fps: int(&case.input, "fps"),
            density: num(&case.input, "density") as f32,
        };
        let streams: Vec<Value> = (-1..=4)
            .map(|level| {
                let mut d = spec_json(save_ladder_stream(level, ceiling));
                d["level"] = json!(level);
                d
            })
            .collect();
        let got = json!({"steps": save_ladder_steps(ceiling), "streams": streams});
        same(&got, &case.out, &case.name);
    }
}

// MARK: - PauseOutbox

fn message(hex_text: &str) -> Message {
    let mut p = MessageParser::new();
    p.append(&unhex(hex_text));
    let m = p.next().expect("Swift message decodes").expect("a whole message");
    assert!(p.next().expect("nothing after it").is_none(), "one message per hex");
    m
}

fn message_hex(m: Option<Message>) -> Value {
    m.map_or(Value::Null, |m| json!(hex(&m.encoded())))
}

#[test]
fn pause_outbox_matches_swift() {
    let cases = raw_cases("pause-outbox.json");
    assert!(!cases.is_empty());
    for case in &cases {
        let mut o = PauseOutbox::new();
        for (i, (c, want)) in trace(case).into_iter().enumerate() {
            let r = match op(c) {
                "pass" => {
                    let text = c["msg"].as_str().expect("msg");
                    let m = message(text);
                    // The message itself must re-encode to Swift's bytes, or the comparison below
                    // would test the codec, not the outbox.
                    assert_eq!(hex(&m.encoded()), text, "{} call {i}: message re-encodes", case.name);
                    message_hex(o.pass(m, num(c, "now")))
                }
                "due" => message_hex(o.due(num(c, "now"))),
                "changed" => message_hex(o.changed(num(c, "now"))),
                "set_paused" => {
                    let held = o.set_paused(flag(c, "on"), num(c, "now"));
                    Value::Array(held.into_iter().map(|m| json!(hex(&m.encoded()))).collect())
                }
                other => panic!("{}: unknown op {other}", case.name),
            };
            let got = json!({"r": r, "paused": o.paused()});
            same(&got, want, &format!("{} call {i} ({})", case.name, op(c)));
        }
    }
}

// MARK: - PacedSender pictures

/// `pseudoRandom` (DeflateTests.swift): a 32-bit LCG, the top byte of each state.
fn pseudo_random(count: usize, seed: u32) -> Vec<u8> {
    let mut state = seed.wrapping_mul(2_654_435_761).wrapping_add(1);
    (0..count)
        .map(|_| {
            state = state.wrapping_mul(1_664_525).wrapping_add(1_013_904_223);
            (state >> 24) as u8
        })
        .collect()
}

/// `randomSamples` (TileCodecTests.swift): valid samples for a mode.
fn random_samples(width: usize, height: usize, mode: Mode, seed: u32) -> Vec<u8> {
    let mut s = pseudo_random(width * height * mode.bytes_per_sample(), seed);
    if mode == Mode::Gray4 {
        for b in &mut s {
            *b &= 0x0F;
        }
    }
    s
}

/// `PacedSenderTests.scene`: opaque blocky pixels in screen space, BGRA.
fn scene_bgra(x: usize, y: usize, w: usize, h: usize, noise_from: Option<usize>) -> Vec<u8> {
    let mut bgra = vec![255u8; w * h * 4];
    let mut rng: u32 = 12345;
    for py in 0..h {
        for px in 0..w {
            let o = (py * w + px) * 4;
            // Swift: `UInt32(truncatingIfNeeded: ((x + px) / 3) &* 2_654_435_761 ^ ((y + py) / 2) &* 40503)`
            // in 64-bit Int; `&*` binds tighter than `^`.
            let a = (((x + px) / 3) as i64).wrapping_mul(2_654_435_761);
            let b = (((y + py) / 2) as i64).wrapping_mul(40503);
            let mut v = (a ^ b) as u32;
            if let Some(n) = noise_from {
                if py >= n {
                    rng = rng.wrapping_mul(1_664_525).wrapping_add(1_013_904_223);
                    v = rng;
                }
            }
            bgra[o] = (v & 0xFF) as u8;
            bgra[o + 1] = (v >> 8 & 0xFF) as u8;
            bgra[o + 2] = (v >> 16 & 0xFF) as u8;
        }
    }
    bgra
}

/// One edit of `PacingFixtures.apply`.
fn apply_edit(e: &Value, bgra: &mut [u8], w: usize, h: usize) {
    match e["kind"].as_str().expect("edit kind") {
        "typed" => {
            let n = int(e, "n") as usize;
            for c in 0..n {
                for py in (h - 40)..(h - 24) {
                    for px in (w - 200 + c * 8)..(w - 194 + c * 8) {
                        let o = (py * w + px) * 4;
                        bgra[o] = 10;
                        bgra[o + 1] = 10;
                        bgra[o + 2] = 10;
                    }
                }
            }
        }
        "touch" => {
            let seed = int(e, "seed") as u8;
            let row = int(e, "row") as usize;
            for py in row..(row + 16) {
                for px in 0..16 {
                    bgra[(py * w + px) * 4] = seed.wrapping_add(px as u8);
                }
            }
        }
        "corner" => {
            let i = int(e, "i") as usize;
            for py in (h - 64)..h {
                for px in (w - 64)..w {
                    let o = (py * w + px) * 4;
                    bgra[o] = (i * 37 + px) as u8;
                    bgra[o + 1] = (i * 11 + py) as u8;
                }
            }
        }
        other => panic!("unknown edit {other}"),
    }
}

struct Picture {
    samples: Vec<u8>,
    raw: Option<Vec<u8>>,
    width: usize,
    height: usize,
    region: CanvasRect,
}

/// Rebuilds one picture from its spec and checks it against Swift's hashes.
fn picture(spec: &Value, at: &str) -> Picture {
    let p = match spec["gen"].as_str().expect("gen") {
        "random" => {
            let (w, h) = (int(spec, "w") as usize, int(spec, "h") as usize);
            Picture {
                samples: random_samples(w, h, mode(&spec["mode"]), int(spec, "seed") as u32),
                raw: None,
                width: w,
                height: h,
                region: rect_of(&spec["region"]),
            }
        }
        "scene" => {
            let (w, h) = (int(spec, "w") as usize, int(spec, "h") as usize);
            let noise = spec["noise_from"].as_i64().map(|n| n as usize);
            let mut bgra = scene_bgra(int(spec, "x") as usize, int(spec, "y") as usize, w, h, noise);
            for e in spec["edits"].as_array().expect("edits") {
                apply_edit(e, &mut bgra, w, h);
            }
            let samples = quantize(&bgra, w, h, w * 4, mode(&spec["quantize"]));
            Picture { samples, raw: Some(bgra), width: w, height: h, region: rect_of(&spec["region"]) }
        }
        other => panic!("{at}: unknown generator {other}"),
    };
    assert_eq!(
        fnv_hex(&p.samples),
        spec["samples_fnv"].as_str().unwrap(),
        "{at}: samples differ from Swift's (generator or quantizer)"
    );
    let raw_fnv = p.raw.as_deref().map(fnv_hex);
    assert_eq!(raw_fnv.as_deref(), spec["raw_fnv"].as_str(), "{at}: raw pixels differ from Swift's (generator)");
    p
}

// MARK: - PacedSender

fn events(out: Vec<SenderOutput>) -> Vec<Value> {
    out.into_iter()
        .map(|e| match e {
            SenderOutput::Frame { region, payload } => {
                let bytes = Message::Frame { region, payload }.encoded();
                let hex_value = if bytes.len() <= 512 { json!(hex(&bytes)) } else { Value::Null };
                json!({"frame": {"len": bytes.len(), "fnv": fnv_hex(&bytes), "hex": hex_value}})
            }
            SenderOutput::LevelChanged(n) => json!({"level": n}),
            SenderOutput::Encoded(r) => {
                // Swift `[Int(minX), Int(minY), Int(width), Int(height)]`: truncation toward zero.
                let copy = r.copy_bounds.map_or(Value::Null, |b| {
                    json!([b.x as i64, b.y as i64, b.width as i64, b.height as i64])
                });
                json!({"encoded": {
                    "region": rect_json(r.region), "width": r.width, "height": r.height,
                    "full": r.full, "changed": r.changed, "copy": copy,
                }})
            }
        })
        .collect()
}

fn stats_json(st: &Stats) -> Value {
    json!({
        "rtt_ms": opt_i(st.rtt_ms), "base_rtt_ms": opt_i(st.base_rtt_ms), "latency_ms": opt_i(st.latency_ms),
        "in_flight": st.in_flight, "cap": st.cap, "weak": st.weak, "level": st.level,
        "full_frames": st.full_frames, "encode_ms_max": opt_i(st.encode_ms_max),
    })
}

#[test]
fn paced_sender_matches_swift() {
    let cases = raw_cases("paced-sender.json");
    assert!(!cases.is_empty());
    for case in &cases {
        let pictures: Vec<Picture> = case.input["pictures"]
            .as_array()
            .expect("pictures")
            .iter()
            .enumerate()
            .map(|(i, spec)| picture(spec, &format!("{} picture {i}", case.name)))
            .collect();
        // No timer: the clock moves only between calls, so every encode takes 0 ms, as in Swift.
        let mut s = PacedSender::new(mode(&case.input["mode"]), int(&case.input, "fps"));
        for (i, (c, want)) in trace(case).into_iter().enumerate() {
            let mut stats = None;
            let out = match op(c) {
                "offer" => {
                    let p = &pictures[int(c, "pic") as usize];
                    s.offer(
                        p.samples.clone(),
                        p.raw.clone(),
                        p.width,
                        p.height,
                        p.region,
                        num(c, "captured"),
                        num(c, "now"),
                    )
                }
                "ack" => s.ack(int(c, "ms") as u16, num(c, "now")),
                "settle" => s.settle_if_idle(num(c, "now")),
                "tick" => s.tick(num(c, "now")),
                "set_paused" => s.set_paused(flag(c, "on"), num(c, "now")),
                "set_mode" => {
                    s.set_mode(mode(&c["mode"]));
                    Vec::new()
                }
                "set_fps" => {
                    s.set_fps(int(c, "fps"));
                    Vec::new()
                }
                "set_pinned" => s.set_pinned(flag(c, "on")),
                "set_steps" => s.set_steps(ints(c, "steps")),
                "take_stats" => {
                    stats = Some(s.take_stats(num(c, "now")));
                    Vec::new()
                }
                other => panic!("{}: unknown op {other}", case.name),
            };
            let mut got = json!({"events": events(out), "level": s.level(), "weak": s.weak()});
            if let Some(st) = &stats {
                got["stats"] = stats_json(st);
            }
            same(&got, want, &format!("{} call {i} ({})", case.name, op(c)));
        }
    }
}

/// Plan B Task 6: with no acks, offers only replace the held one: one frame goes
/// out (the cap before any round trip is one) and at most one frame's samples wait.
#[test]
fn unacknowledged_stream_keeps_one_frame() {
    let (w, h) = (64usize, 64usize);
    let region = CanvasRect::new(0.0, 0.0, 1.0, 1.0);
    let mut s = PacedSender::new(Mode::Gray4, 30);
    let mut frames = 0usize;
    for k in 0..1001u32 {
        let now = k as f64 / 30.0;
        let out = s.offer(random_samples(w, h, Mode::Gray4, k + 1), None, w, h, region, now, now);
        frames += out.iter().filter(|e| matches!(e, SenderOutput::Frame { .. })).count();
        assert!(s.pending_bytes() <= w * h, "offer {k}: {} bytes held", s.pending_bytes());
    }
    assert_eq!(frames, 1, "nothing but the first frame may go out without an ack");
    assert_eq!(s.pending_bytes(), w * h, "the newest offer is held");
}
