//! rapp-hub (spec §4): B side. JSON-line commands on stdin, events on stdout.
//! Hosts are reached at the addresses saved in `hosts.json` (added as `id@ip`, or by bare ID through
//! the relay), and through the relay when no address answers.

mod hosts;
mod link;
mod presence;
mod session;

use anyhow::{bail, Context, Result};
use hosts::{Host, Hosts};
use link::Link;
use quinn::Endpoint;
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
    /// Where `service.json` (relay, key) and the device key live.
    home: PathBuf,
    /// This device's key and certificate, shared with the service on this machine.
    identity: Arc<rapp_wire::Identity>,
    bin_dir: Option<PathBuf>,
    ep: Endpoint,
    links: Mutex<HashMap<String, Link>>,
    /// The connection to the relay, kept while the settings it was dialed with stand.
    relay: tokio::sync::Mutex<Option<link::RelayCache>>,
    hosts: Hosts,
    out: tokio::sync::Mutex<Out>,
    /// sid → writer of the client's stdin (None once closed).
    sessions: Mutex<HashMap<u64, HubSession>>,
    next_sid: AtomicU64,
    /// sid → reason set by `close` with `reason`, read when the session ends.
    close_why: Mutex<HashMap<u64, String>>,
    /// Hosts the presence probe stopped trying after an auth-type failure, until the user acts on them.
    probe_halt: Mutex<std::collections::HashSet<String>>,
    kill: tokio::sync::watch::Sender<bool>,
    log: Log,
    /// B's self-declared name in `auth` (spec §2): this machine's hostname.
    name: String,
}

pub async fn run<R, W>(opts: Opts, input: R, output: W) -> Result<()>
where
    R: AsyncRead + Unpin + Send + 'static,
    W: AsyncWrite + Unpin + Send + 'static,
{
    opts.log.event(Lvl::Info, "hub_start", json!({"version": env!("CARGO_PKG_VERSION")}));
    let identity = Arc::new(rapp_wire::Identity::load_or_create(&opts.home, "device").context("device key")?);
    let hub = Arc::new(Hub {
        home: opts.home.clone(),
        identity,
        ep: rapp_net::quic::client_endpoint(([0, 0, 0, 0], 0).into())?,
        links: Default::default(),
        relay: Default::default(),
        hosts: Hosts::load(&opts.home)?,
        out: tokio::sync::Mutex::new(Box::new(output)),
        sessions: Default::default(),
        next_sid: AtomicU64::new(sid_seed()),
        close_why: Default::default(),
        probe_halt: Default::default(),
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
    if let Some(c) = hub.relay.lock().await.take() {
        c.conn.close();
    }
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
                let password = v.get("password").and_then(Value::as_str);
                self.add_host(s("id")?, password).await?
            }
            Some("remove_host") => {
                let id = s("id")?;
                self.hosts.remove(id)?;
                self.forget(id);
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
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_millis() as u64).unwrap_or(0)
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
