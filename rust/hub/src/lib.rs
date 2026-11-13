//! rapp-hub (spec §4): B side. JSON-line commands on stdin, events on stdout.
//! Relay address and key come from `service.json` in the same config dir.

mod hosts;
mod link;
mod presence;
mod session;

use anyhow::{bail, Context, Result};
use hosts::{Host, Hosts};
use link::{Force, Link};
use quinn::{Connection, Endpoint};
use rapp_net::log::{Log, Lvl};
use rapp_net::msg::Op;
use serde_json::{json, Value};
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::atomic::AtomicU64;
use std::sync::{Arc, Mutex};
use tokio::io::{AsyncBufReadExt, AsyncRead, AsyncWrite, AsyncWriteExt, BufReader};

pub struct Opts {
    pub home: PathBuf,
    pub bin_dir: Option<PathBuf>,
    /// `RAPP_FORCE_PATH`: relay | direct | lan.
    pub force_path: Option<String>,
    /// `hub.log` (spec §4.4); `Log::none()` writes nothing.
    pub log: Log,
    /// Presence probe period; None = no probe (tests).
    pub presence_every: Option<std::time::Duration>,
}

/// One open session. `tx` is the writer of the client's stdin (None once closed).
pub(crate) struct HubSession {
    tx: Option<tokio::sync::mpsc::UnboundedSender<String>>,
    id: String,
    app: String,
    path: String,
    embed: bool,
}

type Out = Box<dyn AsyncWrite + Unpin + Send>;

pub(crate) struct Hub {
    bin_dir: Option<PathBuf>,
    force: Option<Force>,
    ep: Endpoint,
    /// (address, key) from service.json.
    relay: Option<(String, String)>,
    relay_conn: tokio::sync::Mutex<Option<Connection>>,
    links: Mutex<HashMap<String, Link>>,
    hosts: Hosts,
    out: tokio::sync::Mutex<Out>,
    /// sid → writer of the client's stdin (None once closed).
    sessions: Mutex<HashMap<u64, HubSession>>,
    next_sid: AtomicU64,
    /// sid → reason set by `close` with `reason`, read when the session ends.
    close_why: Mutex<HashMap<u64, String>>,
    /// Hosts the presence probe stopped trying after an auth-type failure, until the user acts on them.
    probe_halt: Mutex<std::collections::HashSet<String>>,
    /// Hosts with LAN addresses the relay called "unknown id" this run (`id@ip` hosts that never
    /// registered there): presence probes them over LAN only, so it never asks the relay again.
    lan_only: Mutex<std::collections::HashSet<String>>,
    kill: tokio::sync::watch::Sender<bool>,
    log: Log,
    /// B's self-declared name in `auth` / `connect` (spec §2): this machine's hostname.
    name: String,
}

/// Relay settings from `<home>/service.json`; None when unset or empty.
fn relay_settings(home: &std::path::Path) -> Result<Option<(String, String)>> {
    let cfg: Option<Value> = rapp_net::config::read_json(&home.join("service.json"))?;
    let get = |k: &str| cfg.as_ref().and_then(|c| c[k].as_str()).filter(|s| !s.is_empty()).map(str::to_string);
    Ok(get("relay").map(|r| (r, get("key").unwrap_or_default())))
}

pub async fn run<R, W>(opts: Opts, input: R, output: W) -> Result<()>
where
    R: AsyncRead + Unpin + Send + 'static,
    W: AsyncWrite + Unpin + Send + 'static,
{
    let relay = relay_settings(&opts.home)?;
    let mut start = json!({"version": env!("CARGO_PKG_VERSION")});
    if let Some((addr, _)) = &relay {
        start["relay"] = addr.as_str().into(); // the address only, never the key
    }
    opts.log.event(Lvl::Info, "hub_start", start);
    let hub = Arc::new(Hub {
        force: Force::parse(opts.force_path.as_deref())?,
        ep: rapp_net::quic::client_endpoint(([0, 0, 0, 0], 0).into())?,
        relay,
        relay_conn: Default::default(),
        links: Default::default(),
        hosts: Hosts::load(&opts.home)?,
        out: tokio::sync::Mutex::new(Box::new(output)),
        sessions: Default::default(),
        next_sid: AtomicU64::new(sid_seed()),
        close_why: Default::default(),
        probe_halt: Default::default(),
        lan_only: Default::default(),
        kill: tokio::sync::watch::channel(false).0,
        bin_dir: opts.bin_dir,
        log: opts.log,
        name: rapp_net::config::hostname(),
    });
    let probe = opts.presence_every.map(|every| tokio::spawn(presence::run(hub.clone(), every)));
    let mut lines = BufReader::new(input).lines();
    let read = async {
        while let Some(line) = lines.next_line().await? {
            if line.trim().is_empty() {
                continue;
            }
            let hub = hub.clone();
            tokio::spawn(async move { hub.command(&line).await });
        }
        anyhow::Ok(())
    }
    .await;
    if let Some(p) = probe {
        p.abort();
        let _ = p.await;
    }
    read?;
    hub.close_all().await;
    hub.ep.close(0u32.into(), b"hub exit");
    let _ = hub.out.lock().await.shutdown().await;
    Ok(())
}

impl Hub {
    /// Writes one event line, echoing `req` when given.
    async fn emit(&self, mut v: Value, req: &Option<Value>) {
        if let Some(r) = req {
            v["req"] = r.clone();
        }
        let mut out = self.out.lock().await;
        let _ = out.write_all(format!("{v}\n").as_bytes()).await;
        let _ = out.flush().await;
    }

    /// The name B introduces itself with.
    fn me(&self) -> Option<String> {
        Some(self.name.clone())
    }

    fn host(&self, id: &str) -> Result<Host> {
        self.hosts.get(id).context("unknown host")
    }

    fn hosts_event(&self) -> Value {
        json!({"event":"hosts","hosts":self.hosts.summary()})
    }

    async fn command(self: &Arc<Self>, line: &str) {
        let (v, req) = match serde_json::from_str::<Value>(line) {
            Ok(v) => {
                let req = v.get("req").cloned();
                (v, req)
            }
            Err(e) => return self.emit(json!({"event":"error","error":format!("bad json: {e}")}), &None).await,
        };
        match self.dispatch(&v, &req).await {
            Ok(Some(ev)) => self.emit(ev, &req).await,
            Ok(None) => {}
            Err(e) => self.emit(json!({"event":"error","error":format!("{e:#}")}), &req).await,
        }
    }

    /// The reply event, or None when the command emits its own (`open`) or none (`close`).
    async fn dispatch(self: &Arc<Self>, v: &Value, req: &Option<Value>) -> Result<Option<Value>> {
        let s = |k: &str| v.get(k).and_then(Value::as_str).with_context(|| format!("missing {k}"));
        Ok(Some(match v.get("cmd").and_then(Value::as_str) {
            Some("hosts") => self.hosts_event(),
            Some("add_host") => {
                let (id, addr) = rapp_net::addr::split_host_ref(s("id")?)?;
                let (id, password) = (id.as_str(), s("password")?);
                if let Some(addr) = addr {
                    // `id@ip[:port]`: straight to A with the password, no relay (§2.3).
                    let auth = Op::Auth { token: None, password: Some(password.into()), name: self.me() };
                    let (conn, r) = self.dial(&addr, link::LAN_WAIT, &auth).await?;
                    conn.close(0u32.into(), b"host added");
                    if r["id"] != id {
                        bail!("{addr} is ID {}, not {id}", r["id"].as_str().unwrap_or("?"));
                    }
                    let name = r["name"].as_str().unwrap_or(id).to_string();
                    self.hosts.upsert(Host { id: id.into(), name: name.clone(), password: password.into(), lan: vec![addr] })?;
                    self.forget_host(id);
                    return Ok(Some(json!({"event":"host_added","id":id,"name":name})));
                }
                let info = match self.relay_connect(id, password).await {
                    Ok(Ok(info)) => info,
                    Ok(Err(msg)) => bail!(msg),
                    Err(e) => return Err(e.context("relay unreachable")),
                };
                let name = info["name"].as_str().unwrap_or(id).to_string();
                let lan = info["lan"].as_array().into_iter().flatten().filter_map(Value::as_str).map(str::to_string).collect();
                self.hosts.upsert(Host { id: id.into(), name: name.clone(), password: password.into(), lan })?;
                self.forget_host(id);
                json!({"event":"host_added","id":id,"name":name})
            }
            Some("remove_host") => {
                let id = s("id")?;
                self.hosts.remove(id)?;
                self.forget_host(id);
                self.hosts_event()
            }
            Some("set_home") => {
                self.hosts.reload(std::path::Path::new(s("dir")?))?;
                json!({"event":"home_set"})
            }
            Some("apps") => {
                let id = s("id")?;
                let (_, r, path) = self.request(&self.host(id)?, &Op::ListApps).await?;
                let mut ev = json!({"event":"apps","id":id,"path":path,"apps":r["apps"]});
                // Only newer macOS hosts report what they are missing.
                if r["permissions"].is_object() {
                    ev["permissions"] = r["permissions"].clone();
                }
                ev
            }
            Some("open") => {
                let embed = v.get("embed").and_then(Value::as_bool).unwrap_or(false);
                let reconnect = v.get("reconnect").and_then(Value::as_bool).unwrap_or(false);
                self.open(s("id")?, s("app")?, embed, reconnect, req).await?;
                return Ok(None);
            }
            Some("close") => {
                let why = match v.get("reason") {
                    None | Some(Value::Null) => None,
                    Some(r) if r == "user" => Some("user"),
                    Some(_) => bail!("bad reason"),
                };
                self.close(v.get("sid").and_then(Value::as_u64).context("missing sid")?, why)?;
                return Ok(None);
            }
            Some("focus") => {
                self.focus(v.get("sid").and_then(Value::as_u64).context("missing sid")?)?;
                return Ok(None);
            }
            Some("note") => {
                let sid = v.get("sid").and_then(Value::as_u64).context("missing sid")?;
                let what = v.get("what").and_then(Value::as_str).filter(|w| ["detach", "attach"].contains(w));
                let (Some(what), Some(windows)) = (what, v.get("windows").and_then(Value::as_u64)) else {
                    bail!("bad note");
                };
                self.note(sid, what, windows)?;
                return Ok(None);
            }
            _ => bail!("unknown cmd"),
        }))
    }
}

/// Where this hub's sids start: the wall clock in ms. Sids only need to be unique per GUI launch,
/// and the GUI keeps old sids across 「重启服务」; starting from the clock keeps a restarted hub
/// from reusing them.
fn sid_seed() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

#[cfg(test)]
mod sid_tests {
    use super::sid_seed;
    use std::time::{SystemTime, UNIX_EPOCH};

    /// Sids continue from the wall clock in ms, so a restarted hub never hands out a sid the
    /// GUI still holds from before the restart.
    #[test]
    fn sid_seed_is_wall_clock_millis() {
        let now = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_millis() as u64;
        let seed = sid_seed();
        assert!(seed + 1000 >= now && seed <= now + 1000, "seed {seed} vs now {now}");
        // Stays exact as a JSON number / Dart int.
        assert!(seed < (1u64 << 53));
    }
}
