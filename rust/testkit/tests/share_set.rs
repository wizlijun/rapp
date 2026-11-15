//! Port sharing 1.5: another device lists and sets this device's share table over `rapp/2`.

mod common;
use common::sharing::*;
use common::*;

use rapp_net::quic::ALPN_PEER;
use serde_json::{json, Value};
use std::path::Path;
use std::time::Duration;
use tokio::io::AsyncReadExt;

const WARN: &str = "分享这个端口，等于把这台机器能到的网络也交出去";

fn fp_hex(b: u8) -> String {
    rapp_wire::Fp([b; 32]).to_string()
}

fn saved(home: &Path) -> Value {
    serde_json::from_slice(&std::fs::read(home.join("shares.json")).unwrap()).unwrap()
}

fn saved_port(home: &Path, port: u16) -> Value {
    saved(home).as_array().unwrap().iter().find(|s| s["port"] == port).cloned().unwrap_or(Value::Null)
}

/// `ask`, keeping only the reply.
async fn say(a: &TestService, key: &rapp_wire::Key, b: &Visitor, request: Value) -> Value {
    ask(a, key, b, request).await.0
}

#[tokio::test]
async fn shares_is_the_whole_table_and_known_is_paired_json() {
    let (p, q) = (5001u16, 5002u16);
    let b = visitor();
    let x = fp_hex(7);
    let (a, key) = sharing(json!([{"port": p, "allow": [x]}, {"port": q}])).await;
    let r = say(&a, &key, &b, json!({"op":"shares"})).await;
    assert_eq!(r["ok"], true, "{r}");
    let shares = r["shares"].as_array().unwrap();
    assert_eq!(shares.len(), 2, "{r}");
    assert_eq!(shares[0], json!({"port": p, "note": "", "allow": [{"fp": x, "name": ""}], "listening": false}));
    assert_eq!(shares[1]["port"], q);
    assert_eq!(shares[1]["allow"], json!([]));
    assert!(r["known"].as_array().unwrap().contains(&json!({"fp": b.id.fp.to_string(), "name": "test-b"})), "{r}");
    let r = say(&a, &key, &b, json!({"op":"list_shares"})).await;
    assert_eq!(r, json!({"ok":true,"shares":[{"port": q}]}));
}

#[tokio::test]
async fn shares_says_what_is_listening() {
    let (port, _echo) = echo().await;
    let (a, key) = sharing_ports(&[port]).await;
    let r = say(&a, &key, &visitor(), json!({"op":"shares"})).await;
    assert_eq!(r["shares"][0]["listening"], true, "{r}");
}

#[tokio::test]
async fn a_remote_share_is_saved_and_says_who() {
    let (a, key) = start_sharing(|_| {}).await;
    let b = visitor();
    let r = say(&a, &key, &b, json!({"op":"share","ports":[5001],"note":"jupyter"})).await;
    assert_eq!(r, json!({"ok":true,"shared":[{"port":5001}]}));
    assert_eq!(saved_port(a.home.path(), 5001), json!({"port":5001,"note":"jupyter"}));
    let short = b.id.fp.short();
    let l = wait_log(a.home.path(), "share", |v| v["port"] == 5001).await;
    assert_eq!((&l["by"], &l["name"]), (&json!(short), &json!("test-b")), "{l}");
    let r = say(&a, &key, &b, json!({"op":"share","ports":[22]})).await;
    assert_eq!(r["shared"][0]["warn"], WARN, "{r}");
}

#[tokio::test]
async fn sharing_again_without_allow_keeps_it() {
    let x = fp_hex(7);
    let (a, key) = sharing(json!([{"port": 5001, "allow": [x]}])).await;
    let b = visitor();
    let r = say(&a, &key, &b, json!({"op":"share","ports":[5001],"note":"n"})).await;
    assert_eq!(r["ok"], true, "{r}");
    assert_eq!(saved_port(a.home.path(), 5001), json!({"port":5001,"note":"n","allow":[x]}));
    let r = say(&a, &key, &b, json!({"op":"share","ports":[5001],"allow":[]})).await;
    assert_eq!(r["ok"], true, "{r}");
    assert_eq!(saved_port(a.home.path(), 5001), json!({"port":5001,"note":"n"}));
}

#[tokio::test]
async fn a_remote_share_leaves_raw_alone() {
    let (a, key) = sharing(json!([{"port": 5001, "raw": true}])).await;
    let b = visitor();
    say(&a, &key, &b, json!({"op":"share","ports":[5001],"note":"n"})).await;
    assert_eq!(saved_port(a.home.path(), 5001), json!({"port":5001,"note":"n","raw":true}));
    say(&a, &key, &b, json!({"op":"share","ports":[5001],"raw":false})).await;
    assert_eq!(saved_port(a.home.path(), 5001)["raw"], true);
}

#[tokio::test]
async fn a_remote_unshare_cuts_the_forward() {
    let (port, _echo) = echo().await;
    let (a, key) = sharing_ports(&[port]).await;
    let (b, c) = (visitor(), visitor());
    let (r, mut s, _conn) = forward(&a, &key, &c, port).await;
    assert_eq!(r, json!({"ok":true}));
    let r = say(&a, &key, &b, json!({"op":"unshare","port":port})).await;
    assert_eq!(r, json!({"ok":true,"was":true}));
    let mut buf = [0u8; 8];
    let n = tokio::time::timeout(Duration::from_secs(2), s.read(&mut buf)).await.expect("ends within 2 s");
    assert!(matches!(n, Ok(0) | Err(_)), "{n:?}");
    let (r, _, _conn2) = forward(&a, &key, &c, port).await;
    assert_eq!(r, json!({"ok":false,"error":"not shared"}));
    let l = wait_log(a.home.path(), "unshare", |v| v["port"] == port).await;
    assert_eq!(l["by"], b.id.fp.short(), "{l}");
    let r = say(&a, &key, &b, json!({"op":"unshare","port":port})).await;
    assert_eq!(r, json!({"ok":true,"was":false}));
}

#[tokio::test]
async fn narrowing_allow_cuts_the_one_left_out() {
    let (port, _echo) = echo().await;
    let (a, key) = sharing_ports(&[port]).await;
    let (b, c) = (visitor(), visitor());
    let (r, mut s, _conn) = forward(&a, &key, &c, port).await;
    assert_eq!(r, json!({"ok":true}));
    let r = say(&a, &key, &b, json!({"op":"share","ports":[port],"allow":[b.id.fp.to_string()]})).await;
    assert_eq!(r["ok"], true, "{r}");
    let mut buf = [0u8; 8];
    let n = tokio::time::timeout(Duration::from_secs(2), s.read(&mut buf)).await.expect("ends within 2 s");
    assert!(matches!(n, Ok(0) | Err(_)), "{n:?}");
    let (r, _, _conn2) = forward(&a, &key, &c, port).await;
    assert_eq!(r, json!({"ok":false,"error":"not allowed"}));
}

#[tokio::test]
async fn the_password_connection_cannot_set() {
    let (a, _key) = sharing(json!([{"port": 5001}])).await;
    let before = std::fs::read(a.home.path().join("shares.json")).unwrap();
    let ep = b_endpoint();
    let conn = dial(&ep, a_addr(&a.svc), ALPN_PEER).await;
    let r = req(&conn, json!({"op":"auth","password":PASSWORD,"name":"old-b"})).await;
    assert_eq!(r["ok"], true, "{r}");
    let nope = json!({"ok":false,"error":"not supported"});
    assert_eq!(req(&conn, json!({"op":"shares"})).await, nope);
    assert_eq!(req(&conn, json!({"op":"share","ports":[5002]})).await, nope);
    assert_eq!(req(&conn, json!({"op":"unshare","port":5001})).await, nope);
    assert_eq!(std::fs::read(a.home.path().join("shares.json")).unwrap(), before);
    for op in ["shares", "share", "unshare"] {
        let l = wait_log(a.home.path(), "share_refused", |v| v["op"] == op).await;
        assert_eq!(l["reason"], "not supported", "{l}");
    }
}

#[tokio::test]
async fn the_65th_port_is_limit_and_nothing_changes() {
    let table: Vec<Value> = (6001..6065).map(|p| json!({"port": p})).collect();
    let (a, key) = sharing(Value::Array(table)).await;
    let b = visitor();
    let file = a.home.path().join("shares.json");
    let before = std::fs::read(&file).unwrap();
    let r = say(&a, &key, &b, json!({"op":"share","ports":[7000]})).await;
    assert_eq!(r, json!({"ok":false,"error":"limit"}));
    assert_eq!(std::fs::read(&file).unwrap(), before);
    let r = say(&a, &key, &b, json!({"op":"share","ports":[6001,7000],"note":"x"})).await;
    assert_eq!(r, json!({"ok":false,"error":"limit"}));
    assert_eq!(std::fs::read(&file).unwrap(), before);
    assert_eq!(saved_port(a.home.path(), 6001), json!({"port":6001}));
}

#[tokio::test]
async fn bad_values() {
    let (a, key) = start_sharing(|_| {}).await;
    let b = visitor();
    let bad_port = json!({"ok":false,"error":"bad port"});
    for ports in [json!([0]), json!([70000]), json!(["x"]), json!([]), Value::Null] {
        let r = say(&a, &key, &b, json!({"op":"share","ports":ports})).await;
        assert_eq!(r, bad_port, "ports {ports}");
    }
    assert_eq!(say(&a, &key, &b, json!({"op":"share"})).await, bad_port);
    assert_eq!(say(&a, &key, &b, json!({"op":"unshare","port":0})).await, bad_port);
    assert_eq!(say(&a, &key, &b, json!({"op":"unshare"})).await, bad_port);
    let bad_allow = json!({"ok":false,"error":"bad allow"});
    // A name, a short prefix, a non-hex string of 64 characters, a number, a string.
    for allow in [json!(["mini"]), json!(["abababab"]), json!(["z".repeat(64)]), json!([7]), json!("x")] {
        let r = say(&a, &key, &b, json!({"op":"share","ports":[5001],"allow":allow})).await;
        assert_eq!(r, bad_allow, "allow {allow}");
        // The same A still answers on a new stream.
        assert_eq!(say(&a, &key, &b, json!({"op":"ping"})).await["ok"], true);
    }
    assert!(!a.home.path().join("shares.json").exists());
    let r = say(&a, &key, &b, json!({"op":"share","ports":[5001],"allow":[fp_hex(9)]})).await;
    assert_eq!(r["ok"], true, "{r}");
    assert_eq!(saved_port(a.home.path(), 5001)["allow"], json!([fp_hex(9)]));
}

/// Services A and B that trust each other (the same key); B's `hosts.json` has A's LAN address.
async fn a_and_b() -> (TestService, TestService, String) {
    let (a, key) = start_sharing(|_| {}).await;
    let (b, _) = start_sharing(|_| {}).await;
    let r = ipc_once(&b.svc, b.home.path(), json!({"cmd":"set_relay","relay":"","key":key.to_string()})).await;
    assert_eq!(r["ok"], true, "{r}");
    let hosts = json!([{"id": a.id, "name": "a", "lan": [a_addr(&a.svc).to_string()]}]);
    std::fs::write(b.home.path().join("hosts.json"), hosts.to_string()).unwrap();
    let me = ipc_once(&b.svc, b.home.path(), json!({"cmd":"status"})).await["fp"].as_str().unwrap().to_string();
    (a, b, me)
}

async fn b_ipc(b: &TestService, cmd: Value) -> Value {
    ipc_once(&b.svc, b.home.path(), cmd).await
}

#[tokio::test]
async fn b_lists_and_sets_a_through_its_own_ipc() {
    let (a, b, me) = a_and_b().await;
    let p = 5101u16;
    let r = b_ipc(&b, json!({"cmd":"share","to":a.id,"ports":[p],"note":"n"})).await;
    assert_eq!(r, json!({"ok":true,"shared":[{"port":p}]}));
    assert_eq!(saved_port(a.home.path(), p)["port"], p);

    let r = b_ipc(&b, json!({"cmd":"shares","to":a.id})).await;
    assert_eq!(r["ok"], true, "{r}");
    assert_eq!((r["id"].as_str(), r["me"].as_str()), (Some(a.id.as_str()), Some(me.as_str())), "{r}");
    let row = &r["shares"][0];
    let url = format!("http://{}.rapp:{p}", a.id);
    assert_eq!((&row["url"], &row["addr"], &row["web"], &row["mine"], &row["note"]), (&json!(url), &json!(url), &json!(true), &json!(true), &json!("n")), "{r}");
    assert_eq!(r["known"][0], json!({"fp": me, "name": "本机"}), "{r}");

    let r = b_ipc(&b, json!({"cmd":"share","to":a.id,"ports":[22]})).await;
    assert_eq!(r["shared"][0]["warn"], WARN, "{r}");
    let r = b_ipc(&b, json!({"cmd":"shares","to":a.id})).await;
    let ssh = r["shares"].as_array().unwrap().iter().find(|s| s["port"] == 22).unwrap();
    assert_eq!((&ssh["addr"], &ssh["web"]), (&json!(format!("ssh {}.rapp", a.id)), &json!(false)), "{r}");

    let x = fp_hex(9);
    let r = b_ipc(&b, json!({"cmd":"share","to":a.id,"ports":[p],"allow":[x]})).await;
    assert_eq!(r["ok"], true, "{r}");
    let r = b_ipc(&b, json!({"cmd":"shares","to":a.id})).await;
    let row = r["shares"].as_array().unwrap().iter().find(|s| s["port"] == p).unwrap();
    assert_eq!(row["mine"], false, "{r}");
    assert_eq!(row["allow"], json!([{"fp": x, "name": &x[..8]}]), "{r}");

    let r = b_ipc(&b, json!({"cmd":"unshare","to":a.id,"port":p})).await;
    assert_eq!(r, json!({"ok":true,"was":true}));
}

#[tokio::test]
async fn to_this_device_is_local() {
    let (a, _) = start_sharing(|_| {}).await;
    let p = 5102u16;
    let r = ipc_once(&a.svc, a.home.path(), json!({"cmd":"share","to":a.id,"ports":[p]})).await;
    assert_eq!(r["shared"][0]["url"], format!("http://{}.rapp:{p}", a.id), "{r}");
    let log = log_events(a.home.path());
    for l in log.iter().filter(|l| l["ev"] == "share") {
        assert_eq!(l["by"], "local", "{l}");
    }
}

#[tokio::test]
async fn an_offline_device_is_offline_within_the_wait() {
    let (_, b, _) = a_and_b().await;
    let began = std::time::Instant::now();
    let r = b_ipc(&b, json!({"cmd":"shares","to":"999999999"})).await;
    assert_eq!(r, json!({"ok":false,"error":"offline"}));
    assert!(began.elapsed() < Duration::from_secs(7), "{:?}", began.elapsed());
}

#[tokio::test]
async fn the_cli_still_prints_the_same() {
    let (a, _) = start_sharing(|_| {}).await;
    let p = 5103u16;
    let r = ipc_once(&a.svc, a.home.path(), json!({"cmd":"share","ports":[p]})).await;
    assert_eq!(r["ok"], true, "{r}");
    // A shares with no allow list prints no "只给" column text; the allowed case is in say.rs's
    // tests (strings and objects both print the name).
    let r = ipc_once(&a.svc, a.home.path(), json!({"cmd":"shares"})).await;
    assert_eq!(r["shares"][0]["allow"], json!([]), "{r}");
    assert_eq!(r["shares"][0]["url"], format!("http://{}.rapp:{p}", a.id), "{r}");
}
