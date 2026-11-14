//! Reaching a host. A host with a stored fingerprint, or any host when B has a key, is reached over
//! `rapp/2` (the saved LAN addresses tried together, 500 ms each, first to answer wins); a host that
//! never showed a fingerprint may fall back to `rapp/1` and its password. A host with a stored
//! fingerprint never falls back. When no address answers and B has a relay and key, the host is reached
//! through the relay: one relayed stream per request. A host forced onto the relay (`route`) is reached
//! through the relay only, never on its LAN. One connection per host is cached, and each one cached is
//! announced with a `path` event; a lost connection triggers one fresh connect.

use crate::hosts::Host;
use crate::Hub;
use anyhow::{anyhow, bail, Context, Result};
use quinn::{Connection, Endpoint};
use rapp_conn::relay::{Found, RelayConn};
use rapp_conn::{e2e_connect, quic_facts, read_welcome, send_hello, Accepted, Me, Pipe, Role};
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
/// The relay lookup of a connect: a hung relay must not hang the connect.
const RELAY_WAIT: Duration = Duration::from_secs(5);

tokio::task_local! {
    /// Set around presence probes: they must leave hub.log alone (no `route`, no `reconnecting`).
    pub static QUIET: bool;
}

fn quiet() -> bool {
    QUIET.try_with(|q| *q).unwrap_or(false)
}

/// How a host is reached: over a QUIC connection of ours, or by a stream through the relay per request.
#[derive(Clone)]
pub enum Link {
    Quic { conn: Connection, path: &'static str },
    Relay,
}

impl Link {
    pub fn path(&self) -> &'static str {
        match self {
            Link::Quic { path, .. } => path,
            Link::Relay => "relay",
        }
    }

    fn close(&self, why: &'static [u8]) {
        if let Link::Quic { conn, .. } = self {
            conn.close(0u32.into(), why);
        }
    }
}

/// The connection to the relay and the settings it was dialed with: a change of any redials.
pub struct RelayCache {
    addr: String,
    key_text: String,
    /// The device it was dialed as.
    fp: Fp,
    pub(crate) conn: RelayConn,
    key: Arc<Key>,
}

/// A probe found the host through the relay: online, with nothing more to ask.
#[derive(Debug)]
struct Relayed;

impl std::fmt::Display for Relayed {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("reachable through the relay")
    }
}

impl std::error::Error for Relayed {}

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

/// The relay itself did not answer (as opposed to the relay answering for the host).
fn is_relay_unreachable(e: &anyhow::Error) -> bool {
    e.to_string().starts_with("relay unreachable: ")
}

/// The relay has no device with this ID (it counts that against the asker).
fn is_unknown_id(e: &anyhow::Error) -> bool {
    e.to_string() == "unknown id"
}

/// Why a settled host was not reached: no saved address answered and the relay did not find it.
/// A host with saved LAN addresses that the relay does not know is offline on its LAN, not an
/// unknown ID; any other relay failure is the relay's.
fn unreached(host: &Host, relay_err: Option<anyhow::Error>) -> anyhow::Error {
    match relay_err {
        Some(e) if host.lan.is_empty() || !is_unknown_id(&e) => e,
        _ if host.lan.is_empty() => anyhow!("no address: add the host again as id@ip"),
        _ => anyhow!("offline: no LAN address answered"),
    }
}

/// Whether a presence probe asks the relay about a host it has no verdict on from this run: a host
/// with no saved address (only the relay can find it), or one added over `rapp/2` with the key (no
/// password; by bare ID, or by `id@ip`), which is likely on the same relay. A host added with a
/// password (0.5.5 and older, LAN only) is not asked about until the relay has found it.
fn probe_asks_relay(host: &Host, seen: Option<bool>) -> bool {
    seen.unwrap_or(host.lan.is_empty() || host.password.is_empty())
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
        Dialer { ep: self.ep.clone(), identity: self.at_home().1, name: self.name.clone(), key }
    }

    /// The connection to the relay for the settings as they are now, dialed when there is none, it has
    /// ended or the settings changed. None: no relay or no key set.
    pub(crate) async fn relay(&self) -> Result<Option<(RelayConn, Arc<Key>)>> {
        let (home, identity) = self.at_home();
        let settings = rapp_conn::settings::load(&home);
        let (Some(addr), Some(key)) = (settings.relay, settings.key) else { return Ok(None) };
        let key_text = key.to_string();
        let mut cache = self.relay.lock().await;
        if let Some(c) = cache.as_ref() {
            if c.addr == addr && c.key_text == key_text && c.fp == identity.fp && !c.conn.is_closed() {
                return Ok(Some((c.conn.clone(), c.key.clone())));
            }
            c.conn.close();
            *cache = None;
        }
        let conn = RelayConn::dial(&self.ep, &addr, &key, &identity).await?;
        let key = Arc::new(key);
        *cache = Some(RelayCache { addr, key_text, fp: identity.fp, conn: conn.clone(), key: key.clone() });
        Ok(Some((conn, key)))
    }

    /// The relay's `connect` to `id`, within `RELAY_WAIT`: a relay that never answers must not stall
    /// a caller (presence probes run one host after another). Remembers what the relay said.
    async fn relay_connect(&self, relay: &RelayConn, id: &str) -> Result<Found> {
        let r = tokio::time::timeout(RELAY_WAIT, relay.connect_to(id))
            .await
            .unwrap_or_else(|_| Err(anyhow!("relay unreachable: timed out")));
        match &r {
            Ok(_) => drop(self.relay_seen.lock().unwrap().insert(id.to_string(), true)),
            Err(e) if is_unknown_id(e) => drop(self.relay_seen.lock().unwrap().insert(id.to_string(), false)),
            Err(_) => {}
        }
        r
    }

    /// Whether this connect asks the relay about `host`. The user acting on a host always asks (and
    /// forgets an earlier `unknown id`); a probe asks only as `probe_asks_relay` says.
    fn asks_relay(&self, host: &Host) -> bool {
        let mut seen = self.relay_seen.lock().unwrap();
        if !quiet() {
            if seen.get(&host.id) == Some(&false) {
                seen.remove(&host.id);
            }
            return true;
        }
        probe_asks_relay(host, seen.get(&host.id).copied())
    }

    /// Asks the relay where `id` is (`connect`), within `RELAY_WAIT`. `None`: no relay set, or no key.
    async fn lookup(&self, id: &str, wanted: bool) -> Result<Option<Found>> {
        if !wanted {
            return Ok(None);
        }
        let ask = async {
            match self.relay().await? {
                Some((relay, _)) => self.relay_connect(&relay, id).await.map(Some),
                None => Ok(None),
            }
        };
        tokio::time::timeout(RELAY_WAIT, ask).await.unwrap_or_else(|_| Err(anyhow!("relay unreachable: timed out")))
    }

    /// A host forced onto the relay: the relay or an error, never the LAN.
    async fn establish_forced(&self, host: &Host) -> Result<Link> {
        let relay = tokio::time::timeout(RELAY_WAIT, self.relay())
            .await
            .unwrap_or_else(|_| Err(anyhow!("relay unreachable: timed out")));
        let relay = match relay {
            Ok(Some((relay, _))) => relay,
            Ok(None) => bail!("relay not set: add the host as id@ip"),
            // The dial says `relay unreachable: ...` itself; other failures (a wrong relay identity) get it.
            Err(e) if is_relay_unreachable(&e) => return Err(e),
            Err(e) => bail!("relay unreachable: {e:#}"),
        };
        match self.relay_connect(&relay, &host.id).await {
            Ok(_) => {
                self.route(&host.id, "relay", None, Ok(()));
                Ok(Link::Relay)
            }
            Err(e) => {
                self.route(&host.id, "relay", None, Err(format!("{e:#}")));
                Err(e)
            }
        }
    }

    async fn establish(&self, host: &Host) -> Result<Link> {
        if host.forced_relay() {
            return self.establish_forced(host).await;
        }
        // Read on every connect: the user may have set a key since the last one.
        let key = rapp_conn::settings::load(&self.at_home().0).key.map(Arc::new);
        // The relay lookup (its `connect` also tells A somebody is coming, and may name more addresses)
        // runs alongside the race over the saved addresses; a relay that is down never delays a LAN win.
        let lookup = self.lookup(&host.id, key.is_some() && self.asks_relay(host));
        tokio::pin!(lookup);
        let mut looked_up = None;
        let mut found = None;
        let mut relay_err = None;
        if key.is_some() || host.fp.is_some() {
            // Seen with a key before, or nothing to fall back on: the answer stands.
            let settled = host.fp.is_some() || host.password.is_empty();
            let order = dial_order(&host.lan);
            let stored = self.first_v2(host, &order, key.clone());
            tokio::pin!(stored);
            let mut raced = None;
            while raced.is_none() {
                tokio::select! {
                    r = &mut stored => raced = Some(r),
                    l = &mut lookup, if looked_up.is_none() => looked_up = Some(l),
                }
            }
            let mut raced = raced.expect("race finished");
            if matches!(raced, Ok(None)) {
                let l = match looked_up.take() {
                    Some(l) => l,
                    None => lookup.await,
                };
                match l {
                    Ok(f) => found = f,
                    Err(e) => relay_err = Some(e),
                }
                // Addresses only the relay knew.
                let extra: Vec<String> =
                    found.iter().flat_map(|f| &f.lan).filter(|a| !host.lan.contains(a)).cloned().collect();
                if !extra.is_empty() {
                    raced = self.first_v2(host, &dial_order(&extra), key).await;
                }
            }
            match raced {
                Ok(Some((link, _))) => return Ok(link),
                Err(e) if settled => {
                    // A probe must not keep knocking on a host that refuses this device; a slow or
                    // restarting host (no reply, reset) is not a refusal and keeps being probed. A host
                    // that is not settled may still take its password below.
                    if quiet() && is_refusal(&e) {
                        self.probe_halt.lock().unwrap().insert(host.id.clone());
                    }
                    return Err(e);
                }
                Err(_) => {}
                Ok(None) if found.is_some() => {
                    self.route(&host.id, "relay", None, Ok(()));
                    return Ok(Link::Relay);
                }
                Ok(None) if settled => {
                    if let Some(e) = &relay_err {
                        self.route(&host.id, "relay", None, Err(format!("{e:#}")));
                    }
                    return Err(unreached(host, relay_err));
                }
                Ok(None) => {}
            }
        }
        if host.lan.is_empty() {
            bail!("no address: add the host again as id@ip");
        }
        let auth = Op::Auth { password: Some(host.password.clone()), name: self.me() };
        match self.first_lan(&host.id, &host.lan, &auth).await {
            Some(conn) => Ok(Link::Quic { conn, path: "lan" }),
            None => Err(anyhow!("offline: no LAN address answered")),
        }
    }

    /// Tries every address over `rapp/2` at once (500 ms each) and keeps the first that is welcomed.
    /// A host that answered and refused is an error; `None` means nobody answered.
    async fn first_v2(
        &self,
        host: &Host,
        addrs: &[&String],
        key: Option<Arc<Key>>,
    ) -> Result<Option<(Link, Accepted)>> {
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
                    return Ok(Some((Link::Quic { conn, path }, accepted)));
                }
                Err(e) => {
                    let unreachable = e.downcast_ref::<Unreachable>().is_some();
                    if let Ok(sock) = addr.parse::<SocketAddr>() {
                        self.route(&host.id, direct_path(&sock), Some(&addr), Err(format!("{e:#}")));
                    }
                    if !unreachable {
                        refused.get_or_insert(e);
                    }
                }
            }
        }
        refused.map_or(Ok(None), Err)
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
        let Some(addr) = addr else { return self.add_by_id(id).await };
        let sock: SocketAddr = addr.parse().with_context(|| format!("bad address {addr}"))?;
        let key = rapp_conn::settings::load(&self.at_home().0).key.map(Arc::new);
        let saved = self.hosts.get(&id);
        let known = saved.as_ref().and_then(|h| h.fp);
        let password = password.filter(|p| !p.is_empty());
        let mut refused = None;
        if key.is_some() {
            match self.dialer(key).dial(sock, &id, known, LAN_WAIT).await {
                Ok((conn, accepted)) => {
                    conn.close(0u32.into(), b"host added");
                    if let Some(saved) = &saved {
                        // A new fingerprint for a saved host is a key change, logged as on any connect.
                        self.remember_fp(saved, &accepted);
                    }
                    let name = Some(accepted.name).filter(|n| !n.is_empty()).unwrap_or_else(|| id.clone());
                    let host = Host {
                        id,
                        name,
                        password: password.unwrap_or("").into(),
                        lan: vec![addr],
                        fp: Some(accepted.fp),
                        route: None,
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
        self.save_host(Host { id, name, password: password.into(), lan: vec![addr], fp: None, route: None })
    }

    /// `add_host` by bare ID: found through the relay, reached on the addresses it reports or else
    /// through the relay itself. Saved with those addresses, the fingerprint it showed and no password.
    async fn add_by_id(&self, id: String) -> Result<Value> {
        let Some((relay, key)) = self.relay().await? else { bail!("relay not set: add the host as id@ip") };
        let found = self.relay_connect(&relay, &id).await?;
        let known = self.hosts.get(&id).and_then(|h| h.fp);
        let mut host = Host {
            id: id.clone(),
            name: String::new(),
            password: String::new(),
            lan: found.lan,
            fp: known,
            route: None,
        };
        let accepted = match self.first_v2(&host, &dial_order(&host.lan), Some(key.clone())).await? {
            Some((link, accepted)) => {
                link.close(b"host added");
                accepted
            }
            None => {
                let (_, r, accepted) = self.relay_hello(&relay, &key, &host, &Op::Ping).await?;
                if r["ok"] != true {
                    bail!(error_of(&r));
                }
                accepted
            }
        };
        host.name = Some(accepted.name).filter(|n| !n.is_empty()).unwrap_or(id);
        host.fp = Some(accepted.fp);
        self.save_host(host)
    }

    /// One relayed stream to `host`: end-to-end TLS, hello and `op` in one flight, then A's welcome.
    /// Returns the stream positioned after the reply to `op`, which is read too.
    async fn relay_hello(&self, relay: &RelayConn, key: &Key, host: &Host, op: &Op) -> Result<(Pipe, Value, Accepted)> {
        let known = self.hosts.get(&host.id).map_or(host.fp, |h| h.fp);
        let stream = relay.relay_to(&host.id).await?;
        // The relay's refusal (`offline`, `unknown id`, ...) comes back as the failure of this first read.
        let identity = self.at_home().1;
        let tls = tokio::time::timeout(REPLY_WAIT, e2e_connect(stream, &identity));
        let (mut pipe, facts) = tls.await.map_err(|_| anyhow!("no reply"))?.map_err(relay_failure)?;
        send_hello(&mut pipe, &facts, &Me { id: "", name: &self.name, key: Some(key) }).await?;
        write_json(&mut pipe, op).await?;
        let wait = async {
            let accepted = read_welcome(&mut pipe, &facts, Some(key), &host.id, known.as_ref()).await?;
            let r = read_json(&mut pipe).await?;
            anyhow::Ok((r, accepted))
        };
        let (r, accepted) = tokio::time::timeout(REPLY_WAIT, wait).await.map_err(|_| anyhow!("no reply"))??;
        self.remember_fp(host, &accepted);
        Ok((pipe, r, accepted))
    }

    fn save_host(&self, host: Host) -> Result<Value> {
        let ev = json!({"event":"host_added","id":host.id,"name":host.name});
        self.hosts.upsert(host.clone())?;
        self.forget(&host.id);
        Ok(ev)
    }

    async fn send_on(&self, host: &Host, link: &Link, op: &Op) -> Result<(Pipe, Value)> {
        match link {
            Link::Quic { conn, .. } => exchange(conn, &[op]).await,
            Link::Relay => {
                let Some((relay, key)) = self.relay().await? else { bail!("relay not set: add the host as id@ip") };
                let (pipe, r, _) = self.relay_hello(&relay, &key, host, op).await?;
                Ok((pipe, r))
            }
        }
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

    /// Caches `link` as the way to `id` and announces it with a `path` event. A host removed meanwhile
    /// gets neither: the link is dropped from here (not closed; a caller may still be using it).
    pub(crate) async fn cache_link(&self, id: &str, link: Link) {
        let path = link.path();
        {
            let mut links = self.links.lock().unwrap();
            if self.hosts.get(id).is_none() {
                return;
            }
            links.insert(id.to_string(), link);
        }
        self.emit(json!({"event":"path","id":id,"path":path}), &None).await;
    }

    /// Takes the link to `id` out of the cache without closing it: sessions on it keep running (quinn
    /// closes the connection when its last stream ends), and the next request connects anew.
    pub(crate) fn uncache(&self, id: &str) {
        self.links.lock().unwrap().remove(id);
    }

    /// Tries `id`'s LAN at once (filled in by the LAN upgrade).
    pub(crate) fn upgrade_now(&self, _id: &str) {}

    pub fn forget(&self, id: &str) {
        self.probe_halt.lock().unwrap().remove(id);
        if let Some(link) = self.links.lock().unwrap().remove(id) {
            link.close(b"forgotten");
        }
    }

    /// Whether `host` is there, for presence. A host reached through the relay is looked up with the
    /// relay's `connect` (ok means online); no stream is opened through the relay.
    pub async fn probe(&self, host: &Host) -> Result<()> {
        let cached = self.links.lock().unwrap().get(&host.id).cloned();
        if matches!(cached, Some(Link::Relay)) {
            let looked_up = match self.relay().await {
                Ok(Some((relay, _))) => self.relay_connect(&relay, &host.id).await.map(drop),
                Ok(None) => Err(anyhow!("relay not set: add the host as id@ip")),
                Err(e) => Err(e),
            };
            if looked_up.is_err() {
                // Offline now; the next probe finds the way again (LAN may be back).
                self.forget(&host.id);
            }
            return looked_up;
        }
        match self.request(host, &Op::Ping).await {
            Err(e) if e.downcast_ref::<Relayed>().is_some() => Ok(()),
            r => r.map(drop),
        }
    }

    /// Sends `op` to `host` and returns the open stream, the ok reply and the path used.
    pub async fn request(&self, host: &Host, op: &Op) -> Result<(Pipe, Value, &'static str)> {
        if !quiet() {
            // The user is acting on this host: presence may try it again.
            self.probe_halt.lock().unwrap().remove(&host.id);
        }
        let cached = {
            let mut links = self.links.lock().unwrap();
            if host.forced_relay() && links.get(&host.id).is_some_and(|l| !matches!(l, Link::Relay)) {
                // Cached before the host was forced: uncached, not closed (sessions on it keep it).
                links.remove(&host.id);
            }
            links.get(&host.id).cloned()
        };
        if let Some(link) = cached {
            match self.send_on(host, &link, op).await {
                // The relay was just dialed and did not answer: a forced host has no other way to go.
                Err(e) if host.forced_relay() && is_relay_unreachable(&e) => {
                    self.forget(&host.id);
                    return Err(e);
                }
                Err(e) if quiet() => drop(e),
                Err(e) => self.log.msg(Lvl::Warn, format_args!("{} via {}: {e:#}; reconnecting", host.id, link.path())),
                Ok(x) => return finish(x, link.path()),
            }
            self.forget(&host.id);
        }
        let link = self.establish(host).await?;
        // A host removed while this was in flight does not come back through the cache.
        self.cache_link(&host.id, link.clone()).await;
        if quiet() && matches!(link, Link::Relay) {
            // A probe asks the relay (`probe`), it does not open a stream through it.
            return Err(Relayed.into());
        }
        match self.send_on(host, &link, op).await {
            Ok(x) => finish(x, link.path()),
            Err(e) => {
                self.forget(&host.id);
                Err(e)
            }
        }
    }
}

/// What the relay said, from the io error `e2e_connect` fails with when the relay refused the stream.
fn relay_failure(e: anyhow::Error) -> anyhow::Error {
    match e.chain().find_map(|c| c.downcast_ref::<std::io::Error>()) {
        Some(io) => anyhow!(io.to_string()),
        None => e,
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
    use super::{dial_order, is_refusal, probe_asks_relay, unreached};
    use crate::hosts::Host;
    use anyhow::anyhow;

    fn host(password: &str, lan: &[&str]) -> Host {
        let lan = lan.iter().map(|a| a.to_string()).collect();
        Host { id: "100000001".into(), name: "n".into(), password: password.into(), lan, fp: None, route: None }
    }

    #[test]
    fn unknown_id_of_a_lan_host_reads_offline() {
        let lan = host("", &["192.168.1.5:22028"]);
        let bare = host("", &[]);
        let says = |h: &Host, e: Option<&str>| unreached(h, e.map(|e| anyhow!(e.to_string()))).to_string();
        assert_eq!(says(&lan, Some("unknown id")), "offline: no LAN address answered");
        assert_eq!(says(&lan, None), "offline: no LAN address answered");
        assert_eq!(says(&lan, Some("relay unreachable: timed out")), "relay unreachable: timed out");
        assert_eq!(says(&bare, Some("unknown id")), "unknown id");
        assert_eq!(says(&bare, Some("offline")), "offline");
        assert_eq!(says(&bare, None), "no address: add the host again as id@ip");
    }

    #[test]
    fn probes_ask_the_relay_only_about_hosts_it_may_know() {
        let old = host("pw", &["192.168.1.5:22028"]);
        assert!(!probe_asks_relay(&old, None), "a password host on the LAN");
        assert!(probe_asks_relay(&old, Some(true)), "found through the relay in this run");
        assert!(probe_asks_relay(&host("pw", &[]), None), "no address: only the relay can find it");
        assert!(probe_asks_relay(&host("", &["192.168.1.5:22028"]), None), "added over rapp/2");
        assert!(!probe_asks_relay(&host("", &[]), Some(false)), "the relay said unknown id");
    }

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
