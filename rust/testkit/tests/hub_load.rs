//! rapp-hub's device load: one `watch_load` stream per online device, as `load` events, and the one-shot `load`.

mod common;

use common::*;
use rapp_update::fake::FakeRunner;
use serde_json::{json, Value};
use std::path::Path;
use std::sync::Arc;
use std::time::Duration;

fn at(a: &TestService) -> String {
    format!("{}@{}", a.id, a_addr(&a.svc))
}

async fn presence_hub(a: &TestService, home: &Path) -> Hub {
    let mut hub = Hub::start_with_presence(home, a.bins.path(), Duration::from_millis(200));
    hub.send(json!({"cmd":"add_host","id":at(a),"password":PASSWORD,"req":1})).await;
    next_where(&mut hub, "host_added", |r| r["req"] == 1).await;
    hub
}

async fn next_where(hub: &mut Hub, what: &str, pred: impl Fn(&Value) -> bool) -> Value {
    let deadline = tokio::time::Instant::now() + WAIT;
    loop {
        let r = tokio::time::timeout_at(deadline, hub.next()).await.unwrap_or_else(|_| panic!("no {what} in time"));
        assert_ne!(r["event"], "error", "{r}");
        if pred(&r) {
            return r;
        }
    }
}

async fn pushed_load(hub: &mut Hub) -> Value {
    next_where(hub, "pushed load event", |r| r["event"] == "load" && r.get("req").is_none()).await
}

/// A service whose load sampling is off, as an older device.
async fn old_service() -> TestService {
    let (home, bins) = (tempfile::tempdir().unwrap(), bins());
    service_json(home.path());
    let svc = rapp_service::Service::start(rapp_service::Opts {
        home: home.path().to_path_buf(),
        bin_dir: Some(bins.path().to_path_buf()),
        gui: None,
        lock_grace: Duration::from_secs(1),
        worker_idle: Duration::from_secs(60),
        log_dir: home.path().join("logs"),
        runner: Arc::new(FakeRunner::new()),
        update: None,
        data: None,
        advertise_lan: None,
        forward_sum_every: Duration::from_secs(600),
        forward_priority: rapp_conn::relay::FORWARD_PRIORITY,
        channels: true,
        pacing: true,
        map_ports: TEST_PORTS,
        own_ports: true,
        load: None,
    })
    .await
    .unwrap();
    let id = ipc_once(&svc, home.path(), json!({"cmd":"status"})).await["id"].as_str().unwrap().to_string();
    TestService { svc, home, bins, id }
}

#[tokio::test]
async fn hub_streams_load_events() {
    let a = service().await;
    let home = tempfile::tempdir().unwrap();
    let mut hub = presence_hub(&a, home.path()).await;
    let first = pushed_load(&mut hub).await;
    assert_eq!(first["id"], json!(a.id), "{first}");
    assert!(first["history"].is_array(), "{first}");
    let next = pushed_load(&mut hub).await;
    assert!(next["point"].is_object() && next.get("history").is_none(), "{next}");
    hub.finish().await;
}

#[tokio::test]
async fn offline_host_load_is_gone() {
    let a = service().await;
    let home = tempfile::tempdir().unwrap();
    let mut hub = presence_hub(&a, home.path()).await;
    pushed_load(&mut hub).await;
    a.svc.stop();
    let gone = next_where(&mut hub, "gone", |r| r["event"] == "load" && r["gone"] == true).await;
    assert_eq!(gone, json!({"event":"load","id":a.id,"gone":true}));
    hub.finish().await;
}

#[tokio::test]
async fn old_host_is_unsupported_once() {
    let a = old_service().await;
    let home = tempfile::tempdir().unwrap();
    let mut hub = presence_hub(&a, home.path()).await;
    let deadline = tokio::time::Instant::now() + Duration::from_secs(3);
    let mut seen = Vec::new();
    while let Ok(r) = tokio::time::timeout_at(deadline, hub.next()).await {
        seen.push(r);
    }
    let unsupported: Vec<_> = seen.iter().filter(|r| r["event"] == "load" && r["unsupported"] == true).collect();
    assert_eq!(unsupported.len(), 1, "{seen:?}");
    assert_eq!(unsupported[0]["id"], json!(a.id));
    // The service does not log an `unknown op` request, so a second ask shows as a second `unsupported` event.
    hub.finish().await;
}

#[tokio::test]
async fn load_cmd_answers_one_shot() {
    let a = service().await;
    let home = tempfile::tempdir().unwrap();
    let mut hub = Hub::start(home.path(), a.bins.path());
    let r = hub.call(json!({"cmd":"add_host","id":at(&a),"password":PASSWORD,"req":1})).await;
    assert_eq!(r["event"], "host_added");
    let deadline = tokio::time::Instant::now() + WAIT;
    let r = loop {
        let r = hub.call(json!({"cmd":"load","id":a.id,"req":2})).await;
        if r["event"] == "load" {
            break r;
        }
        assert!(tokio::time::Instant::now() < deadline, "{r}");
        tokio::time::sleep(Duration::from_millis(50)).await;
    };
    assert_eq!((&r["req"], &r["id"]), (&json!(2), &json!(a.id)), "{r}");
    assert!(r.get("headroom").is_some(), "{r}");
    hub.finish().await;
}
