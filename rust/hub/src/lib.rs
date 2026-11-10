//! rapp-hub (spec §4): B side. JSON-line commands on stdin, events on stdout.
//! Relay address and key come from `service.json` in the same config dir.

mod hosts;
mod link;
mod session;

use anyhow::{bail, Context, Result};
use hosts::{Host, Hosts};
use link::{Force, Link};
use quinn::{Connection, Endpoint};
use rapp_net::msg::Op;
use serde_json::{json, Value};
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::atomic::AtomicU64;
use std::sync::{Arc, Mutex};
use tokio::io::{AsyncBufReadExt, AsyncRead, AsyncWrite, AsyncWriteExt, BufReader};
use tokio::process::ChildStdin;

pub struct Opts {
    pub home: PathBuf,
    pub bin_dir: Option<PathBuf>,
    /// `RAPP_FORCE_PATH`: relay | direct | lan.
    pub force_path: Option<String>,
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
    /// sid → client stdin (None once closed).
    sessions: Mutex<HashMap<u64, Option<ChildStdin>>>,
    next_sid: AtomicU64,
    kill: tokio::sync::watch::Sender<bool>,
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
    let hub = Arc::new(Hub {
        force: Force::parse(opts.force_path.as_deref())?,
        ep: rapp_net::quic::client_endpoint(([0, 0, 0, 0], 0).into())?,
        relay: relay_settings(&opts.home)?,
        relay_conn: Default::default(),
        links: Default::default(),
        hosts: Hosts::load(&opts.home)?,
        out: tokio::sync::Mutex::new(Box::new(output)),
        sessions: Default::default(),
        next_sid: AtomicU64::new(0),
        kill: tokio::sync::watch::channel(false).0,
        bin_dir: opts.bin_dir,
    });
    let mut lines = BufReader::new(input).lines();
    while let Some(line) = lines.next_line().await? {
        if line.trim().is_empty() {
            continue;
        }
        let hub = hub.clone();
        tokio::spawn(async move { hub.command(&line).await });
    }
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
                let (id, password) = (s("id")?, s("password")?);
                let info = match self.relay_connect(id, password).await {
                    Ok(Ok(info)) => info,
                    Ok(Err(msg)) => bail!(msg),
                    Err(e) => return Err(e.context("relay unreachable")),
                };
                let name = info["name"].as_str().unwrap_or(id).to_string();
                let lan = info["lan"].as_array().into_iter().flatten().filter_map(Value::as_str).map(str::to_string).collect();
                self.hosts.upsert(Host { id: id.into(), name: name.clone(), password: password.into(), lan })?;
                self.forget(id);
                json!({"event":"host_added","id":id,"name":name})
            }
            Some("remove_host") => {
                let id = s("id")?;
                self.hosts.remove(id)?;
                self.forget(id);
                self.hosts_event()
            }
            Some("apps") => {
                let id = s("id")?;
                let (_, r, path) = self.request(&self.host(id)?, &Op::ListApps).await?;
                json!({"event":"apps","id":id,"path":path,"apps":r["apps"]})
            }
            Some("open") => {
                self.open(s("id")?, s("app")?, req).await?;
                return Ok(None);
            }
            Some("close") => {
                self.close(v.get("sid").and_then(Value::as_u64).context("missing sid")?)?;
                return Ok(None);
            }
            _ => bail!("unknown cmd"),
        }))
    }
}
