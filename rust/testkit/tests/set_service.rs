//! `SetService`: one device turns another's state service on or off.

mod common;
use common::sharing::*;
use common::*;

use rapp_net::quic::ALPN_PEER;
use serde_json::{json, Value};
use std::path::Path;
use std::time::Duration;

fn services(home: &Path, port: u16) {
    std::fs::write(home.join("services.json"), json!({"state": {"on": false, "port": port, "store": "memory"}}).to_string()).unwrap();
}

fn free_port() -> u16 {
    std::net::TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap().port()
}

async fn say(a: &TestService, key: &rapp_wire::Key, b: &Visitor, request: Value) -> Value {
    ask(a, key, b, request).await.0
}

async fn b_ipc(b: &TestService, cmd: Value) -> Value {
    ipc_once(&b.svc, b.home.path(), cmd).await
}

/// Polls A's own IPC `state` until its `on` is `want`.
async fn wait_state(a: &TestService, want: bool) -> Value {
    let deadline = tokio::time::Instant::now() + WAIT;
    loop {
        let r = ipc_once(&a.svc, a.home.path(), json!({"cmd":"state"})).await;
        if r["on"] == want {
            return r;
        }
        assert!(tokio::time::Instant::now() < deadline, "state never became {want}: {r}");
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
}

fn file_on(home: &Path) -> Option<bool> {
    let v: Value = serde_json::from_slice(&std::fs::read(home.join("services.json")).ok()?).ok()?;
    v["state"]["on"].as_bool()
}

async fn a_and_b(a_port: u16) -> (TestService, TestService, rapp_wire::Key) {
    let (a, key) = start_sharing(|h| services(h, a_port)).await;
    let (b, _) = start_sharing_ports(|_| {}, (29420, 10)).await;
    let r = b_ipc(&b, json!({"cmd":"set_relay","relay":"","key":key.to_string()})).await;
    assert_eq!(r["ok"], true, "{r}");
    let hosts = json!([{"id": a.id, "name": "a", "lan": [a_addr(&a.svc).to_string()]}]);
    std::fs::write(b.home.path().join("hosts.json"), hosts.to_string()).unwrap();
    (a, b, key)
}

#[tokio::test]
async fn b_turns_a_state_service_on_and_off() {
    let (a, b, _key) = a_and_b(free_port()).await;
    let r = b_ipc(&b, json!({"cmd":"state","to": a.id,"on":true})).await;
    assert_eq!((r["ok"].as_bool(), r["on"].as_bool()), (Some(true), Some(true)), "{r}");
    wait_state(&a, true).await;
    assert_eq!(file_on(a.home.path()), Some(true));
    let l = wait_log(a.home.path(), "service_set", |v| v["on"] == true).await;
    assert_eq!(l["name"], "state", "{l}");
    let ask = b_ipc(&b, json!({"cmd":"state","to": a.id})).await;
    assert_eq!(ask["on"], true, "{ask}");
    let r = b_ipc(&b, json!({"cmd":"state","to": a.id,"on":false})).await;
    assert_eq!(r["on"], false, "{r}");
    wait_state(&a, false).await;
    assert_eq!(file_on(a.home.path()), Some(false));
}

#[tokio::test]
async fn a_password_connection_cannot_set_a_service() {
    let (a, _key) = start_sharing(|h| services(h, free_port())).await;
    let ep = b_endpoint();
    let conn = dial(&ep, a_addr(&a.svc), ALPN_PEER).await;
    let r = req(&conn, json!({"op":"auth","password":PASSWORD,"name":"old-b"})).await;
    assert_eq!(r["ok"], true, "{r}");
    let r = req(&conn, json!({"op":"set_service","name":"state","on":true})).await;
    assert_eq!(r, json!({"ok":false,"error":"not supported"}));
    let l = wait_log(a.home.path(), "service_refused", |_| true).await;
    assert_eq!((&l["name"], &l["reason"]), (&json!("state"), &json!("not supported")), "{l}");
    assert_eq!(file_on(a.home.path()), Some(false));
}

#[tokio::test]
async fn an_unknown_service_is_named() {
    let (a, key) = start_sharing(|_| {}).await;
    let r = say(&a, &key, &visitor(), json!({"op":"set_service","name":"nope","on":true})).await;
    assert_eq!(r["error"], "unknown service", "{r}");
}
