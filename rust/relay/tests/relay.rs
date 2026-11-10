//! rapp-relay against raw QUIC clients playing A and B (spec §2.2).

use quinn::Connection;
use rapp_net::crypto::{pw_hash, random_hex};
use rapp_net::line::{read_json, write_json};
use rapp_net::quic::{bi, client_endpoint, connect, ALPN_RELAY};
use rapp_relay::{Opts, Relay};
use serde_json::{json, Value};
use std::path::Path;
use std::time::Duration;
use tokio::sync::mpsc;

const KEY: &str = "relay-key";

fn start(db: &Path, ttl: Duration) -> Relay {
    Relay::start(Opts {
        listen: "127.0.0.1:0".parse().unwrap(),
        key: KEY.into(),
        db: db.to_path_buf(),
        token_ttl: ttl,
    })
    .unwrap()
}

async fn dial(relay: &Relay) -> Connection {
    dial_from(relay).await.1
}

/// Also returns the client's own address (what the relay sees as its public address).
async fn dial_from(relay: &Relay) -> (String, Connection) {
    let ep = client_endpoint("127.0.0.1:0".parse().unwrap()).unwrap();
    let conn = connect(&ep, relay.addr, ALPN_RELAY, Duration::from_secs(2)).await.unwrap();
    (ep.local_addr().unwrap().to_string(), conn)
}

async fn req(conn: &Connection, v: Value) -> Value {
    let mut s = bi(conn.open_bi().await.unwrap());
    write_json(&mut s, &v).await.unwrap();
    read_json(&mut s).await.unwrap()
}

fn register_msg(id: Option<&str>, secret: &str, password: &str) -> Value {
    let salt = random_hex(16);
    json!({"op":"register","key":KEY,"id":id,"secret":secret,"name":"host-a",
           "pw_salt":salt,"pw_hash":pw_hash(&salt, password),"lan":["192.168.1.5:21118","127.0.0.1:21118"]})
}

/// Plays A: answers `incoming` with ok (reporting it on `seen`), and for `relayed`
/// streams reads one line and answers `{"echo":line,"token":T}`.
fn serve_a(conn: Connection) -> mpsc::UnboundedReceiver<Value> {
    let (tx, rx) = mpsc::unbounded_channel();
    tokio::spawn(async move {
        while let Ok(pair) = conn.accept_bi().await {
            let tx = tx.clone();
            tokio::spawn(async move {
                let mut s = bi(pair);
                let first = read_json(&mut s).await.unwrap();
                let _ = tx.send(first.clone());
                if first["op"] == "incoming" {
                    write_json(&mut s, &json!({"ok":true})).await.unwrap();
                } else {
                    let next = read_json(&mut s).await.unwrap();
                    write_json(&mut s, &json!({"echo":next,"token":first["token"]})).await.unwrap();
                }
                let _ = s.writer_mut().finish();
            });
        }
    });
    rx
}

async fn online_a(relay: &Relay, password: &str) -> (Connection, String, mpsc::UnboundedReceiver<Value>) {
    let a = dial(relay).await;
    let r = req(&a, register_msg(None, &random_hex(32), password)).await;
    assert_eq!(r["ok"], true, "{r}");
    let id = r["id"].as_str().unwrap().to_string();
    let rx = serve_a(a.clone());
    (a, id, rx)
}

fn connect_msg(id: &str, password: &str) -> Value {
    json!({"op":"connect","key":KEY,"id":id,"password":password})
}

#[tokio::test]
async fn register_assigns_id_and_keeps_it_for_same_secret() {
    let dir = tempfile::tempdir().unwrap();
    let relay = start(&dir.path().join("relay.json"), Duration::from_secs(60));
    let a = dial(&relay).await;
    let secret = random_hex(32);
    let r = req(&a, register_msg(None, &secret, "pw")).await;
    assert_eq!(r["ok"], true, "{r}");
    let id = r["id"].as_str().unwrap().to_string();
    assert_eq!(id.len(), 9);
    assert!(id.bytes().all(|c| c.is_ascii_digit()) && !id.starts_with('0'));

    let again = req(&a, register_msg(Some(&id), &secret, "pw2")).await;
    assert_eq!(again, json!({"ok":true,"id":id}));

    let other = dial(&relay).await;
    let taken = req(&other, register_msg(Some(&id), &random_hex(32), "pw")).await;
    assert_eq!(taken, json!({"ok":false,"error":"id taken"}));
}

#[tokio::test]
async fn reregister_from_new_connection_replaces_old_one() {
    let dir = tempfile::tempdir().unwrap();
    let relay = start(&dir.path().join("relay.json"), Duration::from_secs(60));
    let secret = random_hex(32);
    let a1 = dial(&relay).await;
    let id = req(&a1, register_msg(None, &secret, "pw")).await["id"].as_str().unwrap().to_string();
    let a2 = dial(&relay).await;
    assert_eq!(req(&a2, register_msg(Some(&id), &secret, "pw")).await["ok"], true);
    tokio::time::timeout(Duration::from_secs(2), a1.closed()).await.expect("old connection closed");
    let _seen = serve_a(a2.clone());
    let b = dial(&relay).await;
    assert_eq!(req(&b, connect_msg(&id, "pw")).await["ok"], true);
}

#[tokio::test]
async fn db_survives_restart() {
    let dir = tempfile::tempdir().unwrap();
    let db = dir.path().join("relay.json");
    let secret = random_hex(32);
    let id = {
        let relay = start(&db, Duration::from_secs(60));
        let a = dial(&relay).await;
        req(&a, register_msg(None, &secret, "pw")).await["id"].as_str().unwrap().to_string()
    };
    let saved: Value = serde_json::from_slice(&std::fs::read(&db).unwrap()).unwrap();
    assert_eq!(saved[&id]["name"], "host-a");
    let relay = start(&db, Duration::from_secs(60));
    let a = dial(&relay).await;
    let taken = req(&a, register_msg(Some(&id), &random_hex(32), "pw")).await;
    assert_eq!(taken["error"], "id taken");
    assert_eq!(req(&a, register_msg(Some(&id), &secret, "pw")).await["id"], id.as_str());
}

#[tokio::test]
async fn bad_relay_key_on_every_op() {
    let dir = tempfile::tempdir().unwrap();
    let relay = start(&dir.path().join("relay.json"), Duration::from_secs(60));
    let c = dial(&relay).await;
    let mut reg = register_msg(None, &random_hex(32), "pw");
    reg["key"] = json!("nope");
    let bad = json!({"ok":false,"error":"bad relay key"});
    assert_eq!(req(&c, reg).await, bad);
    assert_eq!(req(&c, json!({"op":"connect","key":"nope","id":"123456789","password":"x"})).await, bad);
    assert_eq!(req(&c, json!({"op":"relay","key":"nope","token":"t"})).await, bad);
}

#[tokio::test]
async fn connect_returns_token_and_notifies_a() {
    let dir = tempfile::tempdir().unwrap();
    let relay = start(&dir.path().join("relay.json"), Duration::from_secs(60));
    let (a_addr, a) = dial_from(&relay).await;
    let id = req(&a, register_msg(None, &random_hex(32), "secret-pw")).await["id"].as_str().unwrap().to_string();
    let mut seen = serve_a(a);
    let (b_addr, b) = dial_from(&relay).await;
    let r = req(&b, connect_msg(&id, "secret-pw")).await;
    assert_eq!(r["ok"], true, "{r}");
    let token = r["token"].as_str().unwrap();
    assert_eq!(token.len(), 32);
    assert_eq!(r["name"], "host-a");
    assert_eq!(r["lan"], json!(["192.168.1.5:21118", "127.0.0.1:21118"]));
    assert_eq!(r["public"], a_addr.as_str());
    let incoming = seen.recv().await.unwrap();
    assert_eq!(incoming["op"], "incoming");
    assert_eq!(incoming["token"], token);
    assert_eq!(incoming["peer"], b_addr.as_str());
}

#[tokio::test]
async fn connect_errors() {
    let dir = tempfile::tempdir().unwrap();
    let relay = start(&dir.path().join("relay.json"), Duration::from_secs(60));
    let b = dial(&relay).await;
    assert_eq!(req(&b, connect_msg("123456789", "x")).await["error"], "unknown id");

    let (a, id, _seen) = online_a(&relay, "pw").await;
    assert_eq!(req(&b, connect_msg(&id, "wrong")).await["error"], "bad password");
    a.close(0u32.into(), b"bye");
    tokio::time::sleep(Duration::from_millis(200)).await;
    assert_eq!(req(&b, connect_msg(&id, "pw")).await["error"], "offline");
}

#[tokio::test]
async fn offline_when_a_does_not_answer_incoming() {
    let dir = tempfile::tempdir().unwrap();
    let relay = start(&dir.path().join("relay.json"), Duration::from_secs(60));
    let a = dial(&relay).await;
    let id = req(&a, register_msg(None, &random_hex(32), "pw")).await["id"].as_str().unwrap().to_string();
    // A never accepts streams.
    let b = dial(&relay).await;
    let t0 = std::time::Instant::now();
    assert_eq!(req(&b, connect_msg(&id, "pw")).await["error"], "offline");
    assert!(t0.elapsed() >= Duration::from_millis(1900));
}

#[tokio::test]
async fn rate_limit_by_id() {
    let dir = tempfile::tempdir().unwrap();
    let relay = start(&dir.path().join("relay.json"), Duration::from_secs(60));
    let (_a, id, _seen) = online_a(&relay, "pw").await;
    let b = dial(&relay).await;
    for _ in 0..5 {
        assert_eq!(req(&b, connect_msg(&id, "wrong")).await["error"], "bad password");
    }
    // Locked even with the right password.
    assert_eq!(req(&b, connect_msg(&id, "pw")).await["error"], "locked, retry in 1s");
    tokio::time::sleep(Duration::from_millis(1100)).await;
    // 6th failure: lock doubles to 2 s.
    assert_eq!(req(&b, connect_msg(&id, "wrong")).await["error"], "bad password");
    assert_eq!(req(&b, connect_msg(&id, "pw")).await["error"], "locked, retry in 2s");
    tokio::time::sleep(Duration::from_millis(2100)).await;
    assert_eq!(req(&b, connect_msg(&id, "pw")).await["ok"], true);
    // Success reset the counter.
    assert_eq!(req(&b, connect_msg(&id, "wrong")).await["error"], "bad password");
    assert_eq!(req(&b, connect_msg(&id, "pw")).await["ok"], true);
}

#[tokio::test]
async fn rate_limit_by_source_ip() {
    let dir = tempfile::tempdir().unwrap();
    let relay = start(&dir.path().join("relay.json"), Duration::from_secs(60));
    let (_a, id, _seen) = online_a(&relay, "pw").await;
    let b = dial(&relay).await;
    for n in 0..5 {
        let unknown = format!("10000000{n}");
        assert_eq!(req(&b, connect_msg(&unknown, "x")).await["error"], "unknown id");
    }
    let r = req(&b, connect_msg(&id, "pw")).await;
    assert_eq!(r["error"], "locked, retry in 1s");
}

#[tokio::test]
async fn relay_splices_b_to_a() {
    let dir = tempfile::tempdir().unwrap();
    let relay = start(&dir.path().join("relay.json"), Duration::from_secs(60));
    let (_a, id, mut seen) = online_a(&relay, "pw").await;
    let b = dial(&relay).await;
    let token = req(&b, connect_msg(&id, "pw")).await["token"].as_str().unwrap().to_string();
    let _incoming = seen.recv().await.unwrap();

    let mut s = bi(b.open_bi().await.unwrap());
    // B may pipeline its request right after the relay line.
    write_json(&mut s, &json!({"op":"relay","key":KEY,"token":token})).await.unwrap();
    write_json(&mut s, &json!({"op":"list_apps"})).await.unwrap();
    let r = read_json(&mut s).await.unwrap();
    assert_eq!(r, json!({"echo":{"op":"list_apps"},"token":token}));
    assert_eq!(seen.recv().await.unwrap(), json!({"op":"relayed","token":token}));
}

#[tokio::test]
async fn relay_with_unknown_or_expired_token_is_bad_token() {
    let dir = tempfile::tempdir().unwrap();
    let relay = start(&dir.path().join("relay.json"), Duration::from_millis(300));
    let (_a, id, _seen) = online_a(&relay, "pw").await;
    let b = dial(&relay).await;
    let bad = json!({"ok":false,"error":"bad token"});
    assert_eq!(req(&b, json!({"op":"relay","key":KEY,"token":"0".repeat(32)})).await, bad);

    let token = req(&b, connect_msg(&id, "pw")).await["token"].as_str().unwrap().to_string();
    tokio::time::sleep(Duration::from_millis(400)).await;
    assert_eq!(req(&b, json!({"op":"relay","key":KEY,"token":token})).await, bad);
}

#[tokio::test]
async fn unknown_op_and_garbage() {
    let dir = tempfile::tempdir().unwrap();
    let relay = start(&dir.path().join("relay.json"), Duration::from_secs(60));
    let c = dial(&relay).await;
    assert_eq!(req(&c, json!({"op":"list_apps"})).await["ok"], false);
    assert_eq!(req(&c, json!({"hello":1})).await["ok"], false);
}
