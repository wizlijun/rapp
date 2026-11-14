//! rapp-service's terminal-session requests (spec §6, §8, §9) against the fake `rapp-term`.

mod common;

use common::*;
use quinn::{Connection, Endpoint};
use rapp_net::line::{read_json, write_json};
use rapp_net::quic::{bi, BiStream};
use serde_json::{json, Value};
use std::path::Path;
use tokio::io::AsyncWriteExt;

const OFF: &str = "terminal sessions are off";
const INVALID: &str = "term.json is invalid";

/// B, authenticated (the endpoint must outlive the connection).
async fn b(a: &TestService) -> (Endpoint, Connection) {
    let ep = b_endpoint();
    let (conn, r) = direct(&ep, a_addr(&a.svc), json!({"op":"auth","password":PASSWORD})).await;
    assert_eq!(r["ok"], true, "{r}");
    (ep, conn)
}

fn term_log(bins: &Path) -> Option<String> {
    std::fs::read_to_string(bins.join("term.log")).ok()
}

fn service_log_text(home: &Path) -> String {
    std::fs::read_to_string(home.join("logs/service.log")).unwrap_or_default()
}

fn add(name: &str, target: &str) -> Value {
    json!({"op":"add_term_target","name":name,"target":target})
}

/// The next line on a watch stream, or Null when it ended.
async fn next(s: &mut BiStream) -> Value {
    match tokio::time::timeout(WAIT, read_json(s)).await.expect("a watch line in time") {
        Ok(v) => v,
        Err(_) => Value::Null,
    }
}

async fn watch(conn: &Connection) -> BiStream {
    let mut s = bi(conn.open_bi().await.unwrap());
    write_json(&mut s, &json!({"op":"watch_terms"})).await.unwrap();
    s
}

/// Waits for `term.log` to hold `line`.
async fn wait_term_log(bins: &Path, line: &str) {
    let deadline = tokio::time::Instant::now() + WAIT;
    while !term_log(bins).unwrap_or_default().lines().any(|l| l == line) {
        assert!(tokio::time::Instant::now() < deadline, "no {line:?} in term.log: {:?}", term_log(bins));
        tokio::time::sleep(std::time::Duration::from_millis(20)).await;
    }
}

#[tokio::test]
async fn list_terms_goes_to_one_rapp_term_worker() {
    let a = service().await;
    let (_ep, conn) = b(&a).await;
    for _ in 0..2 {
        let r = req(&conn, json!({"op":"list_terms"})).await;
        assert_eq!(r["ok"], true, "{r}");
        assert_eq!(r["terms"][0]["id"], "term:tmux:work", "{r}");
        assert_eq!(r["hosts"][0], json!({"host":null}), "{r}");
    }
    let config = a.home.path().join("term.json");
    let argv =
        format!("argv serve --bind 127.0.0.1 --port 0 --token-env RAPP_TOKEN --config {} --json", config.display());
    let log = term_log(a.bins.path()).unwrap();
    assert_eq!(log.lines().filter(|l| l.starts_with("argv ")).collect::<Vec<_>>(), [argv.as_str()]);
    wait_log(a.home.path(), "request", |v| v["op"] == "list_terms" && v["result"] == "ok").await;
}

#[tokio::test]
async fn with_terminals_off_nothing_starts() {
    let a = service().await;
    std::fs::write(a.home.path().join("term.json"), r#"{"allow":false}"#).unwrap();
    let (_ep, conn) = b(&a).await;
    for op in [
        json!({"op":"list_terms"}),
        json!({"op":"watch_terms"}),
        json!({"op":"new_term","command":["bash"],"cols":80,"rows":24}),
        add("gpu1", "me@gpu1"),
        json!({"op":"remove_term_target","name":"gpu1"}),
    ] {
        assert_eq!(req(&conn, op.clone()).await, json!({"ok":false,"error":OFF}), "{op}");
    }
    assert_eq!(term_log(a.bins.path()), None);
    assert_eq!(std::fs::read_to_string(a.home.path().join("term.json")).unwrap(), r#"{"allow":false}"#);
    assert_eq!(req(&conn, json!({"op":"list_apps"})).await["ok"], true);
}

#[tokio::test]
async fn a_broken_term_json_is_reported_and_left_alone() {
    let a = service().await;
    let path = a.home.path().join("term.json");
    std::fs::write(&path, "{not json").unwrap();
    let (_ep, conn) = b(&a).await;
    for op in [json!({"op":"list_terms"}), add("gpu1", "me@gpu1")] {
        assert_eq!(req(&conn, op.clone()).await, json!({"ok":false,"error":INVALID}), "{op}");
    }
    assert_eq!(std::fs::read(&path).unwrap(), b"{not json");
    assert_eq!(term_log(a.bins.path()), None);
    assert!(!service_log_text(a.home.path()).contains("not json"));
}

#[tokio::test]
async fn targets_are_added_checked_and_removed() {
    let a = service().await;
    let path = a.home.path().join("term.json");
    let (_ep, conn) = b(&a).await;
    let gpu1 = json!({"name":"gpu1","target":"me@gpu1","tmux":"/opt/homebrew/bin/tmux"});
    let mut op = add("gpu1", "me@gpu1");
    op["tmux"] = json!("/opt/homebrew/bin/tmux");
    assert_eq!(req(&conn, op.clone()).await, json!({"ok":true,"targets":[gpu1]}));
    use std::os::unix::fs::PermissionsExt;
    assert_eq!(std::fs::metadata(&path).unwrap().permissions().mode() & 0o777, 0o600);
    let file: Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
    assert_eq!(file["targets"], json!([gpu1]));
    assert_eq!(file["allow"], true);

    assert_eq!(req(&conn, op).await, json!({"ok":false,"error":"name is taken"}));
    let r = req(&conn, add("evil", "-oProxyCommand=x")).await;
    assert_eq!(r, json!({"ok":false,"error":"invalid ssh target"}));
    let text = std::fs::read_to_string(&path).unwrap();
    assert!(!text.contains("ProxyCommand") && !text.contains("evil"), "{text}");
    assert!(!service_log_text(a.home.path()).contains("ProxyCommand"));

    for i in 2..=32 {
        let r = req(&conn, add(&format!("h{i}"), "me@h")).await;
        assert_eq!(r["targets"].as_array().map(Vec::len), Some(i), "{r}");
    }
    assert_eq!(req(&conn, add("h33", "me@h")).await, json!({"ok":false,"error":"too many targets"}));

    let rm = json!({"op":"remove_term_target","name":"gpu1"});
    let r = req(&conn, rm.clone()).await;
    assert_eq!(r["ok"], true, "{r}");
    let names: Vec<_> = r["targets"].as_array().unwrap().iter().map(|t| t["name"].clone()).collect();
    assert_eq!(names.len(), 31);
    assert!(!names.contains(&json!("gpu1")));
    assert_eq!(req(&conn, rm).await, json!({"ok":false,"error":"unknown target"}));

    wait_log(a.home.path(), "request", |v| v["op"] == "add_term_target" && v["name"] == "gpu1").await;
    wait_log(a.home.path(), "request", |v| {
        v["op"] == "remove_term_target" && v["name"] == "gpu1" && v["result"] == "unknown target"
    })
    .await;
    // Editing targets never starts the worker.
    assert_eq!(term_log(a.bins.path()), None);
}

#[tokio::test]
async fn watch_terms_pushes_changes() {
    let a = service().await;
    let (_ep, conn) = b(&a).await;
    let mut s = watch(&conn).await;
    let first = next(&mut s).await;
    assert_eq!(first["ok"], true, "{first}");
    assert_eq!(first["terms"][0]["id"], "term:tmux:work", "{first}");
    assert_eq!(req(&conn, add("gpu1", "me@gpu1")).await["ok"], true);
    loop {
        let v = next(&mut s).await;
        assert_eq!(v["ok"], true, "{v}");
        if v["terms"].as_array().unwrap().iter().any(|t| t["id"] == "term:tmux@gpu1:main") {
            break;
        }
    }
    wait_log(a.home.path(), "request", |v| v["op"] == "watch_terms" && v["result"] == "ok").await;
    // B closing its side ends the watch on the worker too.
    s.shutdown().await.unwrap();
    wait_term_log(a.bins.path(), "watch closed").await;
}

#[tokio::test]
async fn a_watch_ends_with_an_error_when_terminals_turn_off() {
    let a = service().await;
    let (_ep, conn) = b(&a).await;
    let mut s = watch(&conn).await;
    assert_eq!(next(&mut s).await["ok"], true);
    std::fs::write(a.home.path().join("term.json"), r#"{"allow":false}"#).unwrap();
    assert_eq!(next(&mut s).await, json!({"ok":false,"error":OFF}));
    assert_eq!(next(&mut s).await, Value::Null);
}

#[tokio::test]
async fn new_term_returns_the_id_and_logs_no_command() {
    let a = service().await;
    let (_ep, conn) = b(&a).await;
    let op = json!({"op":"new_term","command":["secret-cmd-1"],"cols":80,"rows":24,"name":"n1"});
    assert_eq!(req(&conn, op).await, json!({"ok":true,"id":"term:tmux:n1"}));
    wait_log(a.home.path(), "request", |v| v["op"] == "new_term" && v["host"].is_null() && v["result"] == "ok").await;
    assert!(!service_log_text(a.home.path()).contains("secret-cmd-1"));
    assert!(!term_log(a.bins.path()).unwrap().contains("secret-cmd-1"));
}
