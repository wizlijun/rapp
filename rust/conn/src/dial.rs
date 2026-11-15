//! Sending one request to another device: over a direct `rapp/2` connection when one is held or a
//! known LAN address answers, else through the relay (one relayed stream per request). The
//! direct connection is kept per device ID and reused; the connection to the relay is kept for
//! the settings it was dialed with.
//!
//! A smaller sibling of the hub's `link.rs` (same hello, same path rule), without its host list,
//! presence probes or LAN upgrades.

use std::collections::HashMap;
use std::net::SocketAddr;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use anyhow::{anyhow, bail, Result};
use quinn::Connection;
use rapp_net::addr::is_private;
use rapp_net::line::{read_json, write_json};
use rapp_net::msg::Op;
use rapp_net::quic::bi;
use rapp_wire::tls::{device_client_config, ALPN_DEVICE, SNI};
use rapp_wire::{Fp, Identity, Key};
use serde_json::Value;

use crate::relay::RelayConn;
use crate::{e2e_connect, quic_facts, read_welcome, send_hello, Accepted, Me, Pipe, Role};

/// How long one LAN address may take to connect.
pub const DIRECT_WAIT: Duration = Duration::from_secs(1);
/// How long the other device (or the relay) may take to answer.
pub const REPLY_WAIT: Duration = Duration::from_secs(20);
/// At most this many LAN addresses are tried, from each list.
const MAX_LAN: usize = 3;

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

pub struct Outbound {
    ep: quinn::Endpoint,
    identity: Arc<Identity>,
    name: String,
    links: Mutex<HashMap<String, Link>>,
    relay: tokio::sync::Mutex<Option<RelayCache>>,
}

impl Outbound {
    pub fn new(ep: quinn::Endpoint, identity: Arc<Identity>, name: String) -> Outbound {
        Outbound { ep, identity, name, links: Mutex::new(HashMap::new()), relay: tokio::sync::Mutex::new(None) }
    }

    /// Sends `op` on a new stream to the device and returns it with the reply.
    pub async fn request(&self, via: &Via<'_>, to: &Target<'_>, op: &Op) -> Result<Sent> {
        let key_text = via.key.to_string();
        if let Some(sent) = self.on_held(to, &key_text, op).await {
            return Ok(sent);
        }
        // The first definite refusal from a LAN address (another device, another key): the error
        // when the relay does not reach the device either.
        let mut refused = None;
        let tried: Vec<&String> = dial_order(to.lan).into_iter().take(MAX_LAN).collect();
        if let Some(sent) = self.on_lan(via, to, &tried, op, &mut refused).await {
            return Ok(sent);
        }
        let Some(addr) = via.relay else {
            return Err(refused.unwrap_or_else(|| NotReached("offline").into()));
        };
        match self.through_relay(addr, via, to, &tried, op, &mut refused).await {
            Err(e) if e.downcast_ref::<NotReached>().is_some() => Err(refused.unwrap_or(e)),
            r => r,
        }
    }

    /// Closes every connection it holds. A request in flight may still open new ones.
    pub fn close(&self) {
        for (_, l) in self.links.lock().unwrap().drain() {
            l.conn.close(0u32.into(), b"bye");
        }
        if let Ok(mut r) = self.relay.try_lock() {
            if let Some(c) = r.take() {
                c.conn.close();
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

    /// Step 2: `addrs` one after another; the first that welcomes us is kept for the device and
    /// carries `op` as in step 1 (a link whose request fails is dropped and the next address tried).
    /// None when none did; the first definite refusal goes to `refused`.
    async fn on_lan(
        &self,
        via: &Via<'_>,
        to: &Target<'_>,
        addrs: &[&String],
        op: &Op,
        refused: &mut Option<anyhow::Error>,
    ) -> Option<Sent> {
        for a in addrs {
            let Ok(sock) = a.parse::<SocketAddr>() else { continue };
            match self.dial(sock, via.key, to).await {
                Ok((conn, accepted)) => {
                    let path = direct_path(&sock);
                    let link = Link { conn: conn.clone(), path, fp: accepted.fp, key_text: via.key.to_string() };
                    self.links.lock().unwrap().insert(to.id.to_string(), link);
                    match exchange(&conn, op).await {
                        Ok((pipe, reply)) => return Some(Sent { pipe, reply, path, fp: accepted.fp }),
                        Err(_) => self.forget(to.id, &conn),
                    }
                }
                Err(e) if is_refusal(&e) && refused.is_none() => *refused = Some(e),
                Err(_) => {}
            }
        }
        None
    }

    /// Steps 4 and 5: ask the relay where the device is, try the LAN addresses only it knows,
    /// else one relayed stream.
    async fn through_relay(
        &self,
        addr: &str,
        via: &Via<'_>,
        to: &Target<'_>,
        tried: &[&String],
        op: &Op,
        refused: &mut Option<anyhow::Error>,
    ) -> Result<Sent> {
        let relay = self.relay_conn(addr, via.key).await?;
        let found = tokio::time::timeout(REPLY_WAIT, relay.connect_to(to.id))
            .await
            .map_err(|_| anyhow!("relay unreachable: timed out"))?
            .map_err(not_reached)?;
        let extra: Vec<&String> =
            dial_order(&found.lan).into_iter().filter(|a| !tried.contains(a)).take(MAX_LAN).collect();
        if let Some(sent) = self.on_lan(via, to, &extra, op, refused).await {
            return Ok(sent);
        }
        self.relayed(&relay, via.key, to, op).await
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

    /// Connects over `rapp/2` and says hello, with a `ping` in the same flight (as the hub's
    /// `Dialer::dial`).
    async fn dial(&self, addr: SocketAddr, key: &Key, to: &Target<'_>) -> Result<(Connection, Accepted)> {
        let cfg = device_client_config(&self.identity, ALPN_DEVICE)?;
        let connecting = self.ep.connect_with(cfg, addr, SNI)?;
        let conn = match tokio::time::timeout(DIRECT_WAIT, connecting).await {
            Err(_) => bail!("timed out"),
            Ok(r) => r?,
        };
        match self.hello(&conn, key, to).await {
            Ok(accepted) => Ok((conn, accepted)),
            Err(e) => {
                conn.close(0u32.into(), b"hello failed");
                Err(e)
            }
        }
    }

    async fn hello(&self, conn: &Connection, key: &Key, to: &Target<'_>) -> Result<Accepted> {
        let facts = quic_facts(conn, &self.identity.fp, Role::Client)?;
        let mut pipe: Pipe = Box::new(bi(conn.open_bi().await?));
        send_hello(&mut pipe, &facts, &Me { id: "", name: &self.name, key: Some(key) }).await?;
        write_json(&mut pipe, &Op::Ping).await?;
        let wait = async {
            let accepted = read_welcome(&mut pipe, &facts, Some(key), to.id, to.known.as_ref()).await?;
            let r = read_json(&mut pipe).await?;
            if r["ok"] != true {
                bail!(r["error"].as_str().unwrap_or("bad reply").to_string());
            }
            anyhow::Ok(accepted)
        };
        tokio::time::timeout(REPLY_WAIT, wait).await.map_err(|_| anyhow!("no reply"))?
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
    }
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
