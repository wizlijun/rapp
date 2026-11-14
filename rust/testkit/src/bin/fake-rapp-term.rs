//! Test double for `rapp-term serve`, with fake data: the same command line
//! (`serve --bind B --port P --token-env VAR --config term.json [--json]`), the same connections (a request
//! line, then the token line) and the same events (`listening`, `ended`, `exit`) as the real worker.
//! `term.json` is read afresh for each request and polled by `watch`: `allow:false` answers "terminal sessions
//! are off". The data: one session `term:tmux:work` here and `term:tmux@<name>:main` on each target; a target
//! named `down` is unreachable. `view` says hello and echoes every line back. `term.log` next to argv[0]
//! gets `argv <arguments>` per start, `view <term> <lines>` per view (never the lines) and `watch closed`.

use serde_json::{json, Value};
use std::io::{BufRead, BufReader, Read, Write};
use std::net::{Shutdown, TcpListener, TcpStream};
use std::sync::Mutex;
use std::time::Duration;

const OFF: &str = "terminal sessions are off";
const INVALID: &str = "term.json is invalid";
static OUT: Mutex<()> = Mutex::new(());
/// Every connection, so stdin EOF can close them all.
static CONNS: Mutex<Vec<TcpStream>> = Mutex::new(Vec::new());

fn emit(v: &Value) {
    let _g = OUT.lock().unwrap();
    let mut out = std::io::stdout().lock();
    let _ = writeln!(out, "{v}");
    let _ = out.flush();
}

fn exit(code: i32, reason: &str) -> ! {
    emit(&json!({"event":"exit","code":code,"reason":reason}));
    std::process::exit(code)
}

fn bin_dir() -> std::path::PathBuf {
    let argv0 = std::path::PathBuf::from(std::env::args().next().unwrap_or_default());
    argv0.parent().unwrap_or(std::path::Path::new(".")).to_path_buf()
}

/// Appends to `term.log` next to argv[0] (tests give each case its own bin dir).
fn log(line: &str) {
    if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(bin_dir().join("term.log")) {
        let _ = writeln!(f, "{line}");
    }
}

fn flag(args: &[String], name: &str) -> Option<String> {
    args.iter().position(|a| a == name).and_then(|i| args.get(i + 1).cloned())
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    log(&format!("argv {}", args.join(" ")));
    if args.first().map(String::as_str) != Some("serve") {
        eprintln!("fake-rapp-term: usage: serve");
        std::process::exit(2)
    }
    let token = flag(&args, "--token-env").and_then(|v| std::env::var(v).ok()).filter(|t| !t.is_empty());
    let Some(token) = token else { exit(2, "the --token-env variable is not set") };
    let Some(config) = flag(&args, "--config") else { exit(2, "serve needs --config") };
    let bind = flag(&args, "--bind").unwrap_or_else(|| "127.0.0.1".into());
    let port: u16 = flag(&args, "--port").and_then(|p| p.parse().ok()).unwrap_or(0);
    let listener = TcpListener::bind((bind.as_str(), port)).unwrap_or_else(|_| exit(1, "could not listen"));
    emit(&json!({"event":"listening","port":listener.local_addr().unwrap().port()}));
    std::thread::spawn(move || {
        for s in listener.incoming().flatten() {
            CONNS.lock().unwrap().push(s.try_clone().unwrap());
            let (token, config) = (token.clone(), config.clone());
            std::thread::spawn(move || conn(s, &token, &config));
        }
    });
    let mut sink = Vec::new();
    let _ = std::io::stdin().lock().read_to_end(&mut sink);
    for s in CONNS.lock().unwrap().iter() {
        let _ = s.shutdown(Shutdown::Both);
    }
    // Let the views and watches that just lost their connection log and report `ended`, as the real worker does.
    std::thread::sleep(Duration::from_millis(200));
    exit(0, "stdin closed")
}

/// `term.json` as the text it has now and, when it can be used, its value.
fn config(path: &str) -> (String, Result<Value, &'static str>) {
    // No file is the default, as in the real worker.
    let text = match std::fs::read_to_string(path) {
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => "{}".to_string(),
        r => r.unwrap_or_default(),
    };
    let v = serde_json::from_str::<Value>(&text).ok().filter(Value::is_object).ok_or(INVALID);
    let v = v.and_then(|v| if v["allow"] == json!(false) { Err(OFF) } else { Ok(v) });
    (text, v)
}

fn row(host: Option<&str>, name: &str) -> Value {
    let id = match host {
        Some(h) => format!("term:tmux@{h}:{name}"),
        None => format!("term:tmux:{name}"),
    };
    json!({"id":id,"host":host,"name":name,"command":"bash","panes":1,"attached":0,"activity":0,"dead":false,"unread":false})
}

fn term_list(cfg: &Value) -> Value {
    let (mut terms, mut hosts) = (vec![row(None, "work")], vec![json!({"host":null})]);
    for t in cfg["targets"].as_array().cloned().unwrap_or_default() {
        let name = t["name"].as_str().unwrap_or_default();
        let mut h = json!({"host":name,"target":t["target"]});
        if !t["tmux"].is_null() {
            h["tmux"] = t["tmux"].clone();
        }
        if name == "down" {
            h["error"] = json!("unreachable");
        } else {
            terms.push(row(Some(name), "main"));
        }
        hosts.push(h);
    }
    json!({"terms":terms,"hosts":hosts})
}

fn send(s: &mut TcpStream, v: &Value) -> bool {
    writeln!(s, "{v}").is_ok()
}

fn conn(mut s: TcpStream, token: &str, config_path: &str) {
    let mut r = BufReader::new(s.try_clone().unwrap());
    let _ = s.set_read_timeout(Some(Duration::from_secs(30)));
    let (mut req, mut tok) = (String::new(), String::new());
    if !matches!(r.read_line(&mut req), Ok(1..)) || !matches!(r.read_line(&mut tok), Ok(1..)) {
        return;
    }
    let _ = s.set_read_timeout(None);
    if tok.trim_end_matches('\n') != token {
        send(&mut s, &json!({"error":"bad token"}));
        return;
    }
    let Ok(req) = serde_json::from_str::<Value>(&req) else {
        send(&mut s, &json!({"error":"bad request"}));
        return;
    };
    let cfg = config(config_path).1;
    match req["op"].as_str() {
        Some("list") => {
            send(&mut s, &cfg.map_or_else(|e| json!({"error":e}), |c| term_list(&c)));
        }
        Some("watch") => match cfg {
            Ok(_) => watch(s, r, config_path),
            Err(e) => {
                send(&mut s, &json!({"error":e}));
            }
        },
        Some("new") => {
            let v = match cfg {
                Err(e) => json!({"error":e}),
                Ok(_) => match (req["name"].as_str().or(req["command"][0].as_str()), req["host"].as_str()) {
                    (None, _) => json!({"error":"no command"}),
                    (Some(n), None) => json!({"ok":true,"id":format!("term:tmux:{n}")}),
                    (Some(n), Some(h)) => json!({"ok":true,"id":format!("term:tmux@{h}:{n}")}),
                },
            };
            send(&mut s, &v);
        }
        Some("view") => view(s, r, &req, cfg.err()),
        _ => {
            send(&mut s, &json!({"error":"bad request"}));
        }
    }
}

/// The list now, and again within 100 ms of `term.json` changing, until the other end closes.
fn watch(mut s: TcpStream, mut r: BufReader<TcpStream>, config_path: &str) {
    let _ = s.set_read_timeout(Some(Duration::from_millis(20)));
    let (mut last, mut sent): (Option<String>, Option<Value>) = (None, None);
    'run: loop {
        let (text, cfg) = config(config_path);
        if last.as_ref() != Some(&text) {
            last = Some(text);
            match cfg {
                Err(OFF) => {
                    send(&mut s, &json!({"error":OFF}));
                    break;
                }
                // Halfway through being rewritten, perhaps: the list stays as it was.
                Err(_) => {}
                Ok(c) => {
                    let list = term_list(&c);
                    if sent.as_ref() != Some(&list) {
                        if !send(&mut s, &list) {
                            break;
                        }
                        sent = Some(list);
                    }
                }
            }
        }
        // Anything the other end writes is ignored; its close ends the watch.
        let mut buf = [0u8; 256];
        loop {
            match r.read(&mut buf) {
                Ok(0) => break 'run,
                Ok(_) => {}
                Err(e) if matches!(e.kind(), std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut) => break,
                Err(_) => break 'run,
            }
        }
    }
    let _ = s.shutdown(Shutdown::Both);
    log("watch closed");
}

/// Hello, then every line received is sent back as it came; the count of lines after the token line is the
/// view's inputs.
fn view(mut s: TcpStream, mut r: BufReader<TcpStream>, req: &Value, off: Option<&str>) {
    if let Some(e) = off {
        send(&mut s, &json!({"t":"error","error":e}));
        return;
    }
    let term = req["term"].as_str().unwrap_or_default().to_string();
    send(&mut s, &json!({"t":"hello","fake":true,"term":term}));
    let (mut n, mut line) = (0u64, Vec::new());
    loop {
        line.clear();
        match r.read_until(b'\n', &mut line) {
            Ok(1..) if line.ends_with(b"\n") => {
                n += 1;
                if s.write_all(&line).is_err() {
                    break;
                }
            }
            _ => break,
        }
    }
    log(&format!("view {term} {n}"));
    if let Some(sid) = req["sid"].as_u64() {
        emit(&json!({"event":"ended","sid":sid,"term":term,"inputs":n}));
    }
    let _ = s.shutdown(Shutdown::Both);
}
