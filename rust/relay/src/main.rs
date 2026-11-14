//! `rapp-relay`: runs the relay, or talks to the running one over its admin socket (spec §6.5,
//! §10.1). The only option is `--data <dir>` (default `/data`).

use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};
use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::time::{Duration, SystemTime};

use anyhow::{bail, Context, Result};
use rapp_net::log::Log;
use rapp_relay::config::{self, LogLevel};
use rapp_relay::server::{Opts, Relay};
use rapp_relay::{admin, audit};
use rapp_wire::tls::{self, Expect};
use rapp_wire::{Fp, Identity};
use serde_json::{json, Value};
use tokio::signal::unix::{signal, SignalKind};

const USAGE: &str = "\
usage: rapp-relay [--data <dir>] [command]
  (no command)                 run the relay
  key                          make the key and show it once
  rotate-key                   replace the key and show the new one once; every device is disconnected
                               and must enter the new key
  devices                      list the enrolled devices
  revoke <ID|fingerprint>      revoke a device (a fingerprint prefix of 8+ hex digits works)
  unbind <ID>                  free an ID
  enroll open|closed           let new devices enroll, or not
  audit [--since <N>d|<N>h] [--id <ID>] [--event <name>]
                               print audit records
  check                        health check: exit 0 when the relay answers
  --version                    print the version
--data defaults to /data.";

const KEY_SHOWN: &str = "key 已经显示过。到任何一台已接入的设备的设置里查看；要换新的用 rotate-key。";
const ENV_OVERRIDES: &str = "注意：环境变量 RAPP_RELAY_ENROLL 会在重启后盖过这个设置。";

/// The whole `check` command, the admin call included.
const CHECK_WAIT: Duration = Duration::from_secs(3);

enum Cmd {
    Serve,
    Version,
    Help,
    Key { rotate: bool },
    Devices,
    Revoke(String),
    Unbind(String),
    Enroll(String),
    Audit { since: Option<SystemTime>, id: Option<String>, event: Option<String> },
    Check,
}

fn main() -> ExitCode {
    let (data, cmd) = match parse(std::env::args().skip(1).collect()) {
        Ok(c) => c,
        Err(e) => {
            eprintln!("rapp-relay: {e}\n{USAGE}");
            return ExitCode::from(2);
        }
    };
    match cmd {
        Cmd::Version => {
            println!("rapp-relay {}", env!("CARGO_PKG_VERSION"));
            return ExitCode::SUCCESS;
        }
        Cmd::Help => {
            println!("{USAGE}");
            return ExitCode::SUCCESS;
        }
        _ => {}
    }
    let rt = match tokio::runtime::Runtime::new() {
        Ok(rt) => rt,
        Err(e) => {
            eprintln!("rapp-relay: {e}");
            return ExitCode::from(1);
        }
    };
    ExitCode::from(rt.block_on(run(&data, cmd)))
}

fn parse(args: Vec<String>) -> Result<(PathBuf, Cmd)> {
    let mut data = PathBuf::from("/data");
    let mut rest = Vec::new();
    let mut it = args.into_iter();
    while let Some(a) = it.next() {
        if a == "--data" {
            data = it.next().context("--data needs a directory")?.into();
        } else if let Some(d) = a.strip_prefix("--data=") {
            data = d.into();
        } else {
            rest.push(a);
        }
    }
    let words: Vec<&str> = rest.iter().map(String::as_str).collect();
    let cmd = match words[..] {
        [] => Cmd::Serve,
        ["--version"] => Cmd::Version,
        ["-h" | "--help" | "help"] => Cmd::Help,
        ["key"] => Cmd::Key { rotate: false },
        ["rotate-key"] => Cmd::Key { rotate: true },
        ["devices"] => Cmd::Devices,
        ["revoke", target] => Cmd::Revoke(target.into()),
        ["unbind", id] => Cmd::Unbind(id.into()),
        ["enroll", state @ ("open" | "closed")] => Cmd::Enroll(state.into()),
        ["audit", ref flags @ ..] => parse_audit(flags)?,
        ["check"] => Cmd::Check,
        _ => bail!("unknown command or argument: {}", rest.join(" ")),
    };
    Ok((data, cmd))
}

fn parse_audit(flags: &[&str]) -> Result<Cmd> {
    let (mut since, mut id, mut event) = (None, None, None);
    let mut it = flags.iter();
    while let Some(f) = it.next() {
        let mut value = || it.next().map(|v| v.to_string()).with_context(|| format!("{f} needs a value"));
        match *f {
            "--since" => since = Some(parse_since(&value()?, SystemTime::now())?),
            "--id" => id = Some(value()?),
            "--event" => event = Some(value()?),
            _ => bail!("unknown audit flag: {f}"),
        }
    }
    Ok(Cmd::Audit { since, id, event })
}

/// `7d` / `12h`: that long before `now`.
fn parse_since(s: &str, now: SystemTime) -> Result<SystemTime> {
    let bad = || anyhow::anyhow!("--since: bad value {s:?}, expected <N>d or <N>h");
    let (n, mult) = if let Some(n) = s.strip_suffix('d') {
        (n, 86_400)
    } else if let Some(n) = s.strip_suffix('h') {
        (n, 3_600)
    } else {
        return Err(bad());
    };
    let n: u64 = n.parse().map_err(|_| bad())?;
    let secs = n.checked_mul(mult).ok_or_else(bad)?;
    Ok(now.checked_sub(Duration::from_secs(secs)).unwrap_or(SystemTime::UNIX_EPOCH))
}

async fn run(data: &Path, cmd: Cmd) -> u8 {
    let res = match cmd {
        Cmd::Serve => return serve(data).await,
        Cmd::Version | Cmd::Help => Ok(()),
        Cmd::Key { rotate } => key(data, rotate).await,
        Cmd::Devices => devices(data).await,
        Cmd::Revoke(target) => request(data, json!({"cmd": "revoke", "target": target}))
            .await
            .map(|v| println!("已吊销 {}", v["fp"].as_str().unwrap_or("-"))),
        Cmd::Unbind(id) => request(data, json!({"cmd": "unbind", "id": id})).await.map(|_| println!("已解除 {id}")),
        Cmd::Enroll(state) => enroll(data, &state).await,
        Cmd::Audit { since, id, event } => audit::read(data, since, id.as_deref(), event.as_deref())
            .map(|lines| lines.iter().for_each(|l| println!("{l}"))),
        Cmd::Check => match tokio::time::timeout(CHECK_WAIT, check(data)).await {
            Ok(r) => r,
            Err(_) => Err(anyhow::anyhow!("check: no answer within {}s", CHECK_WAIT.as_secs())),
        },
    };
    match res {
        Ok(()) => 0,
        Err(e) => {
            match e.downcast_ref::<admin::NotRunning>() {
                Some(nr) => eprintln!("{nr}"),
                None => eprintln!("rapp-relay: {e:#}"),
            }
            1
        }
    }
}

/// Runs the relay until SIGTERM or SIGINT. 2: the configuration or the data dir is unusable.
async fn serve(data: &Path) -> u8 {
    if let Err(e) = usable_dir(data) {
        eprintln!("rapp-relay: {e:#}");
        return 2;
    }
    let config = match config::load(data, &|k| std::env::var(k).ok()) {
        Ok(c) => c,
        Err(e) => {
            eprintln!("rapp-relay: {e:#}");
            return 2;
        }
    };
    let (mut term, mut int) = match (signal(SignalKind::terminate()), signal(SignalKind::interrupt())) {
        (Ok(t), Ok(i)) => (t, i),
        (Err(e), _) | (_, Err(e)) => {
            eprintln!("rapp-relay: signals: {e}");
            return 1;
        }
    };
    let log = Log::stderr().with_debug(config.log == LogLevel::Debug);
    let enroll_from_env = std::env::var_os("RAPP_RELAY_ENROLL").is_some();
    let opts = Opts { data: data.to_path_buf(), config, log, enroll_from_env };
    let relay = match Relay::start(opts).await {
        Ok(r) => r,
        Err(e) => {
            eprintln!("rapp-relay: {e:#}");
            return 1;
        }
    };
    tokio::select! {
        _ = term.recv() => {}
        _ = int.recv() => {}
    }
    relay.stop_with("signal").await;
    0
}

/// Creates `dir` (0700) if it is missing; an error naming it when it cannot be a data dir.
fn usable_dir(dir: &Path) -> Result<()> {
    let mut b = std::fs::DirBuilder::new();
    std::os::unix::fs::DirBuilderExt::mode(b.recursive(true), 0o700);
    b.create(dir).with_context(|| format!("data dir {}", dir.display()))?;
    if !dir.is_dir() {
        bail!("data dir {} is not a directory", dir.display());
    }
    Ok(())
}

/// One admin request; a reply with `"ok": false` is an error carrying its text.
async fn request(data: &Path, req: Value) -> Result<Value> {
    let v = admin::call(data, req).await?;
    if v["ok"] != true {
        bail!("{}", v["error"].as_str().unwrap_or("bad reply"));
    }
    Ok(v)
}

async fn key(data: &Path, rotate: bool) -> Result<()> {
    match admin::issue_key(data, rotate).await? {
        Some(k) => println!("{k}"),
        None => bail!("{KEY_SHOWN}"),
    }
    Ok(())
}

/// A header, then one tab-separated line per device.
async fn devices(data: &Path) -> Result<()> {
    let v = request(data, json!({"cmd": "devices"})).await?;
    println!("ID\t指纹\t入网时间\t最近在线\t状态");
    for d in v["devices"].as_array().map(Vec::as_slice).unwrap_or_default() {
        let text = |k: &str| d[k].as_str().unwrap_or("-").to_string();
        let seen = if d["online"] == true { "online".to_string() } else { text("last_seen") };
        let state = if d["revoked"] == true {
            "revoked"
        } else if d["stale"] == true {
            "stale"
        } else {
            ""
        };
        println!("{}\t{}\t{}\t{seen}\t{state}", text("id"), text("fp"), text("enrolled_at"));
    }
    Ok(())
}

async fn enroll(data: &Path, state: &str) -> Result<()> {
    let v = request(data, json!({"cmd": "enroll", "state": state})).await?;
    println!("{}", if state == "open" { "入网已打开" } else { "入网已关闭" });
    if v["env_overrides"] == true {
        println!("{ENV_OVERRIDES}");
    }
    Ok(())
}

/// Asks the relay where it listens, then finishes a handshake with it as a throwaway device.
async fn check(data: &Path) -> Result<()> {
    let info = request(data, json!({"cmd": "info"})).await?;
    let fp: Fp = info["fp"].as_str().context("info: no fp")?.parse()?;
    let mut addr: SocketAddr = info["listen"].as_str().context("info: no listen")?.parse()?;
    if addr.ip().is_unspecified() {
        addr.set_ip(match addr.ip() {
            IpAddr::V4(_) => Ipv4Addr::LOCALHOST.into(),
            IpAddr::V6(_) => Ipv6Addr::LOCALHOST.into(),
        });
    }
    let local: SocketAddr = if addr.is_ipv4() { "0.0.0.0:0" } else { "[::]:0" }.parse()?;
    let endpoint = quinn::Endpoint::client(local)?;
    let cc = tls::client_config(&Identity::generate()?, tls::ALPN_RELAY, Expect::Pin(fp.prefix16()))?;
    let conn = endpoint.connect_with(cc, addr, tls::SNI)?.await.with_context(|| format!("handshake with {addr}"))?;
    conn.close(0u32.into(), b"check");
    endpoint.wait_idle().await;
    println!("ok");
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_since_takes_days_and_hours_and_never_panics() {
        let now = SystemTime::UNIX_EPOCH + Duration::from_secs(10 * 86_400);
        assert_eq!(parse_since("7d", now).unwrap(), now - Duration::from_secs(7 * 86_400));
        assert_eq!(parse_since("12h", now).unwrap(), now - Duration::from_secs(12 * 3_600));
        // A multibyte suffix is a bad value, not a panic in the middle of a character.
        for bad in ["7天", "天", "", "d", "7", "7x", "-1d", "99999999999999999999d"] {
            assert!(parse_since(bad, now).is_err(), "{bad:?}");
        }
    }
}
