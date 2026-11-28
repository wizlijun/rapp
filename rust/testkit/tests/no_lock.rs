//! `NoLock`: one device turns another's 不锁屏 on or off.

mod common;
use common::sharing::*;
use common::*;

use rapp_net::quic::ALPN_PEER;
use serde_json::{json, Value};
use std::time::Duration;

async fn say(a: &TestService, key: &rapp_wire::Key, b: &Visitor, request: Value) -> Value {
    ask(a, key, b, request).await.0
}

/// The saved switch in A's config.
fn file_on(home: &std::path::Path) -> Option<bool> {
    let v: Value = serde_json::from_slice(&std::fs::read(home.join("service.json")).ok()?).ok()?;
    v["no_lock"].as_bool()
}

#[tokio::test]
async fn b_turns_a_no_lock_on_and_off() {
    let (a, key) = start_sharing(|_| {}).await;
    let b = visitor();
    let r = say(&a, &key, &b, json!({"op":"no_lock","on":true})).await;
    assert_eq!((&r["ok"], &r["no_lock"]), (&json!(true), &json!(true)), "{r}");
    let st = ipc_once(&a.svc, a.home.path(), json!({"cmd":"status"})).await;
    assert_eq!(st["no_lock"], true, "{st}");
    // The snapshot carries the keys where the switch is supported; sampling may be off here.
    let deadline = tokio::time::Instant::now() + WAIT;
    loop {
        let l = say(&a, &key, &b, json!({"op":"load"})).await;
        if l["ok"] == true {
            if cfg!(target_os = "macos") {
                assert_eq!(l["no_lock"], true, "{l}");
            }
            break;
        }
        if l["error"] == "unknown op" {
            break;
        }
        assert!(tokio::time::Instant::now() < deadline, "load never answered: {l}");
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    let set = wait_log(a.home.path(), "no_lock_set", |v| v["on"] == true).await;
    // Put down to B, not to this device.
    assert!(set["by"].is_string() && set["by"] != "local", "{set}");
    assert!(!set["peer"].as_str().unwrap_or_default().is_empty(), "{set}");
    let r = say(&a, &key, &b, json!({"op":"no_lock"})).await;
    assert_eq!(r["no_lock"], true, "{r}");
    let r = say(&a, &key, &b, json!({"op":"no_lock","on":false})).await;
    assert_eq!((&r["ok"], &r["no_lock"]), (&json!(true), &json!(false)), "{r}");
}

#[tokio::test]
async fn a_password_connection_cannot_set_no_lock() {
    let (a, _key) = start_sharing(|_| {}).await;
    let ep = b_endpoint();
    let conn = dial(&ep, a_addr(&a.svc), ALPN_PEER).await;
    let r = req(&conn, json!({"op":"auth","password":PASSWORD,"name":"old-b"})).await;
    assert_eq!(r["ok"], true, "{r}");
    let r = req(&conn, json!({"op":"no_lock","on":true})).await;
    assert_eq!(r, json!({"ok":false,"error":"not supported"}));
    let l = wait_log(a.home.path(), "no_lock_refused", |_| true).await;
    assert_eq!((&l["reason"], &l["on"]), (&json!("not supported"), &json!(true)), "{l}");
    assert_ne!(file_on(a.home.path()), Some(true));
}

fn hub_trusting(key: &rapp_wire::Key) -> tempfile::TempDir {
    let home = tempfile::tempdir().unwrap();
    rapp_net::config::write_json(&home.path().join("service.json"), &json!({"relay": "", "key": key.to_string()})).unwrap();
    home
}

#[tokio::test]
async fn hub_no_lock_says_the_reply() {
    let (a, key) = start_sharing(|_| {}).await;
    let h = hub_trusting(&key);
    let hosts = json!([{"id": a.id, "name": "a", "lan": [a_addr(&a.svc).to_string()]}]);
    std::fs::write(h.path().join("hosts.json"), hosts.to_string()).unwrap();
    let mut hub = Hub::start(h.path(), a.bins.path());
    let (_, r) = hub.call_learning_fp(json!({"cmd":"no_lock","id":a.id,"on":true}), &a.id).await;
    assert_eq!((&r["event"], &r["id"], &r["reply"]["ok"], &r["reply"]["no_lock"]), (&json!("no_lock"), &json!(a.id), &json!(true), &json!(true)), "{r}");
    hub.finish().await;
}
