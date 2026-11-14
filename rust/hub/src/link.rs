//! Reaching a host. A host with a stored fingerprint, or any host when B has a key, is reached over
//! `rapp/2` (the saved LAN addresses tried together, 500 ms each, first to answer wins); a host that
//! never showed a fingerprint may fall back to `rapp/1` and its password. A host with a stored
//! fingerprint never falls back. One connection per host is cached; a lost connection triggers one
//! fresh connect.

use crate::hosts::Host;
use crate::Hub;
use anyhow::{anyhow, bail, Context, Result};
use quinn::{Connection, Endpoint};
use rapp_conn::{quic_facts, read_welcome, send_hello, Accepted, Me, Pipe, Role};
use rapp_net::addr::{is_private, split_host_ref};
use rapp_net::line::{read_json, write_json};
use rapp_net::log::Lvl;
use rapp_net::msg::Op;
use rapp_net::quic::{bi, connect, ALPN_PEER};
use rapp_wire::tls::{device_client_config, ALPN_DEVICE, SNI};
use rapp_wire::{Fp, Identity, Key};
use serde_json::{json, Value};
use std::net::SocketAddr;
use std::sync::Arc;
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

/// A cached connection to a host, and the path it came by.
#[derive(Clone)]
pub struct Link {
    conn: Connection,
    path: &'static str,
}

impl Link {
    pub fn path(&self) -> &'static str {
        self.path
    }
}

/// One request/reply on a new stream; the stream stays open for `open`.
async fn exchange(conn: &Connection, lines: &[&Op]) -> Result<(Pipe, Value)> {
    let mut s: Pipe = Box::new(bi(conn.open_bi().await?));
    for l in lines {
        write_json(&mut s, l).await?;
    }
    let reply = tokio::time::timeout(REPLY_WAIT, read_json(&mut s)).await.map_err(|_| anyhow!("no reply"))??;
    Ok((s, reply))
}

fn error_of(v: &Value) -> String {
    v["error"].as_str().unwrap_or("bad reply").to_string()
}

/// The connection never came up (as opposed to the host answering and refusing us).
#[derive(Debug)]
struct Unreachable(String);

impl std::fmt::Display for Unreachable {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for Unreachable {}

/// What a `rapp/2` dial needs, owned so that several dials can run as tasks.
#[derive(Clone)]
struct Dialer {
    ep: Endpoint,
    identity: Arc<Identity>,
    name: String,
    key: Option<Arc<Key>>,
}

impl Dialer {
    /// Connects over `rapp/2` and says hello. The hello goes out with a `ping` (which `rapp/2` A serves
    /// on the hello stream) in the same flight, so the host's answer costs no extra round trip.
    async fn dial(
        &self,
        addr: SocketAddr,
        want_id: &str,
        known: Option<Fp>,
        wait: Duration,
    ) -> Result<(Connection, Accepted)> {
        let cfg = device_client_config(&self.identity, ALPN_DEVICE)?;
        let connecting = self.ep.connect_with(cfg, addr, SNI).map_err(|e| Unreachable(e.to_string()))?;
        let conn = match tokio::time::timeout(wait, connecting).await {
            Err(_) => return Err(Unreachable("timed out".into()).into()),
            Ok(Err(e)) => return Err(Unreachable(e.to_string()).into()),
            Ok(Ok(c)) => c,
        };
        match self.hello(&conn, want_id, known).await {
            Ok(accepted) => Ok((conn, accepted)),
            Err(e) => {
                conn.close(0u32.into(), b"hello failed");
                Err(e)
            }
        }
    }

    async fn hello(&self, conn: &Connection, want_id: &str, known: Option<Fp>) -> Result<Accepted> {
        let facts = quic_facts(conn, &self.identity.fp, Role::Client)?;
        let mut pipe: Pipe = Box::new(bi(conn.open_bi().await?));
        let me = Me { id: "", name: &self.name, key: self.key.as_deref() };
        send_hello(&mut pipe, &facts, &me).await?;
        write_json(&mut pipe, &Op::Ping).await?;
        let wait = async {
            let accepted = read_welcome(&mut pipe, &facts, self.key.as_deref(), want_id, known.as_ref()).await?;
            let r = read_json(&mut pipe).await?;
            if r["ok"] != true {
                bail!(error_of(&r));
            }
            anyhow::Ok(accepted)
        };
        tokio::time::timeout(REPLY_WAIT, wait).await.map_err(|_| anyhow!("no reply"))?
    }
}

/// A definite answer of the host (or of the stored fingerprint) that retrying cannot change.
fn is_refusal(e: &anyhow::Error) -> bool {
    matches!(e.to_string().as_str(), "not trusted" | "host key mismatch")
}

/// `lan` for a private address, `direct` for a public one.
fn direct_path(addr: &SocketAddr) -> &'static str {
    if is_private(addr.ip()) {
        "lan"
    } else {
        "direct"
    }
}

/// The addresses to try, in order. Relay-era lists end in `127.0.0.1:<port>`, which on B is B's own
/// service, so loopback is skipped when a real address is saved; a list of loopback only (an explicit
/// `id@127.0.0.1`) is used as is.
fn dial_order(lan: &[String]) -> Vec<&String> {
    let loopback = |a: &String| a.parse::<SocketAddr>().map(|a| a.ip().is_loopback()).unwrap_or(false);
    if lan.iter().any(|a| !loopback(a)) {
        lan.iter().filter(|a| !loopback(a)).collect()
    } else {
        lan.iter().collect()
    }
}

impl Hub {
    fn dialer(&self, key: Option<Arc<Key>>) -> Dialer {
        Dialer { ep: self.ep.clone(), identity: self.identity.clone(), name: self.name.clone(), key }
    }

    async fn establish(&self, host: &Host) -> Result<Link> {
        if host.lan.is_empty() {
            bail!("no address: add the host again as id@ip");
        }
        // Read on every connect: the user may have set a key since the last one.
        let key = rapp_conn::settings::load(&self.home).key.map(Arc::new);
        if key.is_some() || host.fp.is_some() {
            match self.first_v2(host, &dial_order(&host.lan), key).await {
                Ok(link) => return Ok(link),
                // Seen with a key before, or nothing to fall back on: the answer stands.
                Err(e) if host.fp.is_some() || host.password.is_empty() => return Err(e),
                Err(_) => {}
            }
        }
        let auth = Op::Auth { password: Some(host.password.clone()), name: self.me() };
        match self.first_lan(&host.id, &host.lan, &auth).await {
            Some(conn) => Ok(Link { conn, path: "lan" }),
            None => Err(anyhow!("offline: no LAN address answered")),
        }
    }

    /// Tries every address over `rapp/2` at once (500 ms each) and keeps the first that is welcomed.
    /// A host that answered and refused is reported in preference to "nobody answered".
    async fn first_v2(&self, host: &Host, addrs: &[&String], key: Option<Arc<Key>>) -> Result<Link> {
        let dialer = self.dialer(key);
        let mut attempts = tokio::task::JoinSet::new();
        for a in addrs {
            let (dialer, addr, id, known) = (dialer.clone(), a.to_string(), host.id.clone(), host.fp);
            attempts.spawn(async move {
                let r = match addr.parse::<SocketAddr>() {
                    Ok(sock) => dialer.dial(sock, &id, known, LAN_WAIT).await.map(|(c, a)| (c, a, sock)),
                    Err(_) => Err(Unreachable(format!("bad address {addr}")).into()),
                };
                (addr, r)
            });
        }
        let mut refused: Option<anyhow::Error> = None;
        while let Some(done) = attempts.join_next().await {
            let Ok((addr, r)) = done else { continue };
            match r {
                Ok((conn, accepted, sock)) => {
                    let path = direct_path(&sock);
                    self.route(&host.id, path, Some(&addr), Ok(()));
                    self.remember_fp(host, &accepted);
                    return Ok(Link { conn, path });
                }
                Err(e) => {
                    let unreachable = e.downcast_ref::<Unreachable>().is_some();
                    if let Ok(sock) = addr.parse::<SocketAddr>() {
                        self.route(&host.id, direct_path(&sock), Some(&addr), Err(format!("{e:#}")));
                    }
                    if !unreachable {
                        // A probe must not keep knocking on a host that refuses this device; a slow or
                        // restarting host (no reply, reset) is not a refusal and keeps being probed.
                        if quiet() && is_refusal(&e) {
                            self.probe_halt.lock().unwrap().insert(host.id.clone());
                        }
                        refused.get_or_insert(e);
                    }
                }
            }
        }
        Err(refused.unwrap_or_else(|| anyhow!("offline: no LAN address answered")))
    }

    /// Saves the fingerprint a host showed, logging a change (hex only, never key material).
    fn remember_fp(&self, host: &Host, accepted: &Accepted) {
        if host.fp == Some(accepted.fp) {
            return;
        }
        match self.hosts.set_fp(&host.id, accepted.fp) {
            Ok(true) => {
                if let Some(old) = host.fp.filter(|_| accepted.changed) {
                    let (old, new) = (old.to_string(), accepted.fp.to_string());
                    self.log.event(Lvl::Warn, "host_key_changed", json!({"id": host.id, "old": old, "new": new}));
                }
            }
            Ok(false) => {}
            Err(e) => self.log.msg(Lvl::Warn, format_args!("{}: cannot save host fingerprint: {e:#}", host.id)),
        }
    }

    /// `add_host`: a host reached over `rapp/2` is saved with its fingerprint and no password; one
    /// that only the password gets into is saved the old way.
    pub(crate) async fn add_host(&self, host_ref: &str, password: Option<&str>) -> Result<Value> {
        let (id, addr) = split_host_ref(host_ref)?;
        // Through the relay comes with Task 7: until then a bare ID has no way to be reached.
        let Some(addr) = addr else { bail!("relay not set: add the host as id@ip") };
        let sock: SocketAddr = addr.parse().with_context(|| format!("bad address {addr}"))?;
        let key = rapp_conn::settings::load(&self.home).key.map(Arc::new);
        let known = self.hosts.get(&id).and_then(|h| h.fp);
        let password = password.filter(|p| !p.is_empty());
        let mut refused = None;
        if key.is_some() {
            match self.dialer(key).dial(sock, &id, known, LAN_WAIT).await {
                Ok((conn, accepted)) => {
                    conn.close(0u32.into(), b"host added");
                    let name = Some(accepted.name).filter(|n| !n.is_empty()).unwrap_or_else(|| id.clone());
                    let host = Host {
                        id,
                        name,
                        password: password.unwrap_or("").into(),
                        lan: vec![addr],
                        fp: Some(accepted.fp),
                    };
                    return self.save_host(host);
                }
                Err(e) => refused = Some(e),
            }
        }
        // A host seen over `rapp/2` before is never added by password.
        let password = match (password, known) {
            (Some(p), None) => p,
            _ => return Err(refused.unwrap_or_else(|| anyhow!("missing password"))),
        };
        let auth = Op::Auth { password: Some(password.into()), name: self.me() };
        let (conn, r) = self.dial(&addr, LAN_WAIT, &auth).await?;
        conn.close(0u32.into(), b"host added");
        if r["id"] != id.as_str() {
            bail!("{addr} is ID {}, not {id}", r["id"].as_str().unwrap_or("?"));
        }
        let name = r["name"].as_str().unwrap_or(&id).to_string();
        self.save_host(Host { id, name, password: password.into(), lan: vec![addr], fp: None })
    }

    fn save_host(&self, host: Host) -> Result<Value> {
        let ev = json!({"event":"host_added","id":host.id,"name":host.name});
        self.hosts.upsert(host.clone())?;
        self.forget(&host.id);
        Ok(ev)
    }

    async fn send_on(&self, link: &Link, op: &Op) -> Result<(Pipe, Value)> {
        exchange(&link.conn, &[op]).await
    }

    /// Dials `addr` over `rapp/1` and authenticates; the connection is closed on refusal.
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
        for a in dial_order(lan) {
            match self.dial(a, LAN_WAIT, auth).await {
                Ok((c, r)) if r["id"] == id => {
                    self.route(id, "lan", Some(a), Ok(()));
                    return Some(c);
                }
                Ok((c, r)) => {
                    // Someone else's service (e.g. B's own, from a relay-era loopback entry): not this host.
                    c.close(0u32.into(), b"wrong host");
                    let why = format!("is ID {}, not {id}", r["id"].as_str().unwrap_or("?"));
                    self.route(id, "lan", Some(a), Err(why));
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
    pub async fn request(&self, host: &Host, op: &Op) -> Result<(Pipe, Value, &'static str)> {
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

fn finish((s, r): (Pipe, Value), path: &'static str) -> Result<(Pipe, Value, &'static str)> {
    if r["ok"] == true {
        Ok((s, r, path))
    } else {
        Err(anyhow!(error_of(&r)))
    }
}

#[cfg(test)]
mod tests {
    use super::{dial_order, is_refusal};
    use anyhow::anyhow;

    #[test]
    fn only_definite_refusals_halt_probes() {
        assert!(is_refusal(&anyhow!("not trusted")));
        assert!(is_refusal(&anyhow!("host key mismatch")));
        for transient in ["no reply", "stream closed", "stream closed mid-line", "connection lost", "unknown op"] {
            assert!(!is_refusal(&anyhow!(transient)), "{transient}");
        }
    }

    fn order(l: &[&str]) -> Vec<String> {
        let l: Vec<String> = l.iter().map(|s| s.to_string()).collect();
        dial_order(&l).into_iter().cloned().collect()
    }

    #[test]
    fn loopback_is_skipped_only_when_a_real_address_exists() {
        assert_eq!(
            order(&["192.168.1.5:22028", "10.0.0.2:22028", "127.0.0.1:22028"]),
            ["192.168.1.5:22028", "10.0.0.2:22028"]
        );
        assert_eq!(order(&["[::1]:22028", "192.168.1.5:22028"]), ["192.168.1.5:22028"]);
        assert_eq!(order(&["127.0.0.1:22028"]), ["127.0.0.1:22028"]);
        assert_eq!(order(&["127.0.0.1:1", "127.0.0.2:2"]), ["127.0.0.1:1", "127.0.0.2:2"]);
    }
}
