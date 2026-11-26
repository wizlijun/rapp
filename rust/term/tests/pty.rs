#![cfg(unix)]
//! `rapp-term run` in a terminal window of its own (a pty the test holds), seen through its local socket.

#[path = "common/pty.rs"]
mod pty;

use pty::{process_exists, short_dir, socket_of, wait_status, Viewer, Window, BIN, WAIT};
use rapp_term::pty::local;
use serde_json::json;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};
use tokio::io::{AsyncBufReadExt, BufReader};

#[tokio::test]
async fn status_reports_the_name_command_and_window_size() {
    let d = short_dir();
    let w = Window::start(d.path(), &["--name", "t", "--", "/bin/cat"]);
    let s = wait_status(d.path(), "t").await;
    assert_eq!((s.command.as_str(), s.cols, s.rows, s.viewers), ("/bin/cat", 100, 30, 0));
    assert_eq!((s.pid, s.ticket), (w.pid(), None));
}

#[tokio::test]
async fn a_ticket_is_reported() {
    let d = short_dir();
    let _w = Window::start(d.path(), &["--name", "t", "--ticket", "abc", "--", "/bin/cat"]);
    assert_eq!(wait_status(d.path(), "t").await.ticket.as_deref(), Some("abc"));
}

#[tokio::test]
async fn remote_typing_shows_in_both_the_window_and_the_viewer() {
    let d = short_dir();
    let w = Window::start(d.path(), &["--name", "t", "--", "/bin/cat"]);
    let mut v = Viewer::connect(d.path(), "t").await;
    v.open().await;
    v.send(json!({"t":"type","pane":"%0","text":"hi\r"})).await;
    w.wait_output("hi");
    // Echoed by the pty, then written back by cat.
    v.wait_text("hi", 2).await;
}

#[tokio::test]
async fn the_local_keyboard_still_works() {
    let d = short_dir();
    let mut w = Window::start(d.path(), &["--name", "t", "--", "/bin/cat"]);
    let mut v = Viewer::connect(d.path(), "t").await;
    v.open().await;
    w.type_in(b"yo\r");
    v.wait_text("yo", 2).await;
    w.wait_output("yo");
}

#[tokio::test]
async fn a_viewer_leaving_never_ends_run() {
    let d = short_dir();
    let mut w = Window::start(d.path(), &["--name", "t", "--", "/bin/cat"]);
    let mut a = Viewer::connect(d.path(), "t").await;
    let mut b = Viewer::connect(d.path(), "t").await;
    a.open().await;
    b.open().await;
    drop(a);
    b.send(json!({"t":"type","pane":"%0","text":"x"})).await;
    b.wait_text("x", 1).await;
    let mut c = Viewer::connect(d.path(), "t").await;
    assert_eq!(c.open().await["full"], true);
    assert_eq!(c.count("x"), 1);
    assert!(w.alive());
    // The one that left is no longer counted; the two still here are.
    let end = Instant::now() + WAIT;
    while wait_status(d.path(), "t").await.viewers != 2 {
        assert!(Instant::now() < end, "the viewers were never counted as 2");
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
}

#[tokio::test]
async fn a_window_resize_reaches_the_viewer() {
    let d = short_dir();
    let w = Window::start(d.path(), &["--name", "t", "--", "/bin/cat"]);
    let mut v = Viewer::connect(d.path(), "t").await;
    let first = v.open().await;
    assert_eq!((first["cols"].as_u64(), first["rows"].as_u64()), (Some(100), Some(30)));
    w.resize(120, 40);
    let seen = v.until(|_, m| m["t"] == "panes").await;
    let panes = seen.last().unwrap();
    assert_eq!((panes["panes"][0]["cols"].as_u64(), panes["panes"][0]["rows"].as_u64()), (Some(120), Some(40)));
    let s = v.until(|_, m| m["t"] == "screen").await.pop().unwrap();
    assert_eq!((s["cols"].as_u64(), s["rows"].as_u64(), s["full"].as_bool()), (Some(120), Some(40), Some(true)));
    let st = wait_status(d.path(), "t").await;
    assert_eq!((st.cols, st.rows), (120, 40));
}

#[tokio::test]
async fn a_viewer_cannot_change_the_size() {
    let d = short_dir();
    let _w = Window::start(d.path(), &["--name", "t", "--", "/bin/cat"]);
    let mut v = Viewer::connect(d.path(), "t").await;
    v.open().await;
    v.send(json!({"t":"refit","pane":"%0","cols":50,"rows":10})).await;
    let seen = v.until(|_, m| m["t"] == "error").await;
    assert_eq!(seen.last().unwrap()["error"], "bad message");
    let s = wait_status(d.path(), "t").await;
    assert_eq!((s.cols, s.rows), (100, 30));
}

#[tokio::test]
async fn a_view_without_fit_never_resizes_the_window() {
    let d = short_dir();
    let w = Window::start(d.path(), &["--name", "t", "--", "/bin/cat"]);
    let mut v = Viewer::connect(d.path(), "t").await;
    v.open().await;
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert!(!w.output().contains("\x1b[8;"), "{:?}", w.output());
}

#[tokio::test]
async fn a_fit_view_resizes_the_window() {
    let d = short_dir();
    let w = Window::start(d.path(), &["--name", "t", "--", "/bin/cat"]);
    let mut v = Viewer::connect(d.path(), "t").await;
    v.open().await;
    v.send(json!({"t":"view","pane":"%0","cols":90,"rows":20,"fit":true})).await;
    w.wait_output("\x1b[8;20;90t");
}

#[tokio::test]
async fn typing_from_a_second_viewer_takes_over_after_two_seconds() {
    let d = short_dir();
    let w = Window::start(d.path(), &["--name", "t", "--", "/bin/cat"]);
    let mut a = Viewer::connect(d.path(), "t").await;
    a.open().await;
    a.send(json!({"t":"view","pane":"%0","cols":90,"rows":20,"fit":true})).await;
    w.wait_output("\x1b[8;20;90t");
    // open() sent fit:false first, so A's fit view is already a false-to-true op; this extra keys is harmless and
    // makes A's operation the latest, so A holds the seat for two seconds.
    a.send(json!({"t":"keys","pane":"%0","keys":["a"]})).await;
    let mut b = Viewer::connect(d.path(), "t").await;
    b.open().await;
    b.send(json!({"t":"view","pane":"%0","cols":70,"rows":15,"fit":true})).await;
    b.send(json!({"t":"keys","pane":"%0","keys":["a"]})).await;
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert!(!w.output().contains("\x1b[8;15;70t"), "{:?}", w.output());
    tokio::time::sleep(Duration::from_secs(2)).await;
    b.send(json!({"t":"keys","pane":"%0","keys":["a"]})).await;
    w.wait_output("\x1b[8;15;70t");
}

#[tokio::test]
async fn names_count_up() {
    let d = short_dir();
    let _a = Window::start(d.path(), &["--name", "t", "--", "/bin/cat"]);
    let _b = Window::start(d.path(), &["--name", "t", "--", "/bin/cat"]);
    wait_status(d.path(), "t").await;
    wait_status(d.path(), "t-2").await;
    let token = local::token(d.path()).unwrap();
    let names: Vec<String> = local::scan(d.path(), &token).await.into_iter().map(|s| s.name).collect();
    assert_eq!(names, ["t", "t-2"]);
}

#[tokio::test]
async fn the_name_defaults_to_the_program() {
    let d = short_dir();
    let _w = Window::start(d.path(), &["--", "/bin/cat", "-u"]);
    assert_eq!(wait_status(d.path(), "cat").await.command, "/bin/cat -u");
}

#[tokio::test]
async fn the_program_exiting_ends_run_and_removes_its_socket() {
    let d = short_dir();
    let mut w = Window::start(d.path(), &["--name", "t", "--", "/bin/cat"]);
    let mut v = Viewer::connect(d.path(), "t").await;
    v.open().await;
    let sock = socket_of(d.path(), w.pid());
    assert!(sock.exists());
    // The window is in raw mode while run holds it.
    assert_eq!(w.lflag() & (libc::ICANON | libc::ECHO), 0);
    v.send(json!({"t":"keys","pane":"%0","keys":["Ctrl-D"]})).await;
    let seen = v.until(|_, m| m["t"] == "error").await;
    assert_eq!(seen.last().unwrap()["error"], "session ended");
    assert!(v.next().await.is_null());
    assert_eq!(w.wait_exit(), 0);
    assert!(!sock.exists());
    // And back to how it was.
    assert_ne!(w.lflag() & libc::ICANON, 0);
}

#[tokio::test]
async fn the_exit_code_is_the_program_s() {
    let d = short_dir();
    let mut w = Window::start(d.path(), &["--name", "t", "--", "/bin/sh", "-c", "read x; exit 7"]);
    wait_status(d.path(), "t").await;
    w.type_in(b"\r");
    assert_eq!(w.wait_exit(), 7);
}

#[tokio::test]
async fn the_last_output_reaches_the_viewer_before_the_end() {
    let d = short_dir();
    let mut w = Window::start(d.path(), &["--name", "t", "--", "/bin/sh", "-c", "read x; echo BYE"]);
    let mut v = Viewer::connect(d.path(), "t").await;
    v.open().await;
    v.send(json!({"t":"type","pane":"%0","text":"\r"})).await;
    let seen = v.until(|_, m| m["t"] == "error").await;
    assert_eq!(seen.last().unwrap()["error"], "session ended");
    assert_eq!(v.count("BYE"), 1, "{:?}", v.lines);
    assert_eq!(w.wait_exit(), 0);
}

#[tokio::test]
async fn closing_the_window_ends_run() {
    let d = short_dir();
    let mut w = Window::start(d.path(), &["--name", "t", "--", "/bin/cat"]);
    wait_status(d.path(), "t").await;
    let sock = socket_of(d.path(), w.pid());
    let kids = w.children();
    assert_eq!(kids.len(), 1, "{kids:?}");
    w.close();
    // 128 + SIGHUP.
    assert_eq!(w.wait_exit(), 129);
    assert!(!sock.exists());
    let end = Instant::now() + WAIT;
    while process_exists(kids[0]) {
        assert!(Instant::now() < end, "cat outlived run");
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
}

#[tokio::test]
async fn sigterm_ends_run_and_its_program() {
    let d = short_dir();
    let mut w = Window::start(d.path(), &["--name", "t", "--", "/bin/cat"]);
    let mut v = Viewer::connect(d.path(), "t").await;
    v.open().await;
    let kids = w.children();
    unsafe { libc::kill(w.pid() as i32, libc::SIGTERM) };
    let seen = v.until(|_, m| m["t"] == "error").await;
    assert_eq!(seen.last().unwrap()["error"], "session ended");
    assert_eq!(w.wait_exit(), 143);
    assert!(!socket_of(d.path(), w.pid()).exists());
    assert!(!kids.is_empty() && !process_exists(kids[0]));
}

/// SIGINT and SIGQUIT sent to run's pid end it like SIGTERM, the window put back on the way out.
#[tokio::test]
async fn sigint_and_sigquit_end_run_like_sigterm() {
    for (sig, code) in [(libc::SIGINT, 130), (libc::SIGQUIT, 131)] {
        let d = short_dir();
        let mut w = Window::start(d.path(), &["--name", "t", "--", "/bin/cat"]);
        let mut v = Viewer::connect(d.path(), "t").await;
        v.open().await;
        let kids = w.children();
        unsafe { libc::kill(w.pid() as i32, sig) };
        let seen = v.until(|_, m| m["t"] == "error").await;
        assert_eq!(seen.last().unwrap()["error"], "session ended");
        assert_eq!(w.wait_exit(), code);
        assert!(!socket_of(d.path(), w.pid()).exists());
        assert!(!kids.is_empty() && !process_exists(kids[0]));
    }
}

#[tokio::test]
async fn an_unfinished_synchronized_update_still_reaches_a_viewer() {
    let d = short_dir();
    let _w = Window::start(d.path(), &["--name", "t", "--", "/bin/sh", "-c", "printf '\\033[?2026hSYNC'; cat"]);
    let mut v = Viewer::connect(d.path(), "t").await;
    v.open().await;
    v.wait_text("SYNC", 1).await;
}

#[tokio::test]
async fn the_local_protocol_refuses_a_bad_token_and_an_unknown_op() {
    let d = short_dir();
    let w = Window::start(d.path(), &["--name", "t", "--", "/bin/cat"]);
    wait_status(d.path(), "t").await;
    let sock = socket_of(d.path(), w.pid());
    let token = local::token(d.path()).unwrap();
    for (op, token, want) in [
        ("status", "nope", json!({"error":"bad token"})),
        ("dance", token.as_str(), json!({"error":"unsupported","v":2})),
    ] {
        let s = local::connect(&sock, op, token).await.unwrap();
        let mut r = BufReader::new(s);
        let mut line = String::new();
        tokio::time::timeout(WAIT, r.read_line(&mut line)).await.unwrap().unwrap();
        assert_eq!(serde_json::from_str::<serde_json::Value>(&line).unwrap(), want);
        line.clear();
        assert_eq!(tokio::time::timeout(WAIT, r.read_line(&mut line)).await.unwrap().unwrap(), 0);
    }
    // Still there.
    wait_status(d.path(), "t").await;
}

#[test]
fn without_a_terminal_it_refuses() {
    let d = short_dir();
    let out = Command::new(BIN)
        .args(["run", "--dir"])
        .arg(d.path())
        .args(["--", "/bin/cat"])
        .stdin(Stdio::null())
        .output()
        .unwrap();
    assert_eq!(out.status.code(), Some(2));
    assert!(String::from_utf8_lossy(&out.stderr).contains("rapp-term run needs a terminal window"));
}

#[tokio::test]
async fn two_runs_with_the_same_name_after_a_rename_stay_apart() {
    let d = short_dir();
    let _a = Window::start(d.path(), &["--name", "a", "--", "/bin/cat"]);
    let _b = Window::start(d.path(), &["--name", "b", "--", "/bin/sh", "-c", "echo bee; cat"]);
    let (sa, sb) = (wait_status(d.path(), "a").await, wait_status(d.path(), "b").await);
    let (ka, kb) = (sa.key.clone().unwrap(), sb.key.clone().unwrap());
    assert!(ka != kb && ka.len() == 16 && ka.bytes().all(|c| matches!(c, b'0'..=b'9' | b'a'..=b'f')), "{ka} {kb}");
    let token = local::token(d.path()).unwrap();
    local::rename(&socket_of(d.path(), sb.pid), &token, "a").await.unwrap();
    // Both are called `a` now; each id still reaches its own program.
    let statuses = local::scan(d.path(), &token).await;
    assert_eq!(statuses.iter().map(|s| s.name.as_str()).collect::<Vec<_>>(), ["a", "a"]);
    // Equal names keep one order, scan after scan.
    let order = |v: &[local::Status]| v.iter().map(|s| s.pid).collect::<Vec<_>>();
    for _ in 0..10 {
        assert_eq!(order(&local::scan(d.path(), &token).await), order(&statuses));
    }
    assert_eq!(statuses.iter().find(|s| s.key.as_ref() == Some(&kb)).unwrap().pid, sb.pid);
    let mut vb = Viewer::connect_op_at(&socket_of(d.path(), sb.pid), d.path(), "view").await;
    vb.open().await;
    vb.wait_text("bee", 1).await;
    let mut va = Viewer::connect_op_at(&socket_of(d.path(), sa.pid), d.path(), "view").await;
    va.open().await;
    assert_eq!(va.count("bee"), 0);
    // A bad name is refused by the run itself.
    assert_eq!(
        local::rename(&socket_of(d.path(), sa.pid), &token, "a\u{7}").await.unwrap_err(),
        local::Probe::Refused("invalid name".into())
    );
}

#[tokio::test]
async fn end_op_answers_then_exits() {
    let d = short_dir();
    let mut w = Window::start(d.path(), &["--name", "t", "--", "/bin/cat"]);
    let mut v = Viewer::connect(d.path(), "t").await;
    v.open().await;
    let token = local::token(d.path()).unwrap();
    let kids = w.children();
    local::end(&socket_of(d.path(), w.pid()), &token).await.unwrap();
    let seen = v.until(|_, m| m["t"] == "error").await;
    assert_eq!(seen.last().unwrap()["error"], "session ended");
    // 128 + SIGHUP, like a closed window.
    assert_eq!(w.wait_exit(), 129);
    assert!(!kids.is_empty() && !process_exists(kids[0]));
}

#[tokio::test]
async fn end_op_kills_stubborn_child() {
    let d = short_dir();
    let mut w = Window::start(d.path(), &["--name", "t", "--", "/bin/sh", "-c", "trap '' HUP; sleep 100"]);
    wait_status(d.path(), "t").await;
    tokio::time::sleep(Duration::from_millis(300)).await;
    let token = local::token(d.path()).unwrap();
    let kids = w.children();
    assert_eq!(kids.len(), 1, "{kids:?}");
    local::end(&socket_of(d.path(), w.pid()), &token).await.unwrap();
    assert_eq!(w.wait_exit(), 129);
    let end = Instant::now() + WAIT;
    while process_exists(kids[0]) {
        assert!(Instant::now() < end, "the stubborn child outlived run");
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
}

#[tokio::test]
async fn no_marker_without_a_ticket() {
    let d = short_dir();
    let mut w = Window::start(d.path(), &["--name", "t", "--", "/bin/cat"]);
    wait_status(d.path(), "t").await;
    let token = local::token(d.path()).unwrap();
    local::end(&socket_of(d.path(), w.pid()), &token).await.unwrap();
    w.wait_exit();
    assert!(std::fs::read_dir(d.path().join("ended")).map(|mut r| r.next().is_none()).unwrap_or(true));
}

#[tokio::test]
async fn a_ticketed_run_leaves_a_marker_named_for_its_tty() {
    let d = short_dir();
    let mut w = Window::start(d.path(), &["--name", "t", "--ticket", "abc", "--", "/bin/cat"]);
    let s = wait_status(d.path(), "t").await;
    let tty = s.tty.clone().expect("a tty");
    let before = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_secs();
    let token = local::token(d.path()).unwrap();
    local::end(&socket_of(d.path(), w.pid()), &token).await.unwrap();
    w.wait_exit();
    let name = tty.rsplit('/').next().unwrap();
    let text = std::fs::read_to_string(d.path().join("ended").join(name)).expect("the marker");
    assert!(text.trim().parse::<u64>().unwrap() >= before, "{text}");
}

// Snapshots (`saved/<key>.json`) and `--restore`: a real zsh through the hook, with a home of its own.

use rapp_term::pty::saved::{self, Snapshot};
use std::path::Path;

/// Taken out of the holder's environment, so a ZDOTDIR or hook variable set where the tests run changes nothing.
const SEALED: [&str; 5] = ["ZDOTDIR", "RAPP_ZDOTDIR", "RAPP_BASH_LOGIN", "RAPP_RESTORE_VENV", "RAPP_RESTORE_CONDA"];

/// A term dir (`<tmp>/t`, so `term.json` beside it is the test's own) and a home with a plain `.zshrc`.
fn zsh_setup() -> Option<(tempfile::TempDir, std::path::PathBuf, tempfile::TempDir)> {
    if !Path::new("/bin/zsh").is_file() {
        eprintln!("note: /bin/zsh is not installed here; the test is skipped");
        return None;
    }
    let d = short_dir();
    let term = d.path().join("t");
    let home = tempfile::tempdir().unwrap();
    std::fs::write(home.path().join(".zshrc"), "PS1='%# '\n").unwrap();
    Some((d, term, home))
}

fn zsh_window(term: &Path, home: &Path, args: &[&str]) -> Window {
    let env = [("HOME", home.display().to_string()), ("PATH", "/usr/bin:/bin:/usr/sbin:/sbin".into()), ("TERM", "xterm-256color".into())];
    let all: Vec<&str> = args.iter().copied().chain(["--", "/bin/zsh", "-l"]).collect();
    Window::start_env(term, &all, &env, &SEALED)
}

/// The snapshot of `key`, waiting up to `within` for one that `ok` takes.
fn wait_snapshot(term: &Path, key: &str, within: Duration, ok: impl Fn(&Snapshot) -> bool) -> Snapshot {
    let end = Instant::now() + within;
    loop {
        let s = saved::read(term, key);
        if let Some(s) = s.filter(|s| ok(s)) {
            return s;
        }
        assert!(Instant::now() < end, "no such snapshot of {key} within {within:?}: {:?}", saved::read(term, key));
        std::thread::sleep(Duration::from_millis(50));
    }
}

async fn key_of(term: &Path, name: &str) -> String {
    wait_dir(term);
    wait_status(term, name).await.key.expect("a key")
}

/// Until the holder made the term dir (the tests' `<tmp>/t` is not there before).
fn wait_dir(term: &Path) {
    let end = Instant::now() + WAIT;
    while !term.join("pty").is_dir() {
        assert!(Instant::now() < end, "no term dir");
        std::thread::sleep(Duration::from_millis(20));
    }
}

#[tokio::test]
async fn holder_writes_snapshot_with_cwd() {
    let Some((_d, term, home)) = zsh_setup() else { return };
    let mut w = zsh_window(&term, home.path(), &["--name", "t"]);
    let key = key_of(&term, "t").await;
    // Written at start.
    let first = wait_snapshot(&term, &key, WAIT, |_| true);
    assert_eq!((first.key.as_str(), first.name.as_str(), first.shell.as_str(), first.named), (key.as_str(), "t", "/bin/zsh", true));
    w.wait_output("\x1b]133;A");
    w.type_in(b"cd /tmp\r");
    let s = wait_snapshot(&term, &key, Duration::from_secs(5), |s| s.cwd.as_deref().is_some_and(|c| c.ends_with("/tmp")));
    assert_eq!(s.started, first.started);
    let mode = std::os::unix::fs::PermissionsExt::mode(&std::fs::metadata(saved::path(&term, &key)).unwrap().permissions());
    assert_eq!(mode & 0o777, 0o600);
}

#[tokio::test]
async fn exit_removes_snapshot() {
    let Some((_d, term, home)) = zsh_setup() else { return };
    let mut w = zsh_window(&term, home.path(), &["--name", "t"]);
    let key = key_of(&term, "t").await;
    wait_snapshot(&term, &key, WAIT, |_| true);
    w.wait_output("\x1b]133;A");
    w.type_in(b"exit\r");
    assert_eq!(w.wait_exit(), 0);
    assert!(!saved::path(&term, &key).exists());
}

#[tokio::test]
async fn sighup_keeps_snapshot() {
    let Some((_d, term, home)) = zsh_setup() else { return };
    let mut w = zsh_window(&term, home.path(), &["--name", "t"]);
    let key = key_of(&term, "t").await;
    wait_snapshot(&term, &key, WAIT, |_| true);
    w.close();
    assert_eq!(w.wait_exit(), 129);
    assert!(saved::path(&term, &key).exists());
}

#[tokio::test]
async fn sigterm_keeps_and_end_removes_the_snapshot() {
    let d = short_dir();
    let mut w = Window::start(d.path(), &["--name", "t", "--", "/bin/cat"]);
    let key = key_of(d.path(), "t").await;
    wait_snapshot(d.path(), &key, WAIT, |_| true);
    unsafe { libc::kill(w.pid() as i32, libc::SIGTERM) };
    assert_eq!(w.wait_exit(), 143);
    assert!(saved::path(d.path(), &key).exists());

    let mut w = Window::start(d.path(), &["--name", "u", "--", "/bin/cat"]);
    let key = key_of(d.path(), "u").await;
    wait_snapshot(d.path(), &key, WAIT, |_| true);
    let token = local::token(d.path()).unwrap();
    local::end(&socket_of(d.path(), w.pid()), &token).await.unwrap();
    assert_eq!(w.wait_exit(), 129);
    assert!(!saved::path(d.path(), &key).exists());
}

#[tokio::test]
async fn restore_reuses_key_and_prefills_without_running() {
    let Some((_d, term, home)) = zsh_setup() else { return };
    let k = "00000000000000a1";
    let cwd = home.path().join("work dir");
    std::fs::create_dir(&cwd).unwrap();
    let snap = Snapshot {
        v: 1,
        key: k.into(),
        name: "work".into(),
        named: true,
        shell: "/bin/zsh".into(),
        cwd: Some(cwd.display().to_string()),
        cmd: Some("echo RAN".into()),
        prog: Some("echo".into()),
        started: 1234,
        saved: 1300,
        ..Default::default()
    };
    saved::write(&term, &snap).unwrap();
    let _w = zsh_window(&term, home.path(), &["--restore", k]);
    wait_dir(&term);
    let st = wait_status(&term, "work").await;
    assert_eq!(st.key.as_deref(), Some(k));
    let mut v = Viewer::connect(&term, "work").await;
    v.open().await;
    v.wait_text("echo RAN", 1).await;
    // Typed, not run: for three seconds no line says RAN alone.
    let end = Instant::now() + Duration::from_secs(3);
    while let Some(left) = end.checked_duration_since(Instant::now()) {
        let _ = tokio::time::timeout(left, v.next()).await;
        assert!(!v.lines.values().any(|l| l.trim() == "RAN"), "{:?}", v.lines);
    }
    assert_eq!(v.count("echo RAN"), 1, "{:?}", v.lines);
    // Opened in the saved directory; the snapshot goes on under the same key, its start kept, the command still there.
    let s = wait_snapshot(&term, k, WAIT, |s| s.saved != 1300);
    assert_eq!((s.started, s.name.as_str(), s.named, s.cmd.as_deref()), (1234, "work", true, Some("echo RAN")));
    let real = cwd.canonicalize().unwrap();
    assert!(s.cwd.as_deref().is_some_and(|c| Path::new(c).canonicalize().ok() == Some(real.clone())), "{:?}", s.cwd);
}

#[tokio::test]
async fn restore_never_answers_a_startup_question() {
    let Some((_d, term, home)) = zsh_setup() else { return };
    // A startup file that asks before the first prompt, for longer than the 2 s an unhooked shell is given.
    std::fs::write(home.path().join(".zshrc"), "PS1='%# '\nread -k 1 'ans?[Y/n] '\necho \"GOT<$ans>\"\n").unwrap();
    let k = "00000000000000a5";
    let snap = Snapshot { v: 1, key: k.into(), name: "ask".into(), shell: "/bin/zsh".into(), cmd: Some("echo RAN".into()), prog: Some("echo".into()), started: 1, saved: 2, ..Default::default() };
    saved::write(&term, &snap).unwrap();
    let mut w = zsh_window(&term, home.path(), &["--restore", k]);
    w.wait_output("[Y/n]");
    std::thread::sleep(Duration::from_secs(3));
    assert!(!w.output().contains("GOT<"), "the command answered the question: {:?}", w.output());
    w.type_in(b"n");
    w.wait_output("GOT<n>");
    // Typed at the prompt that follows.
    let end = Instant::now() + WAIT;
    while !w.output().split_once("GOT<n>").is_some_and(|(_, after)| after.contains("133;A\x07echo RAN")) {
        assert!(Instant::now() < end, "never typed at the prompt: {:?}", w.output());
        std::thread::sleep(Duration::from_millis(20));
    }
}

#[tokio::test]
async fn restore_unknown_key_starts_fresh() {
    let d = short_dir();
    let k = "00000000000000b2";
    let _w = Window::start(d.path(), &["--restore", k, "--", "/bin/cat"]);
    let key = key_of(d.path(), "cat").await;
    assert!(key != k && saved::key_ok(&key), "{key}");
    wait_snapshot(d.path(), &key, WAIT, |_| true);
    assert!(!saved::path(d.path(), k).exists());
}

#[tokio::test]
async fn restore_of_an_unreadable_snapshot_stops_and_keeps_it() {
    if unsafe { libc::geteuid() } == 0 {
        eprintln!("note: root reads any file; the test is skipped");
        return;
    }
    use std::os::unix::fs::PermissionsExt;
    let d = short_dir();
    let k = "00000000000000b3";
    let mut a = Window::start(d.path(), &["--name", "a", "--", "/bin/cat"]);
    let ka = key_of(d.path(), "a").await;
    wait_snapshot(d.path(), &ka, WAIT, |_| true);
    // The same snapshot under another key, then made unreadable: run must not start a new terminal beside it.
    let mut s = saved::read(d.path(), &ka).unwrap();
    s.key = k.into();
    saved::write(d.path(), &s).unwrap();
    a.type_in(b"\x04");
    a.wait_exit();
    let p = saved::path(d.path(), k);
    std::fs::set_permissions(&p, std::fs::Permissions::from_mode(0o000)).unwrap();
    let mut w = Window::start(d.path(), &["--restore", k, "--", "/bin/cat"]);
    assert_ne!(w.wait_exit(), 0, "{:?}", w.output());
    assert!(w.output().contains("could not be read"), "{:?}", w.output());
    assert!(p.exists());
    assert!(std::fs::read_dir(d.path().join("saved")).unwrap().count() == 1, "no new terminal's snapshot");
}

#[tokio::test]
async fn restore_of_a_busy_holders_key_takes_a_new_one() {
    let d = short_dir();
    // A holder (this test) too busy to answer: its socket takes connections and never replies.
    let sock = rapp_term::pty::local::socket_path(d.path(), std::process::id()).unwrap();
    std::fs::create_dir_all(sock.parent().unwrap()).unwrap();
    let _busy = std::os::unix::net::UnixListener::bind(&sock).unwrap();
    let k = "00000000000000b4";
    let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_secs();
    let snap = Snapshot { v: 1, key: k.into(), name: "busy".into(), pid: Some(std::process::id()), saved: now, ..Default::default() };
    saved::write(d.path(), &snap).unwrap();
    let _w = Window::start(d.path(), &["--restore", k, "--", "/bin/cat"]);
    let key = key_of(d.path(), "cat").await;
    assert!(key != k && saved::key_ok(&key), "{key}");
    assert_eq!(saved::read(d.path(), k), Some(snap), "the busy one's snapshot is its own still");
}

#[tokio::test]
async fn restore_of_a_live_key_takes_a_new_one() {
    let d = short_dir();
    let _a = Window::start(d.path(), &["--name", "a", "--", "/bin/cat"]);
    let ka = key_of(d.path(), "a").await;
    wait_snapshot(d.path(), &ka, WAIT, |_| true);
    let _b = Window::start(d.path(), &["--name", "b", "--restore", &ka, "--", "/bin/cat"]);
    let kb = key_of(d.path(), "b").await;
    assert_ne!(ka, kb);
}

#[tokio::test]
async fn a_child_killed_by_a_signal_keeps_the_snapshot() {
    let d = short_dir();
    let mut w = Window::start(d.path(), &["--name", "t", "--", "/bin/cat"]);
    let key = key_of(d.path(), "t").await;
    wait_snapshot(d.path(), &key, WAIT, |_| true);
    // The holder's child (cat), killed from outside: an out-of-memory kill, a shutdown that reached it first.
    let out = Command::new("/usr/bin/pgrep").args(["-P", &w.pid().to_string()]).output().unwrap();
    let child: i32 = String::from_utf8_lossy(&out.stdout).trim().parse().expect("one child");
    unsafe { libc::kill(child, libc::SIGKILL) };
    assert_eq!(w.wait_exit(), 1);
    assert!(saved::path(d.path(), &key).exists());
}

/// A term dir and a home whose `.bash_profile` is `profile`; none when /bin/bash is not here.
fn bash_window(profile: &str) -> Option<(tempfile::TempDir, std::path::PathBuf, tempfile::TempDir, Window)> {
    if !Path::new("/bin/bash").is_file() {
        eprintln!("note: /bin/bash is not installed here; the test is skipped");
        return None;
    }
    let d = short_dir();
    let term = d.path().join("t");
    let home = tempfile::tempdir().unwrap();
    std::fs::write(home.path().join(".bash_profile"), profile).unwrap();
    let env = [("HOME", home.path().display().to_string()), ("PATH", "/usr/bin:/bin:/usr/sbin:/sbin".into()), ("TERM", "xterm-256color".into())];
    let w = Window::start_env(&term, &["--name", "t", "--", "/bin/bash", "-l"], &env, &SEALED);
    Some((d, term, home, w))
}

#[tokio::test]
async fn bash_with_a_debug_trap_saves_the_program_in_front() {
    // bash-preexec, starship: a DEBUG trap already set, so the hook reports no runs and says so.
    let Some((_d, term, _home, mut w)) = bash_window("PS1='$ '\ntrap ':' DEBUG\n") else { return };
    let key = key_of(&term, "t").await;
    w.wait_output("norun=");
    w.wait_output("\x1b]133;A");
    w.type_in(b"sleep 30\r");
    let s = wait_snapshot(&term, &key, WAIT, |s| s.cmd.is_some());
    assert_eq!((s.cmd.as_deref(), s.prog.as_deref(), s.shell.as_str()), (Some("sleep 30"), Some("sleep"), "/bin/bash"));
}

#[tokio::test]
async fn bash_hooked_never_saves_a_line_kept_out_of_history() {
    let Some((_d, term, _home, mut w)) = bash_window("PS1='$ '\nHISTCONTROL=ignorespace\n") else { return };
    let key = key_of(&term, "t").await;
    w.wait_output("\x1b]133;A");
    w.type_in(b" sleep 30\r");
    // Past the quiet time a change would be written after; the program in front is not read for a hooked bash.
    std::thread::sleep(Duration::from_secs(4));
    let s = saved::read(&term, &key).expect("a snapshot");
    assert_eq!((s.cmd, s.prog), (None, None));
}
