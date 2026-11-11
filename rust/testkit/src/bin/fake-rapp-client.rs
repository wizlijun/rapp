//! Test double for `rapp-client` (spec §5):
//! `[connect] "rapp://h:p/?…" --token-env VAR --json`.
//! Connects (stderr: `fake-rapp-client: connected`), sends the token line, expects `ok`, sends `ping`, expects the echo,
//! opens a side connection (token, `ok`, `side` echo), writes the port to `client.port`
//! beside itself, prints `ready`, then waits for stdin EOF / quit (exit reason `echo ok`) or the
//! socket closing (exit reason `connection closed`).

use std::io::{BufRead, BufReader, Write};
use std::net::TcpStream;
use std::sync::Mutex;

static OUT: Mutex<()> = Mutex::new(());

fn exit(code: i32, reason: &str) -> ! {
    let _g = OUT.lock().unwrap();
    let mut out = std::io::stdout().lock();
    let _ = writeln!(out, r#"{{"event":"exit","code":{code},"reason":"{reason}"}}"#);
    let _ = out.flush();
    std::process::exit(code)
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).filter(|a| a != "connect").collect();
    let token = args
        .iter()
        .position(|a| a == "--token-env")
        .and_then(|i| args.get(i + 1))
        .and_then(|v| std::env::var(v).ok());
    let addr = args.first().and_then(|a| a.strip_prefix("rapp://")).and_then(|a| a.split('/').next());
    let (Some(token), Some(addr)) = (token, addr) else { exit(2, "usage") };

    let mut s = TcpStream::connect(addr).unwrap_or_else(|_| exit(1, "connect failed"));
    eprintln!("fake-rapp-client: connected");
    let mut r = BufReader::new(s.try_clone().unwrap());
    let mut line = String::new();
    s.write_all(format!("{token}\n").as_bytes()).unwrap();
    if r.read_line(&mut line).is_err() || line != "ok\n" {
        exit(1, "bad token")
    }
    line.clear();
    s.write_all(b"ping\n").unwrap();
    if r.read_line(&mut line).is_err() || line != "ping\n" {
        exit(1, "echo failed")
    }
    // A side connection to the same address: its own token line, then an echo.
    let mut side = TcpStream::connect(addr).unwrap_or_else(|_| exit(1, "side failed"));
    let mut side_r = BufReader::new(side.try_clone().unwrap());
    line.clear();
    side.write_all(format!("{token}\n").as_bytes()).unwrap();
    if side_r.read_line(&mut line).is_err() || line != "ok\n" {
        exit(1, "side failed")
    }
    line.clear();
    side.write_all(b"side\n").unwrap();
    if side_r.read_line(&mut line).is_err() || line != "side\n" {
        exit(1, "side failed")
    }
    if let Some(dir) = std::env::args().next().and_then(|a| std::path::Path::new(&a).parent().map(|d| d.to_path_buf())) {
        let _ = std::fs::write(dir.join("client.port"), addr.rsplit(':').next().unwrap_or(""));
    }
    {
        let _g = OUT.lock().unwrap();
        println!(r#"{{"event":"ready","width":1,"height":1,"title":"echo"}}"#);
        let _ = std::io::stdout().flush();
    }
    std::thread::spawn(move || {
        let mut rest = Vec::new();
        let _ = std::io::Read::read_to_end(&mut r, &mut rest);
        exit(0, "connection closed")
    });
    for l in std::io::stdin().lock().lines() {
        match l {
            Ok(l) if l.contains("\"quit\"") => break,
            Ok(l) if l.contains("\"focus\"") => {
                if let Some(dir) = std::env::args().next().and_then(|a| std::path::Path::new(&a).parent().map(|d| d.to_path_buf())) {
                    use std::io::Write as _;
                    if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(dir.join("client.focus")) {
                        let _ = f.write_all(b"focus\n");
                    }
                }
            }
            Ok(_) => {}
            Err(_) => break,
        }
    }
    exit(0, "echo ok")
}
