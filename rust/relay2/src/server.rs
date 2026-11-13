//! The relay service (spec §6.4, §9.2): QUIC accept with address validation, the connection
//! caps, mandatory device certificates, revocation at the handshake, and the enrollment gate.
//!
//! Every bidirectional stream a device opens carries one request line and gets one reply line.
//! A connection whose fingerprint is not enrolled may only `enroll`.

use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use anyhow::{Context, Result};
use rapp_net::log::{Log, Lvl};
use rapp_wire::line::{err, ok, read_json, write_json};
use rapp_wire::msg::Req;
use rapp_wire::tls::{self, BiStream};
use rapp_wire::{join_hash, Fp, Identity};
use serde_json::{json, Value};
use tokio::io::BufReader;

use crate::audit::Audit;
use crate::config::{Config, Enroll};
use crate::limits::{source_key, Backoff, ConnGuard, Conns, Rate};
use crate::store::{FileRegistry, Registry};

const VERSION: &str = env!("CARGO_PKG_VERSION");
const TENANT: &str = "default";

/// Connection close codes (rapp_wire::msg).
const CLOSE_NORMAL: u32 = 0;
const CLOSE_REVOKED: u32 = 2;
const CLOSE_LIMIT: u32 = 3;

/// How long `stop` waits for connections to finish closing.
const STOP_WAIT: Duration = Duration::from_secs(2);

const BAD_REQUEST: &str = "bad request";

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
}

/// One device connection, as its request streams see it.
struct Peer {
    conn: quinn::Connection,
    fp: Fp,
    from: SocketAddr,
    /// Set once, by a successful `enroll` (or at the handshake for a known device).
    enrolled: AtomicBool,
}

impl Peer {
    fn enrolled(&self) -> bool {
        self.enrolled.load(Ordering::Acquire)
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
    let peer = Arc::new(Peer { conn, fp, from, enrolled: AtomicBool::new(known.is_some()) });
    s.log.event(
        Lvl::Debug,
        "conn_open",
        json!({"fp": fp.short(), "from": from.to_string(), "enrolled": peer.enrolled()}),
    );
    if !peer.enrolled() {
        tokio::spawn(enroll_deadline(Duration::from_secs(s.config.limits.unenrolled_idle_secs), peer.clone()));
    }
    while let Ok(pair) = peer.conn.accept_bi().await {
        tokio::spawn(stream(s.clone(), peer.clone(), tls::bi(pair)));
    }
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
    async fn request(&self, peer: &Peer, req: Req) -> Value {
        match req {
            Req::Enroll { join } => self.enroll(peer, &join),
            _ if !peer.enrolled() => err("not enrolled"),
            // Task 9: register, connect.
            Req::Register { .. } | Req::Connect { .. } | Req::Relay { .. } => err(BAD_REQUEST),
        }
    }

    /// One enrollment attempt; every attempt is audited with its result.
    fn enroll(&self, peer: &Peer, join: &str) -> Value {
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
                peer.enrolled.store(true, Ordering::Release);
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
