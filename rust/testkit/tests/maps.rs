//! Local ports for other devices' shares: `localhost:<local>` on B is a port A shares.

mod common;
use common::sharing::*;
use common::*;

use serde_json::{json, Value};
use std::path::Path;
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;

/// A service on a fresh home that gives local ports from `first` on, trusting `key`.
async fn start_on(first: u16, key: &rapp_wire::Key) -> TestService {
    let (home, bins) = (tempfile::tempdir().unwrap(), bins());
    service_json(home.path());
    let svc = start_service_ports(home.path(), bins.path(), Duration::from_secs(60), (first, 10)).await;
    let r = ipc_once(&svc, home.path(), json!({"cmd":"set_relay","relay":"","key":key.to_string()})).await;
    assert_eq!(r["ok"], true, "{r}");
    let id = ipc_once(&svc, home.path(), json!({"cmd":"status"})).await["id"].as_str().unwrap().to_string();
    TestService { svc, home, bins, id }
}

fn knows(b: &TestService, a: &TestService) {
    let hosts = json!([{"id": a.id, "name": "a", "lan": [a_addr(&a.svc).to_string()]}]);
    std::fs::write(b.home.path().join("hosts.json"), hosts.to_string()).unwrap();
}

/// A sharing `ports`, and B (local ports from `first` on) that trusts it and has its LAN address.
async fn a_and_b(first: u16, ports: Value) -> (TestService, TestService) {
    let (a, key) = sharing(ports).await;
    let b = start_on(first, &key).await;
    knows(&b, &a);
    (a, b)
}

async fn ipc(s: &TestService, cmd: Value) -> Value {
    ipc_once(&s.svc, s.home.path(), cmd).await
}

/// B's `shares` of A: the row of `port`.
async fn row(b: &TestService, a: &TestService, port: u16) -> Value {
    let r = ipc(b, json!({"cmd":"shares","to":a.id})).await;
    assert_eq!(r["ok"], true, "{r}");
    r["shares"].as_array().unwrap().iter().find(|s| s["port"] == port).cloned().unwrap_or(Value::Null)
}

fn saved_maps(home: &Path) -> Value {
    match std::fs::read(home.join("maps.json")) {
        Ok(b) => serde_json::from_slice(&b).unwrap(),
        Err(_) => json!([]),
    }
}

/// Writes `data` to `127.0.0.1:<local>`, finishes writing, and reads to the end.
async fn through(local: u16, data: &[u8]) -> Vec<u8> {
    let mut c = TcpStream::connect(("127.0.0.1", local)).await.expect("the local port accepts");
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

#[tokio::test]
async fn a_share_of_a_is_reached_on_a_local_port_of_b() {
    let (port, _echo) = echo().await;
    let (a, b) = a_and_b(29300, json!([{"port": port, "note": "echo"}])).await;
    let r = row(&b, &a, port).await;
    assert_eq!(
        r,
        json!({"port": port, "note": "echo", "allow": [], "addr": "http://localhost:29300", "local": 29300,
               "web": true, "listening": true, "mine": true})
    );
    assert_eq!(through(29300, b"hello").await, b"hello");
    assert_eq!(saved_maps(b.home.path()), json!([{"id": a.id, "port": port, "local": 29300}]));
    // Asking again gives the same port.
    assert_eq!(row(&b, &a, port).await["local"], 29300);
}

#[tokio::test]
async fn ssh_is_reached_with_the_port_spelled_out() {
    let (a, b) = a_and_b(29310, json!([{"port": 22}, {"port": 8000}])).await;
    let r = row(&b, &a, 22).await;
    assert_eq!((&r["addr"], &r["local"], &r["web"]), (&json!("ssh -p 29310 localhost"), &json!(29310), &json!(false)), "{r}");
    let r = row(&b, &a, 8000).await;
    assert_eq!((&r["addr"], &r["web"]), (&json!("http://localhost:29311"), &json!(true)), "{r}");
}

#[tokio::test]
async fn this_devices_own_shares_are_reached_on_themselves() {
    let (a, _) = sharing(json!([{"port": 22}, {"port": 8000}])).await;
    let r = ipc(&a, json!({"cmd":"shares"})).await;
    let s = r["shares"].as_array().unwrap();
    assert_eq!((&s[0]["addr"], &s[0]["local"]), (&json!("ssh localhost"), &json!(22)), "{r}");
    assert_eq!((&s[1]["addr"], &s[1]["local"]), (&json!("http://localhost:8000"), &json!(8000)), "{r}");
    assert_eq!(saved_maps(a.home.path()), json!([]));
}

#[tokio::test]
async fn a_share_that_is_not_for_this_device_has_no_local_port() {
    let (port, _echo) = echo().await;
    let (a, b) = a_and_b(29320, json!([{"port": port}])).await;
    assert_eq!(row(&b, &a, port).await["local"], 29320);
    assert_eq!(through(29320, b"x").await, b"x");

    let other = rapp_wire::Fp([7; 32]).to_string();
    let r = ipc(&a, json!({"cmd":"share","ports":[port],"allow":[other]})).await;
    assert_eq!(r["ok"], true, "{r}");
    let r = row(&b, &a, port).await;
    assert_eq!((&r["mine"], &r["addr"], &r["local"]), (&json!(false), &json!(""), &Value::Null), "{r}");
    refuses(29320).await;
    assert_eq!(saved_maps(b.home.path()), json!([]));
}

#[tokio::test]
async fn a_share_that_is_gone_gives_its_local_port_back() {
    let ((p, _e1), (q, _e2)) = (echo().await, echo().await);
    let (a, b) = a_and_b(29330, json!([{"port": p}, {"port": q}])).await;
    let (lp, lq) = (row(&b, &a, p).await["local"].clone(), row(&b, &a, q).await["local"].clone());
    let (lp, lq) = (lp.as_u64().unwrap() as u16, lq.as_u64().unwrap() as u16);
    assert_ne!(lp, lq);
    let r = ipc(&b, json!({"cmd":"unshare","to":a.id,"port":p})).await;
    assert_eq!(r, json!({"ok":true,"was":true}));
    assert_eq!(row(&b, &a, p).await, Value::Null);
    refuses(lp).await;
    assert_eq!(through(lq, b"still").await, b"still");
    assert_eq!(saved_maps(b.home.path()), json!([{"id": a.id, "port": q, "local": lq}]));
}

#[tokio::test]
async fn a_restart_of_b_keeps_the_address_and_listens_before_anyone_asks() {
    let (port, _echo) = echo().await;
    let (a, mut b) = a_and_b(29340, json!([{"port": 9}, {"port": port}])).await;
    assert_eq!(row(&b, &a, port).await["local"], 29341);
    b.svc.stop();
    refuses(29341).await;
    b.svc = start_service_ports(b.home.path(), b.bins.path(), Duration::from_secs(60), (29340, 10)).await;
    assert_eq!(through(29341, b"again").await, b"again");
    assert_eq!(row(&b, &a, port).await["local"], 29341);
}

#[tokio::test]
async fn a_connection_to_a_share_that_is_gone_is_closed_and_the_log_says_why() {
    let (port, _echo) = echo().await;
    let (a, b) = a_and_b(29350, json!([{"port": port}])).await;
    assert_eq!(row(&b, &a, port).await["local"], 29350);
    // A stops sharing; B has not asked since.
    let r = ipc(&a, json!({"cmd":"unshare","port":port})).await;
    assert_eq!(r["ok"], true, "{r}");
    // The connection is accepted and then closed with nothing sent back.
    let mut c = TcpStream::connect(("127.0.0.1", 29350)).await.expect("the local port accepts");
    c.write_all(b"hello").await.unwrap();
    let mut buf = [0u8; 8];
    let n = tokio::time::timeout(WAIT, c.read(&mut buf)).await.expect("ends in time");
    assert!(matches!(n, Ok(0) | Err(_)), "{n:?}");
    let l = wait_log(b.home.path(), "map_refused", |v| v["local"] == 29350).await;
    assert_eq!((&l["id"], &l["port"], &l["reason"]), (&json!(a.id), &json!(port), &json!("not shared")), "{l}");
}

#[tokio::test]
async fn hosts_says_the_local_address_of_every_share() {
    let (a, b) = a_and_b(29360, json!([{"port": 22}, {"port": 8000, "note": "web"}])).await;
    let r = ipc(&b, json!({"cmd":"hosts"})).await;
    assert_eq!(
        r["hosts"],
        json!([{"id": a.id, "name": "a", "shares": [
            {"port": 22, "local": 29360, "addr": "ssh -p 29360 localhost"},
            {"port": 8000, "note": "web", "local": 29361, "addr": "http://localhost:29361"},
        ]}])
    );
}

#[tokio::test]
async fn a_device_taken_off_the_list_loses_its_local_ports() {
    let (port, _echo) = echo().await;
    let (a, b) = a_and_b(29370, json!([{"port": port}])).await;
    assert_eq!(row(&b, &a, port).await["local"], 29370);
    std::fs::write(b.home.path().join("hosts.json"), "[]").unwrap();
    let r = ipc(&b, json!({"cmd":"hosts"})).await;
    assert_eq!(r["hosts"], json!([]));
    refuses(29370).await;
    assert_eq!(saved_maps(b.home.path()), json!([]));
}

#[tokio::test]
async fn through_the_relay() {
    let rig = RelayRig::start().await;
    let (port, _echo) = echo().await;
    // Neither registers a LAN address and B has no hosts.json: B can only reach A through the relay.
    let a = a_on_relay(&rig, Some(vec![])).await;
    let b = a_on_relay(&rig, Some(vec![])).await;
    let r = ipc(&a, json!({"cmd":"share","ports":[port]})).await;
    assert_eq!(r["ok"], true, "{r}");
    let local = row(&b, &a, port).await["local"].as_u64().expect("a local port") as u16;
    let big: Vec<u8> = (0..300_000u32).map(|i| (i % 251) as u8).collect();
    assert_eq!(through(local, &big).await, big);
}
