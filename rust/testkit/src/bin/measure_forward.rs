//! `measure-forward --to <ID> --port <port> [--n 50] [--parallel 6]`: run on the visiting device,
//! it opens forwards to a shared echo port through the local service and prints four lines.

use rapp_testkit::{measure, Plan};
use std::path::PathBuf;

const USAGE: &str = "usage: measure-forward --to <ID> --port <echo port> [--n 50] [--parallel 6]";

fn local_dir() -> PathBuf {
    match std::env::var_os("RAPP_LOCAL").filter(|v| !v.is_empty()) {
        Some(dir) => dir.into(),
        None => rapp_net::config::local(&rapp_net::config::home()),
    }
}

fn ipc_port(local: &std::path::Path) -> u16 {
    std::fs::read(local.join("service.json"))
        .ok()
        .and_then(|b| serde_json::from_slice::<serde_json::Value>(&b).ok())
        .and_then(|v| v["ipc_port"].as_u64())
        .and_then(|p| u16::try_from(p).ok())
        .filter(|&p| p != 0)
        .unwrap_or(22029)
}

fn parse() -> Result<Plan, String> {
    let (mut to, mut port, mut n, mut parallel) = (None, None, 50usize, 6usize);
    let mut args = std::env::args().skip(1);
    while let Some(flag) = args.next() {
        let value = args.next().ok_or_else(|| format!("{flag} needs a value"))?;
        let number = |what: &str| value.parse::<usize>().map_err(|_| format!("{what} must be a number"));
        match flag.as_str() {
            "--to" => to = Some(value.clone()),
            "--port" => port = Some(u16::try_from(number("--port")?).map_err(|_| "--port is out of range".to_string())?),
            "--n" => n = number("--n")?,
            "--parallel" => parallel = number("--parallel")?,
            other => return Err(format!("unknown argument {other}")),
        }
    }
    let local = local_dir();
    let token = std::fs::read_to_string(local.join("ipc.token"))
        .map_err(|e| format!("cannot read {}: {e} (is the rapp service running?)", local.join("ipc.token").display()))?;
    Ok(Plan {
        ipc_port: ipc_port(&local),
        token: token.trim().to_string(),
        to: to.ok_or("--to is required")?,
        port: port.ok_or("--port is required")?,
        n,
        parallel,
    })
}

#[tokio::main]
async fn main() {
    let plan = match parse() {
        Ok(p) => p,
        Err(e) => {
            eprintln!("{e}\n{USAGE}");
            std::process::exit(2);
        }
    };
    match measure(&plan).await {
        Ok(report) => println!("{}", report.lines().join("\n")),
        Err(e) => {
            eprintln!("measure-forward: {e}");
            if e.to_string().contains("\"limit\"") {
                // The relay lets one device be connected to 60 times a minute by default, and a run
                // opens 2 * n forwards.
                eprintln!("the relay (or the sharing device) answered limit: try a smaller --n, or wait a minute");
            }
            std::process::exit(1);
        }
    }
}
