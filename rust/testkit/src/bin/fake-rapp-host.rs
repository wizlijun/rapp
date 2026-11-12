//! Test double for `rapp-host` (spec §5), just enough for rapp-service:
//! `check --json`, `list-apps --json`, `serve --app X --bind B --port P --token-env VAR --json`.
//! A "session" is a TCP connection whose first line must be the token; after `ok\n`
//! every byte is echoed back. For the service's logs, `serve` writes one stderr line and each
//! session one `transfer` event. Permissions come from a `perms` file next to argv[0]
//! (`{"screen_recording":…,"accessibility":…}`); without one both are granted, and
//! `broken` makes `check` fail with no output. A `serve_delay` file (ms) slows `serve`'s start.
//! Every stdin line goes to `host.log` as `stdin <app> <line>`. A valid session whose port a
//! `{"cmd":"peer",...}` line announced closes the previous such session's TCP (a takeover); the
//! others (side connections, unnamed B) neither take over nor get taken over. Inside a session
//! the whole line `input` emits `input` and `blocked <name>` emits `input_blocked` (both still echoed).

use std::io::{BufRead, BufReader, Read, Write};
use std::net::{Shutdown, TcpListener, TcpStream};
use std::sync::Mutex;

static OUT: Mutex<()> = Mutex::new(());
/// The live session (its number and a handle to close it), and the last number given out.
static LIVE: Mutex<(u64, Option<(u64, TcpStream)>)> = Mutex::new((0, None));
/// Ports announced by `peer` lines on stdin.
static NAMED: Mutex<Vec<u16>> = Mutex::new(Vec::new());

/// The `port` of a `{"cmd":"peer","port":P,...}` line.
fn peer_port(line: &str) -> Option<u16> {
    if !line.contains(r#""cmd":"peer""#) {
        return None;
    }
    let rest = &line[line.find(r#""port":"#)? + 7..];
    rest[..rest.find(|c: char| !c.is_ascii_digit()).unwrap_or(rest.len())].parse().ok()
}

/// Whether the service announced `port` (it does so before B can say hello; a short wait covers
/// the stdin line arriving a moment after the hello).
fn named(port: u16) -> bool {
    for _ in 0..20 {
        if NAMED.lock().unwrap().contains(&port) {
            return true;
        }
        std::thread::sleep(std::time::Duration::from_millis(5));
    }
    false
}

fn emit(line: &str) {
    let _g = OUT.lock().unwrap();
    let mut out = std::io::stdout().lock();
    let _ = writeln!(out, "{line}");
    let _ = out.flush();
}

fn exit(code: i32, reason: &str) -> ! {
    emit(&format!(r#"{{"event":"exit","code":{code},"reason":"{reason}"}}"#));
    std::process::exit(code)
}

/// Appends to `host.log` next to argv[0] (tests give each case its own bin dir).
fn log(line: &str) {
    let path = bin_dir().join("host.log");
    if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(path) {
        let _ = writeln!(f, "{line}");
    }
}

fn bin_dir() -> std::path::PathBuf {
    let argv0 = std::path::PathBuf::from(std::env::args().next().unwrap_or_default());
    argv0.parent().unwrap_or(std::path::Path::new(".")).to_path_buf()
}

/// `(screen_recording, accessibility)` from the `perms` file.
fn perms() -> (bool, bool) {
    let v = std::fs::read_to_string(bin_dir().join("perms")).unwrap_or_default().replace(' ', "");
    (!v.contains(r#""screen_recording":false"#), !v.contains(r#""accessibility":false"#))
}

fn perms_json() -> String {
    let (s, a) = perms();
    format!(r#"{{"screen_recording":{s},"accessibility":{a}}}"#)
}

fn flag(args: &[String], name: &str) -> Option<String> {
    args.iter().position(|a| a == name).and_then(|i| args.get(i + 1).cloned())
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args.first().map(String::as_str) {
        Some("check") => {
            log(&format!("check{}", if args.iter().any(|a| a == "--prompt") { " --prompt" } else { "" }));
            if std::fs::read_to_string(bin_dir().join("perms")).is_ok_and(|v| v.trim() == "broken") {
                std::process::exit(1);
            }
            emit(&perms_json());
            exit(0, "ok")
        }
        Some("list-apps") => {
            emit(&format!(
                r#"{{"apps":[{{"app":"com.example.echo","name":"Echo"}},{{"app":"com.apple.Safari","name":"Safari"}}],"permissions":{}}}"#,
                perms_json()
            ));
            exit(0, "ok")
        }
        Some("serve") => serve(&args[1..]),
        _ => {
            eprintln!("fake-rapp-host: usage: check|list-apps|serve");
            std::process::exit(2)
        }
    }
}

fn serve(args: &[String]) -> ! {
    let token = flag(args, "--token-env").and_then(|v| std::env::var(v).ok());
    let Some(token) = token else { exit(2, "missing token") };
    let bind = flag(args, "--bind").unwrap_or_else(|| "0.0.0.0".into());
    let port: u16 = flag(args, "--port").and_then(|p| p.parse().ok()).unwrap_or(0);
    let app = flag(args, "--app").unwrap_or_default();
    let (screen, ax) = perms();
    let missing: Vec<&str> =
        [(!screen).then_some("Screen Recording"), (!ax).then_some("Accessibility")].into_iter().flatten().collect();
    if !missing.is_empty() {
        exit(3, &format!("missing permission: {}\\nAllow rapp (or the terminal running rapp-host) under System Settings > Privacy & Security, then connect again.", missing.join(", ")))
    }
    // `serve_delay` next to argv[0] (milliseconds): a slow start, so a session stays "opening".
    if let Ok(ms) = std::fs::read_to_string(bin_dir().join("serve_delay")) {
        log(&format!("delay {app}"));
        std::thread::sleep(std::time::Duration::from_millis(ms.trim().parse().unwrap_or(0)));
    }
    let listener = TcpListener::bind((bind.as_str(), port)).unwrap_or_else(|_| exit(1, "bind failed"));
    log(&format!("start {app}"));
    emit(&format!(r#"{{"event":"listening","port":{}}}"#, listener.local_addr().unwrap().port()));
    eprintln!("fake-rapp-host: serving {app}");
    std::thread::spawn(move || {
        for s in listener.incoming().flatten() {
            let token = token.clone();
            std::thread::spawn(move || session(s, &token));
        }
    });
    for line in std::io::stdin().lock().lines() {
        let Ok(l) = line else { break };
        log(&format!("stdin {app} {l}"));
        if let Some(p) = peer_port(&l) {
            NAMED.lock().unwrap().push(p);
        }
        if l.contains("\"quit\"") {
            break;
        }
    }
    log(&format!("exit {app}"));
    exit(0, "stdin closed")
}

fn session(mut s: TcpStream, token: &str) {
    let mut r = BufReader::new(s.try_clone().unwrap());
    let mut first = String::new();
    if r.read_line(&mut first).is_err() || first.trim_end() != token {
        emit(r#"{"event":"rejected","reason":"bad token"}"#);
        let _ = s.write_all(b"bad token\n");
        return;
    }
    let me = s.peer_addr().is_ok_and(|a| named(a.port())).then(|| {
        let mut live = LIVE.lock().unwrap();
        live.0 += 1;
        let me = live.0;
        if let Some((_, old)) = live.1.replace((me, s.try_clone().unwrap())) {
            let _ = old.shutdown(Shutdown::Both);
        }
        me
    });
    emit(r#"{"event":"session","state":"started","client":"127.0.0.1","mode":"color16","fps":15}"#);
    emit(r#"{"event":"transfer","dir":"b_to_a","kind":"files","bytes":5,"name":"a.txt"}"#);
    let _ = s.write_all(b"ok\n");
    let (mut buf, mut line) = ([0u8; 8192], Vec::new());
    while let Ok(n @ 1..) = r.read(&mut buf) {
        line.extend_from_slice(&buf[..n]);
        while let Some(i) = line.iter().position(|&b| b == b'\n') {
            let l: Vec<u8> = line.drain(..=i).collect();
            let l = String::from_utf8_lossy(&l[..i]).into_owned();
            if l == "input" {
                emit(r#"{"event":"input"}"#);
            } else if let Some(name) = l.strip_prefix("blocked ") {
                emit(&format!(r#"{{"by":"{name}","event":"input_blocked"}}"#));
            }
        }
        if s.write_all(&buf[..n]).is_err() {
            break;
        }
    }
    let mut live = LIVE.lock().unwrap();
    if live.1.as_ref().is_some_and(|(id, _)| Some(*id) == me) {
        live.1 = None;
    }
    drop(live);
    emit(r#"{"event":"session","state":"ended","reason":"closed"}"#);
}
