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
        ("dance", token.as_str(), json!({"error":"unsupported","v":1})),
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
