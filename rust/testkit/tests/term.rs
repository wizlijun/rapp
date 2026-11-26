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

/// Makes the fake worker list one more session, `term:pty:<key>`.
fn add_row(home: &Path, key: &str) {
    std::fs::write(home.join("term.json"), json!({"allow":true,"fake_rows":[key]}).to_string()).unwrap();
}

/// The request lines `verb` has left in `term.log`, as JSON.
fn term_requests(bins: &Path, verb: &str) -> Vec<Value> {
    let prefix = format!("{verb} ");
    let log = term_log(bins).unwrap_or_default();
    log.lines().filter_map(|l| l.strip_prefix(prefix.as_str())).map(|j| serde_json::from_str(j).unwrap()).collect()
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
        assert_eq!(r["terms"][0]["id"], "term:pty:work", "{r}");
        let host = json!({"host":null,"launchers":["Terminal"],"shells":[{"name":"zsh","path":"/bin/zsh","default":true}]});
        assert_eq!(r["hosts"][0], host, "{r}");
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
        json!({"op":"open_term","app":"Terminal"}),
        json!({"op":"rename_term","term":"term:pty:work","name":"n"}),
        json!({"op":"restore_terms","keys":["k"]}),
        json!({"op":"forget_terms","keys":["k"]}),
    ] {
        assert_eq!(req(&conn, op.clone()).await, json!({"ok":false,"error":OFF}), "{op}");
    }
    assert_eq!(term_log(a.bins.path()), None);
    assert_eq!(std::fs::read_to_string(a.home.path().join("term.json")).unwrap(), r#"{"allow":false}"#);
    assert_eq!(req(&conn, json!({"op":"list_apps"})).await["ok"], true);

    // The hub's background watch stays in the log file but not in the access history; a refused open_term is in both.
    let home = a.home.path();
    wait_log(home, "request", |v| v["op"] == "watch_terms" && v["result"] == OFF).await;
    wait_log(home, "request", |v| v["op"] == "rename_term" && v["result"] == OFF).await;
    let h = ipc_once(&a.svc, home, json!({"cmd":"history","limit":10})).await;
    let ops: Vec<_> =
        h["events"].as_array().unwrap().iter().filter(|v| v["ev"] == "request").map(|v| &v["op"]).collect();
    assert!(ops.contains(&&json!("open_term")), "{h}");
    assert!(!ops.contains(&&json!("watch_terms")), "{h}");
}

#[tokio::test]
async fn a_broken_term_json_is_reported_and_left_alone() {
    let a = service().await;
    let path = a.home.path().join("term.json");
    std::fs::write(&path, "{not json").unwrap();
    let (_ep, conn) = b(&a).await;
    for op in [json!({"op":"list_terms"}), json!({"op":"open_term","app":"Terminal"})] {
        assert_eq!(req(&conn, op.clone()).await, json!({"ok":false,"error":INVALID}), "{op}");
    }
    assert_eq!(std::fs::read(&path).unwrap(), b"{not json");
    assert_eq!(term_log(a.bins.path()), None);
    assert!(!service_log_text(a.home.path()).contains("not json"));
}

#[tokio::test]
async fn watch_terms_pushes_changes() {
    let a = service().await;
    let (_ep, conn) = b(&a).await;
    let mut s = watch(&conn).await;
    let first = next(&mut s).await;
    assert_eq!(first["ok"], true, "{first}");
    assert_eq!(first["terms"][0]["id"], "term:pty:work", "{first}");
    add_row(a.home.path(), "k2");
    loop {
        let v = next(&mut s).await;
        assert_eq!(v["ok"], true, "{v}");
        if v["terms"].as_array().unwrap().iter().any(|t| t["id"] == "term:pty:k2") {
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
async fn an_old_new_term_is_an_unknown_op() {
    let a = service().await;
    let (_ep, conn) = b(&a).await;
    for op in [
        json!({"op":"new_term","command":["bash"],"cols":80,"rows":24}),
        json!({"op":"add_term_target","name":"gpu1","target":"me@gpu1"}),
        json!({"op":"remove_term_target","name":"gpu1"}),
    ] {
        assert_eq!(req(&conn, op.clone()).await, json!({"ok":false,"error":"unknown op"}), "{op}");
    }
    assert_eq!(term_log(a.bins.path()), None);
}

#[tokio::test]
async fn open_term_passes_the_shell() {
    let a = service().await;
    let (_ep, conn) = b(&a).await;
    let r = req(&conn, json!({"op":"open_term","shell":"zsh","app":"Terminal"})).await;
    assert_eq!(r, json!({"ok":true,"id":"term:pty:opened"}));
    let r = req(&conn, json!({"op":"open_term","app":"iTerm"})).await;
    assert_eq!(r, json!({"ok":true,"id":"term:pty:opened"}));
    let sent = term_requests(a.bins.path(), "open");
    assert_eq!(sent[0], json!({"op":"open","shell":"zsh","from":null,"app":"Terminal"}));
    assert_eq!(sent[1], json!({"op":"open","shell":null,"from":null,"app":"iTerm"}));
    wait_log(a.home.path(), "request", |v| v["op"] == "open_term" && v["app"] == "Terminal" && v["result"] == "ok").await;
}

#[tokio::test]
async fn rename_term_reaches_the_worker() {
    let a = service().await;
    let (_ep, conn) = b(&a).await;
    let r = req(&conn, json!({"op":"rename_term","term":"term:pty:k","name":"n-secret"})).await;
    assert_eq!(r, json!({"ok":true}));
    let sent = term_requests(a.bins.path(), "rename");
    assert_eq!(sent, [json!({"op":"rename","term":"term:pty:k","name":"n-secret"})]);
    let logged = wait_log(a.home.path(), "request", |v| v["op"] == "rename_term" && v["result"] == "ok").await;
    assert!(logged.get("term").is_none() && logged.get("name").is_none(), "{logged}");
    assert!(!service_log_text(a.home.path()).contains("n-secret"));
}

#[tokio::test]
async fn end_term_reaches_the_worker() {
    let a = service().await;
    let (_ep, conn) = b(&a).await;
    let r = req(&conn, json!({"op":"end_term","term":"term:pty:k-secret"})).await;
    assert_eq!(r, json!({"ok":true}));
    let sent = term_requests(a.bins.path(), "end");
    assert_eq!(sent, [json!({"op":"end","term":"term:pty:k-secret"})]);
    let logged = wait_log(a.home.path(), "request", |v| v["op"] == "end_term" && v["result"] == "ok").await;
    assert!(logged.get("term").is_none(), "{logged}");
    assert!(!service_log_text(a.home.path()).contains("k-secret"));
    let r = req(&conn, json!({"op":"open_term","app":"Terminal","from":"term:pty:k"})).await;
    assert_eq!(r, json!({"ok":true,"id":"term:pty:opened"}));
    let sent = term_requests(a.bins.path(), "open");
    assert_eq!(sent[0]["from"], json!("term:pty:k"));
}

#[tokio::test]
async fn restore_and_forget_terms_reach_the_worker() {
    let a = service().await;
    let (_ep, conn) = b(&a).await;
    let r = req(&conn, json!({"op":"restore_terms","keys":["k-secret"],"app":"Terminal"})).await;
    assert_eq!(r, json!({"ok":true,"ids":["term:pty:r1","term:pty:r2"]}));
    assert_eq!(term_requests(a.bins.path(), "restore"), [json!({"op":"restore","keys":["k-secret"],"app":"Terminal"})]);
    let r = req(&conn, json!({"op":"forget_terms","keys":["k-secret","j-secret"]})).await;
    assert_eq!(r, json!({"ok":true,"forgot":2}));
    assert_eq!(term_requests(a.bins.path(), "forget"), [json!({"op":"forget","keys":["k-secret","j-secret"]})]);
    let logged = wait_log(a.home.path(), "request", |v| v["op"] == "restore_terms" && v["result"] == "ok").await;
    assert_eq!(logged["keys"], 1, "{logged}");
    wait_log(a.home.path(), "request", |v| v["op"] == "forget_terms" && v["keys"] == 2).await;
    assert!(!service_log_text(a.home.path()).contains("-secret"));
}

/// `saved` is serve's local request (it returns cmd and cwd): no peer reaches it.
#[tokio::test]
async fn a_peer_cannot_ask_for_saved() {
    let a = service().await;
    let (_ep, conn) = b(&a).await;
    let r = req(&conn, json!({"op":"saved"})).await;
    assert_eq!(r["ok"], false, "{r}");
    assert!(r["error"].as_str().unwrap().contains("unknown op"), "{r}");
    assert!(!term_log(a.bins.path()).unwrap_or_default().contains("saved"));
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
    let mut s = open_term(&conn, "term:pty:work").await;
    echo(&mut s, "hello-secret-1").await;
    echo(&mut s, "hello-secret-2").await;
    s.shutdown().await.unwrap();
    ended(&mut s).await;

    let start = wait_log(home, "session_start", |v| v["app"] == "term:pty:work").await;
    assert_eq!(start["path"], "lan", "{start}");
    let sid = start["sid"].clone();
    let end = wait_log(home, "session_end", |v| v["sid"] == sid).await;
    assert_eq!((&end["app"], &end["reason"]), (&json!("term:pty:work"), &json!("closed")), "{end}");
    assert!(end["up"].as_u64().unwrap() > 0 && end["down"].as_u64().unwrap() > 0, "{end}");
    assert!(end["secs"].is_u64(), "{end}");
    let inputs = wait_log(home, "term_inputs", |v| v["sid"] == sid).await;
    assert_eq!(inputs["term"], "term:pty:work", "{inputs}");
    assert_eq!(inputs["inputs"], 2, "{inputs}");
    let req = wait_log(home, "request", |v| v["op"] == "open").await;
    assert_eq!((&req["app"], &req["result"]), (&json!("term:pty:work"), &json!("ok")), "{req}");

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
    let mut one = open_term(&conn, "term:pty:work").await;
    let sid = wait_log(home, "session_start", |_| true).await["sid"].clone();
    let mut two = open_term(&conn, "term:pty:work").await;
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
    let mut term = open_term(&conn, "term:pty:work").await;
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
    let r = req(&conn, json!({"op":"open","app":"term:pty:work"})).await;
    assert_eq!(r, json!({"ok":false,"error":OFF}));
    assert_eq!(argv_lines(a.bins.path()), argv);
    let path = home.join("term.json");
    let file: Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
    assert_eq!(file["allow"], false, "{file}");
    use std::os::unix::fs::PermissionsExt;
    assert_eq!(std::fs::metadata(&path).unwrap().permissions().mode() & 0o777, 0o600);
    assert_eq!(ipc.call(json!({"cmd":"term"})).await, json!({"ok":true,"allow":false}));

    assert_eq!(ipc.call(json!({"cmd":"set_term","allow":true})).await, json!({"ok":true}));
    assert_eq!(req(&conn, json!({"op":"list_terms"})).await["ok"], true);
}

#[tokio::test]
async fn a_view_the_worker_closes_ends_without_b_closing() {
    let idle = std::time::Duration::from_millis(300);
    let a = service_with_idle(idle).await;
    let home = a.home.path();
    let (_ep, conn) = b(&a).await;
    let mut term = open_term(&conn, "term:pty:work").await;
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
    add_row(home, "k2");
    loop {
        let v = next(&mut s).await;
        assert_eq!(v["ok"], true, "{v}");
        if v["terms"].as_array().unwrap().iter().any(|t| t["id"] == "term:pty:k2") {
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
    assert_eq!(std::fs::read(&path).unwrap(), b"{not json");
}

#[tokio::test]
async fn ipc_set_term_ignores_a_tmux_path() {
    let a = service().await;
    let mut ipc = Ipc::open(&a.svc, a.home.path()).await;
    assert_eq!(ipc.call(json!({"cmd":"set_term","tmux":"/opt/homebrew/bin/tmux"})).await, json!({"ok":true}));
    assert_eq!(ipc.call(json!({"cmd":"term"})).await, json!({"ok":true,"allow":true}));
}

/// The local CLI's three IPC commands: keys pass through exactly, forget sends none (= all), and a worker error
/// keeps the `ids` opened so far.
#[tokio::test]
async fn ipc_term_saved_restore_forget() {
    let a = service().await;
    let r = ipc_once(&a.svc, a.home.path(), json!({"cmd":"term_saved"})).await;
    assert_eq!(r["ok"], true, "{r}");
    assert_eq!(r["saved"][0]["cwd"], "/tmp/p", "{r}");
    assert!(term_log(a.bins.path()).unwrap().lines().any(|l| l == "saved"));
    let r = ipc_once(&a.svc, a.home.path(), json!({"cmd":"term_restore","keys":["k1","k2"]})).await;
    assert_eq!(r, json!({"ok":true,"ids":["term:pty:r1","term:pty:r2"]}));
    // Non-string keys are dropped, a missing array is "all" (empty).
    ipc_once(&a.svc, a.home.path(), json!({"cmd":"term_restore","keys":["k3", 5]})).await;
    ipc_once(&a.svc, a.home.path(), json!({"cmd":"term_restore"})).await;
    assert_eq!(
        term_requests(a.bins.path(), "restore"),
        [json!({"op":"restore","keys":["k1","k2"]}), json!({"op":"restore","keys":["k3"]}), json!({"op":"restore","keys":[]})]
    );
    let r = ipc_once(&a.svc, a.home.path(), json!({"cmd":"term_forget","keys":["ignored"]})).await;
    assert_eq!(r, json!({"ok":true,"forgot":0}));
    assert_eq!(term_requests(a.bins.path(), "forget"), [json!({"op":"forget","keys":[]})]);
    // cwd and keys never reach the service log.
    assert!(!service_log_text(a.home.path()).contains("/tmp/p"));
}

#[tokio::test]
async fn ipc_term_restore_error_keeps_ids() {
    let a = service().await;
    std::fs::write(a.home.path().join("term.json"), json!({"allow":true,"fake_restore_error":"boom"}).to_string()).unwrap();
    let r = ipc_once(&a.svc, a.home.path(), json!({"cmd":"term_restore","keys":["k1","k2"]})).await;
    assert_eq!(r["ok"], false, "{r}");
    assert_eq!(r["error"], "boom", "{r}");
    assert_eq!(r["ids"], json!(["term:pty:r1"]), "{r}");
}

#[tokio::test]
async fn ipc_term_commands_with_terminals_off() {
    let a = service().await;
    std::fs::write(a.home.path().join("term.json"), r#"{"allow":false}"#).unwrap();
    for cmd in [json!({"cmd":"term_saved"}), json!({"cmd":"term_restore","keys":["k"]}), json!({"cmd":"term_forget"})] {
        assert_eq!(ipc_once(&a.svc, a.home.path(), cmd.clone()).await, json!({"ok":false,"error":OFF}), "{cmd}");
    }
    assert!(term_log(a.bins.path()).is_none_or(|l| !l.contains("restore") && !l.contains("forget")));
}
