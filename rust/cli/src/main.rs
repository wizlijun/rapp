//! `rapp-cli share|unshare|hosts|pipe` — talks to the local service's IPC only.
//! The service's `local/` directory is found the way the service finds it (`$RAPP_HOME`, the
//! `data-root` pointer, `~/rapp`); `$RAPP_LOCAL` names it directly (for tests).

mod args;
mod say;

use args::Cmd;
use serde_json::{json, Value};
use std::path::PathBuf;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::TcpStream;

const DEFAULT_IPC_PORT: u16 = 22029;
const NOT_RUNNING: &str = "本机的 rapp 服务没有在运行";

fn local_dir() -> PathBuf {
    match std::env::var_os("RAPP_LOCAL").filter(|v| !v.is_empty()) {
        Some(dir) => dir.into(),
        None => rapp_net::config::local(&rapp_net::config::home()),
    }
}

fn ipc_port(local: &std::path::Path) -> u16 {
    std::fs::read(local.join("service.json"))
        .ok()
        .and_then(|b| serde_json::from_slice::<Value>(&b).ok())
        .and_then(|v| v["ipc_port"].as_u64())
        .and_then(|p| u16::try_from(p).ok())
        .filter(|&p| p != 0)
        .unwrap_or(DEFAULT_IPC_PORT)
}

/// A connection to the service's IPC with the token line already sent; `None` when the service
/// cannot be reached.
async fn connect() -> Option<TcpStream> {
    let local = local_dir();
    let token = std::fs::read_to_string(local.join("ipc.token")).ok()?;
    let mut tcp = TcpStream::connect(("127.0.0.1", ipc_port(&local))).await.ok()?;
    tcp.write_all(format!("{}\n", json!({"token": token.trim()})).as_bytes()).await.ok()?;
    Some(tcp)
}

fn fail(line: &str) -> ! {
    eprintln!("{line}");
    std::process::exit(1)
}

/// Sends `cmd` and reads its one reply line; the reader is returned for `pipe`, whose stream
/// follows the reply.
async fn call(cmd: Value) -> (Value, BufReader<tokio::net::tcp::OwnedReadHalf>, tokio::net::tcp::OwnedWriteHalf) {
    let Some(tcp) = connect().await else { fail(NOT_RUNNING) };
    let (r, mut w) = tcp.into_split();
    if w.write_all(format!("{cmd}\n").as_bytes()).await.is_err() {
        fail(NOT_RUNNING);
    }
    let mut r = BufReader::new(r);
    let mut line = String::new();
    match r.read_line(&mut line).await {
        Ok(n) if n > 0 => {}
        _ => fail(NOT_RUNNING),
    }
    match serde_json::from_str(&line) {
        Ok(v) => (v, r, w),
        Err(_) => fail(NOT_RUNNING),
    }
}

fn error_of(reply: &Value) -> &str {
    reply["error"].as_str().unwrap_or("")
}

#[tokio::main]
async fn main() {
    let argv: Vec<String> = std::env::args().skip(1).collect();
    if argv.is_empty() || argv[0] == "-h" || argv[0] == "--help" {
        println!("{}", args::USAGE);
        return;
    }
    let cmd = match args::parse(&argv) {
        Ok(c) => c,
        Err(line) => {
            eprintln!("{line}\n{}", args::USAGE);
            std::process::exit(2);
        }
    };
    match cmd {
        Cmd::Share { ports, .. } if ports.is_empty() => {
            let (r, ..) = call(json!({"cmd":"shares"})).await;
            if r["ok"] != true {
                fail(&format!("没有成功：{}", error_of(&r)));
            }
            print!("{}", say::table(&r));
        }
        Cmd::Share { ports, allow, raw, note, proto } => {
            // What is not written is not sent: the service keeps what the port's share has now.
            let mut c = json!({"cmd":"share","ports":ports});
            if raw {
                c["raw"] = json!(true);
            }
            if !allow.is_empty() {
                c["allow"] = json!(allow);
            }
            if let Some(n) = note {
                c["note"] = json!(n);
            }
            if let Some(p) = proto {
                c["proto"] = json!(p);
            }
            let (r, ..) = call(c).await;
            if r["ok"] != true {
                fail(&say::share_error(error_of(&r)));
            }
            print!("{}", say::shared(&r));
        }
        Cmd::Unshare { port } => {
            let (r, ..) = call(json!({"cmd":"unshare","port":port})).await;
            if r["ok"] != true {
                fail(&say::share_error(error_of(&r)));
            }
            if r["was"] == true {
                println!("已取消分享 {port}");
            } else {
                println!("{port} 本来就没有分享");
            }
        }
        Cmd::Hosts => {
            let (r, ..) = call(json!({"cmd":"hosts"})).await;
            if r["ok"] != true {
                fail(&format!("没有成功：{}", error_of(&r)));
            }
            print!("{}", say::hosts(&r));
        }
        Cmd::Pipe { to, port } => pipe(to, port).await,
    }
}

/// Stdin to the port and the port to stdout; either end finishing is passed on as a half-close.
async fn pipe(to: String, port: u16) {
    let (r, mut from_port, mut to_port) = call(json!({"cmd":"pipe","to":to,"port":port})).await;
    if r["ok"] != true {
        fail(&say::pipe_error(&to, port, error_of(&r)));
    }
    let up = tokio::spawn(async move {
        let _ = tokio::io::copy(&mut tokio::io::stdin(), &mut to_port).await;
        let _ = to_port.shutdown().await;
    });
    let down = tokio::spawn(async move {
        let mut out = tokio::io::stdout();
        let _ = tokio::io::copy(&mut from_port, &mut out).await;
        let _ = out.flush().await;
    });
    let _ = down.await;
    let _ = up.await;
    // A blocking read of stdin must not keep the runtime from ending.
    std::process::exit(0);
}
