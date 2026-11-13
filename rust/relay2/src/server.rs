//! The relay service (spec §6.4, §9.2): QUIC accept with address validation, the connection
//! caps, mandatory device certificates, revocation at the handshake, and the enrollment gate.
//!
//! Every bidirectional stream a device opens carries one request line and gets one reply line.
//! A connection whose fingerprint is not enrolled may only `enroll`. Enrolled devices `register`
//! their ID and `connect` to each other's (§5.1, §8); every enrolled connection gets the
//! revocation list when it comes online and whenever the list changes (§7.4).

use std::collections::HashMap;
use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::{Duration, Instant, SystemTime};

use anyhow::{Context, Result};
use rapp_net::log::{Log, Lvl};
use rapp_wire::line::{err, ok, read_json, write_json};
use rapp_wire::msg::{is_valid_id, Push, Req, MAX_LAN, MAX_LAN_LEN};
use rapp_wire::tls::{self, BiStream};
use rapp_wire::{join_hash, Fp, Identity};
use serde_json::{json, Value};
use tokio::io::BufReader;

use crate::audit::Audit;
use crate::config::{Config, Enroll};
use crate::limits::{source_key, Backoff, ConnGuard, Conns, Rate};
use crate::store::{Bind, FileRegistry, Registry};

const VERSION: &str = env!("CARGO_PKG_VERSION");
const TENANT: &str = "default";

/// Connection close codes (rapp_wire::msg).
const CLOSE_NORMAL: u32 = 0;
const CLOSE_REVOKED: u32 = 2;
const CLOSE_LIMIT: u32 = 3;

/// How long `stop` waits for connections to finish closing.
const STOP_WAIT: Duration = Duration::from_secs(2);

/// How long the target of a `connect` has to answer `incoming` before it counts as offline.
const INCOMING_WAIT: Duration = Duration::from_secs(2);

const BAD_REQUEST: &str = "bad request";
const OFFLINE: &str = "offline";

pub struct Opts {
    pub data: PathBuf,
    pub config: Config,
    pub log: Log,
    /// `RAPP_RELAY_ENROLL` was set at startup (Task 11).
    pub enroll_from_env: bool,
}

pub struct Relay {
    /// The address the endpoint is bound to.
    pub addr: SocketAddr,
    /// The relay identity's fingerprint (what devices pin).
    pub fp: Fp,
    shared: Arc<Shared>,
    endpoint: quinn::Endpoint,
    accept: tokio::task::JoinHandle<()>,
}

/// State every connection task shares.
struct Shared {
    config: Config,
    log: Log,
    audit: Audit,
    registry: Arc<dyn Registry>,
    /// Starts from `config.enroll`; the admin socket flips it at runtime.
    enroll_open: AtomicBool,
    conns: Conns,
    enroll_rate: Rate,
    enroll_backoff: Backoff,
    /// Makes the device-cap check and the registry write one step.
    enroll_lock: Mutex<()>,
    /// `connect` failures (`bad id`, `unknown id`), keyed `fp:<fp>` and `ip:<source>`.
    connect_backoff: Backoff,
    /// `connect`s per target ID, all initiators together.
    connect_rate: Rate,
    online: Mutex<Online>,
}

/// The live connections. One lock covers both tables, so an admission, a `register` and a
/// `revoke` never interleave.
#[derive(Default)]
struct Online {
    /// Every enrolled connection, by `Peer::key`: who gets the revocation list.
    all: HashMap<usize, Arc<Peer>>,
    /// Registered connections, by ID: whom `connect` (and Task 10's `relay`) reaches.
    by_id: HashMap<String, Registered>,
}

struct Registered {
    peer: Arc<Peer>,
    lan: Vec<String>,
}

/// One device connection, as its request streams see it.
struct Peer {
    conn: quinn::Connection,
    fp: Fp,
    from: SocketAddr,
    tenant: String,
    /// Set once, by a successful `enroll` (or at the handshake for a known device).
    enrolled: AtomicBool,
}

impl Peer {
    fn enrolled(&self) -> bool {
        self.enrolled.load(Ordering::Acquire)
    }

    /// Fixed for the connection's lifetime.
    fn key(&self) -> usize {
        self.conn.stable_id()
    }
}

impl Relay {
    pub async fn start(opts: Opts) -> Result<Relay> {
        let Opts { data, config, log, enroll_from_env: _ } = opts;
        let registry: Arc<dyn Registry> = Arc::new(FileRegistry::open(&data)?);
        let identity = Identity::load_or_create(&data, "relay").context("relay identity")?;
        let audit = Audit::open(&data, &config.audit, log.clone())?;
        let sc = tls::server_config(&identity, tls::ALPN_RELAY, config.limits.max_streams)?;
        let endpoint =
            quinn::Endpoint::server(sc, config.listen).with_context(|| format!("listen on {}", config.listen))?;
        let addr = endpoint.local_addr()?;
        audit.event("relay_start", json!({"version": VERSION, "config": &config}), true);
        log.event(Lvl::Info, "listening", json!({"addr": addr.to_string(), "fp": identity.fp.short()}));

        let l = &config.limits;
        let shared = Arc::new(Shared {
            log,
            audit,
            registry,
            enroll_open: AtomicBool::new(config.enroll == Enroll::Open),
            conns: Conns::new(l.max_conns, l.max_conns_per_ip),
            enroll_rate: Rate::new(l.enroll_per_ip_per_min),
            enroll_backoff: Backoff::new(l.lock_after, l.lock_max_secs),
            enroll_lock: Mutex::new(()),
            connect_backoff: Backoff::new(l.lock_after, l.lock_max_secs),
            connect_rate: Rate::new(l.connect_per_target_per_min),
            online: Mutex::new(Online::default()),
            config,
        });
        let accept = tokio::spawn(accept_loop(shared.clone(), endpoint.clone()));
        Ok(Relay { addr, fp: identity.fp, shared, endpoint, accept })
    }

    /// Stops accepting, closes every connection (code 0), records `relay_stop` and flushes.
    pub async fn stop(self) {
        // Task 11: push `going_away` to every connection here, before the endpoint closes.
        self.endpoint.close(CLOSE_NORMAL.into(), b"stop");
        self.accept.abort();
        let _ = tokio::time::timeout(STOP_WAIT, self.endpoint.wait_idle()).await;
        let s = &self.shared;
        if let Err(e) = s.registry.flush() {
            s.log.event(Lvl::Error, "registry_flush_failed", json!({"error": format!("{e:#}")}));
        }
        s.audit.event("relay_stop", json!({"version": VERSION, "reason": "stop"}), true);
        s.audit.flush();
        s.log.flush();
    }

    pub fn registry(&self) -> Arc<dyn Registry> {
        self.shared.registry.clone()
    }

    pub fn audit(&self) -> &Audit {
        &self.shared.audit
    }

    /// Revokes `fp` in the registry; if that changed anything, closes its connections (code 2),
    /// sends the new list to every other enrolled connection and records `revoke`.
    /// False when `fp` was unknown or already revoked.
    pub async fn revoke(&self, fp: &Fp) -> Result<bool> {
        self.shared.revoke(fp)
    }
}

async fn accept_loop(s: Arc<Shared>, endpoint: quinn::Endpoint) {
    while let Some(incoming) = endpoint.accept().await {
        // Address validation first: nothing but a Retry goes to an address that has not
        // echoed a token, so the relay cannot be used to amplify traffic at a forged source.
        if !incoming.remote_address_validated() {
            let _ = incoming.retry();
            continue;
        }
        let slot = s.conns.admit(incoming.remote_address().ip());
        tokio::spawn(handshake(s.clone(), incoming, slot));
    }
}

async fn handshake(s: Arc<Shared>, incoming: quinn::Incoming, slot: Result<ConnGuard, &'static str>) {
    let from = incoming.remote_address();
    let done = match incoming.accept() {
        Ok(connecting) => connecting.await,
        Err(e) => Err(e),
    };
    let failed = |error: String, over: Option<&str>| {
        s.log.event(Lvl::Info, "handshake_failed", json!({"from": from.to_string(), "error": error}));
        if let Some(what) = over {
            s.limit(what, None, from);
        }
    };
    let conn = match done {
        Ok(conn) => conn,
        Err(e) => return failed(e.to_string(), slot.err()),
    };
    let fp = match tls::peer_fp(&conn) {
        Ok(fp) => fp,
        Err(e) => {
            conn.close(CLOSE_NORMAL.into(), b"no certificate");
            return failed(format!("{e:#}"), slot.err());
        }
    };
    // Over a cap: the handshake is finished first so the device sees close code 3,
    // not a bare transport error.
    let guard = match slot {
        Ok(g) => g,
        Err(what) => {
            s.limit(what, Some(&fp), from);
            conn.close(CLOSE_LIMIT.into(), b"limit");
            return;
        }
    };
    serve(s, conn, fp, from, guard).await;
}

/// Runs one admitted connection until it closes; `_slot` holds its place in the caps.
async fn serve(s: Arc<Shared>, conn: quinn::Connection, fp: Fp, from: SocketAddr, _slot: ConnGuard) {
    let known = s.registry.get(&fp);
    if known.as_ref().is_some_and(|d| d.revoked) {
        s.log.event(Lvl::Info, "revoked_refused", json!({"fp": fp.short(), "from": from.to_string()}));
        conn.close(CLOSE_REVOKED.into(), b"revoked");
        return;
    }
    let tenant = known.as_ref().map_or(TENANT, |d| &d.tenant).to_string();
    let peer = Arc::new(Peer { conn, fp, from, tenant, enrolled: AtomicBool::new(known.is_some()) });
    s.log.event(
        Lvl::Debug,
        "conn_open",
        json!({"fp": fp.short(), "from": from.to_string(), "enrolled": peer.enrolled()}),
    );
    if peer.enrolled() {
        if !s.go_online(&peer) {
            return;
        }
    } else {
        tokio::spawn(enroll_deadline(Duration::from_secs(s.config.limits.unenrolled_idle_secs), peer.clone()));
    }
    while let Ok(pair) = peer.conn.accept_bi().await {
        tokio::spawn(stream(s.clone(), peer.clone(), tls::bi(pair)));
    }
    s.go_offline(&peer);
    s.log.event(Lvl::Debug, "conn_closed", json!({"fp": fp.short(), "from": from.to_string()}));
}

/// Closes the connection if it has not enrolled within `idle` of connecting.
async fn enroll_deadline(idle: Duration, peer: Arc<Peer>) {
    tokio::select! {
        _ = tokio::time::sleep(idle) => {
            if !peer.enrolled() {
                peer.conn.close(CLOSE_NORMAL.into(), b"enroll timeout");
            }
        }
        _ = peer.conn.closed() => {}
    }
}

/// One request stream: read the line (within `request_timeout_secs`), dispatch, reply, finish.
async fn stream(s: Arc<Shared>, peer: Arc<Peer>, st: BiStream) {
    let limits = &s.config.limits;
    let mut st = BufReader::new(st);
    let wait = Duration::from_secs(limits.request_timeout_secs);
    let line = match tokio::time::timeout(wait, read_json(&mut st, limits.max_line)).await {
        // `read_json` is not cancel-safe: part of the line is gone, so the stream is reset,
        // not read again. The connection stays up.
        Err(_) => return reset(st),
        Ok(Err(_)) => return reply(st, err(BAD_REQUEST)).await,
        Ok(Ok(v)) => v,
    };
    let Ok(req) = serde_json::from_value::<Req>(line) else { return reply(st, err(BAD_REQUEST)).await };
    // Task 10: `Req::Relay` takes over `st` here instead of getting a reply line.
    let res = s.request(&peer, req).await;
    reply(st, res).await;
}

impl Shared {
    async fn request(&self, peer: &Arc<Peer>, req: Req) -> Value {
        match req {
            Req::Enroll { join } => self.enroll(peer, &join),
            _ if !peer.enrolled() => err("not enrolled"),
            Req::Register { id, lan } => self.register(peer, id, lan),
            Req::Connect { id } => self.connect(peer, &id).await,
            // Task 10: relay.
            Req::Relay { .. } => err(BAD_REQUEST),
        }
    }

    fn online(&self) -> MutexGuard<'_, Online> {
        self.online.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// Puts an enrolled connection in the table of all of them and sends it the revocation list.
    /// The registry is checked again under the lock, so a `revoke` that runs at the same time
    /// either finds this connection or is seen here; then the connection is closed (code 2).
    fn go_online(&self, peer: &Arc<Peer>) -> bool {
        {
            let mut on = self.online();
            if !matches!(self.registry.get(&peer.fp), Some(d) if !d.revoked) {
                peer.conn.close(CLOSE_REVOKED.into(), b"revoked");
                return false;
            }
            // Closed already (an `enroll` that finished late): `go_offline` may have run.
            if peer.conn.close_reason().is_some() {
                return false;
            }
            on.all.insert(peer.key(), peer.clone());
        }
        self.seen(&peer.fp);
        self.push_revoked([peer.clone()]);
        true
    }

    /// Takes a closed connection out of both tables (out of `by_id` only where it is still the
    /// registered one).
    fn go_offline(&self, peer: &Arc<Peer>) {
        let was_online = {
            let mut on = self.online();
            on.by_id.retain(|_, r| r.peer.key() != peer.key());
            on.all.remove(&peer.key()).is_some()
        };
        if was_online {
            self.seen(&peer.fp);
        }
    }

    fn seen(&self, fp: &Fp) {
        self.registry.seen(fp, &rapp_net::log::timestamp(SystemTime::now()));
    }

    /// Sends the current revocation list to each of `peers`, each on a fresh uni stream.
    /// Never waits on a device: every push runs on its own task, and a failed one is only logged.
    fn push_revoked(&self, peers: impl IntoIterator<Item = Arc<Peer>>) {
        let push = Arc::new(Push::Revoked { fps: self.registry.revoked() });
        for peer in peers {
            let (push, log) = (push.clone(), self.log.clone());
            tokio::spawn(async move {
                if let Err(e) = push_uni(&peer.conn, &push).await {
                    let error = format!("{e:#}");
                    log.event(Lvl::Debug, "push_failed", json!({"fp": peer.fp.short(), "error": error}));
                }
            });
        }
    }

    fn revoke(&self, fp: &Fp) -> Result<bool> {
        if !self.registry.revoke(fp)? {
            return Ok(false);
        }
        let (gone, rest): (Vec<_>, Vec<_>) = {
            let mut on = self.online();
            on.by_id.retain(|_, r| r.peer.fp != *fp);
            let (gone, rest) = on.all.values().cloned().partition(|p| p.fp == *fp);
            on.all.retain(|_, p| p.fp != *fp);
            (gone, rest)
        };
        for p in &gone {
            p.conn.close(CLOSE_REVOKED.into(), b"revoked");
        }
        self.push_revoked(rest);
        self.audit.event("revoke", json!({"fp": fp.to_string()}), true);
        Ok(true)
    }

    /// `register`: claims `id` for this device and makes this connection the one it reaches.
    fn register(&self, peer: &Arc<Peer>, id: String, lan: Vec<String>) -> Value {
        if !is_valid_id(&id) {
            return err("bad id");
        }
        if lan.len() > MAX_LAN || lan.iter().any(|a| a.len() > MAX_LAN_LEN) {
            return err(BAD_REQUEST);
        }
        let result = match self.bind(peer, &id, lan) {
            Ok(r) => r,
            Err(e) => {
                self.log.event(
                    Lvl::Error,
                    "register_failed",
                    json!({"fp": peer.fp.short(), "error": format!("{e:#}")}),
                );
                return err(BAD_REQUEST);
            }
        };
        self.audit.event(
            "register",
            json!({"fp": peer.fp.to_string(), "id": id, "from": peer.from.to_string(), "result": result}),
            false,
        );
        match result {
            "id taken" => err(result),
            _ => ok(json!({"id": id})),
        }
    }

    /// The registry bind and the table insert as one step under the online lock, so of two
    /// devices racing for one ID exactly one ends up holding it in both. Returns the audit result.
    fn bind(&self, peer: &Arc<Peer>, id: &str, lan: Vec<String>) -> Result<&'static str> {
        let mut on = self.online();
        let bound = self.registry.bind_id(&peer.fp, id)?;
        if bound == Bind::Taken {
            return Ok("id taken");
        }
        // `bind_id` moves a device's ID: an entry of this device under another ID is stale now.
        on.by_id.retain(|k, r| k == id || r.peer.fp != peer.fp);
        // Closed already: `go_offline` may have run, and nothing would take the entry out again.
        let old = match peer.conn.close_reason() {
            Some(_) => None,
            None => on.by_id.insert(id.to_string(), Registered { peer: peer.clone(), lan }),
        };
        drop(on);
        let replaced = old.is_some_and(|o| {
            let other = o.peer.key() != peer.key();
            if other {
                o.peer.conn.close(CLOSE_NORMAL.into(), b"replaced");
            }
            other
        });
        Ok(match bound {
            Bind::New => "new",
            _ if replaced => "replaced",
            _ => "ok",
        })
    }

    /// `connect`: introduces this device to the one registered as `id`. Every attempt is audited.
    async fn connect(&self, peer: &Arc<Peer>, id: &str) -> Value {
        let res = self.try_connect(peer, id).await;
        let result = match &res {
            Ok(_) => "ok",
            Err(e) => e.as_str(),
        };
        self.audit.event(
            "connect",
            json!({"fp": peer.fp.to_string(), "from": peer.from.to_string(), "to": id, "result": result}),
            false,
        );
        res.unwrap_or_else(|e| err(&e))
    }

    /// Only `bad id` and `unknown id` count as failures: polling a host that is asleep (`offline`)
    /// is normal, and `limit` is the target's budget, not the initiator's fault.
    async fn try_connect(&self, peer: &Arc<Peer>, id: &str) -> Result<Value, String> {
        let now = Instant::now();
        let keys = [format!("fp:{}", peer.fp), format!("ip:{}", source_key(peer.from.ip()))];
        if !is_valid_id(id) {
            self.connect_failed(&keys, now);
            return Err("bad id".into());
        }
        if let Some(secs) = keys.iter().filter_map(|k| self.connect_backoff.locked(k, now)).max() {
            return Err(format!("locked, retry in {secs}s"));
        }
        let Some(holder) = self.registry.by_id(id) else {
            self.connect_failed(&keys, now);
            return Err("unknown id".into());
        };
        // After the lookup, so made-up IDs cannot fill the rate table (the backoff covers those).
        if !self.connect_rate.allow(id, now) {
            self.limit("connect_per_target_per_min", Some(&peer.fp), peer.from);
            return Err("limit".into());
        }
        let target = {
            let on = self.online();
            let r = on.by_id.get(id).filter(|r| r.peer.fp == holder.fp && r.peer.tenant == peer.tenant);
            r.map(|r| (r.peer.clone(), r.lan.clone()))
        };
        let Some((target, lan)) = target else { return Err(OFFLINE.into()) };
        if !introduce(&target, peer, self.config.limits.max_line).await {
            return Err(OFFLINE.into());
        }
        for k in &keys {
            self.connect_backoff.reset(k);
        }
        Ok(ok(json!({"lan": lan, "public": target.from.to_string()})))
    }

    fn connect_failed(&self, keys: &[String], now: Instant) {
        for k in keys {
            if let Some(secs) = self.connect_backoff.fail(k, now) {
                self.audit.event("lockout", json!({"key": k, "secs": secs}), true);
            }
        }
    }

    /// One enrollment attempt; every attempt is audited with its result.
    fn enroll(&self, peer: &Arc<Peer>, join: &str) -> Value {
        let res = self.try_enroll(peer, join);
        let result = match &res {
            Ok(()) => "ok",
            Err(e) => e.as_str(),
        };
        self.audit.event(
            "enroll",
            json!({"fp": peer.fp.to_string(), "from": peer.from.to_string(), "result": result}),
            true,
        );
        match res {
            Ok(()) => {
                if !peer.enrolled.swap(true, Ordering::AcqRel) {
                    self.go_online(peer);
                }
                ok(json!({"relay": {"version": VERSION, "features": []}}))
            }
            Err(e) => err(&e),
        }
    }

    fn try_enroll(&self, peer: &Peer, join: &str) -> Result<(), String> {
        if !self.enroll_open.load(Ordering::Acquire) {
            return Err("closed".into());
        }
        let Some(want) = self.registry.join_hash() else { return Err("no key".into()) };
        let source = source_key(peer.from.ip()).to_string();
        let now = Instant::now();
        if let Some(secs) = self.enroll_backoff.locked(&source, now) {
            return Err(format!("locked, retry in {secs}s"));
        }
        if !self.enroll_rate.allow(&source, now) {
            self.limit("enroll_per_ip_per_min", Some(&peer.fp), peer.from);
            return Err("limit".into());
        }
        let _one_at_a_time = self.enroll_lock.lock().unwrap_or_else(|e| e.into_inner());
        if self.registry.get(&peer.fp).is_none() && self.registry.count() >= self.config.limits.max_devices {
            self.limit("max_devices", Some(&peer.fp), peer.from);
            return Err("limit".into());
        }
        if !join_matches(join, &want) {
            if let Some(secs) = self.enroll_backoff.fail(&source, now) {
                self.audit.event("lockout", json!({"key": source, "secs": secs}), true);
            }
            return Err("bad key".into());
        }
        if let Err(e) = self.registry.enroll(peer.fp, TENANT) {
            self.log.event(Lvl::Error, "enroll_failed", json!({"fp": peer.fp.short(), "error": format!("{e:#}")}));
            return Err(BAD_REQUEST.into());
        }
        self.enroll_backoff.reset(&source);
        Ok(())
    }

    /// Audits one hit on the limit named `what` (the config item).
    fn limit(&self, what: &str, fp: Option<&Fp>, from: SocketAddr) {
        let fp = fp.map(|f| f.to_string());
        self.audit.event("limit", json!({"what": what, "fp": fp, "from": from.to_string()}), false);
    }
}

/// Tells `target` that `from` is about to dial it; true once it answers `{"ok":true}` within
/// `INCOMING_WAIT`.
async fn introduce(target: &Peer, from: &Peer, max_line: usize) -> bool {
    let push = Push::Incoming { peer: from.from.to_string(), fp: from.fp };
    let ask = async {
        let (mut send, recv) = target.conn.open_bi().await?;
        write_json(&mut send, &push).await?;
        let _ = send.finish();
        read_json(&mut BufReader::new(recv), max_line).await
    };
    matches!(tokio::time::timeout(INCOMING_WAIT, ask).await, Ok(Ok(v)) if v["ok"] == true)
}

/// One push on a fresh unidirectional stream.
async fn push_uni(conn: &quinn::Connection, push: &Push) -> Result<()> {
    let mut send = conn.open_uni().await?;
    write_json(&mut send, push).await?;
    send.finish()?;
    Ok(())
}

fn reset(st: BufReader<BiStream>) {
    let (mut recv, mut send) = st.into_inner().into_inner();
    let _ = send.reset(0u32.into());
    let _ = recv.stop(0u32.into());
}

async fn reply(st: BufReader<BiStream>, v: Value) {
    let (_recv, mut send) = st.into_inner().into_inner();
    if write_json(&mut send, &v).await.is_ok() {
        let _ = send.finish();
    }
}

/// `join_hex` (64 hex digits) hashes to `want`; anything that does not decode is a wrong key.
fn join_matches(join_hex: &str, want: &str) -> bool {
    let Ok(bytes) = data_encoding::HEXLOWER_PERMISSIVE.decode(join_hex.as_bytes()) else { return false };
    let Ok(join) = <[u8; 32]>::try_from(bytes) else { return false };
    ct_eq(join_hash(&join).as_bytes(), want.as_bytes())
}

/// Constant time in the contents (the lengths are not secret: both are hex SHA-256).
fn ct_eq(a: &[u8], b: &[u8]) -> bool {
    a.len() == b.len() && a.iter().zip(b).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
}

#[cfg(test)]
mod tests {
    use super::*;
    use rapp_wire::Key;

    #[test]
    fn join_matches_only_the_right_secret() {
        let k = Key::new_local();
        let want = join_hash(&k.join());
        let hex = data_encoding::HEXLOWER.encode(&k.join());
        assert!(join_matches(&hex, &want));
        assert!(join_matches(&hex.to_uppercase(), &want));
        assert!(!join_matches(&data_encoding::HEXLOWER.encode(&Key::new_local().join()), &want));
        assert!(!join_matches(&hex[..62], &want));
        assert!(!join_matches("zz", &want));
        assert!(!join_matches("", &want));
    }

    #[test]
    fn ct_eq_compares_whole_slices() {
        assert!(ct_eq(b"abc", b"abc"));
        assert!(!ct_eq(b"abc", b"abd"));
        assert!(!ct_eq(b"abc", b"ab"));
        assert!(ct_eq(b"", b""));
    }
}
