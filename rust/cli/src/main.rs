//! `rapp-cli share|unshare|hosts|pipe|update` — talks to the local service's IPC only.
//! The service's `local/` directory is found the way the service finds it (`$RAPP_HOME`, the
//! `data-root` pointer, `~/rapp`); `$RAPP_LOCAL` names it directly (for tests).

mod args;
mod ipc;
mod out;
mod say;
mod update;

use args::Cmd;
use serde_json::{json, Value};
use tokio::io::{AsyncWriteExt, BufReader};
use tokio::net::tcp::{OwnedReadHalf, OwnedWriteHalf};

const NOT_RUNNING: &str = "本机的 rApp 服务没有在运行";

fn fail(line: &str) -> ! {
    eprintln!("{line}");
    std::process::exit(1)
}

/// Sends `cmd` and reads its one reply line; the reader is returned for `pipe`, whose stream
/// follows the reply. The service not answering exits 3.
async fn call(cmd: Value) -> (Value, BufReader<OwnedReadHalf>, OwnedWriteHalf) {
    match ipc::open(cmd).await {
        Ok(r) => r,
        Err(ipc::Gone) => {
            eprintln!("{NOT_RUNNING}");
            std::process::exit(out::exit_code("not_running"))
        }
    }
}

fn error_of(reply: &Value) -> &str {
    reply["error"].as_str().unwrap_or("")
}

#[tokio::main]
async fn main() {
    let argv: Vec<String> = std::env::args().skip(1).collect();
    if argv == ["--version"] {
        println!("rapp {}", env!("CARGO_PKG_VERSION"));
        return;
    }
    if argv.is_empty() || argv[0] == "-h" || argv[0] == "--help" {
        println!("{}", args::USAGE);
        return;
    }
    let cmd = match args::parse(&argv) {
        Ok(c) => c,
        Err(line) => {
            // An agent asking for JSON gets its usage error as JSON too.
            if argv.first().map(String::as_str) == Some("update") && argv.iter().any(|a| a == "--json") {
                out::Out { json: true }.fail("usage", &line, None);
            }
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
        Cmd::TermRestore { list, forget, picks } => term_restore(list, forget, picks).await,
        Cmd::Update { what, yes, timeout, json } => update::run(what, yes, timeout, out::Out { json }).await,
    }
}

/// `rapp term restore`: always sends explicit keys, resolved from one `term_saved` call, so what is restored is
/// what `--list` shows.
async fn term_restore(list: bool, forget: bool, picks: Vec<String>) {
    if forget {
        let (r, ..) = call(json!({"cmd":"term_forget"})).await;
        if r["ok"] != true {
            fail(&format!("没有成功：{}", say::plain(error_of(&r))));
        }
        println!("已清掉 {} 个", r["forgot"].as_u64().unwrap_or(0));
        return;
    }
    let (saved, ..) = call(json!({"cmd":"term_saved"})).await;
    if saved["ok"] != true {
        fail(&format!("没有成功：{}", say::plain(error_of(&saved))));
    }
    if list {
        let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0, |d| d.as_secs());
        print!("{}", say::saved_table(&saved, now));
        return;
    }
    if saved["saved"].as_array().is_none_or(Vec::is_empty) {
        println!("没有可以恢复的终端");
        return;
    }
    let keys = match say::pick_keys(&saved, &picks) {
        Ok(k) => k,
        Err(line) => {
            eprintln!("{line}");
            std::process::exit(2);
        }
    };
    let (r, ..) = call(json!({"cmd":"term_restore","keys":keys})).await;
    let (line, failed) = say::restored(&r);
    if failed {
        fail(&line);
    }
    println!("{line}");
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
