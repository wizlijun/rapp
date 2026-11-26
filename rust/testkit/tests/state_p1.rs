//! rapp-state step 1, from the device side: what the outbox does, and does not do, in a running
//! `rapp-service` with the fake `rapp-term`.

mod common;
use common::sharing::*;
use common::*;

use serde_json::{json, Value};
use std::path::Path;
use std::time::Duration;

/// A service on a fresh home, trusting `key`, after `prepare` ran on its home.
async fn start_on(first: u16, key: &rapp_wire::Key, prepare: impl FnOnce(&Path)) -> TestService {
    start_sharing_opts(prepare, (first, 10), true, Some(key.to_string().parse().unwrap())).await.0
}

/// `a`'s `hosts.json` lists `others`.
fn knows(a: &TestService, others: &[&TestService]) {
    let hosts: Vec<Value> = others.iter().map(|o| json!({"id": o.id, "name": o.id, "lan": [a_addr(&o.svc).to_string()]})).collect();
    std::fs::write(a.home.path().join("hosts.json"), Value::Array(hosts).to_string()).unwrap();
}

async fn ipc(s: &TestService, cmd: Value) -> Value {
    ipc_once(&s.svc, s.home.path(), cmd).await
}

fn term_log(bins: &Path) -> String {
    std::fs::read_to_string(bins.join("term.log")).unwrap_or_default()
}

/// A `term.json` whose fake sessions carry program status: session `a` in `state` with question `seq`.
fn term_json(home: &Path, state: &str, seq: u64) {
    let ps = json!({"state": state, "seq": seq, "since": 1764130000 + seq, "msg": "SECRET-TEXT"});
    let rows = json!([{"key": "a", "ps": ps, "title": "SECRET-TITLE", "fg": "claude"}]);
    std::fs::write(home.join("term.json"), json!({"allow": true, "fake_rows": rows}).to_string()).unwrap();
}

fn idle_outbox() -> Value {
    json!({"active":false,"cached":0,"sent":0,"dropped":0,"refused":0,"last_ok":null,"up":false,"dest":null})
}

#[tokio::test]
async fn without_a_state_service_nothing_changes() {
    let key = rapp_wire::Key::new_local();
    let a = start_on(29150, &key, |_| {}).await;
    let b = start_on(29160, &key, |home| term_json(home, "idle", 0)).await;
    knows(&a, &[&b]);
    knows(&b, &[&a]);
    // A reads B's share list: no state service in it.
    let r = ipc(&a, json!({"cmd":"hosts"})).await;
    assert_eq!(r["ok"], true, "{r}");
    for (state, seq) in [("working", 1), ("blocked", 2), ("done", 3)] {
        term_json(b.home.path(), state, seq);
        tokio::time::sleep(Duration::from_millis(700)).await;
    }
    for s in [&a, &b] {
        let r = ipc(s, json!({"cmd":"state"})).await;
        assert_eq!(r["ok"], true, "{r}");
        assert_eq!(r["outbox"], idle_outbox(), "{r}");
        assert_eq!(r["sinks"], json!([]), "{r}");
        let events = log_events(s.home.path());
        let ours: Vec<&Value> = events
            .iter()
            .filter(|v| v["ev"].as_str().is_some_and(|e| e.starts_with("outbox_") || e.starts_with("state_sink")))
            .collect();
        assert!(ours.is_empty(), "{ours:?}");
    }
    assert!(!term_log(b.bins.path()).lines().any(|l| l == "watch open"), "{}", term_log(b.bins.path()));
}

#[tokio::test]
async fn terminals_off_starts_no_worker() {
    let key = rapp_wire::Key::new_local();
    let a = start_on(29170, &key, |_| {}).await;
    let a_id = a.id.clone();
    let b = start_on(29180, &key, |home| {
        std::fs::write(home.join("term.json"), r#"{"allow":false}"#).unwrap();
        std::fs::write(home.join("state-sinks.json"), json!([{"id": a_id, "port": 8102}]).to_string()).unwrap();
    })
    .await;
    knows(&b, &[&a]);
    let deadline = tokio::time::Instant::now() + WAIT;
    loop {
        let r = ipc(&b, json!({"cmd":"state"})).await;
        if r["outbox"]["dest"] == json!({"id": a.id, "port": 8102}) && r["outbox"]["active"] == true {
            break;
        }
        assert!(tokio::time::Instant::now() < deadline, "{r}");
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    tokio::time::sleep(Duration::from_secs(3)).await;
    assert_eq!(term_log(b.bins.path()), "", "no worker while terminal sessions are off");
    let r = ipc(&b, json!({"cmd":"set_term","allow":true})).await;
    assert_eq!(r["ok"], true, "{r}");
    let deadline = tokio::time::Instant::now() + Duration::from_secs(2);
    while !term_log(b.bins.path()).lines().any(|l| l == "watch open") {
        assert!(tokio::time::Instant::now() < deadline, "no watch within 2 s: {}", term_log(b.bins.path()));
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    // A has no such share: B forgets it, and the watch goes with it.
    let l = wait_log(b.home.path(), "state_sink", |v| v["on"] == false).await;
    assert_eq!((l["id"].as_str(), l["from"].as_str()), (Some(a.id.as_str()), Some("outbox")), "{l}");
    let deadline = tokio::time::Instant::now() + WAIT;
    while !term_log(b.bins.path()).lines().any(|l| l == "watch closed") {
        assert!(tokio::time::Instant::now() < deadline, "the watch stayed: {}", term_log(b.bins.path()));
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    let r = ipc(&b, json!({"cmd":"state"})).await;
    assert_eq!(r["outbox"], idle_outbox(), "{r}");
}
