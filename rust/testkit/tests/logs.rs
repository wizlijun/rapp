//! The hub's `logs` command: this device from its own log dir, another forwarded as `Op::Logs`.

mod common;

use common::*;
use serde_json::{json, Value};
use std::time::{Duration, SystemTime};

fn at(s: u64) -> String {
    rapp_net::log::timestamp(SystemTime::now() - Duration::from_secs(s))
}

fn lines(dir: &std::path::Path, file: &str, evs: &[&str]) {
    std::fs::create_dir_all(dir).unwrap();
    let body: String = evs
        .iter()
        .enumerate()
        .map(|(i, e)| format!("{}\n", json!({"ts":at(10 - i as u64),"lvl":"info","ev":e})))
        .collect();
    std::fs::write(dir.join(file), body).unwrap();
}

fn raws(r: &Value) -> String {
    r["events"].as_array().unwrap().iter().map(|e| e["raw"].to_string()).collect::<Vec<_>>().join("\n")
}

fn host_at(a: &TestService) -> String {
    format!("{}@{}", a.id, a_addr(&a.svc))
}

#[tokio::test]
async fn local_logs_without_a_service() {
    let home = tempfile::tempdir().unwrap();
    let logs = tempfile::tempdir().unwrap();
    lines(logs.path(), "hub.log", &["one_m", "two_m", "three_m"]);
    let bins = bins();
    let mut hub = Hub::start_reading_logs(home.path(), bins.path(), logs.path());
    let r = hub.call(json!({"cmd":"logs","req":"l"})).await;
    assert_eq!(r["event"], "logs", "{r}");
    assert_eq!(r["req"], "l");
    assert!(r.get("id").is_none(), "{r}");
    assert!(r.get("ok").is_none(), "{r}");
    assert!(r["counts"].is_object(), "{r}");
    let evs = r["events"].as_array().unwrap();
    assert_eq!(evs.len(), 3, "{r}");
    assert!(evs.iter().all(|e| e["src"] == "hub"), "{r}");
    assert!(raws(&r).contains("three_m"));
}

#[tokio::test]
async fn remote_logs_forwarded() {
    let a = service().await;
    lines(&a.home.path().join("logs"), "service.log", &["a_first", "a_second"]);
    let home = tempfile::tempdir().unwrap();
    let mut hub = Hub::start(home.path(), a.bins.path());
    hub.call(json!({"cmd":"add_host","id":host_at(&a),"password":PASSWORD,"req":1})).await;
    let r = hub.call(json!({"cmd":"logs","id":a.id,"limit":500,"req":"r"})).await;
    assert_eq!(r["event"], "logs", "{r}");
    assert_eq!((&r["id"], &r["req"]), (&json!(a.id), &json!("r")));
    assert!(r.get("ok").is_none(), "{r}");
    assert!(raws(&r).contains("a_first") && raws(&r).contains("a_second"), "{r}");
}

#[tokio::test]
async fn unknown_host_and_no_log_dir_are_errors() {
    let home = tempfile::tempdir().unwrap();
    let bins = bins();
    let mut hub = Hub::start(home.path(), bins.path());
    let r = hub.call(json!({"cmd":"logs","id":"999999999","req":2})).await;
    assert_eq!(r["event"], "error", "{r}");
    assert_eq!(r["req"], 2);
}

#[tokio::test]
async fn no_secrets_in_logs_reply() {
    let a = service().await;
    let home = tempfile::tempdir().unwrap();
    let mut hub = Hub::start(home.path(), a.bins.path());
    hub.call(json!({"cmd":"add_host","id":host_at(&a),"password":PASSWORD,"req":1})).await;
    let o = hub.call(json!({"cmd":"open","id":a.id,"app":"com.example.echo"})).await;
    let sid = o["sid"].clone();
    tokio::time::sleep(Duration::from_millis(300)).await;
    hub.send(json!({"cmd":"close","sid":sid})).await;
    hub.next().await;
    for q in [json!({"cmd":"logs","limit":500}), json!({"cmd":"logs","id":a.id,"limit":500})] {
        let r = hub.call(q).await;
        let text = r.to_string();
        assert_eq!(r["event"], "logs", "{r}");
        assert!(!text.contains(PASSWORD), "{text}");
    }
}
