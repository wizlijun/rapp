//! Reaching a host: the saved addresses are tried one by one (500 ms each) with the saved password.
//! One connection per host is cached; a lost connection triggers one fresh connect.

use crate::hosts::Host;
use crate::Hub;
use anyhow::{anyhow, bail, Context, Result};
use quinn::Connection;
use rapp_net::line::{read_json, write_json};
use rapp_net::log::Lvl;
use rapp_net::msg::Op;
use rapp_net::quic::{bi, connect, BiStream, ALPN_PEER};
use serde_json::{json, Value};
use std::net::SocketAddr;
use std::time::Duration;

pub const LAN_WAIT: Duration = Duration::from_millis(500);
const REPLY_WAIT: Duration = Duration::from_secs(20);

tokio::task_local! {
    /// Set around presence probes: they must leave hub.log alone (no `route`, no `reconnecting`).
    pub static QUIET: bool;
}

fn quiet() -> bool {
    QUIET.try_with(|q| *q).unwrap_or(false)
}

/// An error that retrying with the same saved password will not fix, and that A logs as `auth_fail`:
/// a probe must stop on these until the user acts on the host.
pub fn is_auth_failure(e: &anyhow::Error) -> bool {
    let s = e.to_string();
    s == "bad password" || s.ends_with(": bad password")
}

/// A cached connection to a host; always over a saved LAN address.
#[derive(Clone)]
pub struct Link {
    conn: Connection,
}

impl Link {
    pub fn path(&self) -> &'static str {
        "lan"
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

impl Hub {
    async fn establish(&self, host: &Host) -> Result<Link> {
        if host.lan.is_empty() {
            bail!("no address: add the host again as id@ip");
        }
        let auth = Op::Auth { token: None, password: Some(host.password.clone()), name: self.me() };
        match self.first_lan(&host.id, &host.lan, &auth).await {
            Some(conn) => Ok(Link { conn }),
            None => Err(anyhow!("offline: no LAN address answered")),
        }
    }

    async fn send_on(&self, link: &Link, op: &Op) -> Result<(BiStream, Value)> {
        exchange(&link.conn, &[op]).await
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
                Err(e) => {
                    self.route(id, "lan", Some(a), Err(format!("{e:#}")));
                    // A refused the saved password and logged `auth_fail`: a probe must not repeat that.
                    if quiet() && e.to_string().ends_with(": bad password") {
                        self.probe_halt.lock().unwrap().insert(id.to_string());
                        break;
                    }
                }
            }
        }
        None
    }

    pub fn forget(&self, id: &str) {
        self.probe_halt.lock().unwrap().remove(id);
        if let Some(link) = self.links.lock().unwrap().remove(id) {
            link.conn.close(0u32.into(), b"forgotten");
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
