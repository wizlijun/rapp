//! rapp-service's terminal-session requests (spec §6, §8, §9) against the fake `rapp-term`.

mod common;

use common::*;
use quinn::{Connection, Endpoint};
use rapp_net::line::{read_json, read_line, write_json};
use rapp_net::quic::{bi, BiStream};
use serde_json::{json, Value};
use std::path::Path;
use tokio::io::{AsyncReadExt, AsyncWriteExt};

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

    // The hub's background watch stays in the log file but not in the access history; a refused new_term is in both.
    let home = a.home.path();
    wait_log(home, "request", |v| v["op"] == "watch_terms" && v["result"] == OFF).await;
    wait_log(home, "request", |v| v["op"] == "remove_term_target" && v["result"] == OFF).await;
    let h = ipc_once(&a.svc, home, json!({"cmd":"history","limit":10})).await;
    let ops: Vec<_> =
        h["events"].as_array().unwrap().iter().filter(|v| v["ev"] == "request").map(|v| &v["op"]).collect();
    assert!(ops.contains(&&json!("new_term")), "{h}");
    assert!(!ops.contains(&&json!("watch_terms")), "{h}");
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

/// Opens `term` and passes the worker token through: the stream is then the worker's view (`hello` first).
async fn open_term(conn: &Connection, term: &str) -> BiStream {
    let mut s = bi(conn.open_bi().await.unwrap());
    write_json(&mut s, &json!({"op":"open","app":term})).await.unwrap();
    let r = read_json(&mut s).await.unwrap();
    assert_eq!(r["ok"], true, "{r}");
    let token = r["token"].as_str().unwrap();
    s.write_all(format!("{token}\n").as_bytes()).await.unwrap();
    assert_eq!(read_json(&mut s).await.unwrap(), json!({"t":"hello","fake":true,"term":term}));
    s
}

/// Sends `line` and reads it back from the fake's echo.
async fn echo(s: &mut BiStream, line: &str) {
    s.write_all(format!("{line}\n").as_bytes()).await.unwrap();
    let back = tokio::time::timeout(WAIT, read_line(s)).await.expect("an echo in time").unwrap();
    assert_eq!(back.as_deref(), Some(line));
}

/// Reads until the stream ends (EOF or reset).
async fn ended(s: &mut BiStream) {
    let mut rest = Vec::new();
    let _ = tokio::time::timeout(WAIT, s.read_to_end(&mut rest)).await.expect("the stream ended");
}

fn argv_lines(bins: &Path) -> usize {
    term_log(bins).unwrap_or_default().lines().filter(|l| l.starts_with("argv ")).count()
}

#[tokio::test]
async fn open_term_splices_to_the_worker_and_logs_no_content() {
    let a = service().await;
    let home = a.home.path();
    let (_ep, conn) = b(&a).await;
    let mut s = open_term(&conn, "term:tmux:work").await;
    echo(&mut s, "hello-secret-1").await;
    echo(&mut s, "hello-secret-2").await;
    s.shutdown().await.unwrap();
    ended(&mut s).await;

    let start = wait_log(home, "session_start", |v| v["app"] == "term:tmux:work").await;
    assert_eq!(start["path"], "lan", "{start}");
    let sid = start["sid"].clone();
    let end = wait_log(home, "session_end", |v| v["sid"] == sid).await;
    assert_eq!((&end["app"], &end["reason"]), (&json!("term:tmux:work"), &json!("closed")), "{end}");
    assert!(end["up"].as_u64().unwrap() > 0 && end["down"].as_u64().unwrap() > 0, "{end}");
    assert!(end["secs"].is_u64(), "{end}");
    let inputs = wait_log(home, "term_inputs", |v| v["sid"] == sid).await;
    assert_eq!(inputs["term"], "term:tmux:work", "{inputs}");
    assert_eq!(inputs["inputs"], 2, "{inputs}");
    let req = wait_log(home, "request", |v| v["op"] == "open").await;
    assert_eq!((&req["app"], &req["result"]), (&json!("term:tmux:work"), &json!("ok")), "{req}");

    let h = ipc_once(&a.svc, home, json!({"cmd":"history","limit":10})).await;
    let shown: Vec<_> = h["events"].as_array().unwrap().iter().filter(|v| v["sid"] == sid).map(|v| &v["ev"]).collect();
    for ev in ["session_start", "session_end", "term_inputs"] {
        assert!(shown.contains(&&json!(ev)), "{ev} not in {h}");
    }
    assert!(!service_log_text(home).contains("hello-secret"));
    // No rapp-host was started for it (the service's own permission check is the only thing in host.log).
    assert_eq!(host_log(a.bins.path()), "check\n");
}

/// Whether the stream ends within a short while, rather than staying open.
async fn ends_soon(s: &mut BiStream) -> bool {
    let mut buf = [0u8; 64];
    let r = tokio::time::timeout(std::time::Duration::from_millis(500), s.read(&mut buf)).await;
    matches!(r, Ok(Ok(0) | Err(_)))
}

#[tokio::test]
async fn terminal_sessions_share_one_worker_and_can_be_kicked() {
    let a = service().await;
    let home = a.home.path();
    let (_ep, conn) = b(&a).await;
    let mut one = open_term(&conn, "term:tmux:work").await;
    let sid = wait_log(home, "session_start", |_| true).await["sid"].clone();
    let mut two = open_term(&conn, "term:tmux:work").await;
    echo(&mut one, "x").await;
    echo(&mut two, "y").await;
    assert_eq!(argv_lines(a.bins.path()), 1);

    assert_eq!(ipc_once(&a.svc, home, json!({"cmd":"kick","sid":sid})).await, json!({"ok":true}));
    let end = wait_log(home, "session_end", |v| v["sid"] == sid).await;
    assert_eq!(end["reason"], "kicked", "{end}");
    assert!(ends_soon(&mut one).await);
    echo(&mut two, "still here").await;
    assert!(!log_events(home).iter().any(|v| v["ev"] == "session_end" && v["sid"] != sid));
}

#[tokio::test]
async fn turning_terminals_off_ends_terminal_sessions_only() {
    let a = service().await;
    let home = a.home.path();
    let (_ep, conn) = b(&a).await;
    let mut term = open_term(&conn, "term:tmux:work").await;
    echo(&mut term, "x").await;
    let mut app = bi(conn.open_bi().await.unwrap());
    write_json(&mut app, &json!({"op":"open","app":"com.example.echo"})).await.unwrap();
    let r = read_json(&mut app).await.unwrap();
    assert_eq!(r["ok"], true, "{r}");
    app.write_all(format!("{}\n", r["token"].as_str().unwrap()).as_bytes()).await.unwrap();
    assert_eq!(read_line(&mut app).await.unwrap().as_deref(), Some("ok"));

    let mut ipc = Ipc::open(&a.svc, home).await;
    assert_eq!(ipc.call(json!({"cmd":"set_term","allow":false})).await, json!({"ok":true}));
    ended(&mut term).await;
    wait_log(home, "worker_exit", |v| v["app"] == "term:").await;
    echo(&mut app, "app still here").await;

    let argv = argv_lines(a.bins.path());
    assert_eq!(req(&conn, json!({"op":"list_terms"})).await, json!({"ok":false,"error":OFF}));
    let r = req(&conn, json!({"op":"open","app":"term:tmux:work"})).await;
    assert_eq!(r, json!({"ok":false,"error":OFF}));
    assert_eq!(argv_lines(a.bins.path()), argv);
    let path = home.join("term.json");
    let file: Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
    assert_eq!(file["allow"], false, "{file}");
    use std::os::unix::fs::PermissionsExt;
    assert_eq!(std::fs::metadata(&path).unwrap().permissions().mode() & 0o777, 0o600);
    assert_eq!(ipc.call(json!({"cmd":"term"})).await, json!({"ok":true,"allow":false,"tmux":null,"targets":[]}));

    assert_eq!(ipc.call(json!({"cmd":"set_term","allow":true})).await, json!({"ok":true}));
    assert_eq!(req(&conn, json!({"op":"list_terms"})).await["ok"], true);
}

#[tokio::test]
async fn a_view_the_worker_closes_ends_without_b_closing() {
    let idle = std::time::Duration::from_millis(300);
    let a = service_with_idle(idle).await;
    let home = a.home.path();
    let (_ep, conn) = b(&a).await;
    let mut term = open_term(&conn, "term:tmux:work").await;
    echo(&mut term, "x").await;
    let sid = wait_log(home, "session_start", |_| true).await["sid"].clone();

    // B never closes its side: the worker closing the view is the end of the session.
    let mut ipc = Ipc::open(&a.svc, home).await;
    assert_eq!(ipc.call(json!({"cmd":"set_term","allow":false})).await, json!({"ok":true}));
    ended(&mut term).await;
    let end = wait_log(home, "session_end", |v| v["sid"] == sid).await;
    assert_eq!(end["reason"], "closed", "{end}");
    assert!(end["up"].as_u64().unwrap() > 0 && end["down"].as_u64().unwrap() > 0, "{end}");
    wait_log(home, "worker_exit", |v| v["app"] == "term:").await;

    // The old view counts for nothing on the next worker: B closing it late does not make that one idle.
    assert_eq!(ipc.call(json!({"cmd":"set_term","allow":true})).await, json!({"ok":true}));
    let mut s = watch(&conn).await;
    assert_eq!(next(&mut s).await["ok"], true);
    let argv = argv_lines(a.bins.path());
    let _ = term.shutdown().await; // the service may have stopped reading it already
    drop(term);
    tokio::time::sleep(idle * 3).await;
    assert_eq!(req(&conn, add("gpu1", "me@gpu1")).await["ok"], true);
    loop {
        let v = next(&mut s).await;
        assert_eq!(v["ok"], true, "{v}");
        if v["terms"].as_array().unwrap().iter().any(|t| t["id"] == "term:tmux@gpu1:main") {
            break;
        }
    }
    assert_eq!(argv_lines(a.bins.path()), argv);
    assert_eq!(log_events(home).iter().filter(|v| v["ev"] == "worker_exit" && v["app"] == "term:").count(), 1);
}

#[tokio::test]
async fn ipc_term_refuses_a_broken_file() {
    let a = service().await;
    let path = a.home.path().join("term.json");
    std::fs::write(&path, "{not json").unwrap();
    let mut ipc = Ipc::open(&a.svc, a.home.path()).await;
    let invalid = json!({"ok":false,"error":INVALID});
    assert_eq!(ipc.call(json!({"cmd":"term"})).await, invalid);
    assert_eq!(ipc.call(json!({"cmd":"set_term","allow":false})).await, invalid);
    assert_eq!(ipc.call(json!({"cmd":"set_term","tmux":"/usr/bin/tmux"})).await, invalid);
    assert_eq!(std::fs::read(&path).unwrap(), b"{not json");
}

#[tokio::test]
async fn ipc_term_sets_the_tmux_path_and_keeps_targets() {
    let a = service().await;
    let (_ep, conn) = b(&a).await;
    assert_eq!(req(&conn, add("gpu1", "me@gpu1")).await["ok"], true);
    let mut ipc = Ipc::open(&a.svc, a.home.path()).await;
    let gpu1 = json!([{"name":"gpu1","target":"me@gpu1"}]);
    assert_eq!(ipc.call(json!({"cmd":"set_term","tmux":"/opt/homebrew/bin/tmux"})).await, json!({"ok":true}));
    let r = ipc.call(json!({"cmd":"term"})).await;
    assert_eq!(r, json!({"ok":true,"allow":true,"tmux":"/opt/homebrew/bin/tmux","targets":gpu1}));
    let r = ipc.call(json!({"cmd":"set_term","tmux":"-x"})).await;
    assert_eq!(r, json!({"ok":false,"error":"invalid tmux path"}));
    assert_eq!(ipc.call(json!({"cmd":"set_term","tmux":null})).await, json!({"ok":true}));
    assert_eq!(ipc.call(json!({"cmd":"term"})).await, json!({"ok":true,"allow":true,"tmux":null,"targets":gpu1}));
}
