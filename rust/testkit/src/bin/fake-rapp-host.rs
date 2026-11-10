//! Test double for `rapp-host` (spec §5), just enough for rapp-service:
//! `check --json`, `list-apps --json`, `serve --app X --bind B --port P --token-env VAR --json`.
//! A "session" is a TCP connection whose first line must be the token; after `ok\n`
//! every byte is echoed back.

use std::io::{BufRead, BufReader, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::Mutex;

static OUT: Mutex<()> = Mutex::new(());

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

fn flag(args: &[String], name: &str) -> Option<String> {
    args.iter().position(|a| a == name).and_then(|i| args.get(i + 1).cloned())
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args.first().map(String::as_str) {
        Some("check") => {
            emit(r#"{"screen_recording":true,"accessibility":true}"#);
            exit(0, "ok")
        }
        Some("list-apps") => {
            emit(r#"{"apps":[{"app":"com.example.echo","name":"Echo"},{"app":"com.apple.Safari","name":"Safari"}]}"#);
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
    let listener = TcpListener::bind((bind.as_str(), port)).unwrap_or_else(|_| exit(1, "bind failed"));
    emit(&format!(r#"{{"event":"listening","port":{}}}"#, listener.local_addr().unwrap().port()));
    std::thread::spawn(move || {
        for s in listener.incoming().flatten() {
            let token = token.clone();
            std::thread::spawn(move || session(s, &token));
        }
    });
    for line in std::io::stdin().lock().lines() {
        match line {
            Ok(l) if l.contains("\"quit\"") => break,
            Ok(_) => {}
            Err(_) => break,
        }
    }
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
    emit(r#"{"event":"session","state":"started","client":"127.0.0.1","mode":"color16","fps":15}"#);
    let _ = s.write_all(b"ok\n");
    let _ = std::io::copy(&mut r, &mut s);
    emit(r#"{"event":"session","state":"ended","reason":"closed"}"#);
}
