//! Sending one request to another device: over a direct `rapp/2` connection when one is held or a
//! known LAN address answers, else through the relay: as a stream of the one channel kept for the
//! device (port-sharing 1b), or, to an older version that has no channels, one relayed stream per
//! request. The direct connection and the channel are kept per device ID and reused; the
//! connection to the relay is kept for the settings it was dialed with, and what the relay said
//! about a device for `FOUND_KEEP`.
//!
//! A smaller sibling of the hub's `link.rs` (same hello, same path rule), without its host list,
//! presence probes or LAN upgrades.

use std::collections::HashMap;
use std::future::Future;
use std::io;
use std::net::SocketAddr;
use std::pin::Pin;
use std::sync::{Arc, Mutex, OnceLock};
use std::task::Poll;
use std::time::{Duration, Instant};

use anyhow::{anyhow, bail, Result};
use quinn::Connection;
use rapp_net::addr::is_private;
use rapp_net::line::{read_json, write_json};
use rapp_net::msg::Op;
use rapp_net::quic::bi;
use rapp_wire::tls::{device_client_config, ALPN_DEVICE, SNI};
use rapp_wire::{Fp, Identity, Key};
use serde_json::Value;

use crate::mux::{Mux, MuxStream, Reader, Writer};
use crate::relay::{Found, RelayConn, FORWARD_PRIORITY};
use crate::{e2e_connect, quic_facts, read_welcome, send_hello, Accepted, Me, Pipe, Role};

/// How long one LAN address may take to connect and welcome us. The addresses of one list are
/// dialed at the same time, so this is also what a list of dead addresses costs.
pub const DIRECT_WAIT: Duration = Duration::from_secs(1);
/// How long the other device (or the relay) may take to answer.
pub const REPLY_WAIT: Duration = Duration::from_secs(20);
/// At most this many LAN addresses are tried, from each list.
const MAX_LAN: usize = 3;
/// How long the relay's answer about a device (`connect`) serves the relayed requests that
/// follow. Every `connect` spends the device's per-minute budget on the relay, which remote
/// sessions share, and costs a round trip.
pub const FOUND_KEEP: Duration = Duration::from_secs(30);
/// How long a device that answered `mux` as an older version does is sent one relayed stream per
/// request, without trying a channel again.
pub const OLD_KEEP: Duration = Duration::from_secs(600);

/// Where to find the other device and how to trust it.
pub struct Target<'a> {
    pub id: &'a str,
    /// LAN addresses already known (`hosts.json`); may be empty.
    pub lan: &'a [String],
    /// The fingerprint already known; None: the key vouches.
    pub known: Option<Fp>,
}

/// The settings a request goes out with, read fresh by the caller each time.
pub struct Via<'a> {
    /// The relay's address; None: LAN only.
    pub relay: Option<&'a str>,
    pub key: &'a Key,
}

pub struct Sent {
    pub pipe: Pipe,
    /// The other device's reply line (ok or not).
    pub reply: Value,
    /// "lan", "direct" or "relay".
    pub path: &'static str,
    pub fp: Fp,
}

/// Unreachable in every way that was tried; `to_string()` is "offline" or "unknown id".
#[derive(Debug)]
pub struct NotReached(pub &'static str);

impl std::fmt::Display for NotReached {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.0)
    }
}

impl std::error::Error for NotReached {}

/// A direct connection kept for a device, with what it was trusted by.
struct Link {
    conn: Connection,
    path: &'static str,
    fp: Fp,
    /// The key it was trusted with; in memory only, never logged.
    key_text: String,
}

/// The connection to the relay and the settings it was dialed with: a change of either redials.
struct RelayCache {
    addr: String,
    /// In memory only; never logged.
    key_text: String,
    conn: RelayConn,
}

/// What the last relayed request to a device learned, kept for `FOUND_KEEP` from the relay's
/// answer: the requests that follow go straight to a relayed stream.
#[derive(Clone)]
struct Looked {
    /// When the relay answered.
    at: Instant,
    /// The relay that was asked and the key that was shown (in memory only, never logged):
    /// another relay or key asks anew.
    relay: String,
    key_text: String,
    /// The relay's answer.
    found: Found,
    /// The LAN addresses, ours and the relay's, that did not welcome us since then.
    dead: Vec<String>,
}

impl Looked {
    /// Still good at `now` for a request through `relay` showing `key_text`.
    fn holds(&self, now: Instant, relay: &str, key_text: &str) -> bool {
        now.saturating_duration_since(self.at) < FOUND_KEEP && self.relay == relay && self.key_text == key_text
    }
}

/// The channel kept for a device: many requests, each on a stream of its own, inside one relayed
/// stream with one end-to-end TLS session and one hello.
struct Chan {
    mux: Mux,
    /// The relay and the key it was opened with (the key in memory only, never logged).
    relay: String,
    key_text: String,
    /// Filled when the channel's welcome has been read (in its ready future).
    fp: Arc<OnceLock<Fp>>,
}

impl Chan {
    /// Still good for a request through `relay` showing `key_text` to a device known by `known`
    /// (a fingerprint not yet read does not count against it).
    fn holds(&self, relay: &str, key_text: &str, known: Option<Fp>) -> bool {
        let same_fp = match (known, self.fp.get()) {
            (Some(k), Some(f)) => k == *f,
            _ => true,
        };
        !self.mux.is_closed() && self.relay == relay && self.key_text == key_text && same_fp
    }
}

/// Where a device's channel is kept. The lock is held while one is being opened, so the requests
/// that come meanwhile wait for it instead of opening their own.
type Slot = Arc<tokio::sync::Mutex<Option<Chan>>>;

/// What the LAN and the relay gave a request.
enum Reached {
    Sent(Sent),
    /// A new channel for it to go on, and the first definite refusal of a LAN address (the error
    /// in place of `offline` when the channel does not reach the device either).
    Chan(Chan, Option<anyhow::Error>),
}

pub struct Outbound {
    ep: quinn::Endpoint,
    identity: Arc<Identity>,
    name: String,
    links: Mutex<HashMap<String, Link>>,
    relay: tokio::sync::Mutex<Option<RelayCache>>,
    /// By device ID. An entry is put by a relayed request that got through and dropped by one
    /// that failed.
    looked: Mutex<HashMap<String, Looked>>,
    /// By device ID: the channel through the relay.
    chans: Mutex<HashMap<String, Slot>>,
    /// By device ID: when it answered `mux` as an older version does (good for `OLD_KEEP`).
    old: Mutex<HashMap<String, Instant>>,
}

impl Outbound {
    pub fn new(ep: quinn::Endpoint, identity: Arc<Identity>, name: String) -> Outbound {
        Outbound {
            ep,
            identity,
            name,
            links: Mutex::new(HashMap::new()),
            relay: tokio::sync::Mutex::new(None),
            looked: Mutex::new(HashMap::new()),
            chans: Mutex::new(HashMap::new()),
            old: Mutex::new(HashMap::new()),
        }
    }

    /// Sends `op` on a new stream to the device and returns it with the reply. The way, in order:
    /// the direct connection held, the channel held, the LAN addresses, the relay (opening a
    /// channel; one relayed stream for a device that is an older version).
    pub async fn request(&self, via: &Via<'_>, to: &Target<'_>, op: &Op) -> Result<Sent> {
        let key_text = via.key.to_string();
        if let Some(sent) = self.on_held(to, &key_text, op).await {
            return Ok(sent);
        }
        match via.relay {
            Some(addr) if !self.is_old(to.id) => self.on_channel(addr, via, to, &key_text, op).await,
            _ => self.the_old_way(via, to, op).await,
        }
    }

    /// Steps 2, 4 and 5 without a channel: the LAN addresses, else one relayed stream.
    async fn the_old_way(&self, via: &Via<'_>, to: &Target<'_>, op: &Op) -> Result<Sent> {
        match self.reach(via, to, op, false).await? {
            Reached::Sent(sent) => Ok(sent),
            Reached::Chan(..) => unreachable!("no channel was asked for"),
        }
    }

    /// Steps 3 to 5 with the channel held for the device, or a new one ("plan" rules 7 to 9 of
    /// port-sharing 1b): the slot is locked while a channel is opened, so it is opened once. A
    /// channel held that turns out to be dead is dropped and the request starts over, once; an
    /// older version (its answer to `mux`) is noted for `OLD_KEEP` and sent one relayed stream.
    async fn on_channel(&self, addr: &str, via: &Via<'_>, to: &Target<'_>, key_text: &str, op: &Op) -> Result<Sent> {
        let slot: Slot = self.chans.lock().unwrap().entry(to.id.to_string()).or_default().clone();
        let mut again = true;
        loop {
            let mut held = slot.lock().await;
            let (mux, fp, refused, kept) = match held.as_ref().filter(|c| c.holds(addr, key_text, to.known)) {
                Some(c) => (c.mux.clone(), c.fp.clone(), None, true),
                None => {
                    if let Some(c) = held.take() {
                        c.mux.close();
                    }
                    // While this one waited, the request before it may have found the device on
                    // the LAN, or found it to be an older version.
                    if let Some(sent) = self.on_held(to, key_text, op).await {
                        return Ok(sent);
                    }
                    if self.is_old(to.id) {
                        drop(held);
                        return self.the_old_way(via, to, op).await;
                    }
                    match self.reach(via, to, op, true).await? {
                        Reached::Sent(sent) => return Ok(sent),
                        Reached::Chan(c, refused) => {
                            let got = (c.mux.clone(), c.fp.clone(), refused, false);
                            *held = Some(c);
                            got
                        }
                    }
                }
            };
            drop(held);
            let e = match on_mux(&mux, op).await {
                Ok((s, reply)) => {
                    // The reply came after the welcome, so the fingerprint is there.
                    let fp = *fp.get().ok_or_else(|| anyhow!("no reply"))?;
                    return Ok(Sent { pipe: Box::new(s), reply, path: "relay", fp });
                }
                Err(e) => e,
            };
            let why = mux.reason();
            if matches!(why.as_deref(), Some("unknown op" | "bad request")) {
                self.old_now(to.id);
                drop_chan(&slot, &fp).await;
                return self.relayed_alone(addr, via, to, op).await;
            }
            if mux.is_closed() {
                drop_chan(&slot, &fp).await;
                if kept && again {
                    again = false;
                    continue;
                }
            }
            // Whatever failed, the next request asks the relay again.
            self.looked.lock().unwrap().remove(to.id);
            let e = match why {
                Some(why) => not_reached(anyhow!(why)),
                None => e,
            };
            return Err(match refused {
                Some(r) if e.downcast_ref::<NotReached>().is_some() => r,
                _ => e,
            });
        }
    }

    /// One relayed stream for `op` (a device that is an older version).
    async fn relayed_alone(&self, addr: &str, via: &Via<'_>, to: &Target<'_>, op: &Op) -> Result<Sent> {
        let relay = self.relay_conn(addr, via.key).await?;
        let sent = self.relayed(&relay, via.key, to, op).await;
        if sent.is_err() {
            self.looked.lock().unwrap().remove(to.id);
        }
        sent
    }

    /// The device answered `mux` as an older version does, within `OLD_KEEP`.
    fn is_old(&self, id: &str) -> bool {
        self.old.lock().unwrap().get(id).is_some_and(|at| at.elapsed() < OLD_KEEP)
    }

    fn old_now(&self, id: &str) {
        let mut old = self.old.lock().unwrap();
        old.retain(|_, at| at.elapsed() < OLD_KEEP);
        old.insert(id.to_string(), Instant::now());
    }

    /// Steps 2, 4 and 5: the LAN addresses, else through the relay: a new channel when `chan`,
    /// else one relayed stream.
    async fn reach(&self, via: &Via<'_>, to: &Target<'_>, op: &Op, chan: bool) -> Result<Reached> {
        let key_text = via.key.to_string();
        // What a relayed request learned a moment ago; it only counts for a request that can
        // go through that relay again.
        let looked = via.relay.and_then(|addr| self.looked_for(to.id, addr, &key_text));
        let dead = |a: &&String| looked.as_ref().is_some_and(|l| l.dead.contains(a));
        // The first definite refusal from a LAN address (another device, another key): the error
        // when the relay does not reach the device either.
        let mut refused = None;
        let tried: Vec<&String> = dial_order(to.lan).into_iter().take(MAX_LAN).filter(|a| !dead(a)).collect();
        if let Some(sent) = self.on_lan(via, to, &tried, op, &mut refused).await {
            return Ok(Reached::Sent(sent));
        }
        let Some(addr) = via.relay else {
            return Err(refused.unwrap_or_else(|| NotReached("offline").into()));
        };
        match self.through_relay(addr, via, to, looked, &tried, op, chan, &mut refused).await {
            Ok(Reached::Chan(c, _)) => Ok(Reached::Chan(c, refused)),
            Ok(sent) => Ok(sent),
            Err(e) => {
                // Whatever failed, the next request asks the relay again.
                self.looked.lock().unwrap().remove(to.id);
                match e.downcast_ref::<NotReached>() {
                    Some(_) => Err(refused.unwrap_or(e)),
                    None => Err(e),
                }
            }
        }
    }

    /// What is kept about `id`, when it still holds for `relay` and `key_text`.
    fn looked_for(&self, id: &str, relay: &str, key_text: &str) -> Option<Looked> {
        self.looked.lock().unwrap().get(id).filter(|l| l.holds(Instant::now(), relay, key_text)).cloned()
    }

    /// Closes every connection and channel it holds. A request in flight may still open new ones.
    pub fn close(&self) {
        for (_, l) in self.links.lock().unwrap().drain() {
            l.conn.close(0u32.into(), b"bye");
        }
        self.close_chans();
        if let Ok(mut r) = self.relay.try_lock() {
            if let Some(c) = r.take() {
                c.conn.close();
            }
        }
    }

    /// Closes the channels held (one being opened right now is left to its request).
    fn close_chans(&self) {
        for (_, slot) in self.chans.lock().unwrap().drain() {
            if let Ok(mut held) = slot.try_lock() {
                if let Some(c) = held.take() {
                    c.mux.close();
                }
            }
        }
    }

    /// Step 1: `op` on the direct connection held for the device, if any. A connection that
    /// fails is dropped (and the caller dials anew).
    async fn on_held(&self, to: &Target<'_>, key_text: &str, op: &Op) -> Option<Sent> {
        let (conn, path, fp) = {
            let mut links = self.links.lock().unwrap();
            let l = links.get(to.id)?;
            // Trusted by another key, or showing another fingerprint than the caller knows: not reused.
            let stale = l.key_text != key_text || to.known.is_some_and(|k| k != l.fp) || l.conn.close_reason().is_some();
            if stale {
                let l = links.remove(to.id)?;
                l.conn.close(0u32.into(), b"stale");
                return None;
            }
            (l.conn.clone(), l.path, l.fp)
        };
        match exchange(&conn, op).await {
            Ok((pipe, reply)) => Some(Sent { pipe, reply, path, fp }),
            Err(_) => {
                self.forget(to.id, &conn);
                None
            }
        }
    }

    /// Closes `conn` and drops it as the link held for `id`, unless another has replaced it meanwhile.
    fn forget(&self, id: &str, conn: &Connection) {
        conn.close(0u32.into(), b"request failed");
        let mut links = self.links.lock().unwrap();
        if links.get(id).is_some_and(|l| l.conn.stable_id() == conn.stable_id()) {
            links.remove(id);
        }
    }

    /// Step 2: `addrs` all at the same time, each within `DIRECT_WAIT`. The first that welcomes
    /// us is kept for the device and carries `op` as in step 1; the other dials are dropped,
    /// which closes them. A link whose request fails is dropped too. None when the device was not
    /// reached this way; when no address welcomed us, the first definite refusal (in the order
    /// of `addrs`) goes to `refused`.
    async fn on_lan(
        &self,
        via: &Via<'_>,
        to: &Target<'_>,
        addrs: &[&String],
        op: &Op,
        refused: &mut Option<anyhow::Error>,
    ) -> Option<Sent> {
        let socks = addrs.iter().filter_map(|a| a.parse::<SocketAddr>().ok());
        let dials = socks.map(|sock| async move {
            let (conn, accepted) = self.dial(sock, via.key, to).await?;
            anyhow::Ok((sock, conn, accepted))
        });
        match first_ok(dials).await {
            Ok((sock, conn, accepted)) => {
                let path = direct_path(&sock);
                let link = Link { conn: conn.clone(), path, fp: accepted.fp, key_text: via.key.to_string() };
                self.links.lock().unwrap().insert(to.id.to_string(), link);
                match exchange(&conn, op).await {
                    Ok((pipe, reply)) => Some(Sent { pipe, reply, path, fp: accepted.fp }),
                    Err(_) => {
                        self.forget(to.id, &conn);
                        None
                    }
                }
            }
            Err(errors) => {
                if refused.is_none() {
                    *refused = errors.into_iter().find(is_refusal);
                }
                None
            }
        }
    }

    /// Steps 4 and 5: ask the relay where the device is (unless `looked` still has its answer),
    /// try the LAN addresses only it knows, else a new channel (`chan`) or one relayed stream. A
    /// relayed request (or channel) that got through keeps the answer, and the addresses that were
    /// dead, for the ones that follow.
    #[allow(clippy::too_many_arguments)]
    async fn through_relay(
        &self,
        addr: &str,
        via: &Via<'_>,
        to: &Target<'_>,
        looked: Option<Looked>,
        tried: &[&String],
        op: &Op,
        chan: bool,
        refused: &mut Option<anyhow::Error>,
    ) -> Result<Reached> {
        let relay = self.relay_conn(addr, via.key).await?;
        let mut looked = match looked {
            Some(l) => l,
            None => {
                let found = tokio::time::timeout(REPLY_WAIT, relay.connect_to(to.id))
                    .await
                    .map_err(|_| anyhow!("relay unreachable: timed out"))?
                    .map_err(not_reached)?;
                Looked { at: Instant::now(), relay: addr.to_string(), key_text: via.key.to_string(), found, dead: Vec::new() }
            }
        };
        let extra: Vec<String> = dial_order(&looked.found.lan)
            .into_iter()
            .filter(|a| !tried.contains(a) && !looked.dead.contains(a))
            .take(MAX_LAN)
            .cloned()
            .collect();
        if let Some(sent) = self.on_lan(via, to, &extra.iter().collect::<Vec<_>>(), op, refused).await {
            return Ok(Reached::Sent(sent));
        }
        let sent = if chan {
            Reached::Chan(self.open_channel(&relay, addr, via.key, to).await?, None)
        } else {
            Reached::Sent(self.relayed(&relay, via.key, to, op).await?)
        };
        looked.dead.extend(tried.iter().map(|a| a.to_string()).chain(extra));
        let mut kept = self.looked.lock().unwrap();
        let now = Instant::now();
        kept.retain(|_, l| now.saturating_duration_since(l.at) < FOUND_KEEP);
        kept.insert(to.id.to_string(), looked);
        Ok(sent)
    }

    /// The connection to the relay for `addr` and `key`: the one held, or a new one when there is
    /// none, it ended or the settings changed. A relay that refused the key is not dialed again
    /// with it (it locks out a device that keeps trying).
    async fn relay_conn(&self, addr: &str, key: &Key) -> Result<RelayConn> {
        let key_text = key.to_string();
        let mut cache = self.relay.lock().await;
        if let Some(c) = cache.as_ref() {
            if c.addr == addr && c.key_text == key_text {
                if let Some(why) = c.conn.refused() {
                    bail!(why);
                }
                if !c.conn.is_closed() {
                    return Ok(c.conn.clone());
                }
            }
            c.conn.close();
            *cache = None;
        }
        let conn = RelayConn::dial(&self.ep, addr, key, &self.identity).await?;
        *cache = Some(RelayCache { addr: addr.to_string(), key_text, conn: conn.clone() });
        Ok(conn)
    }

    /// Step 5: one relayed stream: end-to-end TLS, hello and `op` in one flight, the welcome, the reply.
    async fn relayed(&self, relay: &RelayConn, key: &Key, to: &Target<'_>, op: &Op) -> Result<Sent> {
        let stream = relay.relay_to(to.id).await?;
        // The relay's refusal (`offline`, `unknown id`, ...) comes back as the failure of the first read.
        let tls = tokio::time::timeout(REPLY_WAIT, e2e_connect(stream, &self.identity));
        let (mut pipe, facts) = tls.await.map_err(|_| anyhow!("no reply"))?.map_err(|e| not_reached(relay_failure(e)))?;
        send_hello(&mut pipe, &facts, &Me { id: "", name: &self.name, key: Some(key) }).await?;
        write_json(&mut pipe, op).await?;
        let wait = async {
            let accepted = read_welcome(&mut pipe, &facts, Some(key), to.id, to.known.as_ref()).await?;
            let reply = read_json(&mut pipe).await?;
            anyhow::Ok((accepted, reply))
        };
        let (accepted, reply) = tokio::time::timeout(REPLY_WAIT, wait).await.map_err(|_| anyhow!("no reply"))??;
        Ok(Sent { pipe, reply, path: "relay", fp: accepted.fp })
    }

    /// Step 5 with a channel: a relayed stream at `FORWARD_PRIORITY`, end-to-end TLS, then the
    /// hello and `mux` in one flight, and the channel at once: what the caller sends on it goes
    /// out right behind them. The channel starts reading its frames once the welcome and the
    /// answer to `mux` are read (within `REPLY_WAIT`); a failure there closes it with the text as
    /// its reason (`unknown op` or `bad request` from an older version; `no reply` on timeout).
    async fn open_channel(&self, relay: &RelayConn, addr: &str, key: &Key, to: &Target<'_>) -> Result<Chan> {
        let stream = relay.relay_to_at(to.id, FORWARD_PRIORITY).await?;
        // The relay's refusal (`offline`, `unknown id`, ...) comes back as the failure of the first read.
        let tls = tokio::time::timeout(REPLY_WAIT, e2e_connect(stream, &self.identity));
        let (mut pipe, facts) = tls.await.map_err(|_| anyhow!("no reply"))?.map_err(|e| not_reached(relay_failure(e)))?;
        send_hello(&mut pipe, &facts, &Me { id: "", name: &self.name, key: Some(key) }).await?;
        write_json(&mut pipe, &Op::Mux).await?;
        let (mut r, w) = tokio::io::split(pipe);
        let fp = Arc::new(OnceLock::new());
        // `Key` is not `Clone`; the copy lives in the ready future only (in memory, never logged).
        let (filled, trust, id, known) = (fp.clone(), Key { relay: key.relay, root: key.root }, to.id.to_string(), to.known);
        let ready = async move {
            let wait = async {
                let accepted = read_welcome(&mut r, &facts, Some(&trust), &id, known.as_ref()).await?;
                let _ = filled.set(accepted.fp);
                let v = read_json(&mut r).await?;
                if v["ok"] != true {
                    bail!(v["error"].as_str().unwrap_or("bad reply").to_string());
                }
                anyhow::Ok(())
            };
            let done = tokio::time::timeout(REPLY_WAIT, wait).await;
            match done {
                Ok(Ok(())) => Ok(Box::new(r) as Reader),
                Ok(Err(e)) => Err(io::Error::other(relay_failure(e).to_string())),
                Err(_) => Err(io::Error::other("no reply")),
            }
        };
        let mux = Mux::client(ready, Box::new(w) as Writer);
        Ok(Chan { mux, relay: addr.to_string(), key_text: key.to_string(), fp })
    }

    /// Connects over `rapp/2` and says hello, with a `ping` in the same flight (as the hub's
    /// `Dialer::dial`); all of it within `DIRECT_WAIT`.
    async fn dial(&self, addr: SocketAddr, key: &Key, to: &Target<'_>) -> Result<(Connection, Accepted)> {
        let cfg = device_client_config(&self.identity, ALPN_DEVICE)?;
        let connecting = self.ep.connect_with(cfg, addr, SNI)?;
        let deadline = tokio::time::Instant::now() + DIRECT_WAIT;
        let conn = match tokio::time::timeout_at(deadline, connecting).await {
            Err(_) => bail!("timed out"),
            Ok(r) => r?,
        };
        let hello = tokio::time::timeout_at(deadline, self.hello(&conn, key, to)).await;
        match hello.unwrap_or_else(|_| Err(anyhow!("timed out"))) {
            Ok(accepted) => Ok((conn, accepted)),
            Err(e) => {
                conn.close(0u32.into(), b"hello failed");
                Err(e)
            }
        }
    }

    /// The hello and a `ping` on a new stream of `conn`; the caller bounds the wait.
    async fn hello(&self, conn: &Connection, key: &Key, to: &Target<'_>) -> Result<Accepted> {
        let facts = quic_facts(conn, &self.identity.fp, Role::Client)?;
        let mut pipe: Pipe = Box::new(bi(conn.open_bi().await?));
        send_hello(&mut pipe, &facts, &Me { id: "", name: &self.name, key: Some(key) }).await?;
        write_json(&mut pipe, &Op::Ping).await?;
        let accepted = read_welcome(&mut pipe, &facts, Some(key), to.id, to.known.as_ref()).await?;
        let r = read_json(&mut pipe).await?;
        if r["ok"] != true {
            bail!(r["error"].as_str().unwrap_or("bad reply").to_string());
        }
        Ok(accepted)
    }
}

impl Drop for Outbound {
    /// The relay connection's push pump holds it open: dropping it alone would leave it to the
    /// relay's idle timeout.
    fn drop(&mut self) {
        if let Some(c) = self.relay.get_mut().take() {
            c.conn.close();
        }
        for (_, l) in self.links.get_mut().unwrap().drain() {
            l.conn.close(0u32.into(), b"bye");
        }
        self.close_chans();
    }
}

/// Closes the channel whose fingerprint cell is `fp` and empties `slot`, unless another channel
/// has taken its place meanwhile.
async fn drop_chan(slot: &Slot, fp: &Arc<OnceLock<Fp>>) {
    let mut held = slot.lock().await;
    if held.as_ref().is_some_and(|c| Arc::ptr_eq(&c.fp, fp)) {
        if let Some(c) = held.take() {
            c.mux.close();
        }
    }
}

/// `op` on a new stream of the channel, and the reply; the stream stays open after it.
async fn on_mux(mux: &Mux, op: &Op) -> Result<(MuxStream, Value)> {
    let mut s = mux.open()?;
    write_json(&mut s, op).await?;
    let reply = tokio::time::timeout(REPLY_WAIT, read_json(&mut s)).await.map_err(|_| anyhow!("no reply"))??;
    Ok((s, reply))
}

/// Runs `tries` at the same time. The first that is Ok wins, and the others are dropped where
/// they are; when none is, every error, in the order of `tries`.
async fn first_ok<T, F>(tries: impl IntoIterator<Item = F>) -> Result<T, Vec<anyhow::Error>>
where
    F: Future<Output = Result<T>>,
{
    let mut running: Vec<Option<Pin<Box<F>>>> = tries.into_iter().map(|f| Some(Box::pin(f))).collect();
    let mut errors: Vec<Option<anyhow::Error>> = running.iter().map(|_| None).collect();
    std::future::poll_fn(|cx| {
        for (slot, error) in running.iter_mut().zip(errors.iter_mut()) {
            let Some(f) = slot else { continue };
            match f.as_mut().poll(cx) {
                Poll::Ready(Ok(t)) => return Poll::Ready(Ok(t)),
                Poll::Ready(Err(e)) => (*slot, *error) = (None, Some(e)),
                Poll::Pending => {}
            }
        }
        if running.iter().any(Option::is_some) {
            Poll::Pending
        } else {
            Poll::Ready(Err(errors.iter_mut().filter_map(Option::take).collect()))
        }
    })
    .await
}

/// `op` on a new stream, and the reply; the stream stays open after it.
async fn exchange(conn: &Connection, op: &Op) -> Result<(Pipe, Value)> {
    let mut s: Pipe = Box::new(bi(conn.open_bi().await?));
    write_json(&mut s, op).await?;
    let reply = tokio::time::timeout(REPLY_WAIT, read_json(&mut s)).await.map_err(|_| anyhow!("no reply"))??;
    Ok((s, reply))
}

/// A definite answer of the device (or of the known fingerprint) that retrying cannot change
/// (the hub's `is_refusal`): kept in place of `offline`. A timeout or a lost connection is not one.
fn is_refusal(e: &anyhow::Error) -> bool {
    matches!(e.to_string().as_str(), "not trusted" | "host key mismatch")
}

/// The relay's `offline` and `unknown id` as `NotReached`; any other error as it is.
fn not_reached(e: anyhow::Error) -> anyhow::Error {
    match e.to_string().as_str() {
        "offline" => NotReached("offline").into(),
        "unknown id" => NotReached("unknown id").into(),
        _ => e,
    }
}

/// The relay's failure line on a relayed stream comes as an io error whose text is the relay's.
fn relay_failure(e: anyhow::Error) -> anyhow::Error {
    match e.chain().find_map(|c| c.downcast_ref::<std::io::Error>()) {
        Some(io) => anyhow!(io.to_string()),
        None => e,
    }
}

/// `lan` for a private address, `direct` for a public one (the hub's `direct_path`).
fn direct_path(addr: &SocketAddr) -> &'static str {
    if is_private(addr.ip()) {
        "lan"
    } else {
        "direct"
    }
}

/// The addresses to try, in order (the hub's `dial_order`): loopback, which on this device is its
/// own service, is skipped when a real address is listed; a list of loopback only is used as is.
fn dial_order(lan: &[String]) -> Vec<&String> {
    let loopback = |a: &String| a.parse::<SocketAddr>().map(|a| a.ip().is_loopback()).unwrap_or(false);
    if lan.iter().any(|a| !loopback(a)) {
        lan.iter().filter(|a| !loopback(a)).collect()
    } else {
        lan.iter().collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{hello_server, Paired};
    use rapp_net::line::ok;
    use rapp_wire::tls::device_server_config;
    use serde_json::json;
    use tokio::io::AsyncWriteExt;

    const A_ID: &str = "123456789";

    /// What the fake device does with a connection.
    #[derive(Clone, Copy)]
    enum Fake {
        /// Welcomes the hello and answers its `ping`, then closes the connection on the next stream.
        FailsAfterHello,
        /// Takes the hello stream and closes the connection without a word.
        Silent,
    }

    /// A `rapp/2` device on `127.0.0.1` trusting `key`, behaving as `how`; its address.
    fn fake_device(key: Key, how: Fake) -> (SocketAddr, quinn::Endpoint, tempfile::TempDir) {
        let home = tempfile::tempdir().unwrap();
        let id = Identity::generate().unwrap();
        let cfg = device_server_config(&id, &[ALPN_DEVICE]).unwrap();
        let ep = quinn::Endpoint::server(cfg, "127.0.0.1:0".parse().unwrap()).unwrap();
        let (addr, server, paired) = (ep.local_addr().unwrap(), ep.clone(), Paired::empty(home.path()));
        tokio::spawn(async move {
            while let Some(incoming) = server.accept().await {
                let Ok(conn) = incoming.await else { continue };
                let Ok(pair) = conn.accept_bi().await else { continue };
                let mut pipe: Pipe = Box::new(bi(pair));
                if let Fake::FailsAfterHello = how {
                    let facts = quic_facts(&conn, &id.fp, Role::Server).unwrap();
                    let me = Me { id: A_ID, name: "fake-a", key: Some(&key) };
                    hello_server(&mut pipe, &facts, &me, &paired).await.unwrap();
                    assert_eq!(read_json(&mut pipe).await.unwrap()["op"], "ping");
                    write_json(&mut pipe, &ok(json!({}))).await.unwrap();
                    pipe.shutdown().await.unwrap();
                    let _ = conn.accept_bi().await;
                }
                conn.close(0u32.into(), b"fake");
            }
        });
        (addr, ep, home)
    }

    fn outbound() -> Outbound {
        let ep = rapp_net::quic::client_endpoint("127.0.0.1:0".parse().unwrap()).unwrap();
        Outbound::new(ep, Arc::new(Identity::generate().unwrap()), "test-b".into())
    }

    fn not_reached(r: Result<Sent>) -> Option<&'static str> {
        r.err().and_then(|e| e.downcast_ref::<NotReached>().map(|n| n.0))
    }

    #[tokio::test]
    async fn a_lan_link_whose_request_fails_is_dropped_and_the_request_goes_on() {
        let key = Key::new_local();
        let (addr, _ep, _home) = fake_device(key_copy(&key), Fake::FailsAfterHello);
        let out = outbound();
        let lan = [addr.to_string()];
        let to = Target { id: A_ID, lan: &lan, known: None };
        let r = out.request(&Via { relay: None, key: &key }, &to, &Op::Ping).await;
        assert_eq!(not_reached(r), Some("offline"));
        assert!(out.links.lock().unwrap().is_empty(), "the dead link is still held");
    }

    #[tokio::test]
    async fn a_lan_failure_that_is_not_a_refusal_is_offline() {
        let key = Key::new_local();
        let (addr, _ep, _home) = fake_device(key_copy(&key), Fake::Silent);
        let out = outbound();
        let lan = [addr.to_string()];
        let to = Target { id: A_ID, lan: &lan, known: None };
        let r = out.request(&Via { relay: None, key: &key }, &to, &Op::Ping).await;
        assert_eq!(not_reached(r), Some("offline"));
        assert!(out.links.lock().unwrap().is_empty());
    }

    #[tokio::test]
    async fn first_ok_takes_the_first_success_and_else_every_error_in_order() {
        let after = |ms: u64, r: Result<u8, &'static str>| async move {
            tokio::time::sleep(Duration::from_millis(ms)).await;
            r.map_err(|e| anyhow!(e))
        };
        // the quickest success wins, wherever it stands; a failure before it does not end the wait
        let began = std::time::Instant::now();
        assert_eq!(first_ok([after(5_000, Ok(1)), after(1, Err("a")), after(50, Ok(3))]).await.unwrap(), 3);
        assert!(began.elapsed() < Duration::from_secs(2), "it waited for the slow one");
        let errors = first_ok([after(30, Err("a")), after(1, Err("b"))]).await.unwrap_err();
        assert_eq!(errors.iter().map(|e| e.to_string()).collect::<Vec<_>>(), ["a", "b"]);
        assert!(first_ok::<u8, std::future::Ready<Result<u8>>>([]).await.unwrap_err().is_empty());
    }

    /// Addresses that take packets and never answer, with the sockets that keep them so.
    fn silent(n: usize) -> (Vec<std::net::UdpSocket>, Vec<String>) {
        let socks: Vec<_> = (0..n).map(|_| std::net::UdpSocket::bind("127.0.0.1:0").unwrap()).collect();
        let addrs = socks.iter().map(|s| s.local_addr().unwrap().to_string()).collect();
        (socks, addrs)
    }

    /// A `rapp/2` device on `127.0.0.1` trusting `key` that welcomes every connection and answers
    /// each request on it with ok; `ended` gets a word whenever one of its connections has ended.
    fn welcoming_device(
        key: Key,
        ended: tokio::sync::mpsc::UnboundedSender<()>,
    ) -> (SocketAddr, quinn::Endpoint, tempfile::TempDir) {
        let home = tempfile::tempdir().unwrap();
        let id = Arc::new(Identity::generate().unwrap());
        let cfg = device_server_config(&id, &[ALPN_DEVICE]).unwrap();
        let ep = quinn::Endpoint::server(cfg, "127.0.0.1:0".parse().unwrap()).unwrap();
        let (addr, server) = (ep.local_addr().unwrap(), ep.clone());
        let (key, paired) = (Arc::new(key), Arc::new(Paired::empty(home.path())));
        tokio::spawn(async move {
            while let Some(incoming) = server.accept().await {
                let (id, key, paired, ended) = (id.clone(), key.clone(), paired.clone(), ended.clone());
                tokio::spawn(async move {
                    if let Ok(conn) = incoming.await {
                        let mut welcomed = false;
                        while let Ok(pair) = conn.accept_bi().await {
                            let mut pipe: Pipe = Box::new(bi(pair));
                            if !welcomed {
                                let facts = quic_facts(&conn, &id.fp, Role::Server).unwrap();
                                let me = Me { id: A_ID, name: "fake-a", key: Some(&key) };
                                if hello_server(&mut pipe, &facts, &me, &paired).await.is_err() {
                                    break;
                                }
                                welcomed = true;
                            }
                            if read_json(&mut pipe).await.is_err() {
                                break;
                            }
                            let _ = write_json(&mut pipe, &ok(json!({}))).await;
                            let _ = pipe.shutdown().await;
                        }
                    }
                    let _ = ended.send(());
                });
            }
        });
        (addr, ep, home)
    }

    #[tokio::test]
    async fn the_dials_that_did_not_win_are_closed() {
        let key = Key::new_local();
        let (ended_tx, mut ended) = tokio::sync::mpsc::unbounded_channel();
        let (one, _ep1, _home1) = welcoming_device(key_copy(&key), ended_tx.clone());
        let (two, _ep2, _home2) = welcoming_device(key_copy(&key), ended_tx);
        let out = outbound();
        let lan = [one.to_string(), two.to_string()];
        let to = Target { id: A_ID, lan: &lan, known: None };
        let sent = out.request(&Via { relay: None, key: &key }, &to, &Op::Ping).await.unwrap();
        assert_eq!((&sent.reply["ok"], sent.path), (&json!(true), "lan"), "{}", sent.reply);
        // The connection to the other address ends now, not at its idle timeout; the one that won is kept.
        tokio::time::timeout(Duration::from_secs(2), ended.recv()).await.expect("the other dial was not closed").unwrap();
        assert!(tokio::time::timeout(Duration::from_millis(300), ended.recv()).await.is_err(), "the link that won was closed too");
        assert_eq!(out.links.lock().unwrap().len(), 1);
        // and the next request goes on the link that is held
        let again = out.request(&Via { relay: None, key: &key }, &to, &Op::Ping).await.unwrap();
        assert_eq!((&again.reply["ok"], again.path), (&json!(true), "lan"));
    }

    #[tokio::test]
    async fn dead_lan_addresses_are_dialed_together() {
        let key = Key::new_local();
        let out = outbound();
        let (_socks, lan) = silent(3);
        let to = Target { id: A_ID, lan: &lan, known: None };
        let began = std::time::Instant::now();
        let r = out.request(&Via { relay: None, key: &key }, &to, &Op::Ping).await;
        let took = began.elapsed();
        assert_eq!(not_reached(r), Some("offline"));
        assert!(took >= DIRECT_WAIT && took < DIRECT_WAIT * 2, "{took:?}");
    }

    // A device that takes the connection and then says nothing costs `DIRECT_WAIT` too, not `REPLY_WAIT`.
    #[tokio::test]
    async fn a_device_that_never_welcomes_is_given_up_within_the_direct_wait() {
        let key = Key::new_local();
        let id = Identity::generate().unwrap();
        let cfg = device_server_config(&id, &[ALPN_DEVICE]).unwrap();
        let ep = quinn::Endpoint::server(cfg, "127.0.0.1:0".parse().unwrap()).unwrap();
        let (addr, server) = (ep.local_addr().unwrap(), ep.clone());
        tokio::spawn(async move {
            let mut held = Vec::new();
            while let Some(incoming) = server.accept().await {
                held.extend(incoming.await);
            }
        });
        let out = outbound();
        let lan = [addr.to_string()];
        let to = Target { id: A_ID, lan: &lan, known: None };
        let began = std::time::Instant::now();
        let r = out.request(&Via { relay: None, key: &key }, &to, &Op::Ping).await;
        let took = began.elapsed();
        assert_eq!(not_reached(r), Some("offline"));
        assert!(took >= DIRECT_WAIT && took < DIRECT_WAIT * 2, "{took:?}");
    }

    #[test]
    fn what_the_relay_said_holds_for_a_while_and_for_the_same_relay_and_key() {
        let at = Instant::now();
        let found = Found { lan: vec![], public: String::new() };
        let l = Looked { at, relay: "relay:1".into(), key_text: "k".into(), found, dead: vec![] };
        assert!(l.holds(at, "relay:1", "k"));
        assert!(l.holds(at + FOUND_KEEP - Duration::from_millis(1), "relay:1", "k"));
        assert!(!l.holds(at + FOUND_KEEP, "relay:1", "k"));
        assert!(!l.holds(at, "relay:2", "k"));
        assert!(!l.holds(at, "relay:1", "another"));
        assert_eq!(FOUND_KEEP, Duration::from_secs(30));
    }

    #[test]
    fn only_definite_answers_are_refusals() {
        for e in ["not trusted", "host key mismatch"] {
            assert!(is_refusal(&anyhow!(e)), "{e}");
        }
        for e in ["no reply", "timed out", "connection lost", "bad reply"] {
            assert!(!is_refusal(&anyhow!(e)), "{e}");
        }
    }

    /// `Key` is not `Clone` (on purpose); a copy for the fake device.
    fn key_copy(k: &Key) -> Key {
        Key { relay: k.relay, root: k.root }
    }
}
