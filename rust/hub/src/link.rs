//! Path selection (spec §2.4): relay `connect` → LAN addresses (500 ms each, token
//! auth) → `public` (2 s) → relay streams. Relay unreachable → LAN + password (§2.3).
//! One link per host is cached; a lost connection or `bad token` on a cached link
//! triggers one fresh `connect`.

use crate::hosts::Host;
use crate::Hub;
use anyhow::{anyhow, bail, Context, Result};
use quinn::Connection;
use rapp_net::line::{read_json, write_json};
use rapp_net::log::Lvl;
use rapp_net::msg::Op;
use rapp_net::quic::{bi, connect, resolve, BiStream, ALPN_PEER, ALPN_RELAY};
use serde_json::{json, Value};
use std::net::SocketAddr;
use std::time::Duration;

const RELAY_WAIT: Duration = Duration::from_secs(2);
pub const LAN_WAIT: Duration = Duration::from_millis(500);
const PUBLIC_WAIT: Duration = Duration::from_secs(2);
const REPLY_WAIT: Duration = Duration::from_secs(20);

tokio::task_local! {
    /// Set around presence probes: they must leave hub.log alone (no `route`, no `reconnecting`).
    pub static QUIET: bool;
}

fn quiet() -> bool {
    QUIET.try_with(|q| *q).unwrap_or(false)
}

/// An error that retrying with the same saved password will not fix, and that feeds the relay's
/// failure limiter: a probe must stop on these until the user acts on the host.
pub fn is_auth_failure(e: &anyhow::Error) -> bool {
    let s = e.to_string();
    s == "bad password" || s == "unknown id" || s.starts_with("locked")
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Force {
    Lan,
    Direct,
    Relay,
}

impl Force {
    pub fn parse(s: Option<&str>) -> Result<Option<Force>> {
        Ok(match s.unwrap_or("") {
            "" => None,
            "lan" => Some(Force::Lan),
            "direct" => Some(Force::Direct),
            "relay" => Some(Force::Relay),
            other => bail!("RAPP_FORCE_PATH must be relay|direct|lan, got {other:?}"),
        })
    }
}

#[derive(Clone)]
pub enum Link {
    Direct { conn: Connection, path: &'static str },
    Relay { token: String },
}

impl Link {
    pub fn path(&self) -> &'static str {
        match self {
            Link::Direct { path, .. } => path,
            Link::Relay { .. } => "relay",
        }
    }
}

/// One request/reply on a new stream; the stream stays open for `open`.
async fn exchange(conn: &Connection, lines: &[&Op]) -> Result<(BiStream, Value)> {
    let mut s = bi(conn.open_bi().await?);
    for l in lines {
        write_json(&mut s, l).await?;
    }
    let reply = tokio::time::timeout(REPLY_WAIT, read_json(&mut s)).await.map_err(|_| anyhow!("no reply"))??;
    Ok((s, reply))
}

fn error_of(v: &Value) -> String {
    v["error"].as_str().unwrap_or("bad reply").to_string()
}

fn addrs(v: &Value) -> Vec<String> {
    v.as_array().into_iter().flatten().filter_map(Value::as_str).map(str::to_string).collect()
}

impl Hub {
    fn allows(&self, f: Force) -> bool {
        self.force.is_none_or(|x| x == f)
    }

    async fn relay_conn(&self) -> Result<Connection> {
        let (addr, _) = self.relay.as_ref().context("no relay configured")?;
        let mut cached = self.relay_conn.lock().await;
        if let Some(c) = cached.as_ref().filter(|c| c.close_reason().is_none()) {
            return Ok(c.clone());
        }
        let c = connect(&self.ep, resolve(addr).await?, ALPN_RELAY, RELAY_WAIT).await?;
        *cached = Some(c.clone());
        Ok(c)
    }

    /// Relay `connect`. Outer error: relay unreachable. Inner error: relay said no.
    pub async fn relay_connect(&self, id: &str, password: &str) -> Result<Result<Value, String>> {
        let conn = self.relay_conn().await?;
        let key = self.relay.as_ref().map(|r| r.1.clone()).unwrap_or_default();
        let op = Op::Connect { key, id: id.into(), password: password.into(), name: self.me() };
        let (_, r) = self.relay_exchange(&conn, &[&op]).await?;
        Ok(if r["ok"] == true { Ok(r) } else { Err(error_of(&r)) })
    }

    /// `exchange` on the relay connection; a failure drops the cached connection.
    async fn relay_exchange(&self, conn: &Connection, lines: &[&Op]) -> Result<(BiStream, Value)> {
        let r = exchange(conn, lines).await;
        if r.is_err() {
            conn.close(0u32.into(), b"failed");
        }
        r
    }

    /// Dials `addr` and authenticates; the connection is closed on refusal.
    /// Returns the auth reply too (password auth names the host: `id`, `name`).
    pub async fn dial(&self, addr: &str, wait: Duration, auth: &Op) -> Result<(Connection, Value)> {
        let addr: SocketAddr = addr.parse().with_context(|| format!("bad address {addr}"))?;
        let conn = connect(&self.ep, addr, ALPN_PEER, wait).await?;
        let (_, r) = exchange(&conn, &[auth]).await?;
        if r["ok"] != true {
            conn.close(0u32.into(), b"auth refused");
            bail!("{addr}: {}", error_of(&r));
        }
        Ok((conn, r))
    }

    /// One `route` line per path attempt (spec §4.4): `result` is "ok" or why it failed.
    fn route(&self, id: &str, path: &str, addr: Option<&str>, result: Result<(), String>) {
        let mut v = json!({"id": id, "path": path});
        if let Some(a) = addr {
            v["addr"] = a.into();
        }
        if quiet() {
            return;
        }
        let lvl = if result.is_ok() { Lvl::Info } else { Lvl::Warn };
        v["result"] = result.err().unwrap_or_else(|| "ok".into()).into();
        self.log.event(lvl, "route", v);
    }

    async fn first_lan(&self, id: &str, lan: &[String], auth: &Op) -> Option<Connection> {
        for a in lan {
            match self.dial(a, LAN_WAIT, auth).await {
                Ok((c, _)) => {
                    self.route(id, "lan", Some(a), Ok(()));
                    return Some(c);
                }
                Err(e) => self.route(id, "lan", Some(a), Err(format!("{e:#}"))),
            }
        }
        None
    }

    async fn establish(&self, host: &Host) -> Result<Link> {
        let password_auth = Op::Auth { token: None, password: Some(host.password.clone()), name: self.me() };
        let connected = self.relay_connect(&host.id, &host.password).await;
        match &connected {
            Ok(Ok(_)) => {}
            Ok(Err(msg)) => self.route(&host.id, "relay", None, Err(msg.clone())),
            Err(e) => self.route(&host.id, "relay", None, Err(format!("unreachable: {e:#}"))),
        }
        let info = match connected {
            Ok(Ok(info)) => info,
            // A host added as `id@ip` may never have registered with this relay (§2.3).
            Ok(Err(msg)) if (msg == "unknown id" || msg == "offline") && self.allows(Force::Lan) => {
                return match self.first_lan(&host.id, &host.lan, &password_auth).await {
                    Some(conn) => Ok(Link::Direct { conn, path: "lan" }),
                    None => Err(anyhow!(msg)),
                };
            }
            Ok(Err(msg)) => bail!(msg),
            Err(e) if self.allows(Force::Lan) => {
                return match self.first_lan(&host.id, &host.lan, &password_auth).await {
                    Some(conn) => Ok(Link::Direct { conn, path: "lan" }),
                    None => Err(e.context("relay unreachable and no LAN address answered")),
                };
            }
            Err(e) => return Err(e.context("relay unreachable")),
        };
        let lan = addrs(&info["lan"]);
        let name = info["name"].as_str().unwrap_or(&host.name).to_string();
        self.hosts.refresh(Host { name, lan: lan.clone(), ..host.clone() })?;

        let token = info["token"].as_str().context("relay sent no token")?.to_string();
        let auth = Op::Auth { token: Some(token.clone()), password: None, name: self.me() };
        if self.allows(Force::Lan) {
            if let Some(conn) = self.first_lan(&host.id, &lan, &auth).await {
                return Ok(Link::Direct { conn, path: "lan" });
            }
        }
        if self.allows(Force::Direct) {
            match info["public"].as_str() {
                Some(p) => match self.dial(p, PUBLIC_WAIT, &auth).await {
                    Ok((conn, _)) => {
                        self.route(&host.id, "direct", Some(p), Ok(()));
                        return Ok(Link::Direct { conn, path: "direct" });
                    }
                    Err(e) => self.route(&host.id, "direct", Some(p), Err(format!("{e:#}"))),
                },
                None => self.route(&host.id, "direct", None, Err("no public address".into())),
            }
        }
        if self.allows(Force::Relay) {
            self.route(&host.id, "relay", None, Ok(()));
            return Ok(Link::Relay { token });
        }
        bail!("no path to {}", host.id)
    }

    async fn send_on(&self, link: &Link, op: &Op) -> Result<(BiStream, Value)> {
        match link {
            Link::Direct { conn, .. } => exchange(conn, &[op]).await,
            Link::Relay { token } => {
                let key = self.relay.as_ref().map(|r| r.1.clone()).unwrap_or_default();
                let relay = Op::Relay { key, token: token.clone() };
                self.relay_exchange(&self.relay_conn().await?, &[&relay, op]).await
            }
        }
    }

    pub fn forget(&self, id: &str) {
        self.probe_halt.lock().unwrap().remove(id);
        if let Some(Link::Direct { conn, .. }) = self.links.lock().unwrap().remove(id) {
            conn.close(0u32.into(), b"forgotten");
        }
    }

    /// Sends `op` to `host` and returns the open stream, the ok reply and the path used.
    pub async fn request(&self, host: &Host, op: &Op) -> Result<(BiStream, Value, &'static str)> {
        if !quiet() {
            // The user is acting on this host: presence may try it again.
            self.probe_halt.lock().unwrap().remove(&host.id);
        }
        let cached = self.links.lock().unwrap().get(&host.id).cloned();
        if let Some(link) = cached {
            match self.send_on(&link, op).await {
                Ok((_, r)) if r["error"] == "bad token" => {}
                Err(e) if quiet() => drop(e),
                Err(e) => self.log.msg(Lvl::Warn, format_args!("{} via {}: {e:#}; reconnecting", host.id, link.path())),
                Ok(x) => return finish(x, link.path()),
            }
            self.forget(&host.id);
        }
        let link = self.establish(host).await?;
        {
            // A host removed while this was in flight must not come back through the cache.
            let mut links = self.links.lock().unwrap();
            if self.hosts.get(&host.id).is_some() {
                links.insert(host.id.clone(), link.clone());
            }
        }
        match self.send_on(&link, op).await {
            Ok(x) => finish(x, link.path()),
            Err(e) => {
                self.forget(&host.id);
                Err(e)
            }
        }
    }
}

fn finish((s, r): (BiStream, Value), path: &'static str) -> Result<(BiStream, Value, &'static str)> {
    if r["ok"] == true {
        Ok((s, r, path))
    } else {
        Err(anyhow!(error_of(&r)))
    }
}
