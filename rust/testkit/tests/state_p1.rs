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

// ---- the companion: `rapp-state` started, shared and stopped by `rapp-service` ----

/// A port nothing listens on now (never 8102, the real default).
fn free_port() -> u16 {
    std::net::TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap().port()
}

/// `services.json` with the state service on `port` (`store` "memory" or "disk"), `on` or not.
fn services(home: &Path, port: u16, store: &str, on: bool) {
    let v = json!({"state": {"on": on, "port": port, "store": store}});
    std::fs::write(home.join("services.json"), v.to_string()).unwrap();
}

/// Polls IPC `state` on `s` until `f` accepts the reply, for at most `within`.
async fn wait_state(s: &TestService, within: Duration, f: impl Fn(&Value) -> bool) -> Value {
    let deadline = tokio::time::Instant::now() + within;
    loop {
        let r = ipc(s, json!({"cmd":"state"})).await;
        assert_eq!(r["ok"], true, "{r}");
        if f(&r) {
            return r;
        }
        assert!(tokio::time::Instant::now() < deadline, "not within {within:?}: {r}");
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
}

/// `GET /v1/health` on `127.0.0.1:<port>`, by hand: the reply body, or None when nothing answers.
async fn health(port: u16) -> Option<Value> {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    let get = async {
        let mut tcp = tokio::net::TcpStream::connect(("127.0.0.1", port)).await.ok()?;
        tcp.write_all(b"GET /v1/health HTTP/1.1\r\nHost: rapp-state\r\nConnection: close\r\n\r\n").await.ok()?;
        let mut text = String::new();
        tcp.read_to_string(&mut text).await.ok()?;
        let (_, body) = text.split_once("\r\n\r\n")?;
        serde_json::from_str::<Value>(body.trim()).ok()
    };
    tokio::time::timeout(Duration::from_secs(2), get).await.ok().flatten()
}

/// The share of `port` in `s`'s IPC `shares`, if any.
async fn share_of(s: &TestService, port: u16) -> Option<Value> {
    let r = ipc(s, json!({"cmd":"shares"})).await;
    assert_eq!(r["ok"], true, "{r}");
    r["shares"].as_array().unwrap().iter().find(|x| x["port"] == port).cloned()
}

#[tokio::test]
async fn state_on_runs_and_shares_it() {
    let key = rapp_wire::Key::new_local();
    let p = free_port();
    let a = start_on(29000, &key, |h| services(h, p, "memory", false)).await;
    assert_eq!(health(p).await, None);
    let r = ipc(&a, json!({"cmd":"state","on":true})).await;
    assert_eq!(r["ok"], true, "{r}");
    let r = wait_state(&a, Duration::from_secs(5), |r| r["running"] == true).await;
    assert_eq!((r["on"].clone(), r["port"].clone(), r["error"].clone()), (json!(true), json!(p), Value::Null), "{r}");
    assert!(r["share"].as_u64().is_some_and(|n| (29000..29010).contains(&n)), "a share number: {r}");
    assert_eq!(r["stored"], json!({"devices": 0, "sessions": 0, "queued": 0, "last": null}), "{r}");
    let s = share_of(&a, p).await.expect("the state service is shared");
    assert_eq!((s["kind"].as_str(), s["note"].as_str()), (Some("state"), Some("状态服务")), "{s}");
    assert_eq!(s["local"], r["share"], "{s}");
    assert_eq!(health(p).await.unwrap()["name"], "rapp-state");
    let r = wait_state(&a, WAIT, |r| r["outbox"]["dest"] == json!({"local": p})).await;
    assert_eq!(r["sinks"], json!([{"id": a.id, "port": p, "local": true, "chosen": true}]), "{r}");
    let l = wait_log(a.home.path(), "companion_start", |_| true).await;
    assert_eq!((l["name"].as_str(), l["port"].as_u64()), (Some("state"), Some(p as u64)), "{l}");
    assert!(l["pid"].as_u64().is_some(), "{l}");
    wait_log(a.home.path(), "companion_ready", |v| v["name"] == "state").await;
    let l = wait_log(a.home.path(), "state_sink", |v| v["from"] == "local").await;
    assert_eq!((l["id"].as_str(), l["on"].as_bool()), (Some(a.id.as_str()), Some(true)), "{l}");
    // The file keeps what it had, with `on` set.
    let file: Value = serde_json::from_slice(&std::fs::read(a.home.path().join("services.json")).unwrap()).unwrap();
    assert_eq!(file, json!({"state": {"on": true, "port": p, "store": "memory"}}));
}

#[tokio::test]
async fn state_off_stops_and_unshares() {
    let key = rapp_wire::Key::new_local();
    let p = free_port();
    let a = start_on(29010, &key, |h| services(h, p, "disk", false)).await;
    // The user shared the port before, with a note of their own.
    let r = ipc(&a, json!({"cmd":"share","ports":[p],"note":"我的"})).await;
    assert_eq!(r["ok"], true, "{r}");
    // Off while off: an ordinary share of that port is not the companion's, and stays.
    let r = ipc(&a, json!({"cmd":"state","on":false})).await;
    assert_eq!((r["ok"].clone(), r["on"].clone(), r["running"].clone()), (json!(true), json!(false), json!(false)), "{r}");
    assert!(share_of(&a, p).await.is_some());
    ipc(&a, json!({"cmd":"state","on":true})).await;
    let r = wait_state(&a, Duration::from_secs(5), |r| r["running"] == true).await;
    let s = share_of(&a, p).await.unwrap();
    assert_eq!((s["kind"].as_str(), s["note"].as_str()), (Some("state"), Some("我的")), "the user's note stays: {s}");
    assert_eq!(s["local"], r["share"], "{s}");
    // Its stderr goes to its own log file.
    let text = std::fs::read_to_string(a.home.path().join("logs").join("rapp-state.log")).unwrap_or_default();
    assert!(text.contains("\"listening\""), "{text}");
    wait_state(&a, WAIT, |r| r["outbox"]["dest"] == json!({"local": p})).await;

    let r = ipc(&a, json!({"cmd":"state","on":false})).await;
    assert_eq!(r["ok"], true, "{r}");
    assert_eq!((r["on"].clone(), r["running"].clone(), r["share"].clone()), (json!(false), json!(false), Value::Null), "{r}");
    assert_eq!(r["sinks"], json!([]), "{r}");
    assert!(share_of(&a, p).await.is_none(), "unshared");
    let deadline = tokio::time::Instant::now() + Duration::from_secs(2);
    while health(p).await.is_some() {
        assert!(tokio::time::Instant::now() < deadline, "rapp-state still answers");
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    wait_state(&a, WAIT, |r| r["outbox"]["dest"].is_null()).await;
    wait_log(a.home.path(), "state_sink", |v| v["from"] == "local" && v["on"] == false).await;
    let file: Value = serde_json::from_slice(&std::fs::read(a.home.path().join("services.json")).unwrap()).unwrap();
    assert_eq!(file["state"]["on"], false, "{file}");
}

#[tokio::test]
async fn a_taken_port_is_said_and_not_shared() {
    let key = rapp_wire::Key::new_local();
    let hold = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let p = hold.local_addr().unwrap().port();
    let a = start_on(29020, &key, |h| services(h, p, "memory", false)).await;
    ipc(&a, json!({"cmd":"state","on":true})).await;
    let want = format!("端口 {p} 被占用");
    let r = wait_state(&a, Duration::from_secs(5), |r| r["error"] == want.as_str()).await;
    assert_eq!((r["on"].clone(), r["running"].clone(), r["share"].clone()), (json!(true), json!(false), Value::Null), "{r}");
    assert!(share_of(&a, p).await.is_none(), "not shared");
    assert_eq!(r["sinks"], json!([]), "{r}");
    wait_log(a.home.path(), "companion_failed", |v| v["name"] == "state").await;
    // The port is free again: `on` once more tries at once, not after the backoff.
    drop(hold);
    tokio::time::sleep(Duration::from_millis(300)).await;
    ipc(&a, json!({"cmd":"state","on":true})).await;
    let r = wait_state(&a, Duration::from_secs(5), |r| r["running"] == true).await;
    assert_eq!(r["error"], Value::Null, "{r}");
    assert_eq!(share_of(&a, p).await.expect("shared now")["kind"], "state");
}

#[tokio::test]
async fn a_crashed_service_comes_back() {
    let key = rapp_wire::Key::new_local();
    let p = free_port();
    let a = start_on(29030, &key, |h| services(h, p, "memory", false)).await;
    ipc(&a, json!({"cmd":"state","on":true})).await;
    let r = wait_state(&a, Duration::from_secs(5), |r| r["running"] == true).await;
    let share = r["share"].clone();
    let pid = wait_log(a.home.path(), "companion_start", |_| true).await["pid"].as_u64().unwrap();
    assert_eq!(health(p).await.unwrap()["name"], "rapp-state");
    let killed = std::process::Command::new("kill").args(["-9", &pid.to_string()]).status().unwrap();
    assert!(killed.success());
    wait_log(a.home.path(), "companion_exit", |v| v["name"] == "state").await;
    let l = wait_log(a.home.path(), "state_sink", |v| v["from"] == "local" && v["on"] == false).await;
    assert_eq!(l["id"], a.id.as_str(), "{l}");
    let r = wait_state(&a, Duration::from_secs(10), |r| r["running"] == true).await;
    assert_eq!(r["share"], share, "the share stayed: {r}");
    let again = wait_log(a.home.path(), "companion_start", |v| v["pid"] != pid).await;
    assert_eq!(again["port"], p, "{again}");
    assert_eq!(health(p).await.unwrap()["name"], "rapp-state");
    wait_state(&a, WAIT, |r| r["outbox"]["dest"] == json!({"local": p})).await;
}

#[tokio::test]
async fn state_on_tells_the_known_devices() {
    let key = rapp_wire::Key::new_local();
    let p = free_port();
    let a = start_on(29040, &key, |h| services(h, p, "memory", false)).await;
    let b = start_on(29050, &key, |_| {}).await;
    knows(&a, &[&b]);
    ipc(&a, json!({"cmd":"state","on":true})).await;
    let r = wait_state(&b, Duration::from_secs(10), |r| r["sinks"].as_array().is_some_and(|s| !s.is_empty())).await;
    assert_eq!(r["sinks"], json!([{"id": a.id, "port": p, "local": false, "chosen": true}]), "{r}");
    assert_eq!((r["on"].clone(), r["running"].clone()), (json!(false), json!(false)), "{r}");
}

#[tokio::test]
async fn two_companions_pick_the_same_one() {
    let key = rapp_wire::Key::new_local();
    let (pb, pc) = (free_port(), free_port());
    let a = start_on(29060, &key, |_| {}).await;
    let b = start_on(29070, &key, |h| services(h, pb, "memory", false)).await;
    // C's is on in the file: it is started with the service.
    let c = start_on(29080, &key, |h| services(h, pc, "memory", true)).await;
    knows(&a, &[&b, &c]);
    ipc(&b, json!({"cmd":"state","on":true})).await;
    wait_state(&b, Duration::from_secs(5), |r| r["running"] == true).await;
    wait_state(&c, Duration::from_secs(5), |r| r["running"] == true).await;
    let r = ipc(&a, json!({"cmd":"hosts"})).await;
    assert_eq!(r["ok"], true, "{r}");
    let (small, port) = if b.id < c.id { (&b, pb) } else { (&c, pc) };
    let far = json!({"id": small.id, "port": port});
    let within = Duration::from_secs(15);
    for s in [&a, &b, &c] {
        let want = if s.id == small.id { json!({"local": port}) } else { far.clone() };
        let r = wait_state(s, within, |r| r["outbox"]["dest"] == want).await;
        let chosen: Vec<&Value> = r["sinks"].as_array().unwrap().iter().filter(|x| x["chosen"] == true).collect();
        assert_eq!(chosen.len(), 1, "{r}");
        assert_eq!((chosen[0]["id"].as_str(), chosen[0]["port"].as_u64()), (Some(small.id.as_str()), Some(port as u64)), "{r}");
    }
    // B and C each know both: their own and the other's.
    for s in [&b, &c] {
        let r = wait_state(s, within, |r| r["sinks"].as_array().is_some_and(|x| x.len() == 2)).await;
        let local: Vec<bool> = r["sinks"].as_array().unwrap().iter().map(|x| x["local"] == true).collect();
        assert_eq!(local.iter().filter(|l| **l).count(), 1, "{r}");
    }
}
