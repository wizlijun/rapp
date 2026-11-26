//! Session labels (spec `2026-11-26-rapp-session-labels-design.md`): kept by the device's service, pushed to every
//! hub watching it, changed by any of them or by the device's own GUI over IPC.

mod common;

use common::*;
use serde_json::{json, Value};
use std::path::Path;
use std::time::Duration;

fn at(a: &TestService) -> String {
    format!("{}@{}", a.id, a_addr(&a.svc))
}

/// A hub probing every 200 ms, with A's host added.
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
        if pred(&r) {
            return r;
        }
    }
}

/// The next pushed `labels` table whose entry for `app` `pred` accepts (Null: none).
async fn labels_where(hub: &mut Hub, app: &str, pred: impl Fn(&Value) -> bool) -> Value {
    next_where(hub, "labels event", |r| r["event"] == "labels" && r.get("labels").is_some() && pred(&r["labels"][app])).await
}

#[tokio::test]
async fn two_clients_see_one_label() {
    let a = service().await;
    let (h1, h2) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
    let mut one = presence_hub(&a, h1.path()).await;
    let mut two = presence_hub(&a, h2.path()).await;
    // Both watches are up with the empty table.
    labels_where(&mut one, "term:pty:k", Value::is_null).await;
    labels_where(&mut two, "term:pty:k", Value::is_null).await;

    let set = json!({"cmd":"set_label","id":a.id,"app":"term:pty:k","title":"后端 API","note":"改 hub","req":7});
    one.send(set).await;
    let r = next_where(&mut one, "label_set", |r| r["req"] == 7).await;
    assert_eq!((&r["event"], &r["app"], &r["rev"]), (&json!("label_set"), &json!("term:pty:k"), &json!(1)), "{r}");
    let pushed = labels_where(&mut two, "term:pty:k", |l| l["title"] == "后端 API").await;
    assert_eq!((&pushed["id"], &pushed["rev"], &pushed["labels"]["term:pty:k"]["note"]), (&json!(a.id), &json!(1), &json!("改 hub")));

    // The device's own GUI sees it too, and its reset reaches both hubs.
    let mut ipc = Ipc::open(&a.svc, a.home.path()).await;
    assert_eq!(ipc.call(json!({"cmd":"labels"})).await["labels"]["term:pty:k"]["title"], "后端 API");
    assert_eq!(ipc.call(json!({"cmd":"reset_label","app":"term:pty:k"})).await, json!({"ok":true,"rev":2}));
    labels_where(&mut one, "term:pty:k", Value::is_null).await;
    labels_where(&mut two, "term:pty:k", Value::is_null).await;

    // Nothing of the label is logged.
    let log = std::fs::read_to_string(a.home.path().join("logs").join("service.log")).unwrap();
    assert!(log.contains(r#""op":"set_label""#), "{log}");
    assert!(!log.contains("后端") && !log.contains("改 hub") && !log.contains("term:pty:k"), "{log}");
    one.finish().await;
    two.finish().await;
}

#[tokio::test]
async fn a_bad_title_is_refused_with_why() {
    let a = service().await;
    let h = tempfile::tempdir().unwrap();
    let mut hub = presence_hub(&a, h.path()).await;
    let set = json!({"cmd":"set_label","id":a.id,"app":"a","title":"x".repeat(65),"note":"","req":3});
    hub.send(set).await;
    let r = next_where(&mut hub, "reply", |r| r["req"] == 3).await;
    assert_eq!(r["event"], "error", "{r}");
    assert!(r["error"].as_str().unwrap_or("").contains("标题最多 64 个字"), "{r}");
    hub.finish().await;
}

#[tokio::test]
async fn a_terminal_opened_in_place_of_a_gone_one_takes_its_label() {
    let a = service().await;
    let h = tempfile::tempdir().unwrap();
    let mut hub = presence_hub(&a, h.path()).await;
    let mut ipc = Ipc::open(&a.svc, a.home.path()).await;
    assert_eq!(ipc.call(json!({"cmd":"set_label","app":"term:pty:old","title":"写作","note":""})).await["ok"], true);
    let open = json!({"cmd":"open_term","id":a.id,"app":"Terminal","label_from":"term:pty:old","req":5});
    hub.send(open).await;
    let r = next_where(&mut hub, "term_created", |r| r["req"] == 5).await;
    assert_eq!(r["term"], "term:pty:opened", "{r}");
    let table = ipc.call(json!({"cmd":"labels"})).await;
    assert_eq!(table["labels"]["term:pty:opened"]["title"], "写作", "{table}");
    assert!(table["labels"]["term:pty:old"].is_null(), "{table}");
    labels_where(&mut hub, "term:pty:opened", |l| l["title"] == "写作").await;
    hub.finish().await;
}
