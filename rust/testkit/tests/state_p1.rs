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
    hosts_file(a.home.path(), others);
}

/// `home/hosts.json` lists `others` (before its service starts, or after).
fn hosts_file(home: &Path, others: &[&TestService]) {
    let hosts: Vec<Value> = others.iter().map(|o| json!({"id": o.id, "name": o.id, "lan": [a_addr(&o.svc).to_string()]})).collect();
    std::fs::write(home.join("hosts.json"), Value::Array(hosts).to_string()).unwrap();
}

async fn ipc(s: &TestService, cmd: Value) -> Value {
    ipc_once(&s.svc, s.home.path(), cmd).await
}

fn term_log(bins: &Path) -> String {
    std::fs::read_to_string(bins.join("term.log")).unwrap_or_default()
}

/// A `term.json` whose fake sessions carry program status: session `a` (named "secret-name") in
/// `state` with question `seq`; `blocked` asks for a permission.
fn term_json(home: &Path, state: &str, seq: u64) {
    let mut ps = json!({"state": state, "seq": seq, "since": 1764130000 + seq, "msg": "SECRET-TEXT"});
    if state == "blocked" {
        (ps["kind"], ps["app"]) = (json!("permission"), json!("claude-code"));
    }
    let rows = json!([{"key": "a", "name": "secret-name", "ps": ps, "title": "SECRET-TITLE", "fg": "claude"}]);
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
    http_get(port, "/v1/health").await
}

/// `GET <path>` on `127.0.0.1:<port>`, by hand (as `curl` would): the JSON body, or None when
/// nothing answers.
async fn http_get(port: u16, path: &str) -> Option<Value> {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    let get = async {
        let mut tcp = tokio::net::TcpStream::connect(("127.0.0.1", port)).await.ok()?;
        let req = format!("GET {path} HTTP/1.1\r\nHost: rapp-state\r\nConnection: close\r\n\r\n");
        tcp.write_all(req.as_bytes()).await.ok()?;
        let mut text = String::new();
        tcp.read_to_string(&mut text).await.ok()?;
        let (_, body) = text.split_once("\r\n\r\n")?;
        serde_json::from_str::<Value>(body.trim()).ok()
    };
    tokio::time::timeout(Duration::from_secs(5), get).await.ok().flatten()
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
    // The user made that share: it stays, as an ordinary share again.
    let s = share_of(&a, p).await.expect("the user's share stays");
    assert_eq!((s["kind"].clone(), s["note"].as_str()), (Value::Null, Some("我的")), "{s}");
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
    ipc(&a, json!({"cmd":"state","on":true})).await;
    let r = wait_state(&a, Duration::from_secs(5), |r| r["running"] == true).await;
    assert_eq!(r["error"], Value::Null, "{r}");
    assert_eq!(share_of(&a, p).await.expect("shared now")["kind"], "state");
}

/// A crash is for now only: while the supervisor starts it again, the share and the local sink
/// stay (no device is told `on: false`), so the outbox keeps its cache and sends it once it is
/// back: a change made while it was down reaches the queue.
#[tokio::test]
async fn a_crashed_service_comes_back() {
    let key = rapp_wire::Key::new_local();
    let p = free_port();
    let a = start_on(29030, &key, |h| {
        services(h, p, "memory", false);
        term_json(h, "idle", 0);
    })
    .await;
    let a_fp = fp_of(&a).await;
    ipc(&a, json!({"cmd":"state","on":true})).await;
    let r = wait_state(&a, Duration::from_secs(5), |r| r["running"] == true).await;
    let share = r["share"].clone();
    let pid = wait_log(a.home.path(), "companion_start", |_| true).await["pid"].as_u64().unwrap();
    assert_eq!(health(p).await.unwrap()["name"], "rapp-state");
    wait_state(&a, WAIT, |r| r["outbox"]["dest"] == json!({"local": p}) && r["outbox"]["up"] == true).await;
    wait_http_state(p, WAIT, |v| session_a(v, &a_fp).is_some_and(|s| s["state"] == "idle")).await;
    #[cfg(unix)]
    let killed = std::process::Command::new("kill").args(["-9", &pid.to_string()]).status().unwrap();
    #[cfg(windows)]
    let killed = rapp_net::proc::command("taskkill")
        .args(["/F", "/PID", &pid.to_string()])
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .unwrap();
    assert!(killed.success());
    // Changed while it is down.
    term_json(a.home.path(), "working", 0);
    wait_log(a.home.path(), "companion_exit", |v| v["name"] == "state").await;
    let r = ipc(&a, json!({"cmd":"state"})).await;
    assert_eq!(r["sinks"], json!([{"id": a.id, "port": p, "local": true, "chosen": true}]), "the sink is kept: {r}");
    let r = wait_state(&a, Duration::from_secs(10), |r| r["running"] == true).await;
    assert_eq!(r["share"], share, "the share stayed: {r}");
    let again = wait_log(a.home.path(), "companion_start", |v| v["pid"] != pid).await;
    assert_eq!(again["port"], p, "{again}");
    assert_eq!(health(p).await.unwrap()["name"], "rapp-state");
    // The cached change, not only the snap: it is a queue row of the new service.
    let q = wait_queue(p, Duration::from_secs(15), |q| !q.is_empty()).await;
    assert_eq!(shape(&q), [st("working", 0)], "{q:?}");
    let v = wait_http_state(p, WAIT, |v| session_a(v, &a_fp).is_some_and(|s| s["state"] == "working")).await;
    assert_eq!(v["needs"], json!([]), "{v}");
    let r = wait_state(&a, WAIT, |r| r["outbox"]["cached"] == 0 && r["outbox"]["up"] == true).await;
    assert_eq!(r["outbox"]["dest"], json!({"local": p}), "{r}");
    let off: Vec<Value> = log_events(a.home.path()).into_iter().filter(|v| v["ev"] == "state_sink" && v["on"] == false).collect();
    assert!(off.is_empty(), "no device was told the sink is gone: {off:?}");
}

/// `rapp state off` and `on` with the disk store: the service comes back with what it had seen
/// of this device, and this device's numbers go on from there, so its next change is taken.
#[tokio::test]
async fn off_and_on_again_keeps_taking_changes() {
    let key = rapp_wire::Key::new_local();
    let p = free_port();
    let a = start_on(29470, &key, |h| {
        services(h, p, "disk", false);
        term_json(h, "idle", 0);
    })
    .await;
    let a_fp = fp_of(&a).await;
    ipc(&a, json!({"cmd":"state","on":true})).await;
    wait_state(&a, Duration::from_secs(5), |r| r["running"] == true).await;
    wait_http_state(p, WAIT, |v| session_a(v, &a_fp).is_some_and(|s| s["state"] == "idle")).await;
    for (state, seq) in [("working", 0), ("blocked", 1), ("done", 1)] {
        term_json(a.home.path(), state, seq);
        wait_http_state(p, WAIT, |v| session_a(v, &a_fp).is_some_and(|s| s["state"] == state)).await;
    }
    // Saved: the next start has it.
    let file = a.home.path().join("state").join("state.json");
    let saved = || {
        std::fs::read(&file).ok().and_then(|b| serde_json::from_slice::<Value>(&b).ok()).and_then(|v| v["queue"].as_array().map(Vec::len)).unwrap_or(0)
    };
    let deadline = tokio::time::Instant::now() + WAIT;
    while saved() != 3 {
        assert!(tokio::time::Instant::now() < deadline, "never saved");
        tokio::time::sleep(Duration::from_millis(50)).await;
    }

    let r = ipc(&a, json!({"cmd":"state","on":false})).await;
    assert_eq!((r["ok"].clone(), r["running"].clone()), (json!(true), json!(false)), "{r}");
    // The share the companion made itself goes with it.
    assert!(share_of(&a, p).await.is_none(), "unshared");
    ipc(&a, json!({"cmd":"state","on":true})).await;
    wait_state(&a, Duration::from_secs(5), |r| r["running"] == true).await;
    wait_state(&a, WAIT, |r| r["outbox"]["dest"] == json!({"local": p}) && r["outbox"]["up"] == true).await;
    term_json(a.home.path(), "working", 2);
    let v = wait_http_state(p, Duration::from_secs(10), |v| session_a(v, &a_fp).is_some_and(|s| s["state"] == "working" && s["seq"] == 2)).await;
    assert_eq!(v["needs"], json!([]), "{v}");
    let q = wait_queue(p, WAIT, |q| q.len() >= 4).await;
    assert_eq!(shape(&q), [st("working", 2), st("done", 1), st("blocked", 1), st("working", 0)], "{q:?}");
    all_from(&q, &a_fp);
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
    // Both held at once, so they differ.
    let (hb, hc) = (std::net::TcpListener::bind("127.0.0.1:0").unwrap(), std::net::TcpListener::bind("127.0.0.1:0").unwrap());
    let (pb, pc) = (hb.local_addr().unwrap().port(), hc.local_addr().unwrap().port());
    drop((hb, hc));
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

/// A `rapp-state` this service did not start (a foreign one, or an orphan of an earlier run), on
/// `port`; ended on drop.
struct Foreign(std::process::Child);

impl Foreign {
    async fn on(port: u16) -> Foreign {
        let child = std::process::Command::new(env!("CARGO_BIN_EXE_test-rapp-state"))
            .args(["--port", &port.to_string()])
            .stderr(std::process::Stdio::null())
            .spawn()
            .unwrap();
        let f = Foreign(child);
        let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
        while health(port).await.is_none() {
            assert!(tokio::time::Instant::now() < deadline, "the foreign rapp-state does not answer");
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
        f
    }
}

impl Drop for Foreign {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

#[tokio::test]
async fn a_failed_start_takes_back_its_old_share() {
    let key = rapp_wire::Key::new_local();
    let hold = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let p = hold.local_addr().unwrap().port();
    // An earlier run left its share; this start finds the port taken.
    let a = start_on(29090, &key, |h| {
        share_file(h, json!([{"port": p, "note": "状态服务", "kind": "state", "local": 29091}]));
        services(h, p, "memory", true);
    })
    .await;
    let want = format!("端口 {p} 被占用");
    let r = wait_state(&a, Duration::from_secs(5), |r| r["error"] == want.as_str()).await;
    assert_eq!((r["running"].clone(), r["share"].clone()), (json!(false), Value::Null), "{r}");
    assert!(share_of(&a, p).await.is_none(), "the old share is taken back");
    // A plain share of the port (not the companion's) is never touched.
    ipc(&a, json!({"cmd":"share","ports":[p],"note":"我的"})).await;
    ipc(&a, json!({"cmd":"state","on":true})).await;
    wait_state(&a, Duration::from_secs(5), |r| r["error"] == want.as_str()).await;
    let s = share_of(&a, p).await.expect("the user's share stays");
    assert_eq!((s["kind"].clone(), s["note"].as_str()), (Value::Null, Some("我的")), "{s}");
    drop(hold);
}

#[tokio::test]
async fn a_rapp_state_already_on_the_port_is_not_ours() {
    let key = rapp_wire::Key::new_local();
    let p = free_port();
    let foreign = Foreign::on(p).await;
    let a = start_on(29380, &key, |h| services(h, p, "memory", false)).await;
    let r = ipc(&a, json!({"cmd":"state","on":true})).await;
    assert_eq!(r["ok"], true, "{r}");
    let want = format!("端口 {p} 被占用");
    let r = wait_state(&a, Duration::from_secs(5), |r| r["error"] == want.as_str()).await;
    assert_eq!((r["running"].clone(), r["share"].clone()), (json!(false), Value::Null), "{r}");
    assert_eq!(r["sinks"], json!([]), "not this device's sink: {r}");
    assert!(share_of(&a, p).await.is_none(), "not shared");
    wait_log(a.home.path(), "companion_failed", |v| v["why"] == "port taken").await;
    let log = log_events(a.home.path());
    assert!(log.iter().all(|v| v["ev"] != "companion_ready"), "never ready");
    assert!(log.iter().all(|v| !(v["ev"] == "state_sink" && v["from"] == "local")), "never the local sink");
    drop(foreign);
}

// ---- the P1 acceptance (spec §15): B's terminal sessions reach a real `rapp-state` on A ----

/// The texts that must never reach a log: the question, the session's name, title and id.
const SECRETS: [&str; 4] = ["SECRET-TEXT", "secret-name", "SECRET-TITLE", "term:pty:"];

/// The fingerprint `s` shows (IPC `status`): the `fp` of its events.
async fn fp_of(s: &TestService) -> String {
    ipc(s, json!({"cmd":"status"})).await["fp"].as_str().unwrap().to_string()
}

/// The whole of `/v1/queue` on `port`, newest first, page by page (None: nothing answers).
async fn queue_of(port: u16) -> Option<Vec<Value>> {
    let mut all: Vec<Value> = vec![];
    loop {
        let path = match all.last() {
            None => "/v1/queue?limit=200".to_string(),
            Some(last) => format!("/v1/queue?limit=200&before={}", last["eid"].as_str().unwrap()),
        };
        let page = http_get(port, &path).await?;
        all.extend(page["events"].as_array().unwrap().iter().cloned());
        if page["more"] != true {
            return Some(all);
        }
    }
}

/// Polls `/v1/queue` on `port` until `f` accepts it, for at most `within`.
async fn wait_queue(port: u16, within: Duration, f: impl Fn(&[Value]) -> bool) -> Vec<Value> {
    let deadline = tokio::time::Instant::now() + within;
    loop {
        let q = queue_of(port).await;
        if let Some(q) = q.as_ref().filter(|q| f(q)) {
            return q.clone();
        }
        assert!(tokio::time::Instant::now() < deadline, "not within {within:?}: {q:?}");
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
}

/// Polls `/v1/state` on `port` until `f` accepts it, for at most `within`.
async fn wait_http_state(port: u16, within: Duration, f: impl Fn(&Value) -> bool) -> Value {
    let deadline = tokio::time::Instant::now() + within;
    loop {
        let v = http_get(port, "/v1/state").await;
        if let Some(v) = v.as_ref().filter(|v| f(v)) {
            return v.clone();
        }
        assert!(tokio::time::Instant::now() < deadline, "not within {within:?}: {v:?}");
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
}

/// Device `fp`'s row of session `term:pty:a` in a `/v1/state` reply.
fn session_a<'a>(state: &'a Value, fp: &str) -> Option<&'a Value> {
    let dev = state["devices"].as_array()?.iter().find(|d| d["fp"] == fp)?;
    dev["sessions"].as_array()?.iter().find(|s| s["session"] == "term:pty:a")
}

/// `(t, state, seq)` of queue rows, for comparing their order.
fn shape(rows: &[Value]) -> Vec<(String, String, u64)> {
    rows.iter()
        .map(|r| {
            let s = |k: &str| r[k].as_str().unwrap_or_default().to_string();
            (s("t"), s("state"), r["seq"].as_u64().unwrap_or(0))
        })
        .collect()
}

fn st(state: &str, seq: u64) -> (String, String, u64) {
    ("state".into(), state.into(), seq)
}

/// Every row is one of `fp`'s, numbered in one epoch, newest (highest `n`) first.
fn all_from(rows: &[Value], fp: &str) {
    for r in rows {
        assert_eq!(r["fp"], fp, "{r}");
        assert_eq!(r["eid"].as_str().unwrap().split(':').next(), Some(fp), "{r}");
    }
    let epochs: std::collections::BTreeSet<&str> = rows.iter().map(|r| r["epoch"].as_str().unwrap_or("")).collect();
    let ns: Vec<u64> = rows.iter().filter_map(|r| r["eid"].as_str()?.rsplit(':').next()?.parse().ok()).collect();
    assert_eq!(ns.len(), rows.len(), "{rows:?}");
    assert!(ns.windows(2).all(|w| w[0] > w[1]), "newest first by n: {ns:?}");
    // Gap rows carry no epoch field; the others all the same one.
    assert!(epochs.iter().filter(|e| !e.is_empty()).count() <= 1, "{epochs:?}");
}

/// No file in any of `dirs` (recursively), and none of `lines`, holds a secret. Returns how many
/// files were read, after checking that each of `must` (paths) was among them.
fn no_secrets(dirs: &[&Path], lines: &[Value], must: &[std::path::PathBuf]) -> usize {
    fn walk(dir: &Path, out: &mut Vec<std::path::PathBuf>) {
        for e in std::fs::read_dir(dir).unwrap().flatten() {
            let p = e.path();
            if p.is_dir() {
                walk(&p, out);
            } else {
                out.push(p);
            }
        }
    }
    let mut files = vec![];
    for d in dirs {
        walk(d, &mut files);
    }
    for m in must {
        assert!(files.contains(m), "{m:?} not among {files:?}");
    }
    for f in &files {
        let text = String::from_utf8_lossy(&std::fs::read(f).unwrap()).to_string();
        assert!(!text.is_empty() || !must.contains(f), "{f:?} is empty");
        for secret in SECRETS {
            assert!(!text.contains(secret), "{secret} in {f:?}");
        }
    }
    for l in lines {
        for secret in SECRETS {
            assert!(!l.to_string().contains(secret), "{secret} in the state service's log: {l}");
        }
    }
    files.len()
}

/// A, with `rapp state on` (a free port, in memory), and B with session `a` idle: each knows the
/// other, A's `state on` told B, B's outbox is up and its snap is in. Returns them, the port and
/// B's fingerprint.
async fn told_pair(first: u16) -> (TestService, TestService, u16, String) {
    let key = rapp_wire::Key::new_local();
    let p = free_port();
    let a = start_on(first, &key, |h| services(h, p, "memory", false)).await;
    let b = start_on(first + 10, &key, |h| term_json(h, "idle", 0)).await;
    knows(&a, &[&b]);
    knows(&b, &[&a]);
    let b_fp = fp_of(&b).await;
    let r = ipc(&a, json!({"cmd":"state","on":true})).await;
    assert_eq!(r["ok"], true, "{r}");
    let dest = json!({"id": a.id, "port": p});
    wait_state(&b, Duration::from_secs(15), |r| r["outbox"]["dest"] == dest && r["outbox"]["up"] == true).await;
    let v = wait_http_state(p, WAIT, |v| session_a(v, &b_fp).is_some_and(|s| s["state"] == "idle")).await;
    assert_eq!(v["needs"], json!([]), "{v}");
    assert_eq!(queue_of(p).await.unwrap(), Vec::<Value>::new(), "a snap is no queue row");
    (a, b, p, b_fp)
}

/// Session `a` on B goes working → blocked (a permission, question 1) → done; each lands as one
/// more row in A's queue within 10 s. Returns the queue.
async fn working_blocked_done(b: &TestService, p: u16, b_fp: &str) -> Vec<Value> {
    for (i, (state, seq)) in [("working", 0), ("blocked", 1), ("done", 1)].into_iter().enumerate() {
        term_json(b.home.path(), state, seq);
        let q = wait_queue(p, WAIT, |q| q.len() > i).await;
        assert_eq!(q.len(), i + 1, "{q:?}");
        let v = http_get(p, "/v1/state").await.unwrap();
        assert_eq!(session_a(&v, b_fp).map(|s| s["state"].clone()), Some(json!(state)), "{v}");
        let needs = v["needs"].as_array().unwrap();
        if state == "blocked" {
            assert_eq!(needs.len(), 1, "{v}");
            let n = &needs[0];
            assert_eq!((n["fp"].as_str(), n["session"].as_str(), n["kind"].as_str()), (Some(b_fp), Some("term:pty:a"), Some("permission")), "{n}");
        } else {
            assert_eq!(needs.len(), 0, "{v}");
        }
    }
    queue_of(p).await.unwrap()
}

#[tokio::test]
async fn claude_working_blocked_done_reach_the_queue() {
    let (_a, b, p, b_fp) = told_pair(29190).await;
    let q = working_blocked_done(&b, p, &b_fp).await;
    assert_eq!(shape(&q), [st("done", 1), st("blocked", 1), st("working", 0)], "{q:?}");
    all_from(&q, &b_fp);
    for r in &q {
        assert_eq!((r["session"].as_str(), r["fg"].as_str(), r["src"].as_str()), (Some("term:pty:a"), Some("claude"), Some("term")), "{r}");
    }
    assert_eq!((q[1]["kind"].as_str(), q[1]["app"].as_str()), (Some("permission"), Some("claude-code")), "{}", q[1]);
}

/// A `rapp-state` the test runs itself (`rapp_state::serve_with_log`), on a fixed port with its
/// store in a temp dir: stopped by aborting it, started again on the same port and dir.
struct Ctl {
    port: u16,
    dir: tempfile::TempDir,
    task: Option<tokio::task::JoinHandle<anyhow::Result<()>>>,
    lines: std::sync::Arc<std::sync::Mutex<Vec<Value>>>,
}

impl Ctl {
    async fn new() -> Ctl {
        let mut c = Ctl { port: free_port(), dir: tempfile::tempdir().unwrap(), task: None, lines: Default::default() };
        c.start().await;
        c
    }

    async fn start(&mut self) {
        let l = tokio::net::TcpListener::bind(("127.0.0.1", self.port)).await.unwrap();
        let cfg = rapp_state::Config { port: self.port, data: Some(self.dir.path().join("data")), ..Default::default() };
        let lines = self.lines.clone();
        let log = rapp_state::Log::new(move |v| lines.lock().unwrap().push(v.clone()));
        self.task = Some(tokio::spawn(rapp_state::serve_with_log(cfg, l, log)));
        assert_eq!(health(self.port).await.unwrap()["name"], "rapp-state");
    }

    async fn stop(&mut self) {
        let t = self.task.take().unwrap();
        t.abort();
        let _ = t.await;
        assert_eq!(health(self.port).await, None, "stopped");
    }

    /// The queue length in its `state.json` (what a restart finds).
    fn saved_queue(&self) -> usize {
        std::fs::read(self.dir.path().join("data").join("state.json"))
            .ok()
            .and_then(|b| serde_json::from_slice::<Value>(&b).ok())
            .and_then(|v| v["queue"].as_array().map(Vec::len))
            .unwrap_or(0)
    }

    fn log(&self) -> Vec<Value> {
        self.lines.lock().unwrap().clone()
    }
}

/// A sharing `ctl`'s port as a `kind:"state"` share (no companion: no `services.json`), and B
/// pointed at it in `state-sinks.json`, session `a` idle. Returns them once B's snap is in, with
/// B's fingerprint.
async fn ctl_pair(first: u16, ctl: &Ctl) -> (TestService, TestService, String) {
    let key = rapp_wire::Key::new_local();
    let p = ctl.port;
    let a = start_on(first, &key, |h| share_file(h, json!([{"port": p, "note": "状态服务", "kind": "state", "local": first + 1}]))).await;
    let a_id = a.id.clone();
    let b = start_on(first + 10, &key, |h| {
        term_json(h, "idle", 0);
        std::fs::write(h.join("state-sinks.json"), json!([{"id": a_id, "port": p}]).to_string()).unwrap();
        hosts_file(h, &[&a]);
    })
    .await;
    let b_fp = fp_of(&b).await;
    let dest = json!({"id": a.id, "port": p});
    wait_state(&b, Duration::from_secs(15), |r| r["outbox"]["dest"] == dest && r["outbox"]["up"] == true).await;
    wait_http_state(p, WAIT, |v| session_a(v, &b_fp).is_some_and(|s| s["state"] == "idle")).await;
    (a, b, b_fp)
}

/// Working reaches `ctl`, B holds nothing back, and `ctl` has saved it (so a restart has it).
async fn working_arrives(b: &TestService, ctl: &Ctl) {
    term_json(b.home.path(), "working", 0);
    let q = wait_queue(ctl.port, WAIT, |q| !q.is_empty()).await;
    assert_eq!(shape(&q), [st("working", 0)], "{q:?}");
    wait_state(b, WAIT, |r| r["outbox"]["cached"] == 0).await;
    let deadline = tokio::time::Instant::now() + WAIT;
    while ctl.saved_queue() != 1 {
        assert!(tokio::time::Instant::now() < deadline, "never saved");
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
}

/// The share of `ctl` on A is still the one preloaded: no companion took it back.
async fn ctl_share_stays(a: &TestService, ctl: &Ctl) {
    let s = share_of(a, ctl.port).await.expect("the state share stays");
    assert_eq!(s["kind"], "state", "{s}");
    let r = ipc(a, json!({"cmd":"state"})).await;
    assert_eq!((r["on"].clone(), r["running"].clone()), (json!(false), json!(false)), "no companion on A: {r}");
}

#[tokio::test]
async fn three_changes_while_stopped_arrive_later() {
    let mut ctl = Ctl::new().await;
    let (a, b, b_fp) = ctl_pair(29210, &ctl).await;
    let p = ctl.port;
    working_arrives(&b, &ctl).await;
    ctl.stop().await;
    let changes = [("blocked", 1), ("blocked", 2), ("done", 2)];
    for (i, (state, seq)) in changes.into_iter().enumerate() {
        term_json(b.home.path(), state, seq);
        wait_state(&b, WAIT, |r| r["outbox"]["cached"] == i + 1).await;
    }
    // Nothing listens on A's shared port: A's forward says "refused", which is for now only
    // (`Down`), never `Gone` (that would forget the sink and clear the cache).
    wait_log(b.home.path(), "outbox_down", |v| v["why"] == "refused").await;
    let r = ipc(&b, json!({"cmd":"state"})).await;
    assert_eq!(r["sinks"], json!([{"id": a.id, "port": p, "local": false, "chosen": true}]), "{r}");
    let o = &r["outbox"];
    assert_eq!((o["dest"].clone(), o["active"].clone(), o["up"].clone(), o["cached"].clone()), (json!({"id": a.id, "port": p}), json!(true), json!(false), json!(3)), "{r}");
    assert!(log_events(b.home.path()).iter().all(|v| !(v["ev"] == "state_sink" && v["on"] == false)), "the sink is not forgotten");

    ctl.start().await;
    let q = wait_queue(p, Duration::from_secs(15), |q| q.len() >= 4).await;
    assert_eq!(shape(&q), [st("done", 2), st("blocked", 2), st("blocked", 1), st("working", 0)], "{q:?}");
    all_from(&q, &b_fp);
    let v = wait_http_state(p, WAIT, |v| session_a(v, &b_fp).is_some_and(|s| s["state"] == "done")).await;
    assert_eq!(session_a(&v, &b_fp).unwrap()["seq"], 2, "{v}");
    assert_eq!(v["needs"], json!([]), "{v}");
    let r = wait_state(&b, WAIT, |r| r["outbox"]["cached"] == 0 && r["outbox"]["up"] == true).await;
    assert_eq!(r["outbox"]["dropped"], 0, "{r}");
    ctl_share_stays(&a, &ctl).await;
    let must = [a.home.path().join("logs").join("service.log"), b.home.path().join("logs").join("service.log")];
    assert!(ctl.log().iter().any(|l| l["event"] == "events"), "the state service logged its posts");
    no_secrets(&[&a.home.path().join("logs"), &b.home.path().join("logs")], &ctl.log(), &must);
}

#[tokio::test]
async fn three_hundred_changes_leave_a_gap_row() {
    let mut ctl = Ctl::new().await;
    let (a, b, b_fp) = ctl_pair(29230, &ctl).await;
    let p = ctl.port;
    working_arrives(&b, &ctl).await;
    ctl.stop().await;
    // 300 new questions; 120 ms apart so the fake's watch sends each one.
    for seq in 1..=300 {
        term_json(b.home.path(), "blocked", seq);
        tokio::time::sleep(Duration::from_millis(120)).await;
    }
    let r = wait_state(&b, WAIT, |r| r["outbox"]["dropped"] == 100).await;
    assert_eq!((r["outbox"]["cached"].clone(), r["outbox"]["up"].clone()), (json!(200), json!(false)), "{r}");

    ctl.start().await;
    // The backoff has grown to up to a minute while it was down.
    let q = wait_queue(p, Duration::from_secs(90), |q| q.iter().any(|r| r["t"] == "gap")).await;
    let gaps: Vec<&Value> = q.iter().filter(|r| r["t"] == "gap").collect();
    assert_eq!(gaps.len(), 1, "{gaps:?}");
    assert_eq!(gaps[0]["fp"], b_fp.as_str(), "{}", gaps[0]);
    // The snap comes last: the gap row is the newest; under it the 200 kept (questions 101-300),
    // then the working from before the stop. Questions 1-100 were dropped.
    assert_eq!(q[0]["t"], "gap", "{}", q[0]);
    let mut want: Vec<_> = (101..=300).rev().map(|s| st("blocked", s)).collect();
    want.push(st("working", 0));
    assert_eq!(shape(&q[1..]), want);
    all_from(&q, &b_fp);
    let v = wait_http_state(p, WAIT, |v| session_a(v, &b_fp).is_some_and(|s| s["seq"] == 300)).await;
    assert_eq!(session_a(&v, &b_fp).unwrap()["state"], "blocked", "{v}");
    let r = wait_state(&b, WAIT, |r| r["outbox"]["cached"] == 0 && r["outbox"]["up"] == true).await;
    assert_eq!(r["outbox"]["dropped"], 100, "{r}");
    wait_log(b.home.path(), "outbox_dropped", |v| v["count"] == 100).await;
    ctl_share_stays(&a, &ctl).await;
    let must = [a.home.path().join("logs").join("service.log"), b.home.path().join("logs").join("service.log")];
    assert!(ctl.log().iter().any(|l| l["event"] == "events"), "the state service logged its posts");
    no_secrets(&[&a.home.path().join("logs"), &b.home.path().join("logs")], &ctl.log(), &must);
}

#[tokio::test]
async fn no_text_in_any_log() {
    let (a, b, p, b_fp) = told_pair(29250).await;
    let q = working_blocked_done(&b, p, &b_fp).await;
    // The texts did travel: they are in A's queue and state.
    assert!(q.iter().all(|r| r["msg"] == "SECRET-TEXT" && r["name"] == "secret-name" && r["title"] == "SECRET-TITLE"), "{q:?}");
    let (al, bl) = (a.home.path().join("logs"), b.home.path().join("logs"));
    let must = [al.join("service.log"), al.join("rapp-state.log"), bl.join("service.log")];
    // The state service logged the posts it took.
    let text = std::fs::read_to_string(&must[1]).unwrap();
    assert!(text.contains("\"event\":\"events\""), "{text}");
    let n = no_secrets(&[&al, &bl], &[], &must);
    assert!(n >= must.len(), "{n}");
}
