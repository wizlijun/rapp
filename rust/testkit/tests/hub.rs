//! rapp-hub (spec §2.4, §4) driven over its stdin/stdout JSON lines against a real
//! relay and service with fake workers.

mod common;

use common::*;
use serde_json::{json, Value};
use std::time::Duration;

fn apps() -> Value {
    json!([{"app":"com.example.echo","name":"Echo"},{"app":"com.apple.Safari","name":"Safari"}])
}

/// Adds A's host to a fresh hub; returns the hub.
async fn hub_with_host(
    a: &TestService,
    relay: &TestRelay,
    home: &std::path::Path,
    force: Option<&str>,
) -> Hub {
    let mut hub = Hub::start(home, a.bins.path(), Some(relay.relay.addr), force);
    let r = hub.call(json!({"cmd":"add_host","id":a.id,"password":PASSWORD,"req":1})).await;
    assert_eq!(r, json!({"event":"host_added","id":a.id,"name":"test-a","req":1}));
    hub
}

/// open → opened (bytes pass both ways, the fake client checks the echo) → close → closed.
async fn open_and_close(hub: &mut Hub, id: &str, path: &str) {
    let r = hub.call(json!({"cmd":"open","id":id,"app":"com.example.echo","req":"o"})).await;
    assert_eq!(r["event"], "opened", "{r}");
    assert_eq!((&r["id"], &r["app"], &r["path"], &r["req"]), (&json!(id), &json!("com.example.echo"), &json!(path), &json!("o")));
    let sid = r["sid"].clone();
    // Give the fake client time to finish its ping/echo before closing its stdin.
    tokio::time::sleep(Duration::from_millis(300)).await;
    hub.send(json!({"cmd":"close","sid":sid})).await;
    assert_eq!(hub.next().await, json!({"event":"closed","sid":sid,"reason":"echo ok"}));
}

#[tokio::test]
async fn add_host_hosts_apps_open_close_remove() {
    let relay = relay(Duration::from_secs(60));
    let a = service(Some(relay.relay.addr)).await;
    let home = tempfile::tempdir().unwrap();
    let mut hub = hub_with_host(&a, &relay, home.path(), None).await;

    let saved: Value = serde_json::from_slice(&std::fs::read(home.path().join("hosts.json")).unwrap()).unwrap();
    assert_eq!(saved[0]["id"], a.id.as_str());
    assert_eq!(saved[0]["password"], PASSWORD);
    assert!(saved[0]["lan"].as_array().unwrap().iter().any(|l| l == &json!(a_addr(&a.svc).to_string())));
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mode = std::fs::metadata(home.path().join("hosts.json")).unwrap().permissions().mode();
        assert_eq!(mode & 0o777, 0o600);
    }

    assert_eq!(hub.call(json!({"cmd":"hosts"})).await, json!({"event":"hosts","hosts":[{"id":a.id,"name":"test-a"}]}));
    let r = hub.call(json!({"cmd":"apps","id":a.id,"req":"x"})).await;
    assert_eq!(r, json!({"event":"apps","id":a.id,"path":"lan","apps":apps(),"req":"x"}));

    open_and_close(&mut hub, &a.id, "lan").await;
    // A's side of the session ends too.
    let deadline = tokio::time::Instant::now() + WAIT;
    loop {
        let st = ipc_once(&a.svc, a.home.path(), json!({"cmd":"status"})).await;
        if st["sessions"] == json!([]) {
            break;
        }
        assert!(tokio::time::Instant::now() < deadline, "A session never ended: {st}");
        tokio::time::sleep(Duration::from_millis(20)).await;
    }

    let r = hub.call(json!({"cmd":"close","sid":999,"req":2})).await;
    assert_eq!(r, json!({"event":"error","req":2,"error":"unknown sid"}));
    assert_eq!(hub.call(json!({"cmd":"remove_host","id":a.id})).await, json!({"event":"hosts","hosts":[]}));
    let r = hub.call(json!({"cmd":"apps","id":a.id})).await;
    assert_eq!(r, json!({"event":"error","error":"unknown host"}));
    assert_eq!(hub.finish().await, Vec::<Value>::new());
}

#[tokio::test]
async fn forced_relay_path_end_to_end() {
    let relay = relay(Duration::from_secs(60));
    let a = service(Some(relay.relay.addr)).await;
    let home = tempfile::tempdir().unwrap();
    let mut hub = hub_with_host(&a, &relay, home.path(), Some("relay")).await;
    let r = hub.call(json!({"cmd":"apps","id":a.id})).await;
    assert_eq!((&r["path"], &r["apps"]), (&json!("relay"), &apps()), "{r}");
    open_and_close(&mut hub, &a.id, "relay").await;
    assert_eq!(hub.finish().await, Vec::<Value>::new());
}

#[tokio::test]
async fn forced_direct_path_uses_public_address() {
    let relay = relay(Duration::from_secs(60));
    let a = service(Some(relay.relay.addr)).await;
    let home = tempfile::tempdir().unwrap();
    let mut hub = hub_with_host(&a, &relay, home.path(), Some("direct")).await;
    let r = hub.call(json!({"cmd":"apps","id":a.id})).await;
    assert_eq!((&r["path"], &r["apps"]), (&json!("direct"), &apps()), "{r}");
    hub.finish().await;
}

#[tokio::test]
async fn add_host_by_id_at_ip_without_any_relay() {
    let a = service(None).await;
    let home = tempfile::tempdir().unwrap();
    let mut hub = Hub::start(home.path(), a.bins.path(), None, None);
    let at = format!("{}@{}", a.id, a_addr(&a.svc));

    let r = hub.call(json!({"cmd":"add_host","id":format!("987654321@{}", a_addr(&a.svc)),"password":PASSWORD,"req":1})).await;
    assert_eq!(r["event"], "error", "a different ID at that address is refused: {r}");
    let r = hub.call(json!({"cmd":"add_host","id":at,"password":"wrong","req":2})).await;
    assert_eq!(r["event"], "error", "{r}");
    assert!(!home.path().join("hosts.json").exists());

    let r = hub.call(json!({"cmd":"add_host","id":at,"password":PASSWORD,"req":3})).await;
    assert_eq!(r, json!({"event":"host_added","id":a.id,"name":"test-a","req":3}));
    let saved: Value = serde_json::from_slice(&std::fs::read(home.path().join("hosts.json")).unwrap()).unwrap();
    assert_eq!(saved[0]["lan"], json!([a_addr(&a.svc).to_string()]));
    let r = hub.call(json!({"cmd":"apps","id":a.id})).await;
    assert_eq!((&r["path"], &r["apps"]), (&json!("lan"), &apps()), "{r}");
    open_and_close(&mut hub, &a.id, "lan").await;
    hub.finish().await;
}

#[tokio::test]
async fn id_at_ip_host_still_works_when_the_relay_does_not_know_it() {
    // B has a relay; A never registered there. The relay says "unknown id", B falls back to LAN.
    let relay = relay(Duration::from_secs(60));
    let a = service(None).await;
    let home = tempfile::tempdir().unwrap();
    let mut hub = Hub::start(home.path(), a.bins.path(), Some(relay.relay.addr), None);
    let at = format!("{}@{}", a.id, a_addr(&a.svc));
    let r = hub.call(json!({"cmd":"add_host","id":at,"password":PASSWORD})).await;
    assert_eq!(r["event"], "host_added", "{r}");
    let r = hub.call(json!({"cmd":"apps","id":a.id})).await;
    assert_eq!(r["path"], "lan", "{r}");
    hub.finish().await;
}

#[tokio::test]
async fn add_host_errors_are_reported_and_nothing_saved() {
    let relay = relay(Duration::from_secs(60));
    let a = service(Some(relay.relay.addr)).await;
    let home = tempfile::tempdir().unwrap();
    let mut hub = Hub::start(home.path(), a.bins.path(), Some(relay.relay.addr), None);
    let r = hub.call(json!({"cmd":"add_host","id":a.id,"password":"wrong","req":7})).await;
    assert_eq!(r, json!({"event":"error","req":7,"error":"bad password"}));
    let r = hub.call(json!({"cmd":"add_host","id":"123456789","password":"x"})).await;
    assert_eq!(r, json!({"event":"error","error":"unknown id"}));
    assert_eq!(hub.call(json!({"cmd":"hosts"})).await, json!({"event":"hosts","hosts":[]}));
    assert!(!home.path().join("hosts.json").exists());
    assert_eq!(hub.call(json!({"cmd":"nope","req":1})).await, json!({"event":"error","req":1,"error":"unknown cmd"}));
    hub.send(json!("garbage")).await;
    assert_eq!(hub.next().await["event"], "error");
    hub.finish().await;
}

#[tokio::test]
async fn expired_relay_token_triggers_fresh_connect() {
    let relay = relay(Duration::from_millis(300));
    let a = service(Some(relay.relay.addr)).await;
    let home = tempfile::tempdir().unwrap();
    let mut hub = hub_with_host(&a, &relay, home.path(), Some("relay")).await;
    assert_eq!(hub.call(json!({"cmd":"apps","id":a.id})).await["path"], "relay");
    tokio::time::sleep(Duration::from_millis(500)).await;
    let r = hub.call(json!({"cmd":"apps","id":a.id})).await;
    assert_eq!((&r["path"], &r["apps"]), (&json!("relay"), &apps()), "{r}");
    hub.finish().await;
}

#[tokio::test]
async fn restarted_service_rejects_cached_token_and_hub_reconnects() {
    let relay = relay(Duration::from_secs(60));
    let mut a = service(Some(relay.relay.addr)).await;
    let home = tempfile::tempdir().unwrap();
    let mut hub = hub_with_host(&a, &relay, home.path(), Some("direct")).await;
    assert_eq!(hub.call(json!({"cmd":"apps","id":a.id})).await["path"], "direct");
    // Restart A on a new port: the cached connection dies and its token is gone.
    a.svc.stop();
    a.svc = start_service(a.home.path(), a.bins.path(), Duration::from_secs(60)).await;
    assert_eq!(wait_registered(&a.svc, a.home.path()).await, a.id);
    let r = hub.call(json!({"cmd":"apps","id":a.id})).await;
    assert_eq!((&r["path"], &r["apps"]), (&json!("direct"), &apps()), "{r}");
    hub.finish().await;
}

#[tokio::test]
async fn lan_password_fallback_when_relay_is_down() {
    let relay = relay(Duration::from_secs(60));
    let a = service(Some(relay.relay.addr)).await;
    let home = tempfile::tempdir().unwrap();
    let hub = hub_with_host(&a, &relay, home.path(), None).await;
    hub.finish().await;
    relay.relay.stop();

    let mut hub = Hub::start(home.path(), a.bins.path(), None, None);
    let r = hub.call(json!({"cmd":"apps","id":a.id})).await;
    assert_eq!((&r["path"], &r["apps"]), (&json!("lan"), &apps()), "{r}");
    open_and_close(&mut hub, &a.id, "lan").await;
    assert_eq!(hub.finish().await, Vec::<Value>::new());
}

#[tokio::test]
async fn relay_not_configured_falls_back_to_lan() {
    let relay = relay(Duration::from_secs(60));
    let a = service(Some(relay.relay.addr)).await;
    let home = tempfile::tempdir().unwrap();
    hub_with_host(&a, &relay, home.path(), None).await.finish().await;
    service_json(home.path(), None);
    let mut hub = Hub::start(home.path(), a.bins.path(), None, Some("lan"));
    assert_eq!(hub.call(json!({"cmd":"apps","id":a.id})).await["path"], "lan");
    hub.finish().await;
}

#[tokio::test]
async fn stdin_eof_closes_open_sessions() {
    let relay = relay(Duration::from_secs(60));
    let a = service(Some(relay.relay.addr)).await;
    let home = tempfile::tempdir().unwrap();
    let mut hub = hub_with_host(&a, &relay, home.path(), None).await;
    let r = hub.call(json!({"cmd":"open","id":a.id,"app":"com.example.echo"})).await;
    assert_eq!(r["event"], "opened", "{r}");
    tokio::time::sleep(Duration::from_millis(300)).await;
    let rest = hub.finish().await;
    assert_eq!(rest, vec![json!({"event":"closed","sid":r["sid"],"reason":"echo ok"})]);
}

#[tokio::test]
async fn open_unknown_app_worker_failure_is_an_error() {
    let relay = relay(Duration::from_secs(60));
    let a = service(Some(relay.relay.addr)).await;
    let home = tempfile::tempdir().unwrap();
    let mut hub = hub_with_host(&a, &relay, home.path(), None).await;
    // No rapp-client in this bin dir: the hub reports it.
    let empty = tempfile::tempdir().unwrap();
    let mut hub2 = Hub::start(home.path(), empty.path(), Some(relay.relay.addr), None);
    let r = hub2.call(json!({"cmd":"open","id":a.id,"app":"com.example.echo","req":3})).await;
    assert_eq!(r["event"], "error", "{r}");
    assert_eq!(r["req"], 3);
    hub2.finish().await;
    assert_eq!(hub.call(json!({"cmd":"apps","id":"000"})).await["error"], "unknown host");
    hub.finish().await;
}
