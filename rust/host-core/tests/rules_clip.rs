//! Clipboard rules against the Swift reference. Fixtures are written by
//! `Tests/RappCoreTests/HostCoreFixtures/ClipFixtures.swift` (`clip-rules.json`,
//! `paste-session.json`).

mod common;
mod rules_common;

use common::{hex, raw_cases};
use rapp_host_core::clipboard::*;
use rules_common::*;
use serde::Deserialize;
use serde_json::{json, Value};

#[test]
fn clip_rules_match_swift() {
    let cases = raw_cases("clip-rules.json");
    assert!(!cases.is_empty());
    for c in cases {
        let i = &c.input;
        let got: Value = match func(i) {
            "clip_kind" => {
                let types: Vec<String> = arg(&i["types"]);
                match clip_kind(&types) {
                    ClipSource::Files => json!({"kind": "files", "uti": null}),
                    ClipSource::Image => json!({"kind": "image", "uti": null}),
                    ClipSource::Text => json!({"kind": "text", "uti": null}),
                    ClipSource::Data { uti } => json!({"kind": "data", "uti": uti}),
                    ClipSource::None => json!({"kind": "none", "uti": null}),
                }
            }
            "concealed" => json!(is_concealed_clip(&arg::<Vec<String>>(&i["types"]))),
            "should_restore" => json!(should_restore(arg(&i["last"]), arg(&i["current"]))),
            "resume_offset" => json!(resume_offset(arg(&i["part"]), arg(&i["total"]))),
            "safe_file_name" => json!(safe_file_name(&arg::<String>(&i["raw"]))),
            "unique_name" => {
                let existing: Vec<String> = arg(&i["existing"]);
                let name: String = arg(&i["name"]);
                json!(rapp_host_core::filename::unique_name(&name, &|n| existing.iter().any(|e| e == n)))
            }
            "clip_text" => {
                let fill: String = arg(&i["fill"]);
                let count: usize = arg(&i["count"]);
                let tail: String = arg(&i["tail"]);
                let s = fill.repeat(count) + &tail;
                let (t, cut) = clip_text(&s);
                let u = t.as_bytes();
                json!({"len": u.len(), "truncated": cut, "end": hex(&u[u.len().saturating_sub(16)..])})
            }
            "constants" => json!({
                "max_clip_text": MAX_CLIP_TEXT,
                "max_clip_files": MAX_CLIP_FILES,
                "inline_paste_limit": INLINE_PASTE_LIMIT,
                "chunk_size": CHUNK_SIZE,
                "max_side_connections": MAX_SIDE_CONNECTIONS,
                "retry_delays": RETRY_DELAYS,
                "type_file_url": TYPE_FILE_URL,
                "type_png": TYPE_PNG,
                "type_tiff": TYPE_TIFF,
                "type_utf8_text": TYPE_UTF8_TEXT,
                "restore_delay": PasteSession::RESTORE_DELAY,
                "clip_capacity": rapp_host_core::transfers::ClipStore::CAPACITY,
            }),
            other => panic!("{}: unknown fn {other}", c.name),
        };
        // Numbers compare by value: Swift writes `2` for the Double 2.0, serde_json `2.0`.
        assert!(same(&got, &c.out), "{}: got {got}, Swift {}", c.name, c.out);
    }
}

/// JSON equality where numbers compare as f64 (both sides only hold small exact values).
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

#[derive(Debug, Deserialize)]
#[serde(tag = "op", rename_all = "snake_case")]
enum PasteStep {
    Started { now: f64 },
    Finished { now: f64 },
    Due { now: f64 },
    Restored,
}

#[test]
fn paste_session_matches_swift() {
    let cases = raw_cases("paste-session.json");
    assert!(!cases.is_empty());
    for c in cases {
        assert_eq!(func(&c.input), "trace", "{}", c.name);
        let steps: Vec<PasteStep> = arg(&c.input["steps"]);
        let outs: Vec<Value> = arg(&c.out);
        assert_eq!(steps.len(), outs.len(), "{}", c.name);
        let mut p = PasteSession::new();
        for (n, (step, want)) in steps.iter().zip(&outs).enumerate() {
            let got = match step {
                PasteStep::Started { now } => json!(p.paste_started(*now)),
                PasteStep::Finished { now } => {
                    p.paste_finished(*now);
                    Value::Null
                }
                PasteStep::Due { now } => json!(p.restore_due(*now)),
                PasteStep::Restored => {
                    p.restored();
                    Value::Null
                }
            };
            assert_eq!(&got, want, "{} step {n}: {step:?}", c.name);
        }
    }
}

#[test]
fn limits_are_the_specs() {
    // Spec §6.7: PNG and other data under 64 MiB, at most 100 files.
    assert_eq!(MAX_CLIP_IMAGE, 64 << 20);
    assert_eq!(MAX_CLIP_DATA, 64 << 20);
    assert_eq!(MAX_CLIP_FILES, 100);
    assert_eq!(TOO_MANY_FILES, "文件太多（不支持）");
    assert_eq!(FOLDER_UNSUPPORTED, "文件夹（不支持）");
}

#[test]
fn clip_text_never_splits_a_scalar() {
    // 1 MiB + 1 byte, the last character a 4-byte emoji that straddles the limit.
    let s = "a".repeat(MAX_CLIP_TEXT - 3) + "😀";
    let (t, cut) = clip_text(&s);
    assert!(cut);
    assert_eq!(t.len(), MAX_CLIP_TEXT - 3);
    let exact = "a".repeat(MAX_CLIP_TEXT - 4) + "😀";
    assert_eq!(clip_text(&exact), (exact.clone(), false));
}
