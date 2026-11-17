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
async fn unknown_host_is_an_error() {
    let home = tempfile::tempdir().unwrap();
    let bins = bins();
    let mut hub = Hub::start(home.path(), bins.path());
    let r = hub.call(json!({"cmd":"logs","id":"999999999","req":2})).await;
    assert_eq!(r["event"], "error", "{r}");
    assert_eq!(r["req"], 2);
    assert!(r["error"].as_str().is_some_and(|e| !e.is_empty()), "{r}");
}

#[tokio::test]
async fn no_log_dir_is_an_error() {
    let home = tempfile::tempdir().unwrap();
    let bins = bins();
    let mut hub = Hub::start_without_log_dir(home.path(), bins.path());
    let r = hub.call(json!({"cmd":"logs","req":3})).await;
    assert_eq!((&r["event"], &r["error"], &r["req"]), (&json!("error"), &json!("no log dir"), &json!(3)), "{r}");
}

#[tokio::test]
async fn bad_query_and_bad_id_are_errors() {
    let home = tempfile::tempdir().unwrap();
    let logs = tempfile::tempdir().unwrap();
    lines(logs.path(), "hub.log", &["x_m"]);
    let bins = bins();
    let mut hub = Hub::start_reading_logs(home.path(), bins.path(), logs.path());
    let r = hub.call(json!({"cmd":"logs","limit":"bad"})).await;
    assert_eq!(r["event"], "error", "{r}");
    // A non-string id never falls back to this device's logs.
    let r = hub.call(json!({"cmd":"logs","id":123})).await;
    assert_eq!(r["event"], "error", "{r}");
    // The hub is still serving.
    assert_eq!(hub.call(json!({"cmd":"logs"})).await["event"], "logs");
}

#[tokio::test]
async fn no_secrets_in_logs_reply() {
    let a = service().await;
    lines(&a.home.path().join("logs"), "service.log", &["svc_m"]);
    let home = tempfile::tempdir().unwrap();
    // The hub's own relay key: it must never show up in a logs reply.
    let key = rapp_wire::Key::new_local().to_string();
    rapp_net::config::write_json(&home.path().join("service.json"), &json!({"key": key})).unwrap();
    lines(&home.path().join("logs"), "hub.log", &["hub_m"]);
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
        assert!(!r["events"].as_array().unwrap().is_empty(), "{r}");
        assert!(!text.contains(PASSWORD), "{text}");
        assert!(!text.contains(&key), "{text}");
    }
}

/// A `repeat` written after the newest row reaches the GUI as `again`, from
/// this device and through a peer (the hub passes only known reply keys).
#[tokio::test]
async fn a_grown_repeat_comes_back_as_again() {
    let a = service().await;
    let home = tempfile::tempdir().unwrap();
    let logs = tempfile::tempdir().unwrap();
    let mut local = Hub::start_reading_logs(home.path(), a.bins.path(), logs.path());
    let home2 = tempfile::tempdir().unwrap();
    let mut hub = Hub::start(home2.path(), a.bins.path());
    hub.call(json!({"cmd":"add_host","id":host_at(&a),"password":PASSWORD,"req":1})).await;
    // `src: hub` keeps the service's own lines out of the peer's reply.
    let cases = [(&mut local, logs.path().to_owned(), json!(null)), (&mut hub, a.home.path().join("logs"), json!(a.id))];
    for (h, dir, id) in cases {
        lines(&dir, "hub.log", &["first_m", "again_m"]);
        let mut q = json!({"cmd":"logs","src":["hub"]});
        if !id.is_null() {
            q["id"] = id.clone();
        }
        let r = h.call(q.clone()).await;
        assert_eq!(r["event"], "logs", "{r}");
        let row = r["events"][0].clone();
        assert!(row["raw"].as_str().unwrap().contains("again_m"), "{r}");
        let rep = json!({"ts":at(1),"lvl":"info","ev":"repeat","repeat":5});
        let mut f = std::fs::OpenOptions::new().append(true).open(dir.join("hub.log")).unwrap();
        std::io::Write::write_all(&mut f, format!("{rep}\n").as_bytes()).unwrap();
        q["after"] = r["newer"].clone();
        let r2 = h.call(q.clone()).await;
        assert_eq!(r2["events"], json!([]), "{r2}");
        assert_eq!(r2["again"][0]["at"], row["at"], "{r2}");
        assert_eq!(r2["again"][0]["repeat"], 5, "{r2}");
        // The logger ends a run with `repeat` and the next event in one write.
        let rep = json!({"ts":at(0),"lvl":"info","ev":"repeat","repeat":3});
        let next = json!({"ts":at(0),"lvl":"info","ev":"next_m"});
        std::io::Write::write_all(&mut f, format!("{rep}\n{next}\n").as_bytes()).unwrap();
        q["after"] = r2["newer"].clone();
        let r3 = h.call(q).await;
        assert!(r3["events"][0]["raw"].as_str().unwrap().contains("next_m"), "{r3}");
        assert_eq!(r3["again"][0]["at"], row["at"], "{r3}");
        assert_eq!(r3["again"][0]["repeat"], 8, "{r3}");
    }
}
