//! Port sharing, global ports (task 2): the sharer listens on its share numbers and says them
//! (with the protocol) to its own IPC and to other devices.

mod common;
use common::sharing::*;
use common::*;

use serde_json::{json, Value};
use std::path::Path;
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;

async fn ipc(s: &TestService, cmd: Value) -> Value {
    ipc_once(&s.svc, s.home.path(), cmd).await
}

/// The own `shares` row of `port`.
async fn row(a: &TestService, port: u16) -> Value {
    let r = ipc(a, json!({"cmd":"shares"})).await;
    assert_eq!(r["ok"], true, "{r}");
    r["shares"].as_array().unwrap().iter().find(|s| s["port"] == port).cloned().unwrap_or(Value::Null)
}

fn saved(home: &Path) -> Value {
    serde_json::from_slice(&std::fs::read(home.join("shares.json")).unwrap()).unwrap()
}

/// Writes `data` to `127.0.0.1:<local>`, finishes writing, and reads to the end.
async fn through(local: u16, data: &[u8]) -> Vec<u8> {
    let mut c = TcpStream::connect(("127.0.0.1", local)).await.expect("the number accepts");
    c.write_all(data).await.unwrap();
    c.shutdown().await.unwrap();
    let mut got = Vec::new();
    tokio::time::timeout(WAIT, c.read_to_end(&mut got)).await.expect("ends in time").unwrap();
    got
}

async fn refuses(local: u16) {
    let deadline = tokio::time::Instant::now() + WAIT;
    while TcpStream::connect(("127.0.0.1", local)).await.is_ok() {
        assert!(tokio::time::Instant::now() < deadline, "{local} still accepts");
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
}

/// A sharer with `shares` in its table, numbering from `first` (ten numbers), once every share
/// that can has its number (the numbering of an old table runs just after start).
async fn numbered(shares: Value, first: u16) -> (TestService, rapp_wire::Key) {
    let count = shares.as_array().unwrap().len();
    let (a, key) = start_sharing_ports(|home| share_file(home, shares), (first, 10)).await;
    let deadline = tokio::time::Instant::now() + Duration::from_secs(6);
    loop {
        let r = ipc(&a, json!({"cmd":"shares"})).await;
        let n = r["shares"].as_array().unwrap().iter().filter(|s| s["local"].is_number()).count();
        if n == count {
            return (a, key);
        }
        assert!(tokio::time::Instant::now() < deadline, "never numbered: {r}");
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
}

#[tokio::test]
async fn a_share_gets_a_number_and_the_sharer_listens_on_it() {
    let (port, _echo) = echo().await;
    let (a, _) = numbered(json!([{"port": port}]), 29500).await;
    let r = row(&a, port).await;
    assert_eq!((&r["local"], &r["addr"]), (&json!(29500), &json!("http://localhost:29500")), "{r}");
    assert_eq!(through(29500, b"hi").await, b"hi");
    assert_eq!(saved(a.home.path())[0]["local"], 29500);
}

#[tokio::test]
async fn a_new_share_gets_the_next_number() {
    let (first, _e1) = echo().await;
    let (second, _e2) = echo().await;
    let (a, _) = numbered(json!([{"port": first}]), 29510).await;
    let r = ipc(&a, json!({"cmd":"share","ports":[second]})).await;
    assert_eq!(r["ok"], true, "{r}");
    let s = &r["shared"][0];
    assert_eq!(
        (&s["local"], &s["proto"], &s["proto_auto"], &s["addr"]),
        (&json!(29511), &json!("http"), &json!(true), &json!("http://localhost:29511")),
        "{r}"
    );
    assert_eq!(through(29511, b"x").await, b"x");
}

#[tokio::test]
async fn list_shares_and_shares_carry_the_number_and_protocol() {
    let (port, _echo) = echo().await;
    let (a, key) = numbered(json!([{"port": port}]), 29520).await;
    let b = visitor();
    let (r, ..) = ask(&a, &key, &b, json!({"op":"list_shares"})).await;
    assert_eq!((&r["shares"][0]["local"], &r["shares"][0]["proto"]), (&json!(29520), &json!("http")), "{r}");
    let (r, ..) = ask(&a, &key, &b, json!({"op":"shares"})).await;
    let s = &r["shares"][0];
    assert_eq!((&s["local"], &s["proto"], &s["proto_auto"]), (&json!(29520), &json!("http"), &json!(true)), "{r}");
}

#[tokio::test]
async fn a_proto_given_is_kept() {
    let (port, _echo) = echo().await;
    let (a, _) = numbered(json!([]), 29530).await;
    let r = ipc(&a, json!({"cmd":"share","ports":[port],"proto":"tcp"})).await;
    let s = &r["shared"][0];
    assert_eq!((&s["addr"], &s["proto_auto"]), (&json!("tcp://localhost:29530"), &json!(false)), "{r}");
    let r = ipc(&a, json!({"cmd":"share","ports":[port],"note":"n"})).await;
    assert_eq!(r["shared"][0]["proto"], "tcp", "{r}");
    let r = ipc(&a, json!({"cmd":"share","ports":[port],"proto":"ftp"})).await;
    assert_eq!(r, json!({"ok":false,"error":"bad proto"}));
}

#[tokio::test]
async fn a_share_number_another_program_has_on_the_sharer_stays() {
    let (port, _echo) = echo().await;
    let theirs = std::net::TcpListener::bind(("127.0.0.1", 29540)).unwrap();
    let (a, _) = numbered(json!([{"port": port, "local": 29540}]), 29540).await;
    let r = row(&a, port).await;
    assert_eq!((&r["taken"], &r["local"]), (&json!(true), &json!(29540)), "{r}");
    drop(theirs);
    let r = row(&a, port).await;
    assert!(r.get("taken").is_none(), "{r}");
    assert_eq!(through(29540, b"back").await, b"back");
}

#[tokio::test]
async fn unshare_closes_the_number() {
    let (port, _echo) = echo().await;
    let (a, _) = numbered(json!([{"port": port}]), 29545).await;
    assert_eq!(through(29545, b"x").await, b"x");
    let r = ipc(&a, json!({"cmd":"unshare","port":port})).await;
    assert_eq!(r["was"], true, "{r}");
    refuses(29545).await;
}

#[tokio::test]
async fn a_share_with_no_number_left_has_no_address() {
    let (port, _echo) = echo().await;
    let _theirs = std::net::TcpListener::bind(("127.0.0.1", 29550)).unwrap();
    let (a, _) = start_sharing_ports(|_| {}, (29550, 1)).await;
    let r = ipc(&a, json!({"cmd":"share","ports":[port]})).await;
    assert_eq!(r["ok"], true, "{r}");
    assert_eq!(r["shared"][0]["addr"], "", "{r}");
    assert!(r["shared"][0].get("local").is_none(), "{r}");
    let r = row(&a, port).await;
    assert_eq!(r["addr"], "", "{r}");
    assert!(r.get("local").is_none(), "{r}");
}

#[tokio::test]
async fn an_old_table_is_numbered_at_start() {
    let (port, _echo) = echo().await;
    let (a, _) = numbered(json!([{"port": port}]), 29560).await;
    // Done by a task after start, with no hosts.json to ask.
    let deadline = tokio::time::Instant::now() + Duration::from_secs(6);
    loop {
        let r = row(&a, port).await;
        if r["local"] == 29560 {
            break;
        }
        assert!(tokio::time::Instant::now() < deadline, "never numbered: {r}");
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    assert_eq!(through(29560, b"x").await, b"x");
}

#[tokio::test]
async fn an_old_table_avoids_the_numbers_of_devices_online_at_start() {
    let (theirs, _e1) = echo().await;
    let (mine, _e2) = echo().await;
    // B does not listen on its numbers (one machine), so A can tell only by asking B.
    let (b, key) = start_sharing_opts(|home| share_file(home, json!([{"port": theirs}])), (29570, 10), false, None).await;
    let deadline = tokio::time::Instant::now() + Duration::from_secs(6);
    while row(&b, theirs).await["local"] != 29570 {
        assert!(tokio::time::Instant::now() < deadline, "B never numbered");
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    let hosts = json!([{"id": b.id, "name": "b", "lan": [a_addr(&b.svc).to_string()]}]);
    let (a, _) = start_sharing_opts(
        |home| {
            share_file(home, json!([{"port": mine}]));
            std::fs::write(home.join("hosts.json"), hosts.to_string()).unwrap();
        },
        (29570, 10),
        true,
        Some(key),
    )
    .await;
    let deadline = tokio::time::Instant::now() + Duration::from_secs(6);
    loop {
        let r = row(&a, mine).await;
        if r["local"].is_number() {
            assert_eq!(r["local"], 29571, "{r}");
            break;
        }
        assert!(tokio::time::Instant::now() < deadline, "A never numbered: {r}");
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
}
