//! Where the state service is: a device that sees one in a share list tells the devices it knows.
//! A knows B and C (`hosts.json`); B and C know nobody.

mod common;
use common::sharing::*;
use common::*;

use serde_json::{json, Value};
use std::time::Duration;

/// A service on a fresh home, trusting `key`, with local ports from `first` on and, when given,
/// `shares` as its `shares.json`.
async fn start_on(first: u16, key: &rapp_wire::Key, shares: Option<Value>) -> TestService {
    let prepare = |home: &std::path::Path| {
        if let Some(shares) = shares {
            share_file(home, shares);
        }
    };
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

/// The IDs in `s`'s IPC `state` sinks.
async fn sinks(s: &TestService) -> Vec<String> {
    let r = ipc(s, json!({"cmd":"state"})).await;
    assert_eq!(r["ok"], true, "{r}");
    r["sinks"].as_array().unwrap_or_else(|| panic!("{r}")).iter().map(|x| x["id"].as_str().unwrap_or("").to_string()).collect()
}

/// Waits until `s`'s sinks are `want` (as a set).
async fn wait_sinks(s: &TestService, want: &[&str]) {
    let mut want: Vec<String> = want.iter().map(|w| w.to_string()).collect();
    want.sort();
    let deadline = tokio::time::Instant::now() + WAIT;
    loop {
        let mut got = sinks(s).await;
        got.sort();
        if got == want {
            return;
        }
        assert!(tokio::time::Instant::now() < deadline, "sinks {got:?}, want {want:?}");
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
}

fn state_share(local: u16) -> Value {
    json!([{"port": 8102, "local": local, "kind": "state"}])
}

/// A knows B (sharing a state service) and C.
async fn three(first: u16) -> (TestService, TestService, TestService) {
    let key = rapp_wire::Key::new_local();
    let a = start_on(first, &key, None).await;
    let b = start_on(first + 10, &key, Some(state_share(first + 15))).await;
    let c = start_on(first + 20, &key, None).await;
    knows(&a, &[&b, &c]);
    (a, b, c)
}

#[tokio::test]
async fn a_sink_seen_in_shares_spreads() {
    let (a, b, c) = three(29200).await;
    assert!(sinks(&c).await.is_empty());
    let r = ipc(&a, json!({"cmd":"hosts"})).await;
    assert_eq!(r["ok"], true, "{r}");
    wait_sinks(&a, &[&b.id]).await;
    wait_sinks(&c, &[&b.id]).await;
    // B is not told about itself.
    assert!(sinks(&b).await.is_empty());
    let l = wait_log(a.home.path(), "state_sink", |v| v["id"] == b.id.as_str()).await;
    assert_eq!((l["port"].clone(), l["on"].clone(), l["from"].clone()), (json!(8102), json!(true), json!("shares")), "{l}");
    let l = wait_log(c.home.path(), "state_sink", |v| v["id"] == b.id.as_str()).await;
    assert_eq!(l["from"], "notice", "{l}");
    wait_log(a.home.path(), "state_sink_told", |v| v["sent"] == 1 && v["failed"] == 0).await;
    // Learned sinks are kept on disk.
    let saved: Value = serde_json::from_slice(&std::fs::read(c.home.path().join("state-sinks.json")).unwrap()).unwrap();
    assert_eq!(saved, json!([{"id": b.id, "port": 8102}]));
}

#[tokio::test]
async fn an_unshared_sink_is_forgotten_everywhere() {
    let (a, b, c) = three(29230).await;
    ipc(&a, json!({"cmd":"hosts"})).await;
    wait_sinks(&c, &[&b.id]).await;
    let r = ipc(&b, json!({"cmd":"unshare","port":8102})).await;
    assert_eq!(r["ok"], true, "{r}");
    ipc(&a, json!({"cmd":"hosts"})).await;
    wait_sinks(&a, &[]).await;
    wait_sinks(&c, &[]).await;
    let l = wait_log(c.home.path(), "state_sink", |v| v["on"] == false).await;
    assert_eq!((l["id"].as_str(), l["from"].as_str()), (Some(b.id.as_str()), Some("notice")), "{l}");
}

#[tokio::test]
async fn two_sinks_pick_the_same_one() {
    let key = rapp_wire::Key::new_local();
    let a = start_on(29260, &key, None).await;
    let b = start_on(29270, &key, Some(state_share(29275))).await;
    let c = start_on(29280, &key, Some(state_share(29285))).await;
    knows(&a, &[&b, &c]);
    ipc(&a, json!({"cmd":"hosts"})).await;
    wait_sinks(&a, &[&b.id, &c.id]).await;
    wait_sinks(&b, &[&c.id]).await;
    wait_sinks(&c, &[&b.id]).await;
    let r = ipc(&a, json!({"cmd":"state"})).await;
    let smaller = std::cmp::min(&b.id, &c.id);
    let chosen: Vec<&Value> = r["sinks"].as_array().unwrap().iter().filter(|s| s["chosen"] == true).collect();
    assert_eq!(chosen.len(), 1, "{r}");
    assert_eq!((chosen[0]["id"].as_str(), chosen[0]["local"].as_bool()), (Some(smaller.as_str()), Some(false)), "{r}");
    assert_eq!(chosen[0]["port"], 8102, "{r}");
}

#[tokio::test]
async fn no_sink_no_notice() {
    let key = rapp_wire::Key::new_local();
    let a = start_on(29100, &key, None).await;
    let b = start_on(29110, &key, Some(json!([{"port": 8102, "local": 29115}]))).await;
    let c = start_on(29120, &key, None).await;
    knows(&a, &[&b, &c]);
    let r = ipc(&a, json!({"cmd":"hosts"})).await;
    assert_eq!(r["hosts"][0]["shares"][0]["port"], 8102, "{r}");
    tokio::time::sleep(Duration::from_secs(3)).await;
    for s in [&b, &c] {
        assert!(!log_events(s.home.path()).iter().any(|v| v["ev"] == "state_sink"), "{:?}", log_events(s.home.path()));
    }
    let a_log = log_events(a.home.path());
    assert!(!a_log.iter().any(|v| v["ev"] == "state_sink_told" || v["ev"] == "state_sink"), "{a_log:?}");
    assert!(sinks(&a).await.is_empty());
    assert!(!c.home.path().join("state-sinks.json").exists());
}
