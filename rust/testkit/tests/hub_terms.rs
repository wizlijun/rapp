//! rapp-hub's terminal sessions (spec §6): the commands, embedded opens only, and one watch stream per online
//! device, against a real service with the fake `rapp-term`.

mod common;

use common::*;
use serde_json::{json, Value};
use std::path::Path;
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};

/// `id@ip` for A: the only way to add a host.
fn at(a: &TestService) -> String {
    format!("{}@{}", a.id, a_addr(&a.svc))
}

/// Adds A's host to a fresh hub; returns the hub.
async fn hub_with_host(a: &TestService, home: &Path) -> Hub {
    let mut hub = Hub::start(home, a.bins.path());
    let r = hub.call(json!({"cmd":"add_host","id":at(a),"password":PASSWORD,"req":1})).await;
    assert_eq!(r, json!({"event":"host_added","id":a.id,"name":"test-a","req":1}));
    hub
}

/// A hub probing every 200 ms, with A's host added.
async fn presence_hub(a: &TestService, home: &Path) -> Hub {
    let mut hub = Hub::start_with_presence(home, a.bins.path(), Duration::from_millis(200));
    hub.send(json!({"cmd":"add_host","id":at(a),"password":PASSWORD,"req":1})).await;
    assert_eq!(reply(&mut hub, 1).await, json!({"event":"host_added","id":a.id,"name":"test-a","req":1}));
    hub
}

/// The next event `pred` accepts, within `WAIT` (presence events keep coming meanwhile).
async fn next_where(hub: &mut Hub, what: &str, pred: impl Fn(&Value) -> bool) -> Value {
    let deadline = tokio::time::Instant::now() + WAIT;
    loop {
        let r = tokio::time::timeout_at(deadline, hub.next()).await.unwrap_or_else(|_| panic!("no {what} in time"));
        if pred(&r) {
            return r;
        }
    }
}

/// The event answering `req`, skipping the ones pushed meanwhile.
async fn reply(hub: &mut Hub, req: u64) -> Value {
    next_where(hub, "reply", |r| r["req"] == req).await
}

/// The next `terms` event a watch pushed (no `req`).
async fn pushed_terms(hub: &mut Hub) -> Value {
    next_where(hub, "pushed terms event", |r| {
        assert_ne!(r["event"], "error", "{r}");
        r["event"] == "terms" && r.get("req").is_none()
    })
    .await
}

/// Every event within `d`.
async fn events_for(hub: &mut Hub, d: Duration) -> Vec<Value> {
    let deadline = tokio::time::Instant::now() + d;
    let mut seen = Vec::new();
    while let Ok(r) = tokio::time::timeout_at(deadline, hub.next()).await {
        seen.push(r);
    }
    seen
}

fn term_log(bins: &Path) -> String {
    std::fs::read_to_string(bins.join("term.log")).unwrap_or_default()
}

#[tokio::test]
async fn terms_lists_a_hosts_terminal_sessions() {
    let a = service().await;
    let home = tempfile::tempdir().unwrap();
    let mut hub = hub_with_host(&a, home.path()).await;
    let r = hub.call(json!({"cmd":"terms","id":a.id,"req":2})).await;
    assert_eq!(
        (&r["event"], &r["id"], &r["path"], &r["req"]),
        (&json!("terms"), &json!(a.id), &json!("lan"), &json!(2))
    );
    assert_eq!(r["terms"][0]["id"], "term:tmux:work", "{r}");
    assert_eq!(r["hosts"][0], json!({"host":null}), "{r}");
    hub.finish().await;
}

#[tokio::test]
async fn terms_on_a_host_with_terminals_off_says_off() {
    let a = service().await;
    std::fs::write(a.home.path().join("term.json"), r#"{"allow":false}"#).unwrap();
    let home = tempfile::tempdir().unwrap();
    let mut hub = hub_with_host(&a, home.path()).await;
    let r = hub.call(json!({"cmd":"terms","id":a.id,"req":2})).await;
    assert_eq!(r, json!({"event":"terms","id":a.id,"off":true,"req":2}));
    hub.finish().await;
}

#[tokio::test]
async fn targets_and_new_sessions_go_through_the_hub() {
    let a = service().await;
    let home = tempfile::tempdir().unwrap();
    let mut hub = hub_with_host(&a, home.path()).await;
    let r = hub.call(json!({"cmd":"add_term_target","id":a.id,"name":"gpu1","target":"me@gpu1","req":3})).await;
    let targets = json!([{"name":"gpu1","target":"me@gpu1"}]);
    assert_eq!(r, json!({"event":"term_targets","id":a.id,"targets":targets,"req":3}));
    let new = json!({"cmd":"new_term","id":a.id,"name":"n1","command":["sh"],"cols":80,"rows":24,"req":4});
    assert_eq!(hub.call(new).await, json!({"event":"term_created","id":a.id,"term":"term:tmux:n1","req":4}));
    let r = hub.call(json!({"cmd":"remove_term_target","id":a.id,"name":"gpu1","req":5})).await;
    assert_eq!(r, json!({"event":"term_targets","id":a.id,"targets":[],"req":5}));
    // A refusal comes back as an error.
    let r = hub.call(json!({"cmd":"remove_term_target","id":a.id,"name":"gpu1","req":6})).await;
    assert_eq!(r, json!({"event":"error","error":"unknown target","req":6}));
    hub.finish().await;
}

#[tokio::test]
async fn a_terminal_session_opens_embedded_only() {
    let a = service().await;
    let home = tempfile::tempdir().unwrap();
    let mut hub = hub_with_host(&a, home.path()).await;
    let r = hub.call(json!({"cmd":"open","id":a.id,"app":"term:tmux:work","req":"o"})).await;
    assert_eq!(r, json!({"event":"error","error":"terminal sessions open embedded only","req":"o"}));

    let r = hub.call(json!({"cmd":"open","id":a.id,"app":"term:tmux:work","embed":true,"req":"e"})).await;
    assert_eq!((&r["event"], &r["app"], &r["req"]), (&json!("opened"), &json!("term:tmux:work"), &json!("e")), "{r}");
    let (sid, port, token) = (r["sid"].clone(), r["port"].as_u64().unwrap(), r["token"].as_str().unwrap());
    let mut tcp = tokio::net::TcpStream::connect(("127.0.0.1", port as u16)).await.unwrap();
    tcp.write_all(format!("{token}\nx\n").as_bytes()).await.unwrap();
    let mut lines = BufReader::new(&mut tcp).lines();
    let hello = tokio::time::timeout(WAIT, lines.next_line()).await.unwrap().unwrap().unwrap();
    assert_eq!(
        serde_json::from_str::<Value>(&hello).unwrap(),
        json!({"t":"hello","fake":true,"term":"term:tmux:work"})
    );
    let echo = tokio::time::timeout(WAIT, lines.next_line()).await.unwrap().unwrap();
    assert_eq!(echo.as_deref(), Some("x"));
    drop(lines);
    drop(tcp);
    assert_eq!(hub.next().await, json!({"event":"closed","sid":sid,"reason":"connection closed"}));
    assert!(!a.bins.path().join("client.port").exists(), "no rapp-client was started");
    hub.finish().await;
}

#[tokio::test]
async fn an_online_host_gets_one_watch() {
    let a = service().await;
    let home = tempfile::tempdir().unwrap();
    let mut hub = presence_hub(&a, home.path()).await;
    let first = pushed_terms(&mut hub).await;
    assert_eq!((&first["id"], &first["terms"][0]["id"]), (&json!(a.id), &json!("term:tmux:work")), "{first}");
    assert_eq!(first["hosts"], json!([{"host":null}]), "{first}");

    hub.send(json!({"cmd":"add_term_target","id":a.id,"name":"gpu1","target":"me@gpu1","req":2})).await;
    assert_eq!(reply(&mut hub, 2).await["event"], "term_targets");
    loop {
        let r = pushed_terms(&mut hub).await;
        if r["terms"].as_array().unwrap().iter().any(|t| t["id"] == "term:tmux@gpu1:main") {
            break;
        }
    }

    for _ in 0..5 {
        next_where(&mut hub, "presence round", |r| {
            assert_ne!(r["event"], "error", "{r}");
            *r == json!({"event":"presence","id":a.id,"online":true})
        })
        .await;
    }
    let watches = log_events(a.home.path()).into_iter().filter(|v| v["ev"] == "request" && v["op"] == "watch_terms");
    assert_eq!(watches.count(), 1, "{:?}", log_events(a.home.path()));
    hub.finish().await;
}

#[tokio::test]
async fn removing_a_host_stops_its_watch() {
    let a = service().await;
    let home = tempfile::tempdir().unwrap();
    let mut hub = presence_hub(&a, home.path()).await;
    pushed_terms(&mut hub).await;
    hub.send(json!({"cmd":"remove_host","id":a.id,"req":2})).await;
    assert_eq!(reply(&mut hub, 2).await, json!({"event":"hosts","hosts":[],"req":2}));

    let deadline = tokio::time::Instant::now() + Duration::from_secs(2);
    while !term_log(a.bins.path()).lines().any(|l| l == "watch closed") {
        assert!(tokio::time::Instant::now() < deadline, "the watch did not close: {}", term_log(a.bins.path()));
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    // Three probe rounds.
    let seen = events_for(&mut hub, Duration::from_millis(700)).await;
    assert!(!seen.iter().any(|r| r["event"] == "terms" && r.get("req").is_none()), "{seen:?}");
    hub.finish().await;
}

#[tokio::test]
async fn a_watch_says_off_when_terminals_turn_off() {
    let a = service().await;
    let home = tempfile::tempdir().unwrap();
    let mut hub = presence_hub(&a, home.path()).await;
    pushed_terms(&mut hub).await;
    std::fs::write(a.home.path().join("term.json"), r#"{"allow":false}"#).unwrap();
    assert_eq!(pushed_terms(&mut hub).await, json!({"event":"terms","id":a.id,"off":true}));
    hub.finish().await;
}
