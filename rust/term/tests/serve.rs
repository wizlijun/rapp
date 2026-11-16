#[path = "common/pty.rs"]
mod pty;

use pty::{short_dir, Window};
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

/// A running `rapp-term serve` with a `term.json` and a short directory of its own.
struct Worker {
    child: Child,
    stdin: Option<ChildStdin>,
    out: mpsc::UnboundedReceiver<String>,
    err: JoinHandle<String>,
    port: u16,
    dir: tempfile::TempDir,
}

fn command(config: &Path) -> Command {
    let mut c = Command::new(BIN);
    c.args(["serve", "--bind", "127.0.0.1", "--port", "0", "--token-env", "RAPP_TOKEN", "--config"])
        .arg(config)
        .arg("--json")
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

/// A host row without its `launchers` and `shells`, which depend on the machine the test runs on.
fn plain(host: &Value) -> Value {
    let mut h = host.clone();
    h.as_object_mut().unwrap().remove("launchers");
    h.as_object_mut().unwrap().remove("shells");
    h
}

/// The row of session `id` in a session list.
fn row<'a>(list: &'a Value, id: &str) -> Option<&'a Value> {
    list["terms"].as_array()?.iter().find(|r| r["id"] == id)
}

impl Worker {
    async fn start(config: Option<&str>) -> Worker {
        Worker::start_in(short_dir(), config, None).await
    }

    /// Started in `dir` (short, so `term/pty/<pid>.sock` fits a unix socket address), with `PATH` set to `bin_path`.
    async fn start_in(dir: tempfile::TempDir, config: Option<&str>, bin_path: Option<&Path>) -> Worker {
        Worker::start_with(dir, config, bin_path, None).await
    }

    /// Started with `--launch-with launcher`: the program `open` runs instead of macOS's `open -a`.
    async fn start_with(
        dir: tempfile::TempDir,
        config: Option<&str>,
        bin_path: Option<&Path>,
        launch_with: Option<&Path>,
    ) -> Worker {
        let path = dir.path().join("term.json");
        // `{"allow":true}` unless a test says otherwise.
        std::fs::write(&path, config.unwrap_or(r#"{"allow":true}"#)).unwrap();
        let mut c = command(&path);
        c.env("RAPP_TOKEN", TOKEN);
        if let Some(l) = launch_with {
            c.arg("--launch-with").arg(l);
        }
        if let Some(p) = bin_path {
            c.env("PATH", p);
        }
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
        let mut w = Worker { child, stdin, out, err, port: 0, dir };
        let first = w.event().await;
        assert_eq!(first["event"], "listening", "{first}");
        w.port = first["port"].as_u64().unwrap() as u16;
        assert!(w.port > 0);
        w
    }

    /// Where `rapp-term run --dir` puts its sockets for this worker.
    fn pty_dir(&self) -> std::path::PathBuf {
        let d = self.dir.path().join("term");
        rapp_term::pty::local::ensure_dirs(&d).unwrap();
        d
    }

    /// Started with a launcher that runs the `.command` file in a pty of its own, as a window would. `script`
    /// gives up its window when its input ends, so the input is held open for 20 s, longer than any test here.
    async fn start_launching() -> Worker {
        let dir = short_dir();
        let script = dir.path().join("launch.sh");
        std::fs::write(&script, "#!/bin/sh\nsleep 20 | script -q /dev/null sh \"$2\" >/dev/null 2>&1 &\n").unwrap();
        std::fs::set_permissions(&script, std::os::unix::fs::PermissionsExt::from_mode(0o700)).unwrap();
        Worker::start_with(dir, None, None, Some(&script)).await
    }

    fn config(&self) -> std::path::PathBuf {
        self.dir.path().join("term.json")
    }

    async fn event(&mut self) -> Value {
        let l = timeout(WAIT, self.out.recv()).await.expect("no event within 5 seconds").expect("stdout ended");
        serde_json::from_str(&l).unwrap()
    }

    /// Close stdin: the rest of stdout, all of stderr and the exit code.
    async fn stop(self) -> (Vec<String>, String, Option<i32>) {
        let (rest, err, code, _) = self.stop_keeping().await;
        (rest, err, code)
    }

    /// `stop`, handing back the directory too.
    async fn stop_keeping(mut self) -> (Vec<String>, String, Option<i32>, tempfile::TempDir) {
        drop(self.stdin.take());
        let mut rest = Vec::new();
        while let Some(l) = timeout(WAIT, self.out.recv()).await.expect("stdout did not end within 5 seconds") {
            rest.push(l);
        }
        let status = timeout(WAIT, self.child.wait()).await.expect("the worker did not exit").unwrap();
        let err = timeout(WAIT, self.err).await.expect("stderr did not end").unwrap();
        (rest, err, status.code(), self.dir)
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

#[tokio::test]
async fn serve_says_listening_and_exits_on_stdin_eof() {
    let w = Worker::start(None).await;
    let (rest, _, code) = w.stop().await;
    let last: Value = serde_json::from_str(rest.last().expect("no exit event")).unwrap();
    assert_eq!((last["event"].as_str(), last["code"].as_i64()), (Some("exit"), Some(0)), "{last}");
    assert_eq!(code, Some(0));
}

#[tokio::test]
async fn serve_without_its_token_is_an_argument_error() {
    let d = tempfile::tempdir().unwrap();
    for token in [None, Some("")] {
        let mut c = command(&d.path().join("term.json"));
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
    let w = Worker::start(None).await;
    let v = w.ask_with(json!({"op": "list"}), "nope", WAIT).await;
    assert_eq!(v, [json!({"error": "bad token"})]);
    // A token that only starts like the right one is just as wrong.
    let v = w.ask_with(json!({"op": "list"}), &TOKEN[..TOKEN.len() - 1], WAIT).await;
    assert_eq!(v, [json!({"error": "bad token"})]);
    w.stop().await;
}

#[tokio::test]
async fn an_unknown_request_is_a_bad_request() {
    let w = Worker::start(None).await;
    let new = json!({"op": "new", "host": null, "name": "n1", "command": ["sh"], "cols": 100, "rows": 30});
    for req in [new, json!({"op": "nope"}), json!({"op": "new"}), json!("list")] {
        assert_eq!(w.ask(req.clone()).await, [json!({"error": "bad request"})], "{req}");
    }
    w.stop().await;
}

#[tokio::test]
async fn view_of_a_bad_or_removed_id_is_an_error() {
    let w = Worker::start(None).await;
    for term in ["term:x", "term:tmux:w", "term:tmux@nope:x"] {
        let v = w.ask(json!({"op": "view", "term": term, "sid": 1})).await;
        assert_eq!(v, [json!({"t": "error", "error": "invalid term id"})], "{term}");
    }
    let (rest, _, _) = w.stop().await;
    assert!(!rest.iter().any(|l| l.contains("ended")), "{rest:?}");
}

#[tokio::test]
async fn terminals_off_in_the_config_refuse_everything() {
    let w = Worker::start(Some(r#"{"allow":false}"#)).await;
    let off = json!({"error": "terminal sessions are off"});
    assert_eq!(w.ask(json!({"op": "list"})).await, std::slice::from_ref(&off));
    assert_eq!(w.ask(json!({"op": "watch"})).await, std::slice::from_ref(&off));
    let v = w.ask(json!({"op": "view", "term": "term:pty:w", "sid": 1})).await;
    assert_eq!(v, [json!({"t": "error", "error": "terminal sessions are off"})]);
    w.stop().await;
}

#[tokio::test]
async fn an_unreadable_config_is_refused() {
    let w = Worker::start(Some("{not json")).await;
    assert_eq!(w.ask(json!({"op": "list"})).await, [json!({"error": "term.json is invalid"})]);
    assert_eq!(w.ask(json!({"op": "watch"})).await, [json!({"error": "term.json is invalid"})]);
    let v = w.ask(json!({"op": "view", "term": "term:pty:w"})).await;
    assert_eq!(v, [json!({"t": "error", "error": "term.json is invalid"})]);
    w.stop().await;
}

#[tokio::test]
async fn watch_sends_a_list_now_then_only_changes() {
    let w = Worker::start(None).await;
    let mut c = w.connect(&json!({"op": "watch"}), TOKEN).await;
    let first = c.next().await;
    assert_eq!((&first["terms"], plain(&first["hosts"][0])), (&json!([]), json!({"host": null})), "{first}");
    let _win = Window::start(&w.pty_dir(), &["--name", "w2", "--", "/bin/cat"]);
    c.until_list(WAIT, |l| row_named(l, "w2")).await;
    // Nothing changes from here, so nothing is sent.
    let more = timeout(Duration::from_secs(3), c.lines.next_line()).await;
    assert!(more.is_err(), "a line with no change: {more:?}");
    w.stop().await;
}

#[tokio::test]
async fn turning_terminals_off_ends_the_watch() {
    let w = Worker::start(None).await;
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
    let mut w = Worker::start(None).await;
    let mut c = w.connect(&json!({"op": "watch"}), TOKEN).await;
    c.next().await;
    drop(w.stdin.take());
    // Within 2 seconds the connection ends (a line in between would be a change, which can still come).
    let end = Instant::now() + Duration::from_secs(2);
    while c.line(end.saturating_duration_since(Instant::now())).await.is_some() {}
    w.stop().await;
}

/// The id of the session called `name`, which is made from its key.
async fn id_of(dir: &Path, name: &str) -> String {
    format!("term:pty:{}", pty::wait_status(dir, name).await.key.expect("a new run has a key"))
}

fn terms_of(v: &[Value]) -> Vec<String> {
    v[0]["terms"].as_array().unwrap().iter().map(|r| r["id"].as_str().unwrap().to_string()).collect()
}

#[tokio::test]
async fn a_pty_session_is_listed() {
    let w = Worker::start(None).await;
    let _win = Window::start(&w.pty_dir(), &["--name", "t", "--", "/bin/cat"]);
    let id = id_of(&w.pty_dir(), "t").await;
    let v = w.ask(json!({"op": "list"})).await;
    assert_eq!(terms_of(&v), [id.as_str()], "{v:?}");
    assert_eq!(v[0]["hosts"].as_array().unwrap().len(), 1);
    assert_eq!(plain(&v[0]["hosts"][0]), json!({"host": null}));
    let t = row(&v[0], &id).unwrap();
    assert_eq!((t["panes"].as_u64(), t["attached"].as_u64(), t["dead"].as_bool()), (Some(1), Some(0), Some(false)));
    assert_eq!((&t["host"], &t["name"], &t["command"]), (&json!(null), &json!("t"), &json!("/bin/cat")));
    assert_eq!(t["unread"], false);
    w.stop().await;
}

#[tokio::test]
async fn a_watch_sees_a_pty_session_come_and_go() {
    let w = Worker::start(None).await;
    let mut c = w.connect(&json!({"op": "watch"}), TOKEN).await;
    assert_eq!(c.next().await["terms"], json!([]));
    let _win = Window::start(&w.pty_dir(), &["--name", "t", "--", "/bin/cat"]);
    c.until_list(WAIT, |l| row_named(l, "t")).await;
    let id = id_of(&w.pty_dir(), "t").await;
    let mut v = w.connect(&json!({"op": "view", "term": id}), TOKEN).await;
    assert_eq!(v.next().await["t"], "hello");
    v.until("panes").await;
    v.send(json!({"t": "keys", "pane": "%0", "keys": ["Ctrl-D"]})).await;
    c.until_list(WAIT, |l| !row_named(l, "t")).await;
    w.stop().await;
}

#[tokio::test]
async fn viewing_a_pty_session_goes_through_serve() {
    let mut w = Worker::start(None).await;
    let win = Window::start(&w.pty_dir(), &["--name", "t", "--", "/bin/cat"]);
    let id = id_of(&w.pty_dir(), "t").await;
    let mut c = w.connect(&json!({"op": "view", "term": id, "sid": 5}), TOKEN).await;
    let hello = c.next().await;
    assert_eq!((hello["t"].as_str(), hello["backend"].as_str()), (Some("hello"), Some("pty")), "{hello}");
    c.until("panes").await;
    c.send(json!({"t": "view", "pane": "%0", "cols": 80, "rows": 24})).await;
    let screen = c.until("screen").await;
    c.send(json!({"t": "ack", "rev": screen["rev"]})).await;
    c.send(json!({"t": "type", "pane": "%0", "text": "secret-word-2\r"})).await;
    win.wait_output("secret-word-2");
    drop(c);
    let ended = w.event().await;
    assert_eq!(ended, json!({"event": "ended", "sid": 5, "term": id, "inputs": 1}));
    let (rest, err, _) = w.stop().await;
    assert!(!rest.iter().any(|l| l.contains("secret-word-2")) && !err.contains("secret-word-2"), "{rest:?} {err}");
}

#[tokio::test]
async fn the_old_tmux_and_targets_fields_are_ignored() {
    let cfg = r#"{"allow":true,"tmux":"/x","targets":[{"name":"g","target":"me@g"}]}"#;
    let w = Worker::start_in(short_dir(), Some(cfg), Some(tempfile::tempdir().unwrap().path())).await;
    let v = w.ask(json!({"op": "list"})).await;
    assert_eq!(v.len(), 1, "{v:?}");
    assert_eq!(v[0]["terms"], json!([]));
    assert_eq!(v[0]["hosts"].as_array().unwrap().len(), 1, "{v:?}");
    w.stop().await;
}

#[tokio::test]
async fn an_unknown_text_terminal_is_an_error() {
    let w = Worker::start(None).await;
    let v = w.ask(json!({"op": "view", "term": "term:pty:nope"})).await;
    assert_eq!(v, [json!({"t": "error", "error": "no such text terminal"})]);
    let v = w.ask(json!({"op": "view", "term": "term:pty@h:nope"})).await;
    assert_eq!(v, [json!({"t": "error", "error": "invalid term id"})]);
    w.stop().await;
}

#[tokio::test]
async fn restarting_serve_finds_the_session_again() {
    let first = Worker::start(None).await;
    let mut win = Window::start(&first.pty_dir(), &["--name", "t", "--", "/bin/cat"]);
    let id = id_of(&first.pty_dir(), "t").await;
    let (_, _, code, dir) = first.stop_keeping().await;
    assert_eq!(code, Some(0));
    assert!(win.alive());
    let second = Worker::start_in(dir, None, None).await;
    let v = second.ask(json!({"op": "list"})).await;
    assert_eq!(terms_of(&v), [id.as_str()], "{v:?}");
    assert!(win.alive());
    second.stop().await;
}

/// The path of the default shell on this machine, from a list.
async fn default_shell(w: &Worker) -> String {
    let list = &w.ask(json!({"op": "list"})).await[0];
    let d = list["hosts"][0]["shells"].as_array().unwrap().iter().find(|s| s["default"] == true).unwrap().clone();
    d["path"].as_str().unwrap().to_string()
}

#[tokio::test]
async fn the_local_row_lists_shells() {
    let w = Worker::start(None).await;
    let list = &w.ask(json!({"op": "list"})).await[0];
    let shells = list["hosts"][0]["shells"].as_array().unwrap();
    assert!(!shells.is_empty(), "{list}");
    assert_eq!(shells.iter().filter(|s| s["default"] == true).count(), 1, "{list}");
    w.stop().await;
}

#[tokio::test]
async fn open_runs_the_shell_as_a_login_shell() {
    let w = Worker::start_launching().await;
    let path = default_shell(&w).await;
    let file_name = path.rsplit('/').next().unwrap().to_string();
    let r = w.ask(json!({"op":"open","shell":path,"app":"Terminal"})).await;
    let st = pty::wait_status(&w.pty_dir(), &file_name).await;
    let id = format!("term:pty:{}", st.key.clone().unwrap());
    assert_eq!(r, [json!({"id": id})]);
    let list = &w.ask(json!({"op": "list"})).await[0];
    let t = row(list, &id).unwrap();
    assert_eq!((&t["command"], &t["name"]), (&json!(format!("{path} -l")), &json!(file_name)), "{t}");
    unsafe { libc::kill(st.pid as i32, libc::SIGTERM) };
    w.stop().await;
}

#[tokio::test]
async fn open_refuses_a_shell_not_found_now() {
    let w = Worker::start_launching().await;
    let r = w.ask(json!({"op":"open","shell":"/no/such/sh","app":"Terminal"})).await;
    assert_eq!(r, [json!({"error": "this shell is not found any more"})]);
    let launch = w.pty_dir().join("launch");
    assert!(!launch.exists() || std::fs::read_dir(launch).unwrap().next().is_none(), "no window was started");
    w.stop().await;
}

#[tokio::test]
async fn open_without_shell_uses_the_default() {
    let w = Worker::start_launching().await;
    let path = default_shell(&w).await;
    let file_name = path.rsplit('/').next().unwrap().to_string();
    let r = w.ask(json!({"op":"open","cwd":"/tmp","name":"x","command":"claude","app":"Terminal"})).await;
    let st = pty::wait_status(&w.pty_dir(), &file_name).await;
    assert_eq!(r, [json!({"id": format!("term:pty:{}", st.key.clone().unwrap())})]);
    assert_ne!(st.name, "x");
    unsafe { libc::kill(st.pid as i32, libc::SIGTERM) };
    w.stop().await;
}

#[tokio::test]
async fn open_refuses_an_unknown_app() {
    let w = Worker::start_launching().await;
    let r = w.ask(json!({"op":"open","app":"Warp"})).await;
    assert_eq!(r, [json!({"error": "unknown terminal app"})]);
    w.stop().await;
}

#[tokio::test]
async fn open_gives_up_after_ten_seconds() {
    let w = Worker::start_with(short_dir(), None, None, Some(Path::new("/usr/bin/true"))).await;
    let r = w.ask(json!({"op":"open","app":"Terminal"})).await;
    assert_eq!(r, [json!({"error": "the terminal window did not start in 10 s"})]);
    // A window that is slow to start may still read it; a later open sweeps it once it is old.
    let launch = w.pty_dir().join("launch");
    assert_eq!(std::fs::read_dir(launch).unwrap().count(), 1, "the .command file is kept");
    w.stop().await;
}

#[cfg(target_os = "macos")]
#[tokio::test]
async fn this_machine_lists_its_launchers() {
    let w = Worker::start(None).await;
    let list = &w.ask(json!({"op": "list"})).await[0];
    assert!(list["hosts"][0]["launchers"].as_array().unwrap().contains(&json!("Terminal")), "{list}");
    w.stop().await;
}

/// 16 lowercase hex characters.
fn is_key(s: &str) -> bool {
    s.len() == 16 && s.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'))
}

fn rename_req(id: &str, name: &str) -> Value {
    json!({"op": "rename", "term": id, "name": name})
}

/// The id of the one session in the list `w` gives.
async fn only_id(w: &Worker) -> String {
    let v = w.ask(json!({"op": "list"})).await;
    let terms = v[0]["terms"].as_array().unwrap();
    assert_eq!(terms.len(), 1, "{v:?}");
    terms[0]["id"].as_str().unwrap().to_string()
}

#[tokio::test]
async fn a_pty_row_is_keyed_not_named() {
    let w = Worker::start(None).await;
    let _win = Window::start(&w.pty_dir(), &["--name", "t", "--", "/bin/cat"]);
    pty::wait_status(&w.pty_dir(), "t").await;
    let v = w.ask(json!({"op": "list"})).await;
    let t = &v[0]["terms"][0];
    let id = t["id"].as_str().unwrap();
    assert!(id.strip_prefix("term:pty:").is_some_and(is_key), "{id}");
    assert_eq!(t["name"], "t");
    let mut c = w.connect(&json!({"op": "view", "term": id}), TOKEN).await;
    assert_eq!(c.next().await["t"], "hello");
    w.stop().await;
}

#[tokio::test]
async fn rename_changes_the_name_not_the_id() {
    let w = Worker::start(None).await;
    let _win = Window::start(&w.pty_dir(), &["--name", "t", "--", "/bin/cat"]);
    pty::wait_status(&w.pty_dir(), "t").await;
    let id = only_id(&w).await;
    assert_eq!(w.ask(rename_req(&id, "  后端 ")).await, [json!({"ok": true})]);
    let v = w.ask(json!({"op": "list"})).await;
    let t = row(&v[0], &id).expect("the same id");
    assert_eq!(t["name"], "后端");
    // The new name shows in a view's pane too.
    let mut c = w.connect(&json!({"op": "view", "term": id}), TOKEN).await;
    c.next().await;
    assert_eq!(c.until("panes").await["panes"][0]["title"], "后端");
    w.stop().await;
}

#[tokio::test]
async fn rename_refuses_bad_names() {
    let w = Worker::start(None).await;
    let _win = Window::start(&w.pty_dir(), &["--name", "t", "--", "/bin/cat"]);
    pty::wait_status(&w.pty_dir(), "t").await;
    let id = only_id(&w).await;
    for bad in ["".to_string(), "a\u{7}".into(), "x".repeat(65)] {
        assert_eq!(w.ask(rename_req(&id, &bad)).await, [json!({"error": "invalid name"})], "{bad:?}");
    }
    assert_eq!(w.ask(rename_req(&id, &"x".repeat(64))).await, [json!({"ok": true})]);
    w.stop().await;
}

#[tokio::test]
async fn rename_of_an_unknown_term_says_so() {
    let w = Worker::start(None).await;
    let r = w.ask(rename_req("term:pty:0123456789abcdef", "x")).await;
    assert_eq!(r, [json!({"error": "no such text terminal"})]);
    w.stop().await;
}

#[tokio::test]
async fn a_rename_reaches_a_watch_at_once() {
    let dir = short_dir();
    let config = dir.path().join("term.json");
    std::fs::write(&config, r#"{"allow":true}"#).unwrap();
    let mut opts = rapp_term::serve::ServeOpts::new(config);
    opts.poll = Duration::from_secs(30);
    let pty_dir = opts.pty_dir.clone();
    rapp_term::pty::local::ensure_dirs(&pty_dir).unwrap();
    let listener = tokio::net::TcpListener::bind(("127.0.0.1", 0)).await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let (tx, _events) = mpsc::unbounded_channel();
    let (stop, stopped) = tokio::sync::oneshot::channel::<()>();
    let server = tokio::spawn(rapp_term::serve::serve(listener, TOKEN.into(), opts, tx, async {
        let _ = stopped.await;
    }));
    let _win = Window::start(&pty_dir, &["--name", "t", "--", "/bin/cat"]);
    pty::wait_status(&pty_dir, "t").await;
    let open = |req: Value| async move {
        let s = TcpStream::connect(("127.0.0.1", port)).await.unwrap();
        let (r, mut w) = s.into_split();
        w.write_all(format!("{req}\n{TOKEN}\n").as_bytes()).await.unwrap();
        Conn { lines: BufReader::new(r).lines(), w }
    };
    let mut watch = open(json!({"op": "watch"})).await;
    // The first scan may come before or after the window is known; wait for the row.
    let first = watch.until_list(WAIT, |l| row_named(l, "t")).await;
    let id = first["terms"][0]["id"].as_str().unwrap().to_string();
    let mut ask = open(rename_req(&id, "new")).await;
    assert_eq!(ask.next().await, json!({"ok": true}));
    let seen = watch.until_list(Duration::from_secs(1), |l| row_named(l, "new")).await;
    assert_eq!(seen["terms"][0]["id"], id.as_str());
    // A second watch hears a second rename just as soon.
    let mut watch2 = open(json!({"op": "watch"})).await;
    watch2.until_list(WAIT, |l| row_named(l, "new")).await;
    let mut ask = open(rename_req(&id, "newer")).await;
    assert_eq!(ask.next().await, json!({"ok": true}));
    watch.until_list(Duration::from_secs(1), |l| row_named(l, "newer")).await;
    watch2.until_list(Duration::from_secs(1), |l| row_named(l, "newer")).await;
    let _ = stop.send(());
    let _ = server.await;
}

#[tokio::test]
async fn a_watch_sees_the_installed_shells_change() {
    use rapp_term::shells::Shell;
    use std::sync::{Arc, Mutex};
    let dir = short_dir();
    let config = dir.path().join("term.json");
    std::fs::write(&config, r#"{"allow":true}"#).unwrap();
    let mut opts = rapp_term::serve::ServeOpts::new(config);
    opts.poll = Duration::from_millis(100);
    let sh = |name: &str, default| Shell { name: name.into(), path: format!("/bin/{name}"), default };
    let installed = Arc::new(Mutex::new(vec![sh("sh", true), sh("fish", false)]));
    let now = installed.clone();
    opts.shells_with = Some(Arc::new(move || now.lock().unwrap().clone()));
    rapp_term::pty::local::ensure_dirs(&opts.pty_dir).unwrap();
    let listener = tokio::net::TcpListener::bind(("127.0.0.1", 0)).await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let (tx, _events) = mpsc::unbounded_channel();
    let (stop, stopped) = tokio::sync::oneshot::channel::<()>();
    let server = tokio::spawn(rapp_term::serve::serve(listener, TOKEN.into(), opts, tx, async {
        let _ = stopped.await;
    }));
    let s = TcpStream::connect(("127.0.0.1", port)).await.unwrap();
    let (r, mut w) = s.into_split();
    w.write_all(format!("{}\n{TOKEN}\n", json!({"op": "watch"})).as_bytes()).await.unwrap();
    let mut watch = Conn { lines: BufReader::new(r).lines(), w };
    let names = |l: &Value| -> Vec<String> {
        l["hosts"][0]["shells"].as_array().unwrap().iter().map(|s| s["name"].as_str().unwrap().to_string()).collect()
    };
    let first = watch.until_list(WAIT, |_| true).await;
    assert_eq!(names(&first), ["sh", "fish"]);
    // fish is uninstalled while the watch runs: the next push drops its button.
    *installed.lock().unwrap() = vec![sh("sh", true)];
    let seen = watch.until_list(Duration::from_secs(2), |l| names(l) == ["sh"]).await;
    assert_eq!(names(&seen), ["sh"]);
    let _ = stop.send(());
    let _ = server.await;
}

fn row_named(list: &Value, name: &str) -> bool {
    list["terms"].as_array().is_some_and(|t| t.iter().any(|r| r["name"] == name))
}

#[tokio::test]
async fn an_old_run_is_listed_by_name_and_refuses_rename() {
    let w = Worker::start(None).await;
    let dir = w.pty_dir();
    let token = rapp_term::pty::local::token(&dir).unwrap();
    let listener = tokio::net::UnixListener::bind(dir.join("pty/4242.sock")).unwrap();
    tokio::spawn(async move {
        loop {
            let (mut s, _) = listener.accept().await.unwrap();
            let token = token.clone();
            tokio::spawn(async move {
                let (r, mut w) = s.split();
                let head = rapp_term::pty::local::read_head(&mut BufReader::new(r), &token).await.unwrap();
                let reply = match head.op.as_str() {
                    "status" => json!({"v": 1, "name": "old", "command": "sh", "cols": 80, "rows": 24,
                        "activity": 5, "viewers": 0, "pid": 4242}),
                    _ => json!({"error": "unsupported", "v": 1}),
                };
                w.write_all(format!("{reply}\n").as_bytes()).await.unwrap();
            });
        }
    });
    let v = w.ask(json!({"op": "list"})).await;
    assert_eq!(terms_of(&v), ["term:pty:old"], "{v:?}");
    let old = "this window was opened by an older version and cannot be renamed";
    assert_eq!(w.ask(rename_req("term:pty:old", "new")).await, [json!({"error": old})]);
    w.stop().await;
}
