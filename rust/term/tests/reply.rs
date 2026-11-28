#![cfg(unix)]
//! A `reply` on the run's local socket, with no view open.

#[path = "common/pty.rs"]
mod pty;

use pty::{short_dir, socket_of, wait_status, Viewer, Window, WAIT};
use rapp_term::pty::local::{self, Probe};
use serde_json::json;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

async fn reply(dir: &std::path::Path, pid: u32, r: serde_json::Value) -> Result<(), Probe> {
    local::reply(&socket_of(dir, pid), &local::token(dir).unwrap(), &r).await
}

#[tokio::test]
async fn reply_writes_text_then_enter_then_keys() {
    let d = short_dir();
    let w = Window::start(d.path(), &["--name", "t", "--", "/bin/cat"]);
    let s = wait_status(d.path(), "t").await;
    reply(d.path(), s.pid, json!({"text":"abc","enter":true,"keys":["x","Enter"]})).await.unwrap();
    w.wait_output("abc\r\nx\r\n");
}

#[tokio::test]
async fn reply_keeps_window_size() {
    let d = short_dir();
    let w = Window::start(d.path(), &["--name", "t", "--", "/bin/cat"]);
    // Someone on the Mac has it open and the window follows them.
    let mut mac = Viewer::connect(d.path(), "t").await;
    mac.open().await;
    mac.send(json!({"t":"view","pane":"%0","cols":90,"rows":20,"fit":true})).await;
    w.wait_output("\x1b[8;20;90t");
    let before = wait_status(d.path(), "t").await;
    // Past the hand-over time, so any viewer's input would now take the seat.
    tokio::time::sleep(Duration::from_millis(2200)).await;
    reply(d.path(), w.pid(), json!({"text":"hello","enter":true})).await.unwrap();
    w.wait_output("hello\r\n");
    // The Mac's view sees it as it sees any output.
    mac.wait_text("hello", 2).await;
    tokio::time::sleep(Duration::from_millis(300)).await;
    let after = wait_status(d.path(), "t").await;
    assert_eq!((after.cols, after.rows, after.viewers), (before.cols, before.rows, 1));
    assert_eq!(w.output().matches("\x1b[8;").count(), 1, "{:?}", w.output());
    // The Mac still holds the seat: its next size is followed at once.
    mac.send(json!({"t":"view","pane":"%0","cols":80,"rows":18,"fit":true})).await;
    w.wait_output("\x1b[8;18;80t");
}

#[tokio::test]
async fn reply_with_no_viewer_never_resizes() {
    let d = short_dir();
    let w = Window::start(d.path(), &["--name", "t", "--", "/bin/cat"]);
    let s = wait_status(d.path(), "t").await;
    reply(d.path(), s.pid, json!({"keys":["y","Enter"]})).await.unwrap();
    w.wait_output("y\r\n");
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert!(!w.output().contains("\x1b[8;"), "{:?}", w.output());
    assert_eq!(wait_status(d.path(), "t").await.viewers, 0);
}

/// A program that asks once (OSC 7501 blocked), reads one line, says it is working, then echoes.
const ASKS: &str = r#"printf '\033]7501;state=blocked:kind=permission\007'; read a; printf 'got[%s]\n' "$a"; printf '\033]7501;state=working\007'; exec cat"#;

async fn wait_ps(dir: &std::path::Path, state: &str) -> u64 {
    let end = Instant::now() + WAIT;
    loop {
        if let Some(p) = wait_status(dir, "t").await.ps.filter(|p| p.state == state) {
            return p.seq;
        }
        assert!(Instant::now() < end, "never {state}");
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
}

#[tokio::test]
async fn reply_refuses_changed_seq() {
    let d = short_dir();
    let w = Window::start(d.path(), &["--name", "t", "--", "/bin/sh", "-c", ASKS]);
    let seq = wait_ps(d.path(), "blocked").await;
    let pid = w.pid();
    assert_eq!(reply(d.path(), pid, json!({"seq": seq + 7, "keys":["y","Enter"]})).await, Err(Probe::Refused("changed".into())));
    tokio::time::sleep(Duration::from_millis(200)).await;
    assert!(!w.output().contains("got["), "{:?}", w.output());
    reply(d.path(), pid, json!({"seq": seq, "keys":["y","Enter"]})).await.unwrap();
    w.wait_output("got[y]");
    let next = wait_ps(d.path(), "working").await;
    assert!(next > seq);
    // The same card a second time: the question is gone.
    assert_eq!(reply(d.path(), pid, json!({"seq": seq, "keys":["y","Enter"]})).await, Err(Probe::Refused("changed".into())));
}

#[tokio::test]
async fn reply_refuses_after_typing() {
    let d = short_dir();
    let mut w = Window::start(d.path(), &["--name", "t", "--", "/bin/sh", "-c", ASKS]);
    let seq = wait_ps(d.path(), "blocked").await;
    // Typed but not yet sent: the program has not moved on, its status has not changed.
    w.type_in(b"n");
    let end = Instant::now() + WAIT;
    while wait_status(d.path(), "t").await.input == 0 {
        assert!(Instant::now() < end);
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    assert_eq!(reply(d.path(), w.pid(), json!({"seq": seq, "keys":["Enter"]})).await, Err(Probe::Refused("typed".into())));
}

fn now_ns() -> u128 {
    SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos()
}

/// Run by hand: `cargo test -p rapp-term --test reply -- --ignored --nocapture`.
#[tokio::test]
#[ignore]
async fn measure_reply_to_program_latency() {
    let d = short_dir();
    let log = d.path().join("got.log");
    let prog = format!(
        "import sys,time\nf=open({:?},'a')\nfor l in iter(sys.stdin.readline,''):\n  f.write(f'{{time.time_ns()}} {{l.strip()}}\\n'); f.flush()\n",
        log.to_str().unwrap()
    );
    let w = Window::start(d.path(), &["--name", "t", "--", "/usr/bin/python3", "-u", "-c", &prog]);
    let s = wait_status(d.path(), "t").await;
    tokio::time::sleep(Duration::from_millis(500)).await;
    let mut sent = Vec::new();
    for i in 0..50 {
        let t = now_ns();
        reply(d.path(), s.pid, json!({"text": format!("m{i}"), "enter": true})).await.unwrap();
        sent.push(t);
        let end = Instant::now() + WAIT;
        while std::fs::read_to_string(&log).unwrap_or_default().lines().count() <= i {
            assert!(Instant::now() < end, "line {i} never came");
            tokio::time::sleep(Duration::from_millis(2)).await;
        }
    }
    let got: Vec<u128> = std::fs::read_to_string(&log).unwrap().lines().map(|l| l.split(' ').next().unwrap().parse().unwrap()).collect();
    let mut us: Vec<f64> = got.iter().zip(&sent).map(|(g, s)| (*g as f64 - *s as f64) / 1000.0).collect();
    us.sort_by(|a, b| a.partial_cmp(b).unwrap());
    println!("reply→program (local socket, n={}): median {:.0} us, max {:.0} us", us.len(), us[us.len() / 2], us[us.len() - 1]);
    assert!(!w.output().contains("\x1b[8;"));
}

#[tokio::test]
async fn reply_too_long_unknown_key_and_empty() {
    let d = short_dir();
    let _w = Window::start(d.path(), &["--name", "t", "--", "/bin/cat"]);
    let s = wait_status(d.path(), "t").await;
    let long = "x".repeat(3001);
    assert_eq!(reply(d.path(), s.pid, json!({"text": long})).await, Err(Probe::Refused("too long".into())));
    assert_eq!(reply(d.path(), s.pid, json!({"keys":["Nope-Nope"]})).await, Err(Probe::Refused("unknown key".into())));
    assert_eq!(reply(d.path(), s.pid, json!({})).await, Err(Probe::Refused("empty".into())));
    assert_eq!(reply(d.path(), s.pid, json!({"text": ""})).await, Err(Probe::Refused("empty".into())));
}

/// An old holder answers any op it does not know with `unsupported`; the status of such a run has no reply bit.
#[tokio::test]
async fn old_holder_says_old_run() {
    let d = short_dir();
    let _w = Window::start(d.path(), &["--name", "t", "--", "/bin/cat"]);
    let s = wait_status(d.path(), "t").await;
    assert!(s.reply);
    let mut j = serde_json::to_value(&s).unwrap();
    j.as_object_mut().unwrap().remove("reply");
    assert!(!serde_json::from_value::<rapp_term::pty::local::Status>(j).unwrap().reply);
    // The unknown op itself:
    let sock = socket_of(d.path(), s.pid);
    let tok = local::token(d.path()).unwrap();
    let mut c = tokio::net::UnixStream::connect(&sock).await.unwrap();
    use tokio::io::{AsyncBufReadExt, AsyncWriteExt};
    c.write_all(format!("{}\n{tok}\n", json!({"op":"nope","v":1})).as_bytes()).await.unwrap();
    let mut line = String::new();
    tokio::io::BufReader::new(c).read_line(&mut line).await.unwrap();
    assert_eq!(serde_json::from_str::<serde_json::Value>(&line).unwrap()["error"], "unsupported");
}
