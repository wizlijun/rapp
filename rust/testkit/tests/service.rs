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

fn perms(screen_recording: bool, accessibility: bool) -> Value {
    json!({"screen_recording": screen_recording, "accessibility": accessibility})
}

/// What the fake `rapp-host` reports from now on.
fn set_perms(bins: &std::path::Path, v: &Value) {
    std::fs::write(bins.join("perms"), v.to_string()).unwrap();
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
    // No relay configured, yet the service already has its own ID.
    assert!(rapp_net::crypto::is_valid_id(cfg["id"].as_str().unwrap()));
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
    // Without a relay B reaches A by `id@ip`: one per local IPv4, port shown as it is not 21118.
    let want_tail = format!(":{}", svc.port);
    let lan_ids = st["lan_ids"].as_array().expect("lan_ids");
    for l in lan_ids {
        let l = l.as_str().unwrap();
        let (id, addr) = rapp_net::addr::split_host_ref(l).unwrap();
        assert_eq!(id, cfg["id"].as_str().unwrap());
        assert!(addr.unwrap().ends_with(&want_tail), "{l}");
    }
    let ips = rapp_net::addr::local_ipv4s();
    assert_eq!(lan_ids.len(), ips.len());
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
    assert_eq!(req(&conn, json!({"op":"list_apps"})).await, json!({"ok":true,"apps":apps(),"permissions":perms(true, true)}));
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
    // The reply names the host, so B can check an `id@ip` it was given.
    assert_eq!(r, json!({"ok":true,"id":a.id,"name":"test-a"}));
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

#[tokio::test]
async fn permissions_command_checks_and_prompts() {
    let a = service(None).await;
    set_perms(a.bins.path(), &perms(false, true));
    let mut sub = Ipc::open(&a.svc, a.home.path()).await;
    sub.call(json!({"cmd":"subscribe"})).await;

    let mut ipc = Ipc::open(&a.svc, a.home.path()).await;
    let r = ipc.call(json!({"cmd":"permissions"})).await;
    assert_eq!(r, json!({"ok":true,"permissions":perms(false, true)}));
    assert_eq!(sub.next().await, json!({"event":"changed"}));
    assert_eq!(ipc.call(json!({"cmd":"status"})).await["permissions"], perms(false, true));
    assert!(!host_log(a.bins.path()).contains("check --prompt"));

    let r = ipc.call(json!({"cmd":"permissions","prompt":true})).await;
    assert_eq!(r["permissions"], perms(false, true));
    assert!(host_log(a.bins.path()).contains("check --prompt"));
}

type Tccutil = Box<dyn Fn(&[String]) -> rapp_update::runner::Out + Send + Sync>;

/// A relay-less service whose runner scripts `/usr/bin/tccutil` with `tccutil` (None: not installed).
async fn with_tccutil(
    tccutil: Option<Tccutil>,
    bins: &std::path::Path,
) -> (rapp_service::Service, tempfile::TempDir, std::sync::Arc<rapp_update::fake::FakeRunner>) {
    let home = tempfile::tempdir().unwrap();
    service_json(home.path(), None);
    let mut runner = rapp_update::fake::FakeRunner::new();
    if let Some(f) = tccutil {
        runner = runner.on(rapp_update::runner::TCCUTIL, f);
    }
    let runner = std::sync::Arc::new(runner);
    let svc = start_service_with(home.path(), bins, runner.clone(), None).await;
    (svc, home, runner)
}

fn tccutil_calls(r: &rapp_update::fake::FakeRunner) -> Vec<Vec<String>> {
    r.calls().into_iter().filter(|(p, _)| p == rapp_update::runner::TCCUTIL).map(|(_, a)| a).collect()
}

fn strs(v: &[&str]) -> Vec<String> {
    v.iter().map(|s| s.to_string()).collect()
}

#[tokio::test]
async fn permissions_reset_runs_tccutil_for_rapp_only() {
    let bins = bins();
    set_perms(bins.path(), &perms(true, true));
    let b = bins.path().to_path_buf();
    let (svc, home, runner) = with_tccutil(
        Some(Box::new(move |_| {
            set_perms(&b, &perms(false, false));
            rapp_update::runner::Out::ok("")
        })),
        bins.path(),
    )
    .await;
    let r = ipc_once(&svc, home.path(), json!({"cmd":"permissions_reset"})).await;
    assert_eq!(
        r,
        json!({"ok":true,"screen_recording_reset":true,"accessibility_reset":true,"permissions":perms(false, false)})
    );
    assert_eq!(
        tccutil_calls(&runner),
        vec![strs(&["reset", "ScreenCapture", "com.rapp.rapp"]), strs(&["reset", "Accessibility", "com.rapp.rapp"])]
    );
    assert!(host_log(bins.path()).contains("check --prompt"));
    let ev = wait_log(home.path(), "permissions_reset", |_| true).await;
    assert_eq!(ev.as_object().unwrap().keys().filter(|k| !["ts", "lvl", "ev"].contains(&k.as_str())).count(), 0, "{ev}");
}

#[tokio::test]
async fn accessibility_reset_failure_is_reported() {
    let bins = bins();
    set_perms(bins.path(), &perms(true, true));
    let b = bins.path().to_path_buf();
    let (svc, home, _) = with_tccutil(
        Some(Box::new(move |a| {
            if a[1] == "ScreenCapture" {
                set_perms(&b, &perms(false, true));
            }
            rapp_update::runner::Out::ok("")
        })),
        bins.path(),
    )
    .await;
    let r = ipc_once(&svc, home.path(), json!({"cmd":"permissions_reset"})).await;
    assert_eq!((&r["screen_recording_reset"], &r["accessibility_reset"]), (&json!(true), &json!(false)), "{r}");
    assert_eq!(r["permissions"], perms(false, true));
}

#[tokio::test]
async fn tccutil_missing_reports_false() {
    let bins = bins();
    set_perms(bins.path(), &perms(true, true));
    let (svc, home, _) = with_tccutil(None, bins.path()).await;
    let r = ipc_once(&svc, home.path(), json!({"cmd":"permissions_reset"})).await;
    assert_eq!(r["ok"], true, "{r}");
    assert_eq!((&r["screen_recording_reset"], &r["accessibility_reset"]), (&json!(false), &json!(false)), "{r}");
    assert!(host_log(bins.path()).contains("check --prompt"));
}

#[tokio::test]
async fn failed_check_keeps_last_known_permissions() {
    let a = service(None).await;
    set_perms(a.bins.path(), &perms(true, false));
    let mut ipc = Ipc::open(&a.svc, a.home.path()).await;
    assert_eq!(ipc.call(json!({"cmd":"permissions"})).await["permissions"], perms(true, false));
    std::fs::write(a.bins.path().join("perms"), "broken").unwrap();
    assert_eq!(ipc.call(json!({"cmd":"permissions"})).await["permissions"], perms(true, false));
    assert_eq!(ipc.call(json!({"cmd":"status"})).await["permissions"], perms(true, false));
}

#[tokio::test]
async fn list_apps_reports_and_stores_permissions() {
    let a = service(None).await;
    set_perms(a.bins.path(), &perms(true, false));
    let ep = b_endpoint();
    let (conn, _) = direct(&ep, a_addr(&a.svc), json!({"op":"auth","password":PASSWORD})).await;
    let r = req(&conn, json!({"op":"list_apps"})).await;
    assert_eq!(r, json!({"ok":true,"apps":apps(),"permissions":perms(true, false)}));
    assert_eq!(ipc_once(&a.svc, a.home.path(), json!({"cmd":"status"})).await["permissions"], perms(true, false));
}

#[tokio::test]
async fn open_without_permission_says_so_and_rechecks() {
    let a = service(None).await;
    set_perms(a.bins.path(), &perms(false, false));
    let ep = b_endpoint();
    let (conn, _) = direct(&ep, a_addr(&a.svc), json!({"op":"auth","password":PASSWORD})).await;
    let r = req(&conn, json!({"op":"open","app":"com.example.echo"})).await;
    assert_eq!(r["ok"], false);
    let e = r["error"].as_str().unwrap();
    assert!(e.contains("missing permission: Screen Recording, Accessibility"), "{e}");
    assert_eq!(ipc_once(&a.svc, a.home.path(), json!({"cmd":"status"})).await["permissions"], perms(false, false));
}

// ---- observability (spec §4.1, §6) ----

/// Opens `app` on an authenticated direct connection and pushes bytes through it.
async fn open_echo(conn: &quinn::Connection) -> (rapp_net::quic::BiStream, String) {
    let mut s = bi(conn.open_bi().await.unwrap());
    write_json(&mut s, &json!({"op":"open","app":"com.example.echo"})).await.unwrap();
    let r = read_json(&mut s).await.unwrap();
    assert_eq!(r["ok"], true, "{r}");
    let wt = r["token"].as_str().unwrap().to_string();
    echo_through(&mut s, &wt).await;
    (s, wt)
}

#[tokio::test]
async fn logs_who_connected_what_they_opened_and_how_it_ended() {
    let a = service(None).await;
    let home = a.home.path();
    let ep = b_endpoint();
    let (_c, r) = direct(&ep, a_addr(&a.svc), json!({"op":"auth","password":"wrong-pw","name":"mbp"})).await;
    assert_eq!(r["ok"], false);
    let fail = wait_log(home, "auth_fail", |_| true).await;
    assert_eq!(fail["lvl"], "warn");
    assert_eq!(fail["reason"], "bad password");
    assert_eq!(fail["name"], "mbp");
    assert_eq!(fail["path"], "lan");
    assert!(fail["peer"].as_str().unwrap().starts_with("127.0.0.1:"), "{fail}");

    let (conn, _) = direct(&ep, a_addr(&a.svc), json!({"op":"auth","password":PASSWORD,"name":"mbp"})).await;
    let (s, wt) = open_echo(&conn).await;
    let req = wait_log(home, "request", |v| v["op"] == "open").await;
    assert_eq!((&req["app"], &req["result"], &req["name"]), (&json!("com.example.echo"), &json!("ok"), &json!("mbp")));
    let start = wait_log(home, "session_start", |_| true).await;
    let sid = start["sid"].clone();
    assert_eq!((&start["app"], &start["path"], &start["name"]), (&json!("com.example.echo"), &json!("lan"), &json!("mbp")));
    // The worker's stderr text and its transfer event, tagged with the session.
    let host_line = wait_log(home, "log", |v| v["src"] == "host").await;
    assert_eq!(host_line["app"], "com.example.echo");
    assert!(host_line["msg"].as_str().unwrap().contains("serving"), "{host_line}");
    let t = wait_log(home, "transfer", |_| true).await;
    assert_eq!((&t["sid"], &t["kind"], &t["bytes"], &t["name"]), (&sid, &json!("files"), &json!(5), &json!("a.txt")));

    assert_eq!(ipc_once(&a.svc, home, json!({"cmd":"kick","sid":sid})).await["ok"], true);
    wait_log(home, "kick", |v| v["sid"] == sid).await;
    let end = wait_log(home, "session_end", |_| true).await;
    assert_eq!(end["sid"], sid);
    assert_eq!(end["reason"], "kicked");
    assert_eq!(end["name"], "mbp");
    // B sent its worker token plus "hello bytes\n"; the worker sent "ok\n" plus the echo.
    assert!(end["up"].as_u64().unwrap() > 0 && end["down"].as_u64().unwrap() > 0, "{end}");
    assert!(end["secs"].is_u64(), "{end}");
    drop(s);

    // A refused open is in 访问记录; a successful one is not (its session lines are).
    set_perms(a.bins.path(), &perms(false, true));
    assert!(req_open_fails(&conn).await);
    wait_log(home, "request", |v| v["result"] != "ok").await;

    let h = ipc_once(&a.svc, home, json!({"cmd":"history","limit":10})).await;
    assert_eq!(h["ok"], true, "{h}");
    let evs: Vec<&str> = h["events"].as_array().unwrap().iter().map(|e| e["ev"].as_str().unwrap()).collect();
    assert_eq!(evs, ["request", "session_end", "session_start", "auth_fail"], "{h}");
    let h = ipc_once(&a.svc, home, json!({"cmd":"history","limit":2})).await;
    assert_eq!(h["events"].as_array().unwrap().len(), 2);

    let st = ipc_once(&a.svc, home, json!({"cmd":"status"})).await;
    assert_eq!(st["log_dir"], home.join("logs").to_str().unwrap());

    // Never a secret in the log (spec §0).
    let ipc_token = std::fs::read_to_string(home.join("ipc.token")).unwrap();
    let text = std::fs::read_to_string(home.join("logs").join("service.log")).unwrap();
    for secret in [PASSWORD, "wrong-pw", wt.as_str(), ipc_token.trim(), KEY] {
        assert!(!text.contains(secret), "{secret:?} in service.log:\n{text}");
    }
}

/// Opens an app with no worker yet, so the (fake) host's permission check decides.
async fn req_open_fails(conn: &quinn::Connection) -> bool {
    req(conn, json!({"op":"open","app":"com.apple.Safari"})).await["ok"] == false
}

#[tokio::test]
async fn relayed_session_logs_the_name_the_relay_passed_on() {
    let relay = relay(Duration::from_secs(60));
    let a = service(Some(relay.relay.addr)).await;
    let ep = b_endpoint();
    let rc = dial(&ep, relay.relay.addr, rapp_net::quic::ALPN_RELAY).await;
    let r = req(&rc, json!({"op":"connect","key":KEY,"id":a.id,"password":PASSWORD,"name":"phone"})).await;
    let token = r["token"].as_str().unwrap().to_string();
    let mut s = bi(rc.open_bi().await.unwrap());
    write_json(&mut s, &json!({"op":"relay","key":KEY,"token":token})).await.unwrap();
    write_json(&mut s, &json!({"op":"open","app":"com.example.echo"})).await.unwrap();
    let wt = read_json(&mut s).await.unwrap()["token"].as_str().unwrap().to_string();
    echo_through(&mut s, &wt).await;
    let start = wait_log(a.home.path(), "session_start", |_| true).await;
    assert_eq!((&start["path"], &start["name"]), (&json!("relay"), &json!("phone")));
    let st = wait_log(a.home.path(), "relay", |v| v["state"] == "connected").await;
    assert_eq!(st["lvl"], "info");
    let text = std::fs::read_to_string(a.home.path().join("logs").join("service.log")).unwrap();
    for secret in [PASSWORD, token.as_str(), wt.as_str(), KEY] {
        assert!(!text.contains(secret), "{secret:?} in service.log:\n{text}");
    }
}

#[tokio::test]
async fn logs_start_and_worker_exit() {
    let a = service_with_idle(None, Duration::from_millis(200)).await;
    let start = wait_log(a.home.path(), "service_start", |_| true).await;
    assert_eq!(start["port"], a.svc.port);
    assert_eq!(start["id"], a.id.as_str());
    let ep = b_endpoint();
    let (conn, _) = direct(&ep, a_addr(&a.svc), json!({"op":"auth","password":PASSWORD})).await;
    let (mut s, _) = open_echo(&conn).await;
    s.writer_mut().finish().unwrap();
    drop(s);
    let end = wait_log(a.home.path(), "session_end", |_| true).await;
    assert_eq!(end["reason"], "closed");
    assert!(end.get("name").is_none(), "{end}");
    let exit = wait_log(a.home.path(), "worker_exit", |_| true).await;
    assert_eq!((&exit["app"], &exit["code"], &exit["reason"]), (&json!("com.example.echo"), &json!(0), &json!("stdin closed")));
}

#[tokio::test]
async fn oversized_launchd_log_is_emptied_at_start() {
    let (home, bins) = (tempfile::tempdir().unwrap(), bins());
    service_json(home.path(), None);
    let logs = home.path().join("logs");
    std::fs::create_dir_all(&logs).unwrap();
    std::fs::write(logs.join("launchd.log"), vec![b'x'; 5 * 1024 * 1024 + 1]).unwrap();
    let _svc = start_service(home.path(), bins.path(), Duration::from_secs(60)).await;
    assert_eq!(std::fs::metadata(logs.join("launchd.log")).unwrap().len(), 0);
}

// ---- review fixes (O7) ----

#[tokio::test]
async fn a_host_refusal_is_in_history_as_rejected() {
    let a = service(None).await;
    let home = a.home.path();
    let ep = b_endpoint();
    let (conn, _) = direct(&ep, a_addr(&a.svc), json!({"op":"auth","password":PASSWORD})).await;
    let mut s = bi(conn.open_bi().await.unwrap());
    write_json(&mut s, &json!({"op":"open","app":"com.example.echo"})).await.unwrap();
    assert_eq!(read_json(&mut s).await.unwrap()["ok"], true);
    // The worker refuses B's hello (here: the wrong worker token).
    s.write_all(b"not-the-token\n").await.unwrap();
    let start = wait_log(home, "session_start", |_| true).await;
    wait_log(home, "rejected", |_| true).await;
    let h = ipc_once(&a.svc, home, json!({"cmd":"history","limit":10})).await;
    let rej = h["events"].as_array().unwrap().iter().find(|e| e["ev"] == "rejected").cloned();
    let rej = rej.unwrap_or_else(|| panic!("no rejected in {h}"));
    assert_eq!((&rej["sid"], &rej["reason"]), (&start["sid"], &json!("bad token")));
}

#[tokio::test]
async fn a_self_declared_name_is_cleaned_and_capped() {
    let a = service(None).await;
    let ep = b_endpoint();
    let dirty = format!("\u{202e}mb\np{}", "a".repeat(1000));
    let (_c, r) = direct(&ep, a_addr(&a.svc), json!({"op":"auth","password":"wrong","name":dirty})).await;
    assert_eq!(r["ok"], false);
    let fail = wait_log(a.home.path(), "auth_fail", |_| true).await;
    assert_eq!(fail["name"], format!("mbp{}", "a".repeat(61)));
}

#[tokio::test]
async fn a_malformed_auth_line_is_logged_as_an_attempt() {
    let a = service(None).await;
    let ep = b_endpoint();
    let conn = dial(&ep, a_addr(&a.svc), rapp_net::quic::ALPN_PEER).await;
    let mut s = bi(conn.open_bi().await.unwrap());
    s.write_all(b"not json\n").await.unwrap();
    let fail = wait_log(a.home.path(), "auth_fail", |_| true).await;
    assert_eq!(fail["reason"], "bad request");
}

#[tokio::test]
async fn stopping_the_service_ends_open_sessions_in_the_log() {
    let a = service(None).await;
    let home = a.home.path();
    let ep = b_endpoint();
    let (conn, _) = direct(&ep, a_addr(&a.svc), json!({"op":"auth","password":PASSWORD,"name":"mbp"})).await;
    let (_s, _) = open_echo(&conn).await;
    let start = wait_log(home, "session_start", |_| true).await;
    a.svc.stop();
    let end = wait_log(home, "session_end", |_| true).await;
    assert_eq!((&end["sid"], &end["reason"], &end["name"]), (&start["sid"], &json!("service stopped"), &json!("mbp")));
    wait_log(home, "service_stop", |_| true).await;
    // The aborted splice does not write a second end line.
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert_eq!(log_events(home).iter().filter(|e| e["ev"] == "session_end").count(), 1);
}

#[cfg(unix)]
#[tokio::test]
async fn launchd_log_is_made_private_at_start() {
    use std::os::unix::fs::PermissionsExt;
    let home = tempfile::tempdir().unwrap();
    let logs = home.path().join("logs");
    std::fs::create_dir(&logs).unwrap();
    let launchd = logs.join("launchd.log");
    std::fs::write(&launchd, "old panic\n").unwrap();
    std::fs::set_permissions(&launchd, std::fs::Permissions::from_mode(0o644)).unwrap();
    let bins = bins();
    service_json(home.path(), None);
    let _svc = start_service(home.path(), bins.path(), Duration::from_secs(60)).await;
    assert_eq!(std::fs::metadata(&launchd).unwrap().permissions().mode() & 0o777, 0o600);
}

// ---- several B devices (multi-client plan, Task 4) ----

/// A direct LAN connection that calls itself `name`.
async fn b_named(ep: &quinn::Endpoint, a: &TestService, name: &str) -> quinn::Connection {
    let (conn, r) = direct(ep, a_addr(&a.svc), json!({"op":"auth","password":PASSWORD,"name":name})).await;
    assert_eq!(r["ok"], true, "{r}");
    conn
}

/// Opens `app` and pushes the worker token plus a line through it.
async fn open_app(conn: &quinn::Connection, app: &str) -> rapp_net::quic::BiStream {
    let mut s = bi(conn.open_bi().await.unwrap());
    write_json(&mut s, &json!({"op":"open","app":app})).await.unwrap();
    let r = read_json(&mut s).await.unwrap();
    assert_eq!(r["ok"], true, "{r}");
    echo_through(&mut s, r["token"].as_str().unwrap()).await;
    s
}

/// Sends one line to the (fake) worker and reads its echo.
async fn say(s: &mut rapp_net::quic::BiStream, line: &str) {
    let sent = format!("{line}\n");
    s.write_all(sent.as_bytes()).await.unwrap();
    let mut back = vec![0; sent.len()];
    tokio::time::timeout(WAIT, s.read_exact(&mut back)).await.expect("echo").unwrap();
    assert_eq!(back, sent.as_bytes());
}

/// The worker stdin lines the fake host logged for `app`, parsed.
fn stdin_lines(bins: &std::path::Path, app: &str) -> Vec<Value> {
    let prefix = format!("stdin {app} ");
    host_log(bins).lines().filter_map(|l| l.strip_prefix(&prefix)).map(|l| serde_json::from_str(l).unwrap()).collect()
}

async fn wait_until(what: &str, f: impl Fn() -> bool) {
    let deadline = tokio::time::Instant::now() + WAIT;
    while !f() {
        assert!(tokio::time::Instant::now() < deadline, "timed out waiting for {what}");
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
}

#[tokio::test]
async fn takeover_logs_the_old_session_as_taken_over_by_the_new_device() {
    let a = service(None).await;
    let home = a.home.path();
    let ep = b_endpoint();
    let (one, two) = (b_named(&ep, &a, "b-one").await, b_named(&ep, &a, "b-two").await);
    let mut s1 = open_app(&one, "com.example.echo").await;
    let first_sid = wait_log(home, "session_start", |v| v["name"] == "b-one").await["sid"].clone();
    let _s2 = open_app(&two, "com.example.echo").await;
    let second_sid = wait_log(home, "session_start", |v| v["name"] == "b-two").await["sid"].clone();
    // The worker heard each device's name before that device got its `ok`.
    let peers = stdin_lines(a.bins.path(), "com.example.echo");
    let names: Vec<&Value> = peers.iter().filter(|v| v["cmd"] == "peer").map(|v| &v["name"]).collect();
    assert_eq!(names, [&json!("b-one"), &json!("b-two")], "{peers:?}");
    assert!(peers.iter().all(|v| v["port"].as_u64().is_some_and(|p| p > 0)), "{peers:?}");

    // The worker closed the old connection; old B sees EOF and closes its side, as a real B does.
    let mut rest = Vec::new();
    tokio::time::timeout(WAIT, s1.read_to_end(&mut rest)).await.expect("old session ended").unwrap();
    s1.writer_mut().finish().unwrap();
    let end = wait_log(home, "session_end", |v| v["sid"] == first_sid).await;
    assert_eq!((&end["reason"], &end["by"], &end["name"]), (&json!("taken over"), &json!("b-two"), &json!("b-one")));
    let start = wait_log(home, "session_start", |v| v["sid"] == second_sid).await;
    assert_eq!(start["name"], "b-two");
    let h = ipc_once(&a.svc, home, json!({"cmd":"history","limit":10})).await;
    let evs = h["events"].as_array().unwrap();
    assert!(evs.iter().any(|e| e["ev"] == "session_end" && e["sid"] == first_sid && e["reason"] == "taken over"), "{h}");
}

#[tokio::test]
async fn takeover_is_recorded_even_when_old_b_resets_its_stream() {
    let a = service(None).await;
    let home = a.home.path();
    let ep = b_endpoint();
    let (one, two) = (b_named(&ep, &a, "b-one").await, b_named(&ep, &a, "b-two").await);
    let mut s1 = open_app(&one, "com.example.echo").await;
    let first_sid = wait_log(home, "session_start", |v| v["name"] == "b-one").await["sid"].clone();
    let _s2 = open_app(&two, "com.example.echo").await;
    // Old B is still sending when the worker drops it: it resets instead of finishing.
    s1.writer_mut().reset(0u32.into()).unwrap();
    s1.reader_mut().stop(0u32.into()).unwrap();
    let end = wait_log(home, "session_end", |v| v["sid"] == first_sid).await;
    assert_eq!((&end["reason"], &end["by"]), (&json!("taken over"), &json!("b-two")), "{end}");
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert_eq!(log_events(home).iter().filter(|e| e["ev"] == "session_end").count(), 1);
}

#[tokio::test]
async fn input_on_one_app_tells_other_apps_to_yield() {
    let a = service(None).await;
    let ep = b_endpoint();
    let (one, two) = (b_named(&ep, &a, "b-one").await, b_named(&ep, &a, "b-two").await);
    let mut echo = open_app(&one, "com.example.echo").await;
    let _safari = open_app(&two, "com.apple.Safari").await;
    let want = json!({"cmd":"yield","by":"b-one"});
    let yields = || stdin_lines(a.bins.path(), "com.apple.Safari").into_iter().filter(|v| *v == want).count();
    say(&mut echo, "input").await;
    wait_until("first yield", || yields() == 1).await;
    tokio::time::sleep(Duration::from_millis(600)).await;
    say(&mut echo, "input").await;
    wait_until("second yield", || yields() == 2).await;
    // Whole line as serde_json writes it.
    let line = format!("stdin com.apple.Safari {want}");
    assert_eq!(host_log(a.bins.path()).lines().filter(|l| *l == line).count(), 2);
    assert!(stdin_lines(a.bins.path(), "com.example.echo").iter().all(|v| v["cmd"] != "yield"));
}

#[tokio::test]
async fn same_device_does_not_yield_to_itself() {
    let a = service(None).await;
    let ep = b_endpoint();
    let one = b_named(&ep, &a, "b-one").await;
    let mut echo = open_app(&one, "com.example.echo").await;
    let _safari = open_app(&one, "com.apple.Safari").await;
    say(&mut echo, "input").await;
    tokio::time::sleep(Duration::from_millis(500)).await;
    let log = host_log(a.bins.path());
    assert!(log.contains("stdin com.apple.Safari"), "{log}");
    assert!(!log.contains(r#""cmd":"yield""#), "{log}");
}

#[tokio::test]
async fn input_blocked_is_logged_once_a_minute_without_content() {
    let a = service(None).await;
    let home = a.home.path();
    let ep = b_endpoint();
    let one = b_named(&ep, &a, "b-one").await;
    let mut s = open_app(&one, "com.example.echo").await;
    let sid = wait_log(home, "session_start", |_| true).await["sid"].clone();
    say(&mut s, "blocked b-two").await;
    say(&mut s, "blocked b-two").await;
    let v = wait_log(home, "input_blocked", |_| true).await;
    let mut keys: Vec<&str> =
        v.as_object().unwrap().keys().map(String::as_str).filter(|k| !["ts", "lvl", "ev"].contains(k)).collect();
    keys.sort();
    assert_eq!(keys, ["app", "by", "sid"], "{v}");
    assert_eq!((&v["app"], &v["sid"], &v["by"]), (&json!("com.example.echo"), &sid, &json!("b-two")));
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert_eq!(log_events(home).iter().filter(|e| e["ev"] == "input_blocked").count(), 1);
    let h = ipc_once(&a.svc, home, json!({"cmd":"history","limit":10})).await;
    assert!(h["events"].as_array().unwrap().iter().any(|e| e["ev"] == "input_blocked"), "{h}");
}
