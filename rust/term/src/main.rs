//! The `rapp-term` command: version, run, serve.
//!
//! Exit codes: 0 ok, 1 a runtime error, 2 an argument error or `run` without a terminal. `run` otherwise exits as
//! its program did (see `pty::holder`). Errors go to stderr as one line and never carry the command, the screen or
//! the input.

use rapp_term::config;
use rapp_term::id::session_name;
use rapp_term::proto::PROTO;
use rapp_term::pty::holder::{self, NoTerminal, RunOpts};
use rapp_term::pty::local;
use rapp_term::serve::{self, ServeOpts};
use serde::Serialize;
use std::io::Write;
use std::net::IpAddr;
use std::path::{Path, PathBuf};

const USAGE: &str = "\
usage: rapp-term version [--json]
       rapp-term run [--name N] [--cwd DIR] [--dir DIR] [--ticket T] [-- COMMAND...]
       rapp-term serve --token-env <variable> --config <path> [--bind <address>] [--port <port>] [--json]";

/// Why the command stopped.
enum Fail {
    /// Exit 2.
    Usage(String),
    /// Exit 1.
    Runtime(String),
    /// Exit 2: `run` started without a terminal.
    Terminal(String),
}

fn usage(m: impl Into<String>) -> Fail {
    Fail::Usage(m.into())
}

fn runtime(m: impl Into<String>) -> Fail {
    Fail::Runtime(m.into())
}

type Res<T> = Result<T, Fail>;

/// The parsed options of one subcommand.
#[derive(Default)]
struct Args {
    json: bool,
    name: Option<String>,
    token_env: Option<String>,
    config: Option<String>,
    bind: Option<String>,
    port: Option<String>,
    cwd: Option<String>,
    dir: Option<String>,
    ticket: Option<String>,
    /// Hidden: the program `serve` runs to open a window instead of `open -a`, for tests.
    launch_with: Option<String>,
    /// Arguments that are not options.
    pos: Vec<String>,
    /// Everything after `--`.
    command: Option<Vec<String>>,
}

/// Parse `argv` taking only the options in `allowed` (names without the dashes; `"--"` allows a command after
/// `--`). Errors never repeat what was given: it may be the start of a command.
fn parse_args(allowed: &[&str], argv: &[String]) -> Res<Args> {
    let mut a = Args::default();
    let mut it = argv.iter();
    while let Some(arg) = it.next() {
        if arg == "--" {
            if !allowed.contains(&"--") {
                return Err(usage("unexpected --"));
            }
            a.command = Some(it.cloned().collect());
            break;
        }
        let Some(opt) = arg.strip_prefix("--") else {
            if arg.starts_with('-') && arg.len() > 1 {
                return Err(usage("unknown option"));
            }
            a.pos.push(arg.clone());
            continue;
        };
        if !allowed.contains(&opt) {
            return Err(usage("unknown option"));
        }
        if opt == "json" {
            a.json = true;
            continue;
        }
        let slot = match opt {
            "name" => &mut a.name,
            "token-env" => &mut a.token_env,
            "config" => &mut a.config,
            "bind" => &mut a.bind,
            "port" => &mut a.port,
            "cwd" => &mut a.cwd,
            "dir" => &mut a.dir,
            "ticket" => &mut a.ticket,
            "launch-with" => &mut a.launch_with,
            _ => return Err(usage("unknown option")),
        };
        // The value is the next argument whatever it looks like.
        let Some(v) = it.next() else {
            return Err(usage(format!("--{opt} needs a value")));
        };
        *slot = Some(v.clone());
    }
    Ok(a)
}

fn version(a: &Args) {
    #[derive(Serialize)]
    struct V {
        version: &'static str,
        proto: u32,
    }
    if a.json {
        let v = V { version: env!("CARGO_PKG_VERSION"), proto: PROTO };
        println!("{}", serde_json::to_string(&v).expect("always serializes"));
    } else {
        println!("rapp-term {} (protocol {PROTO})", env!("CARGO_PKG_VERSION"));
    }
}

/// A program in a pty in this terminal window; the program's exit code.
async fn run(a: &Args) -> Res<i32> {
    if !a.pos.is_empty() {
        return Err(usage("unexpected argument: the command goes after --"));
    }
    if a.name.as_deref().is_some_and(|n| session_name(n).is_none()) {
        return Err(usage("invalid session name"));
    }
    // The path is not echoed: it is the user's.
    if a.cwd.as_deref().is_some_and(|d| !Path::new(d).is_dir()) {
        return Err(usage("--cwd is not a directory"));
    }
    let dir = a.dir.as_ref().map_or_else(local::default_dir, PathBuf::from);
    // Read once, at start: a broken file means on (serve already refuses requests then, so it is seen).
    let program_status = config::load(&config::beside(&dir)).map(|c| c.program_status).unwrap_or(true);
    let opts = RunOpts {
        name: a.name.clone(),
        cwd: a.cwd.as_ref().map(PathBuf::from),
        dir,
        ticket: a.ticket.clone(),
        command: a.command.clone().unwrap_or_default(),
        program_status,
    };
    holder::run(opts).await.map_err(|e| match e.downcast_ref::<NoTerminal>() {
        Some(n) => Fail::Terminal(n.to_string()),
        None => runtime(format!("run stopped: {e:#}")),
    })
}

/// One line on stdout. A closed stdout is not an error: the one reading it has gone and stops the worker anyway.
fn say(line: &str) {
    let mut o = std::io::stdout().lock();
    let _ = writeln!(o, "{line}");
    let _ = o.flush();
}

/// A worker event: the JSON line with `--json`, a few words without.
fn event(json: bool, v: &serde_json::Value) {
    if json {
        return say(&v.to_string());
    }
    match v["event"].as_str() {
        Some("listening") => say(&format!("listening on port {}", v["port"])),
        Some("ended") => say(&format!("a view of {} ended after {} inputs", v["term"], v["inputs"])),
        _ => say(&v.to_string()),
    }
}

async fn serve(a: &Args) -> Res<()> {
    if !a.pos.is_empty() {
        return Err(usage("serve takes no arguments"));
    }
    let var = a.token_env.as_deref().ok_or_else(|| usage("serve needs --token-env"))?;
    let token = std::env::var(var).ok().filter(|t| !t.is_empty());
    let token = token.ok_or_else(|| usage("the --token-env variable is not set"))?;
    let config = a.config.as_deref().ok_or_else(|| usage("serve needs --config"))?;
    let ip: IpAddr = a.bind.as_deref().unwrap_or("127.0.0.1").parse().map_err(|_| usage("invalid --bind address"))?;
    let port: u16 = match &a.port {
        None => 0,
        Some(p) => p.parse().map_err(|_| usage("invalid --port"))?,
    };
    let listener = tokio::net::TcpListener::bind((ip, port)).await.map_err(|_| runtime("could not listen"))?;
    let port = listener.local_addr().map_err(|_| runtime("could not listen"))?.port();
    let opts =
        ServeOpts { launch_with: a.launch_with.as_ref().map(PathBuf::from), ..ServeOpts::new(PathBuf::from(config)) };
    event(a.json, &serde_json::json!({ "event": "listening", "port": port }));
    let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel();
    let json = a.json;
    let printer = tokio::spawn(async move {
        while let Some(v) = rx.recv().await {
            event(json, &v);
        }
    });
    let stop = async {
        use tokio::io::AsyncReadExt;
        let mut stdin = tokio::io::stdin();
        let mut buf = [0u8; 1024];
        while matches!(stdin.read(&mut buf).await, Ok(n) if n > 0) {}
    };
    serve::serve(listener, token, opts, tx, stop).await;
    // Every sender is gone with the worker, so the printer ends once the last event is out.
    let _ = printer.await;
    Ok(())
}

fn dispatch(argv: &[String]) -> Res<i32> {
    let Some((sub, rest)) = argv.split_first() else {
        return Err(usage("missing subcommand"));
    };
    let allowed: &[&str] = match sub.as_str() {
        "version" => &["json"],
        "run" => &["name", "cwd", "dir", "ticket", "--"],
        "serve" => &["json", "token-env", "config", "bind", "port", "launch-with"],
        "help" | "--help" | "-h" => {
            println!("{USAGE}");
            return Ok(0);
        }
        _ => return Err(usage("unknown subcommand")),
    };
    let a = parse_args(allowed, rest)?;
    if sub == "version" {
        if !a.pos.is_empty() {
            return Err(usage("version takes no arguments"));
        }
        version(&a);
        return Ok(0);
    }
    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .map_err(|_| runtime("could not start the async runtime"))?;
    let res = rt.block_on(async {
        match sub.as_str() {
            "serve" => serve(&a).await.map(|()| 0),
            _ => run(&a).await,
        }
    });
    // Dropping the runtime would wait for tokio's blocking stdin read, which lasts as long as stdin stays open.
    rt.shutdown_background();
    if sub == "serve" && a.json {
        let (code, reason) = match &res {
            Ok(_) => (0, "stdin closed"),
            Err(Fail::Usage(m) | Fail::Terminal(m)) => (2, m.as_str()),
            Err(Fail::Runtime(m)) => (1, m.as_str()),
        };
        say(&serde_json::json!({ "event": "exit", "code": code, "reason": reason }).to_string());
    }
    res
}

fn main() {
    let argv: Option<Vec<String>> = std::env::args_os().skip(1).map(|s| s.into_string().ok()).collect();
    let res = match argv {
        Some(argv) => dispatch(&argv),
        None => Err(usage("arguments must be UTF-8")),
    };
    let code = match res {
        Ok(code) => code,
        Err(Fail::Usage(m)) => {
            eprintln!("rapp-term: {} (see rapp-term help)", m.replace('\n', " "));
            2
        }
        Err(Fail::Runtime(m)) => {
            eprintln!("rapp-term: {}", m.replace('\n', " "));
            1
        }
        Err(Fail::Terminal(m)) => {
            // It names the command already.
            eprintln!("{m}");
            2
        }
    };
    let _ = std::io::stdout().flush();
    // Exit here rather than return: a pending stdin read on tokio's blocking pool would hold the process open.
    std::process::exit(code);
}

#[cfg(test)]
mod tests {
    use super::*;

    fn s(v: &[&str]) -> Vec<String> {
        v.iter().map(|x| x.to_string()).collect()
    }

    #[test]
    fn options_take_the_next_argument_as_their_value() {
        let a = parse_args(&["name", "json"], &s(&["--name", "-oProxyCommand=x", "--json"])).ok().unwrap();
        assert_eq!((a.name.as_deref(), a.json), (Some("-oProxyCommand=x"), true));
        assert!(parse_args(&["name"], &s(&["--name"])).is_err());
        assert!(parse_args(&["json"], &s(&["--name", "x"])).is_err());
        assert!(parse_args(&["json"], &s(&["--", "x"])).is_err());
        let a = parse_args(&["--", "name"], &s(&["--name", "n", "--", "sh", "--json"])).ok().unwrap();
        assert_eq!(a.command, Some(s(&["sh", "--json"])));
    }
}
