mod common;

use std::collections::HashSet;
use std::io::{BufRead, BufReader, Write};
use std::process::{Command, Stdio};
use std::sync::mpsc;
use std::time::{Duration, Instant};

const BIN: &str = env!("CARGO_BIN_EXE_rapp-term");

/// What one finished run of the binary left behind.
struct O {
    code: i32,
    stdout: String,
    stderr: String,
}

fn run(args: &[&str]) -> O {
    let out = Command::new(BIN).args(args).stdin(Stdio::null()).output().unwrap();
    O {
        code: out.status.code().expect("rapp-term was killed by a signal"),
        stdout: String::from_utf8_lossy(&out.stdout).into_owned(),
        stderr: String::from_utf8_lossy(&out.stderr).into_owned(),
    }
}

#[test]
fn version_json() {
    let o = run(&["version", "--json"]);
    assert_eq!(o.code, 0);
    let v: serde_json::Value = serde_json::from_str(o.stdout.trim()).unwrap();
    assert_eq!(v["proto"], 1);
    assert_eq!(v["version"], env!("CARGO_PKG_VERSION"));
}

#[test]
fn bad_arguments_exit_2() {
    for a in [
        &[][..],
        &["nope"],
        &["watch"],
        &["watch", "com.apple.Safari"],
        &["run"],
        &["run", "--size", "axb", "--", "sh"],
        &["list", "--ssh", "-oProxyCommand=x"],
    ] {
        assert_eq!(run(a).code, 2, "{a:?}");
    }
}

#[test]
fn list_run_and_watch_against_a_private_server() {
    let Some(s) = common::Server::start() else { return };
    let o = run(&["run", "--socket", &s.socket, "--name", "cli demo", "--size", "90x20", "--", "cat"]);
    assert_eq!((o.code, o.stdout.trim()), (0, "term:tmux:cli demo"));
    s.wait_command("cli demo", "cat");
    let o = run(&["list", "--json", "--socket", &s.socket]);
    let v: serde_json::Value = serde_json::from_str(o.stdout.trim()).unwrap();
    assert_eq!(v["sessions"][0]["id"], "term:tmux:cli demo");
    assert_eq!(v["sessions"][0]["command"], "cat");

    // watch: one view line (the pane taken from the first pane list), then at least one hello, panes and screen;
    // closing stdin ends the process with 0.
    let mut child = Command::new(BIN)
        .args(["watch", "--socket", &s.socket, "term:tmux:cli demo"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let mut stdin = child.stdin.take().unwrap();
    let stdout = child.stdout.take().unwrap();
    let (tx, rx) = mpsc::channel();
    std::thread::spawn(move || {
        for l in BufReader::new(stdout).lines() {
            let Ok(l) = l else { break };
            if tx.send(l).is_err() {
                break;
            }
        }
    });
    let next = || -> serde_json::Value {
        let l = rx.recv_timeout(Duration::from_secs(5)).expect("no message from watch within 5 seconds");
        serde_json::from_str(&l).unwrap()
    };
    let mut seen = HashSet::new();
    let pane = loop {
        let m = next();
        seen.insert(m["t"].as_str().unwrap().to_string());
        if m["t"] == "panes" {
            break m["panes"][0]["id"].as_str().unwrap().to_string();
        }
    };
    let view = serde_json::json!({"t": "view", "pane": pane, "cols": 90, "rows": 20});
    writeln!(stdin, "{view}").unwrap();
    loop {
        let m = next();
        seen.insert(m["t"].as_str().unwrap().to_string());
        if m["t"] == "screen" {
            break;
        }
    }
    for t in ["hello", "panes", "screen"] {
        assert!(seen.contains(t), "no {t} message");
    }
    drop(stdin);
    let end = Instant::now() + Duration::from_secs(5);
    let status = loop {
        if let Some(st) = child.try_wait().unwrap() {
            break st;
        }
        assert!(Instant::now() < end, "watch did not end within 5 seconds of stdin closing");
        std::thread::sleep(Duration::from_millis(20));
    };
    assert_eq!(status.code(), Some(0));
}

#[test]
fn runtime_errors_exit_1_and_do_not_echo_content() {
    let Some(s) = common::Server::start() else { return };
    let o = run(&["run", "--socket", &s.socket, "--tmux", "/nonexistent/tmux", "--", "echo", "SECRET-TEXT"]);
    assert_eq!(o.code, 1);
    assert!(!o.stderr.contains("SECRET-TEXT"));
}

#[test]
fn watch_ends_when_the_session_does_though_stdin_stays_open() {
    let Some(s) = common::Server::start() else { return };
    s.raw(&["new-session", "-d", "-s", "w", "-x", "80", "-y", "24", "cat"]);
    let mut child = Command::new(BIN)
        .args(["watch", "--socket", &s.socket, "term:tmux:w"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    let mut stdin = child.stdin.take().unwrap();
    let mut lines = BufReader::new(child.stdout.take().unwrap()).lines();
    let mut next = || -> serde_json::Value { serde_json::from_str(&lines.next().unwrap().unwrap()).unwrap() };
    let pane = loop {
        let m = next();
        if m["t"] == "panes" {
            break m["panes"][0]["id"].as_str().unwrap().to_string();
        }
    };
    writeln!(stdin, "{}", serde_json::json!({"t": "view", "pane": pane, "cols": 80, "rows": 24})).unwrap();
    while next()["t"] != "screen" {}
    s.raw(&["kill-session", "-t", "w"]);
    let end = Instant::now() + Duration::from_secs(5);
    let status = loop {
        if let Some(st) = child.try_wait().unwrap() {
            break st;
        }
        if Instant::now() > end {
            let _ = child.kill();
            panic!("watch did not end within 5 seconds of the session ending");
        }
        std::thread::sleep(Duration::from_millis(20));
    };
    assert_eq!(status.code(), Some(0));
    drop(stdin);
}
