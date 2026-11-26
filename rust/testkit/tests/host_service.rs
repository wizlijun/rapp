//! host-core against the real `rapp-service` (plan B, Task 19): with `fake-host-core` linked in
//! as `rapp-host`, the service lists the fake platform's apps through `list-apps --json`, starts a
//! `serve` worker for one of them and gets its `listening` event inside `START_WAIT`, splices B's
//! stream to it (B's hello gets `ready`), and ends it by closing its stdin, which the worker
//! answers with exit code 0.

mod common;

use common::*;
use rapp_client_core::protocol::{decode, Address, Incoming};
use rapp_net::line::{read_json, write_json};
use rapp_net::quic::bi;
use rapp_testkit::fake_platform::{FAKE_APP, FAKE_APP_NAME};
use serde_json::{json, Value};
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};

/// A service whose `rapp-host` is host-core itself; a worker with no sessions is stopped 200 ms
/// after the last one ends.
async fn host_core_service() -> TestService {
    let (home, bins) = (tempfile::tempdir().unwrap(), bins_with_host(env!("CARGO_BIN_EXE_fake-host-core")));
    service_json(home.path());
    let svc = start_service(home.path(), bins.path(), Duration::from_millis(200)).await;
    let id = ipc_once(&svc, home.path(), json!({"cmd":"status"})).await["id"].as_str().unwrap().to_string();
    TestService { svc, home, bins, id }
}

/// Reads one rapp/2 message from the spliced stream: the 5-byte header, then its payload.
async fn next_message(s: &mut rapp_net::quic::BiStream) -> Incoming {
    let mut head = [0u8; 5];
    s.read_exact(&mut head).await.expect("a message header from the worker");
    let n = u32::from_le_bytes(head[1..].try_into().unwrap()) as usize;
    let mut payload = vec![0u8; n];
    s.read_exact(&mut payload).await.expect("the message payload");
    decode(head[0], &payload).unwrap_or_else(|e| panic!("message type {} does not decode: {e:#}", head[0]))
}

#[tokio::test]
async fn service_lists_starts_and_stops_host_core() {
    let a = host_core_service().await;
    let ep = b_endpoint();
    let (conn, r) = direct(&ep, a_addr(&a.svc), json!({"op":"auth","password":PASSWORD,"name":"test-b"})).await;
    assert_eq!(r["ok"], true, "{r}");

    // `list-apps --json`: the desktop entry first, then the fake's one app; its permissions too.
    let r = req(&conn, json!({"op":"list_apps"})).await;
    assert_eq!(r["ok"], true, "{r}");
    let apps = r["apps"].as_array().unwrap_or_else(|| panic!("no apps in {r}"));
    assert_eq!(apps.len(), 2, "{r}");
    assert_eq!(apps[0]["app"], "desktop:", "{r}");
    assert_eq!(apps[1], json!({"app": FAKE_APP, "name": FAKE_APP_NAME}), "{r}");
    assert_eq!(r["permissions"], json!({"screen_recording": true, "accessibility": true}), "{r}");

    // `open` starts `serve --app fake.app ... --json`; the service only answers once the worker
    // said `listening` (within START_WAIT), so `ok` with a token is that event seen.
    let mut s = bi(conn.open_bi().await.unwrap());
    write_json(&mut s, &json!({"op":"open","app":FAKE_APP})).await.unwrap();
    let r: Value = read_json(&mut s).await.unwrap();
    assert_eq!(r["ok"], true, "{r}");
    let token = r["token"].as_str().unwrap_or_else(|| panic!("no token in {r}")).to_string();
    wait_log(a.home.path(), "session_start", |v| v["app"] == FAKE_APP && v["name"] == "test-b").await;

    // The stream now reaches the worker: B's hello with that token is answered with `ready`.
    let address =
        Address { host: "127.0.0.1".to_string(), port: 0, app: FAKE_APP.to_string(), token, mode: 1, fps: 10 };
    s.write_all(&address.hello(1.0)).await.unwrap();
    let ready = tokio::time::timeout(WAIT, async {
        loop {
            if let Incoming::Ready(name, w, h) = next_message(&mut s).await {
                return (name, w, h);
            }
        }
    })
    .await
    .expect("ready from the worker");
    assert!(ready.1 > 0 && ready.2 > 0, "{ready:?}");

    // B leaves: the session ends, the idle worker's stdin is closed, and it exits 0.
    drop(s);
    conn.close(0u32.into(), b"done");
    wait_log(a.home.path(), "session_end", |v| v["app"] == FAKE_APP).await;
    let exit = wait_log(a.home.path(), "worker_exit", |v| v["app"] == FAKE_APP).await;
    assert_eq!(exit["code"], 0, "{exit}");
    assert_eq!(exit["reason"], "stdin closed", "{exit}");
}

#[tokio::test]
async fn an_unknown_app_starts_a_worker_that_refuses_the_hello() {
    let a = host_core_service().await;
    let ep = b_endpoint();
    let (conn, r) = direct(&ep, a_addr(&a.svc), json!({"op":"auth","password":PASSWORD})).await;
    assert_eq!(r["ok"], true, "{r}");
    // Neither the service nor `serve` checks the id up front (Swift's worker does not either):
    // the worker starts, and the session's open is what fails.
    let mut s = bi(conn.open_bi().await.unwrap());
    write_json(&mut s, &json!({"op":"open","app":"no.such.app"})).await.unwrap();
    let r: Value = read_json(&mut s).await.unwrap();
    assert_eq!(r["ok"], true, "{r}");
    let token = r["token"].as_str().unwrap().to_string();
    let address =
        Address { host: "127.0.0.1".to_string(), port: 0, app: "no.such.app".to_string(), token, mode: 1, fps: 10 };
    s.write_all(&address.hello(1.0)).await.unwrap();
    let error = tokio::time::timeout(WAIT, async {
        loop {
            match next_message(&mut s).await {
                Incoming::Error(text) => return text,
                Incoming::Ready(..) => panic!("ready for an app the fake does not have"),
                _ => {}
            }
        }
    })
    .await
    .expect("an error for the hello");
    assert_eq!(error, "no.such.app not found");
}
