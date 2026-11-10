//! rapp-service (spec §2.3, §3) driven by a raw QUIC "B" and the IPC socket.

mod common;

use common::*;
use rapp_net::line::{read_json, write_json};
use rapp_net::quic::bi;
use serde_json::{json, Value};
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};

const APPS: &str = r#"[{"app":"com.example.echo","name":"Echo"},{"app":"com.apple.Safari","name":"Safari"}]"#;

fn apps() -> Value {
    serde_json::from_str(APPS).unwrap()
}

/// Sends the worker token over an `open` stream and checks bytes go both ways.
async fn echo_through(s: &mut rapp_net::quic::BiStream, worker_token: &str) {
    let mut r = BufReader::new(s);
    r.get_mut().write_all(format!("{worker_token}\n").as_bytes()).await.unwrap();
    let mut line = String::new();
    r.read_line(&mut line).await.unwrap();
    assert_eq!(line, "ok\n");
    r.get_mut().write_all(b"hello bytes\n").await.unwrap();
    line.clear();
    r.read_line(&mut line).await.unwrap();
    assert_eq!(line, "hello bytes\n");
}

#[tokio::test]
async fn registers_and_reports_status() {
    let relay = relay(Duration::from_secs(60));
    let a = service(Some(relay.relay.addr)).await;
    assert_eq!(a.id.len(), 9);
    let st = ipc_once(&a.svc, a.home.path(), json!({"cmd":"status"})).await;
    assert_eq!(st["ok"], true);
    assert_eq!(st["name"], "test-a");
    assert_eq!(st["password"], PASSWORD);
    assert_eq!(st["permissions"], json!({"screen_recording":true,"accessibility":true}));
    assert_eq!(st["sessions"], json!([]));
    let cfg: Value = serde_json::from_slice(&std::fs::read(a.home.path().join("service.json")).unwrap()).unwrap();
    assert_eq!(cfg["id"], a.id.as_str());
    assert_eq!(cfg["secret"].as_str().unwrap().len(), 64);

    let mut bad = Ipc::open_with(&a.svc, "nope").await;
    assert_eq!(bad.next().await["error"], "bad token");
    assert_eq!(bad.next().await, Value::Null);
}

#[tokio::test]
async fn first_start_generates_secret_and_password() {
    let (home, bins) = (tempfile::tempdir().unwrap(), bins());
    // Only the ports are preset (never the real 21118/21119); everything else is generated.
    rapp_net::config::write_json(&home.path().join("service.json"), &json!({"port":0,"ipc_port":0})).unwrap();
    let svc = start_service(home.path(), bins.path(), Duration::from_secs(60)).await;
    let cfg: Value = serde_json::from_slice(&std::fs::read(home.path().join("service.json")).unwrap()).unwrap();
    assert_eq!(cfg["secret"].as_str().unwrap().len(), 64);
    assert_eq!(cfg["password"].as_str().unwrap().len(), 8);
    assert_eq!(cfg["id"], Value::Null);
    assert!(!cfg["name"].as_str().unwrap().is_empty());
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        for f in ["service.json", "ipc.token"] {
            let mode = std::fs::metadata(home.path().join(f)).unwrap().permissions().mode();
            assert_eq!(mode & 0o777, 0o600, "{f}");
        }
    }
    let st = ipc_once(&svc, home.path(), json!({"cmd":"status"})).await;
    assert_eq!(st["relay"], "off");
}

#[tokio::test]
async fn token_direct_connect_and_list_apps() {
    let relay = relay(Duration::from_secs(60));
    let a = service(Some(relay.relay.addr)).await;
    let ep = b_endpoint();
    let (_rc, r) = relay_connect(&ep, relay.relay.addr, &a.id, PASSWORD).await;
    assert_eq!(r["ok"], true, "{r}");
    assert_eq!(r["name"], "test-a");
    let lan = r["lan"].as_array().unwrap();
    assert_eq!(lan.last().unwrap(), &json!(format!("127.0.0.1:{}", a.svc.port)));
    let public: std::net::SocketAddr = r["public"].as_str().unwrap().parse().unwrap();
    assert_eq!(public.port(), a.svc.port);

    let (conn, auth) = direct(&ep, public, json!({"op":"auth","token":r["token"]})).await;
    assert_eq!(auth, json!({"ok":true}));
    assert_eq!(req(&conn, json!({"op":"list_apps"})).await, json!({"ok":true,"apps":apps()}));
    // The connection stays usable for more requests.
    assert_eq!(req(&conn, json!({"op":"list_apps"})).await["ok"], true);
    assert_eq!(req(&conn, json!({"op":"nope"})).await["ok"], false);
}

#[tokio::test]
async fn direct_auth_failures_and_lan_password() {
    let a = service(None).await;
    let ep = b_endpoint();
    let (_c, r) = direct(&ep, a_addr(&a.svc), json!({"op":"auth","token":"0".repeat(32)})).await;
    assert_eq!(r, json!({"ok":false,"error":"bad token"}));
    let (_c, r) = direct(&ep, a_addr(&a.svc), json!({"op":"auth","password":"wrong"})).await;
    assert_eq!(r, json!({"ok":false,"error":"bad password"}));
    let (c, r) = direct(&ep, a_addr(&a.svc), json!({"op":"list_apps"})).await;
    assert_eq!(r["ok"], false);
    tokio::time::timeout(WAIT, c.closed()).await.expect("unauthenticated connection closed");
    // Loopback is a private source: password auth is accepted (relay-down fallback).
    let (conn, r) = direct(&ep, a_addr(&a.svc), json!({"op":"auth","password":PASSWORD})).await;
    assert_eq!(r, json!({"ok":true}));
    assert_eq!(req(&conn, json!({"op":"list_apps"})).await["apps"], apps());
}

#[tokio::test]
async fn open_splices_bytes_to_worker_and_kick_ends_it() {
    let a = service(None).await;
    let mut sub = Ipc::open(&a.svc, a.home.path()).await;
    assert_eq!(sub.call(json!({"cmd":"subscribe"})).await, json!({"ok":true}));

    let ep = b_endpoint();
    let (conn, _) = direct(&ep, a_addr(&a.svc), json!({"op":"auth","password":PASSWORD})).await;
    let mut s = bi(conn.open_bi().await.unwrap());
    write_json(&mut s, &json!({"op":"open","app":"com.example.echo"})).await.unwrap();
    let r = read_json(&mut s).await.unwrap();
    assert_eq!(r["ok"], true, "{r}");
    let wt = r["token"].as_str().unwrap().to_string();
    echo_through(&mut s, &wt).await;
    assert!(host_log(a.bins.path()).contains("start com.example.echo"));

    assert_eq!(sub.next().await, json!({"event":"changed"}));
    let st = sub.call(json!({"cmd":"status"})).await;
    let sessions = st["sessions"].as_array().unwrap();
    assert_eq!(sessions.len(), 1, "{st}");
    assert_eq!(sessions[0]["app"], "com.example.echo");
    assert_eq!(sessions[0]["path"], "lan");
    assert!(sessions[0]["since"].as_u64().unwrap() > 1_700_000_000);
    let sid = sessions[0]["sid"].clone();

    // A second session on the same app reuses the worker.
    let mut s2 = bi(conn.open_bi().await.unwrap());
    write_json(&mut s2, &json!({"op":"open","app":"com.example.echo"})).await.unwrap();
    assert_eq!(read_json(&mut s2).await.unwrap()["token"], wt.as_str());
    drop(s2);

    assert_eq!(sub.call(json!({"cmd":"kick","sid":sid})).await, json!({"ok":true}));
    let mut rest = Vec::new();
    let n = tokio::time::timeout(WAIT, s.read_to_end(&mut rest)).await.expect("stream ended");
    let _ = n; // either EOF or reset is fine
    assert_eq!(sub.call(json!({"cmd":"kick","sid":999})).await["ok"], false);
    assert_eq!(host_log(a.bins.path()).matches("start ").count(), 1);
}

#[tokio::test]
async fn open_unknown_worker_binary_is_an_error() {
    let a = service(None).await;
    std::fs::remove_file(a.bins.path().join("rapp-host")).unwrap();
    let ep = b_endpoint();
    let (conn, _) = direct(&ep, a_addr(&a.svc), json!({"op":"auth","password":PASSWORD})).await;
    let r = req(&conn, json!({"op":"open","app":"com.example.echo"})).await;
    assert_eq!(r["ok"], false);
}

#[tokio::test]
async fn idle_worker_gets_stdin_closed() {
    let a = service_with_idle(None, Duration::from_millis(300)).await;
    let ep = b_endpoint();
    let (conn, _) = direct(&ep, a_addr(&a.svc), json!({"op":"auth","password":PASSWORD})).await;
    let mut s = bi(conn.open_bi().await.unwrap());
    write_json(&mut s, &json!({"op":"open","app":"com.example.echo"})).await.unwrap();
    let wt = read_json(&mut s).await.unwrap()["token"].as_str().unwrap().to_string();
    echo_through(&mut s, &wt).await;
    tokio::time::sleep(Duration::from_millis(600)).await;
    assert!(!host_log(a.bins.path()).contains("exit"), "busy worker must stay");
    s.writer_mut().finish().unwrap();
    drop(s);
    let deadline = tokio::time::Instant::now() + WAIT;
    while !host_log(a.bins.path()).contains("exit com.example.echo") {
        assert!(tokio::time::Instant::now() < deadline, "idle worker not closed");
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    // The next open starts a fresh worker.
    let r = req(&conn, json!({"op":"open","app":"com.example.echo"})).await;
    assert_eq!(r["ok"], true);
    assert_ne!(r["token"], wt.as_str());
}

#[tokio::test]
async fn relayed_requests_reach_the_service() {
    let relay = relay(Duration::from_secs(60));
    let a = service(Some(relay.relay.addr)).await;
    let ep = b_endpoint();
    let (rc, r) = relay_connect(&ep, relay.relay.addr, &a.id, PASSWORD).await;
    let token = r["token"].as_str().unwrap().to_string();

    let mut s = bi(rc.open_bi().await.unwrap());
    write_json(&mut s, &json!({"op":"relay","key":KEY,"token":token})).await.unwrap();
    write_json(&mut s, &json!({"op":"list_apps"})).await.unwrap();
    assert_eq!(read_json(&mut s).await.unwrap()["apps"], apps());

    let mut s = bi(rc.open_bi().await.unwrap());
    write_json(&mut s, &json!({"op":"relay","key":KEY,"token":token})).await.unwrap();
    write_json(&mut s, &json!({"op":"open","app":"com.example.echo"})).await.unwrap();
    let wt = read_json(&mut s).await.unwrap()["token"].as_str().unwrap().to_string();
    echo_through(&mut s, &wt).await;
    let st = ipc_once(&a.svc, a.home.path(), json!({"cmd":"status"})).await;
    assert_eq!(st["sessions"][0]["path"], "relay");
}

#[tokio::test]
async fn restarted_service_rejects_old_tokens() {
    let relay = relay(Duration::from_secs(60));
    let a = service(Some(relay.relay.addr)).await;
    let ep = b_endpoint();
    let (rc, r) = relay_connect(&ep, relay.relay.addr, &a.id, PASSWORD).await;
    let token = r["token"].as_str().unwrap().to_string();
    a.svc.stop();
    let svc2 = start_service(a.home.path(), a.bins.path(), Duration::from_secs(60)).await;
    assert_eq!(wait_registered(&svc2, a.home.path()).await, a.id, "same id after restart");

    let mut s = bi(rc.open_bi().await.unwrap());
    write_json(&mut s, &json!({"op":"relay","key":KEY,"token":token})).await.unwrap();
    write_json(&mut s, &json!({"op":"list_apps"})).await.unwrap();
    assert_eq!(read_json(&mut s).await.unwrap(), json!({"ok":false,"error":"bad token"}));
}

#[tokio::test]
async fn set_password_and_set_relay_via_ipc() {
    let relay = relay(Duration::from_secs(60));
    let a = service(Some(relay.relay.addr)).await;
    let mut ipc = Ipc::open(&a.svc, a.home.path()).await;
    assert_eq!(ipc.call(json!({"cmd":"set_password","password":"new-pass"})).await, json!({"ok":true}));
    let ep = b_endpoint();
    let deadline = tokio::time::Instant::now() + WAIT;
    loop {
        let (_c, r) = relay_connect(&ep, relay.relay.addr, &a.id, "new-pass").await;
        if r["ok"] == true {
            break;
        }
        assert!(tokio::time::Instant::now() < deadline, "never re-registered: {r}");
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    let st = ipc.call(json!({"cmd":"status"})).await;
    assert_eq!(st["password"], "new-pass");

    // Point it at a second relay with the wrong key: status reports the error.
    let relay2 = common::relay(Duration::from_secs(60));
    let r = ipc.call(json!({"cmd":"set_relay","relay":relay2.relay.addr.to_string(),"key":"wrong"})).await;
    assert_eq!(r, json!({"ok":true}));
    let deadline = tokio::time::Instant::now() + WAIT;
    loop {
        let st = ipc.call(json!({"cmd":"status"})).await;
        if st["relay_error"] == "bad relay key" {
            assert_eq!(st["relay"], "connecting");
            break;
        }
        assert!(tokio::time::Instant::now() < deadline, "no relay error: {st}");
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    let cfg: Value = serde_json::from_slice(&std::fs::read(a.home.path().join("service.json")).unwrap()).unwrap();
    assert_eq!(cfg["key"], "wrong");
    assert_eq!(cfg["password"], "new-pass");
}
