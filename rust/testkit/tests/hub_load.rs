//! rapp-hub's device load: one `watch_load` stream per online device, as `load` events, and the one-shot `load`.

mod common;

use common::*;
use rapp_net::line::MAX_LINE;
use rapp_service::load::{Cpu, Heat, HeatLevel, Mem, Sample, Sampler, KEEP};
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

/// A service like `old_service`, with `load` as given.
async fn service_with_load(load: Option<rapp_service::LoadOpts>) -> TestService {
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
        load,
    })
    .await
    .unwrap();
    let id = ipc_once(&svc, home.path(), json!({"cmd":"status"})).await["id"].as_str().unwrap().to_string();
    TestService { svc, home, bins, id }
}

/// A service whose load sampling is off, as an older device.
async fn old_service() -> TestService {
    service_with_load(None).await
}

/// A sampler whose every point is as long as `point()` can write it, every 5 ms, so the
/// history is full (KEEP points) within seconds. The service fills `disks` itself.
fn wide_load() -> rapp_service::LoadOpts {
    struct Wide;
    impl Sampler for Wide {
        fn sample(&mut self) -> Sample {
            let at = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map_or(0, |d| d.as_secs());
            Sample {
                at,
                cpu: Some(Cpu {
                    pct: 0.1,
                    cores: 8,
                    load1: None,
                }),
                gpu: Some(0.1),
                mem: Some(Mem {
                    total: 9_876_543_211,
                    avail: 1_234_567_891,
                    swap_used: None,
                    pressure: None,
                }),
                heat: Some(Heat {
                    level: HeatLevel::Critical,
                    celsius: None,
                }),
                ..Default::default()
            }
        }
    }
    rapp_service::LoadOpts {
        every: Duration::from_millis(5),
        sampler: Arc::new(|| Box::new(Wide)),
        disk_wait: Duration::from_secs(2),
    }
}

#[tokio::test]
async fn watch_load_reply_reads_past_64k() {
    let a = service_with_load(Some(wide_load())).await;
    // Wait for the service to hold KEEP points, and check this line really is over 64 KiB.
    let deadline = tokio::time::Instant::now() + Duration::from_secs(30);
    let r = loop {
        let r = ipc_once(&a.svc, a.home.path(), json!({"cmd":"load","history":true})).await;
        if r["history"].as_array().map_or(0, |h| h.len()) == KEEP {
            break r;
        }
        assert!(
            tokio::time::Instant::now() < deadline,
            "history never filled: {}",
            r["history"].as_array().map_or(0, |h| h.len())
        );
        tokio::time::sleep(Duration::from_millis(50)).await;
    };
    assert!(serde_json::to_vec(&r["history"]).unwrap().len() > MAX_LINE);
    let home = tempfile::tempdir().unwrap();
    let mut hub = presence_hub(&a, home.path()).await;
    let first = pushed_load(&mut hub).await;
    assert_eq!(
        first["history"].as_array().map(|h| h.len()),
        Some(KEEP),
        "{first}"
    );
    let next = pushed_load(&mut hub).await;
    assert!(next["point"].is_object(), "{next}");
    hub.finish().await;
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
