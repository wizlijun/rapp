mod common;

use common::Server;
use serde_json::{json, Value};
use std::path::Path;
use std::process::Stdio;
use std::time::{Duration, Instant};
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader, Lines};
use tokio::net::tcp::{OwnedReadHalf, OwnedWriteHalf};
use tokio::net::TcpStream;
use tokio::process::{Child, ChildStdin, Command};
use tokio::sync::mpsc;
use tokio::task::JoinHandle;
use tokio::time::timeout;

const BIN: &str = env!("CARGO_BIN_EXE_rapp-term");
const TOKEN: &str = "test-token-1";
const WAIT: Duration = Duration::from_secs(5);
/// For a target that cannot connect: a poll plus ssh failing, which waits on DNS.
const SSH_WAIT: Duration = Duration::from_secs(15);

/// A running `rapp-term serve` on a private tmux server.
struct Worker {
    child: Child,
    stdin: Option<ChildStdin>,
    out: mpsc::UnboundedReceiver<String>,
    err: JoinHandle<String>,
    port: u16,
    dir: tempfile::TempDir,
    ctl: CtlDir,
}

/// The worker's own ssh control directory, removed with it. `rapp-term` names it `/tmp/rapp-term-$USER`, so each
/// worker is given a `USER` of its own rather than sharing the real one's.
struct CtlDir(std::path::PathBuf);

impl Drop for CtlDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn command(socket: &str, config: &Path) -> Command {
    let mut c = Command::new(BIN);
    c.args(["serve", "--bind", "127.0.0.1", "--port", "0", "--token-env", "RAPP_TOKEN", "--config"])
        .arg(config)
        .args(["--json", "--socket", socket])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);
    c
}

/// One open connection to the worker.
struct Conn {
    lines: Lines<BufReader<OwnedReadHalf>>,
    w: OwnedWriteHalf,
}

impl Conn {
    /// The next line, or `None` when the worker closed.
    async fn line(&mut self, wait: Duration) -> Option<Value> {
        let l = timeout(wait, self.lines.next_line()).await.expect("no line from the worker in time").unwrap()?;
        Some(serde_json::from_str(&l).unwrap())
    }

    async fn next(&mut self) -> Value {
        self.line(WAIT).await.expect("the worker closed the connection")
    }

    async fn send(&mut self, v: Value) {
        self.w.write_all(format!("{v}\n").as_bytes()).await.unwrap();
    }

    /// Lines until one of type `t`, which is returned.
    async fn until(&mut self, t: &str) -> Value {
        loop {
            let m = self.next().await;
            if m["t"] == t {
                return m;
            }
        }
    }

    /// Lines until one that `f` holds for, which is returned; all within `wait`.
    async fn until_list(&mut self, wait: Duration, f: impl Fn(&Value) -> bool) -> Value {
        let end = Instant::now() + wait;
        loop {
            let m = self.line(end.saturating_duration_since(Instant::now())).await.expect("the watch ended");
            if f(&m) {
                return m;
            }
        }
    }
}

/// The row of session `id` in a session list.
fn row<'a>(list: &'a Value, id: &str) -> Option<&'a Value> {
    list["terms"].as_array()?.iter().find(|r| r["id"] == id)
}

/// Whether the row of `id` in `list` is unread.
fn unread(list: &Value, id: &str) -> Option<bool> {
    row(list, id)?["unread"].as_bool()
}

impl Worker {
    async fn start(s: &Server, config: Option<&str>) -> Worker {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("term.json");
        if let Some(c) = config {
            std::fs::write(&path, c).unwrap();
        }
        let mut c = command(&s.socket, &path);
        c.env("RAPP_TOKEN", TOKEN);
        let user = format!("test{}", dir.path().file_name().unwrap().to_str().unwrap());
        c.env("USER", &user);
        let ctl = CtlDir(Path::new("/tmp").join(format!("rapp-term-{user}")));
        let mut child = c.spawn().unwrap();
        let stdin = child.stdin.take();
        let mut lines = BufReader::new(child.stdout.take().unwrap()).lines();
        let (tx, out) = mpsc::unbounded_channel();
        tokio::spawn(async move {
            while let Ok(Some(l)) = lines.next_line().await {
                if tx.send(l).is_err() {
                    break;
                }
            }
        });
        let mut stderr = child.stderr.take().unwrap();
        let err = tokio::spawn(async move {
            let mut s = String::new();
            let _ = stderr.read_to_string(&mut s).await;
            s
        });
        let mut w = Worker { child, stdin, out, err, port: 0, dir, ctl };
        let first = w.event().await;
        assert_eq!(first["event"], "listening", "{first}");
        assert!(w.ctl.0.is_dir(), "no ssh control directory {}", w.ctl.0.display());
        w.port = first["port"].as_u64().unwrap() as u16;
        assert!(w.port > 0);
        w
    }

    fn config(&self) -> std::path::PathBuf {
        self.dir.path().join("term.json")
    }

    async fn event(&mut self) -> Value {
        let l = timeout(WAIT, self.out.recv()).await.expect("no event within 5 seconds").expect("stdout ended");
        serde_json::from_str(&l).unwrap()
    }

    /// Close stdin: the rest of stdout, all of stderr and the exit code.
    async fn stop(mut self) -> (Vec<String>, String, Option<i32>) {
        drop(self.stdin.take());
        let mut rest = Vec::new();
        while let Some(l) = timeout(WAIT, self.out.recv()).await.expect("stdout did not end within 5 seconds") {
            rest.push(l);
        }
        let status = timeout(WAIT, self.child.wait()).await.expect("the worker did not exit").unwrap();
        let err = timeout(WAIT, self.err).await.expect("stderr did not end").unwrap();
        (rest, err, status.code())
    }

    async fn connect(&self, req: &Value, token: &str) -> Conn {
        let s = TcpStream::connect(("127.0.0.1", self.port)).await.unwrap();
        let (r, mut w) = s.into_split();
        w.write_all(format!("{req}\n{token}\n").as_bytes()).await.unwrap();
        Conn { lines: BufReader::new(r).lines(), w }
    }

    /// One request with the right token: every line of the reply until the worker closes.
    async fn ask(&self, req: Value) -> Vec<Value> {
        self.ask_with(req, TOKEN, Duration::from_secs(15)).await
    }

    async fn ask_with(&self, req: Value, token: &str, wait: Duration) -> Vec<Value> {
        let mut c = self.connect(&req, token).await;
        let mut v = Vec::new();
        while let Some(m) = c.line(wait).await {
            v.push(m);
        }
        v
    }
}

fn sessions(s: &Server) -> Vec<String> {
    s.raw(&["list-sessions", "-F", "#{session_name}"]).lines().map(String::from).collect()
}

#[tokio::test]
async fn serve_says_listening_and_exits_on_stdin_eof() {
    let Some(s) = Server::start() else { return };
    let w = Worker::start(&s, None).await;
    let (rest, _, code) = w.stop().await;
    let last: Value = serde_json::from_str(rest.last().expect("no exit event")).unwrap();
    assert_eq!((last["event"].as_str(), last["code"].as_i64()), (Some("exit"), Some(0)), "{last}");
    assert_eq!(code, Some(0));
}

#[tokio::test]
async fn serve_without_its_token_is_an_argument_error() {
    let d = tempfile::tempdir().unwrap();
    for token in [None, Some("")] {
        let mut c = command("unused", &d.path().join("term.json"));
        match token {
            None => c.env_remove("RAPP_TOKEN"),
            Some(t) => c.env("RAPP_TOKEN", t),
        };
        let out = timeout(WAIT, c.output()).await.expect("serve did not exit").unwrap();
        assert_eq!(out.status.code(), Some(2), "{token:?}");
    }
}

#[tokio::test]
async fn a_bad_token_gets_one_error_line() {
    let Some(s) = Server::start() else { return };
    let w = Worker::start(&s, None).await;
    let v = w.ask_with(json!({"op": "list"}), "nope", WAIT).await;
    assert_eq!(v, [json!({"error": "bad token"})]);
    // A token that only starts like the right one is just as wrong.
    let v = w.ask_with(json!({"op": "list"}), &TOKEN[..TOKEN.len() - 1], WAIT).await;
    assert_eq!(v, [json!({"error": "bad token"})]);
    w.stop().await;
}

#[tokio::test]
async fn an_unknown_request_is_a_bad_request() {
    let Some(s) = Server::start() else { return };
    let w = Worker::start(&s, None).await;
    for req in [json!({"op": "nope"}), json!({"op": "new"}), json!("list")] {
        assert_eq!(w.ask(req.clone()).await, [json!({"error": "bad request"})], "{req}");
    }
    w.stop().await;
}

#[tokio::test]
async fn list_shows_the_sessions_and_the_local_host() {
    let Some(s) = Server::start() else { return };
    s.raw(&["new-session", "-d", "-s", "a b", "-x", "80", "-y", "24", "cat"]);
    let w = Worker::start(&s, None).await;
    let v = w.ask(json!({"op": "list"})).await;
    assert_eq!(v.len(), 1, "{v:?}");
    let terms = v[0]["terms"].as_array().unwrap();
    let row = terms.iter().find(|r| r["id"] == "term:tmux:a b").expect("no row for the session");
    assert_eq!((&row["host"], &row["name"], &row["unread"]), (&json!(null), &json!("a b"), &json!(false)));
    assert_eq!((&row["command"], &row["panes"], &row["dead"]), (&json!("cat"), &json!(1), &json!(false)));
    assert_eq!(v[0]["hosts"], json!([{"host": null}]));
    w.stop().await;
}

#[tokio::test]
async fn a_target_that_cannot_connect_is_reported_and_local_is_still_listed() {
    let Some(s) = Server::start() else { return };
    s.raw(&["new-session", "-d", "-s", "here", "-x", "80", "-y", "24", "cat"]);
    let w = Worker::start(&s, Some(r#"{"targets":[{"name":"gone","target":"nohost.invalid"}]}"#)).await;
    let t = Instant::now();
    let v = w.ask(json!({"op": "list"})).await;
    assert!(t.elapsed() < SSH_WAIT);
    assert_eq!(v.len(), 1, "{v:?}");
    let hosts = v[0]["hosts"].as_array().unwrap();
    assert_eq!((hosts.len(), &hosts[0]), (2, &json!({"host": null})), "{hosts:?}");
    assert_eq!((&hosts[1]["host"], &hosts[1]["target"]), (&json!("gone"), &json!("nohost.invalid")));
    assert!(hosts[1]["error"].as_str().is_some_and(|e| !e.is_empty()), "{}", hosts[1]);
    assert!(hosts[1].get("tmux").is_none());
    assert!(v[0]["terms"].as_array().unwrap().iter().any(|r| r["id"] == "term:tmux:here"));
    w.stop().await;
}

#[tokio::test]
async fn view_pumps_the_session_and_reports_inputs_without_content() {
    let Some(s) = Server::start() else { return };
    s.raw(&["new-session", "-d", "-s", "w", "-x", "80", "-y", "24", "cat"]);
    let mut w = Worker::start(&s, None).await;
    let mut c = w.connect(&json!({"op": "view", "term": "term:tmux:w", "sid": 7}), TOKEN).await;
    assert_eq!(c.next().await["t"], "hello");
    let panes = c.until("panes").await;
    let pane = panes["panes"][0]["id"].as_str().unwrap().to_string();
    c.send(json!({"t": "type", "pane": pane, "text": "secret-word-1"})).await;
    c.send(json!({"t": "keys", "pane": pane, "keys": ["Enter"]})).await;
    // The pump has taken both inputs once the screen shows the typed text.
    let end = Instant::now() + WAIT;
    while !s.raw(&["capture-pane", "-p", "-t", "w"]).contains("secret-word-1") {
        assert!(Instant::now() < end, "the typed text never reached the pane");
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    drop(c);
    let ended = w.event().await;
    assert_eq!(ended, json!({"event": "ended", "sid": 7, "term": "term:tmux:w", "inputs": 2}));
    let (rest, err, code) = w.stop().await;
    assert_eq!(code, Some(0));
    assert!(!rest.iter().any(|l| l.contains("secret-word-1")), "{rest:?}");
    assert!(!err.contains("secret-word-1"), "{err}");
}

#[tokio::test]
async fn view_without_a_sid_reports_nothing() {
    let Some(s) = Server::start() else { return };
    s.raw(&["new-session", "-d", "-s", "w", "-x", "80", "-y", "24", "cat"]);
    let w = Worker::start(&s, None).await;
    let mut c = w.connect(&json!({"op": "view", "term": "term:tmux:w"}), TOKEN).await;
    assert_eq!(c.next().await["t"], "hello");
    drop(c);
    let (rest, _, code) = w.stop().await;
    assert_eq!(code, Some(0));
    assert_eq!(rest.len(), 1, "{rest:?}");
}

#[tokio::test]
async fn view_of_an_unknown_host_or_a_bad_id_is_an_error() {
    let Some(s) = Server::start() else { return };
    let w = Worker::start(&s, None).await;
    let v = w.ask(json!({"op": "view", "term": "term:tmux@nope:x", "sid": 1})).await;
    assert_eq!(v, [json!({"t": "error", "error": "unknown host"})]);
    let v = w.ask(json!({"op": "view", "term": "term:x"})).await;
    assert_eq!(v, [json!({"t": "error", "error": "invalid term id"})]);
    let (rest, _, _) = w.stop().await;
    assert!(!rest.iter().any(|l| l.contains("ended")), "{rest:?}");
}

#[tokio::test]
async fn new_makes_a_session_and_refuses_a_taken_name() {
    let Some(s) = Server::start() else { return };
    let w = Worker::start(&s, None).await;
    let new = json!({"op": "new", "host": null, "name": "n1", "command": ["sh"], "cols": 100, "rows": 30});
    assert_eq!(w.ask(new.clone()).await, [json!({"ok": true, "id": "term:tmux:n1"})]);
    assert!(sessions(&s).contains(&"n1".to_string()), "{:?}", sessions(&s));
    assert_eq!(w.ask(new).await, [json!({"error": "a session with that name already exists"})]);
    let empty = json!({"op": "new", "host": null, "name": "n2", "command": [], "cols": 100, "rows": 30});
    assert_eq!(w.ask(empty).await, [json!({"error": "command required"})]);
    let far = json!({"op": "new", "host": "nope", "name": "n3", "command": ["sh"], "cols": 100, "rows": 30});
    assert_eq!(w.ask(far).await, [json!({"error": "unknown host"})]);
    // No name: the program's.
    let unnamed = json!({"op": "new", "host": null, "command": ["/bin/sh"], "cols": 100, "rows": 30});
    assert_eq!(w.ask(unnamed).await, [json!({"ok": true, "id": "term:tmux:sh"})]);
    let (rest, err, _) = w.stop().await;
    assert!(!rest.iter().any(|l| l.contains("/bin/sh")) && !err.contains("/bin/sh"), "{rest:?} {err}");
}

#[tokio::test]
async fn stopping_leaves_no_control_client() {
    let Some(s) = Server::start() else { return };
    s.raw(&["new-session", "-d", "-s", "w", "-x", "80", "-y", "24", "cat"]);
    let w = Worker::start(&s, None).await;
    let mut c = w.connect(&json!({"op": "view", "term": "term:tmux:w", "sid": 3}), TOKEN).await;
    assert_eq!(c.next().await["t"], "hello");
    let pane = c.until("panes").await["panes"][0]["id"].as_str().unwrap().to_string();
    c.send(json!({"t": "view", "pane": pane, "cols": 80, "rows": 24})).await;
    c.until("screen").await;
    assert!(!s.raw(&["list-clients"]).trim().is_empty(), "the view has no control client");
    let (rest, _, code) = w.stop().await;
    assert_eq!(code, Some(0));
    let last: Value = serde_json::from_str(rest.last().unwrap()).unwrap();
    assert_eq!(last["event"], "exit");
    let end = Instant::now() + Duration::from_secs(2);
    loop {
        let clients = s.raw(&["list-clients"]);
        if clients.trim().is_empty() {
            break;
        }
        assert!(Instant::now() < end, "a control client is still there: {clients}");
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    // The worker closed the view.
    assert!(c.line(WAIT).await.is_none());
}

#[tokio::test]
async fn a_view_cut_off_by_stopping_is_still_reported() {
    let Some(s) = Server::start() else { return };
    s.raw(&["new-session", "-d", "-s", "w", "-x", "80", "-y", "24", "cat"]);
    let w = Worker::start(&s, None).await;
    let mut c = w.connect(&json!({"op": "view", "term": "term:tmux:w", "sid": 9}), TOKEN).await;
    assert_eq!(c.next().await["t"], "hello");
    let pane = c.until("panes").await["panes"][0]["id"].as_str().unwrap().to_string();
    c.send(json!({"t": "type", "pane": pane, "text": "typed-before-stop"})).await;
    let end = Instant::now() + WAIT;
    while !s.raw(&["capture-pane", "-p", "-t", "w"]).contains("typed-before-stop") {
        assert!(Instant::now() < end, "the typed text never reached the pane");
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    // The connection stays open: stopping the worker is what ends the view.
    let (rest, _, code) = w.stop().await;
    assert_eq!(code, Some(0));
    let rest: Vec<Value> = rest.iter().map(|l| serde_json::from_str(l).unwrap()).collect();
    assert_eq!(rest.len(), 2, "{rest:?}");
    assert_eq!(rest[0], json!({"event": "ended", "sid": 9, "term": "term:tmux:w", "inputs": 1}));
    assert_eq!(rest[1]["event"], "exit");
    drop(c);
}

#[tokio::test]
async fn terminals_off_in_the_config_refuse_everything() {
    let Some(s) = Server::start() else { return };
    s.raw(&["new-session", "-d", "-s", "w", "-x", "80", "-y", "24", "cat"]);
    let w = Worker::start(&s, Some(r#"{"allow":false}"#)).await;
    let off = json!({"error": "terminal sessions are off"});
    assert_eq!(w.ask(json!({"op": "list"})).await, std::slice::from_ref(&off));
    assert_eq!(w.ask(json!({"op": "watch"})).await, std::slice::from_ref(&off));
    let new = json!({"op": "new", "host": null, "name": "n1", "command": ["sh"], "cols": 100, "rows": 30});
    assert_eq!(w.ask(new).await, [off]);
    let v = w.ask(json!({"op": "view", "term": "term:tmux:w", "sid": 1})).await;
    assert_eq!(v, [json!({"t": "error", "error": "terminal sessions are off"})]);
    assert!(!sessions(&s).contains(&"n1".to_string()));
    w.stop().await;
}

#[tokio::test]
async fn an_unreadable_config_is_refused() {
    let Some(s) = Server::start() else { return };
    let w = Worker::start(&s, Some("{not json")).await;
    assert_eq!(w.ask(json!({"op": "list"})).await, [json!({"error": "term.json is invalid"})]);
    assert_eq!(w.ask(json!({"op": "watch"})).await, [json!({"error": "term.json is invalid"})]);
    let v = w.ask(json!({"op": "view", "term": "term:tmux:w"})).await;
    assert_eq!(v, [json!({"t": "error", "error": "term.json is invalid"})]);
    w.stop().await;
}

#[tokio::test]
async fn watch_sends_a_list_now_then_only_changes() {
    let Some(s) = Server::start() else { return };
    let w = Worker::start(&s, None).await;
    let mut c = w.connect(&json!({"op": "watch"}), TOKEN).await;
    let first = c.next().await;
    assert_eq!((&first["terms"], &first["hosts"]), (&json!([]), &json!([{"host": null}])), "{first}");
    // Output in the second the worker started does not count as unread.
    tokio::time::sleep(Duration::from_millis(1100)).await;
    s.raw(&["new-session", "-d", "-s", "w2", "-x", "80", "-y", "24", "cat"]);
    c.until_list(WAIT, |l| row(l, "term:tmux:w2").is_some()).await;
    c.until_list(Duration::from_secs(10), |l| unread(l, "term:tmux:w2") == Some(true)).await;
    // Nothing changes from here, so nothing is sent.
    let more = timeout(Duration::from_secs(3), c.lines.next_line()).await;
    assert!(more.is_err(), "a line with no change: {more:?}");
    w.stop().await;
}

#[tokio::test]
async fn a_session_goes_unread_after_output_and_quiet_and_clears_when_viewed() {
    let Some(s) = Server::start() else { return };
    s.raw(&["new-session", "-d", "-s", "w", "-x", "80", "-y", "24", "cat"]);
    let w = Worker::start(&s, None).await;
    let mut c = w.connect(&json!({"op": "watch"}), TOKEN).await;
    assert_eq!(unread(&c.next().await, "term:tmux:w"), Some(false));
    // Output in the second the worker started does not count as unread.
    tokio::time::sleep(Duration::from_millis(1100)).await;
    s.raw(&["send-keys", "-t", "w", "echo hi", "Enter"]);
    c.until_list(Duration::from_secs(10), |l| unread(l, "term:tmux:w") == Some(true)).await;
    let mut v = w.connect(&json!({"op": "view", "term": "term:tmux:w"}), TOKEN).await;
    assert_eq!(v.next().await["t"], "hello");
    let pane = v.until("panes").await["panes"][0]["id"].as_str().unwrap().to_string();
    v.send(json!({"t": "view", "pane": pane, "cols": 80, "rows": 24})).await;
    v.until("screen").await;
    // A line can go out between the view attaching (`attached` changes) and its first screen, so the one that
    // clears unread is not always the very next.
    c.until_list(WAIT, |l| unread(l, "term:tmux:w") == Some(false)).await;
    drop(v);
    w.stop().await;
}

#[tokio::test]
async fn a_target_added_while_watching_shows_up() {
    let Some(s) = Server::start() else { return };
    let w = Worker::start(&s, None).await;
    let mut c = w.connect(&json!({"op": "watch"}), TOKEN).await;
    assert_eq!(c.next().await["hosts"], json!([{"host": null}]));
    std::fs::write(w.config(), r#"{"targets":[{"name":"gone","target":"nohost.invalid"}]}"#).unwrap();
    let failed = |h: &Value| h["host"] == "gone" && h["error"].as_str().is_some_and(|e| !e.is_empty());
    let l = c.until_list(SSH_WAIT, |l| l["hosts"].as_array().unwrap().iter().any(failed)).await;
    assert_eq!((&l["hosts"][0], &l["hosts"][1]["target"]), (&json!({"host": null}), &json!("nohost.invalid")));
    w.stop().await;
}

#[tokio::test]
async fn turning_terminals_off_ends_the_watch() {
    let Some(s) = Server::start() else { return };
    let w = Worker::start(&s, None).await;
    let mut c = w.connect(&json!({"op": "watch"}), TOKEN).await;
    c.next().await;
    std::fs::write(w.config(), r#"{"allow":false}"#).unwrap();
    let off = json!({"error": "terminal sessions are off"});
    c.until_list(WAIT, |l| *l == off).await;
    assert!(c.line(WAIT).await.is_none());
    w.stop().await;
}

#[tokio::test]
async fn the_watch_ends_when_the_worker_stops() {
    let Some(s) = Server::start() else { return };
    let mut w = Worker::start(&s, None).await;
    let mut c = w.connect(&json!({"op": "watch"}), TOKEN).await;
    c.next().await;
    drop(w.stdin.take());
    // Within 2 seconds the connection ends (a line in between would be a change, which can still come).
    let end = Instant::now() + Duration::from_secs(2);
    while c.line(end.saturating_duration_since(Instant::now())).await.is_some() {}
    w.stop().await;
}
