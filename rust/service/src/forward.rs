//! Port sharing, the sharing side (port-sharing spec §5.1): the one authorization checkpoint,
//! the live forwards, and serving `list_shares` and `forward`.

use crate::forward_log::Mode;
use crate::shares::Share;
use crate::state::{Peer, State};
use anyhow::Result;
use rapp_conn::Pipe;
use rapp_net::line::{err, ok, write_json};
use rapp_net::quic::{splice_metered, Meter};
use rapp_wire::Fp;
use serde_json::{json, Value};
use std::collections::HashMap;
use std::net::{Ipv4Addr, Ipv6Addr, SocketAddr};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tokio::io::AsyncWriteExt;
use tokio::net::TcpStream;
use tokio::sync::broadcast;

/// Forwarded connections one visiting device may have open at the same time.
pub const MAX_PER_PEER: usize = 256;
/// How long each local address (`127.0.0.1`, then `[::1]`) gets to accept.
pub const LOCAL_CONNECT_WAIT: Duration = Duration::from_secs(3);
/// The visiting device has `MAX_PER_PEER` forwards open already.
const LIMIT: &str = "limit";
/// Nothing on this device accepted a connection on the port.
const REFUSED: &str = "refused";

/// Why a request is refused; `as_str` is what the visiting device is told.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Deny {
    NotSupported,
    HostOnly,
    Policy,
    NotShared,
    NotAllowed,
}

impl Deny {
    pub fn as_str(self) -> &'static str {
        match self {
            Deny::NotSupported => "not supported",
            Deny::HostOnly => "host only",
            Deny::Policy => "policy",
            Deny::NotShared => "not shared",
            Deny::NotAllowed => "not allowed",
        }
    }
}

/// Who is asking.
pub struct Caller<'a> {
    /// Some on a key-trusted connection.
    pub fp: Option<&'a Fp>,
    /// The caller is a server device (always false until step 3).
    pub server: bool,
}

/// Steps 1–3 of the checkpoint, the ones that do not depend on the port. Ok is the caller's fingerprint.
pub(crate) fn admit<'a>(caller: &Caller<'a>, policy_allows: bool) -> Result<&'a Fp, Deny> {
    let fp = caller.fp.ok_or(Deny::NotSupported)?;
    if caller.server {
        return Err(Deny::HostOnly);
    }
    if !policy_allows {
        return Err(Deny::Policy);
    }
    Ok(fp)
}

/// The one place that decides. The order is spec §5.1's. Ok is the admitted caller's fingerprint.
pub fn authorize(caller: &Caller<'_>, policy_allows: bool, share: Option<&Share>) -> Result<Fp, Deny> {
    let fp = admit(caller, policy_allows)?;
    let share = share.ok_or(Deny::NotShared)?;
    if share.allow.is_empty() || share.allow.contains(fp) {
        Ok(*fp)
    } else {
        Err(Deny::NotAllowed)
    }
}

/// The shares of `shares` the caller may use, in their order: the ones `authorize` allows. Err
/// when the checkpoint refuses the caller whatever the port.
fn offered<'s>(caller: &Caller<'_>, policy_allows: bool, shares: &'s [Share]) -> Result<Vec<&'s Share>, Deny> {
    admit(caller, policy_allows)?;
    Ok(shares.iter().filter(|s| authorize(caller, policy_allows, Some(s)).is_ok()).collect())
}

/// Live forwards: the count per visiting device, and the way to cut a port's connections.
pub struct Forwards {
    live: Mutex<HashMap<Fp, usize>>,
    cut: broadcast::Sender<u16>,
}

/// One forward's slot in its device's count; given back when dropped.
pub struct ForwardGuard<'a> {
    forwards: &'a Forwards,
    fp: Fp,
}

impl Drop for ForwardGuard<'_> {
    fn drop(&mut self) {
        let mut live = self.forwards.live.lock().unwrap();
        if let Some(n) = live.get_mut(&self.fp) {
            *n -= 1;
            if *n == 0 {
                live.remove(&self.fp);
            }
        }
    }
}

impl Forwards {
    pub fn new() -> Forwards {
        Forwards { live: Mutex::default(), cut: broadcast::channel(64).0 }
    }

    /// None at MAX_PER_PEER. The guard gives the slot back when dropped.
    pub fn enter(&self, fp: &Fp) -> Option<ForwardGuard<'_>> {
        let mut live = self.live.lock().unwrap();
        let n = live.entry(*fp).or_insert(0);
        if *n >= MAX_PER_PEER {
            return None;
        }
        *n += 1;
        Some(ForwardGuard { forwards: self, fp: *fp })
    }

    /// Ends every forward of `port` that is running now.
    pub fn cut(&self, port: u16) {
        // No receiver: nothing is running.
        let _ = self.cut.send(port);
    }

    pub fn cuts(&self) -> broadcast::Receiver<u16> {
        self.cut.subscribe()
    }
}

/// `{"ok":true,"shares":[{"port","note"?}]}`: the shares this device may use, sorted by port.
pub async fn serve_list(state: &Arc<State>, mut s: Pipe, peer: Peer) -> Result<()> {
    let caller = Caller { fp: peer.fp.as_ref(), server: false };
    let reply = match offered(&caller, true, &state.shares.list()) {
        Ok(shares) => ok(json!({"shares": shares.into_iter().map(listed).collect::<Vec<Value>>()})),
        Err(d) => {
            state.forward_log.refused(&peer, None, d.as_str());
            err(d.as_str())
        }
    };
    reply_and_finish(&mut s, &reply).await
}

/// What `list_shares` tells about one share: its port, and its note when there is one.
fn listed(share: &Share) -> Value {
    let mut v = json!({"port": share.port});
    if !share.note.is_empty() {
        v["note"] = json!(share.note);
    }
    v
}

/// Connects the stream to this device's own `port`, once the checkpoint allows it.
pub async fn serve_forward(state: &Arc<State>, mut s: Pipe, port: u16, peer: Peer) -> Result<()> {
    // Before the checkpoint, so a cut that comes after it is not missed.
    let mut cuts = state.forwards.cuts();
    let caller = Caller { fp: peer.fp.as_ref(), server: false };
    let fp = match authorize(&caller, true, state.shares.get(port).as_ref()) {
        Ok(fp) => fp,
        Err(d) => return refuse(state, s, &peer, port, d.as_str()).await,
    };
    let Some(_slot) = state.forwards.enter(&fp) else {
        return refuse(state, s, &peer, port, LIMIT).await;
    };
    let Some(mut tcp) = connect_local(&local_addrs(port), LOCAL_CONNECT_WAIT).await else {
        return refuse(state, s, &peer, port, REFUSED).await;
    };
    let _ = tcp.set_nodelay(true);
    let mode = Mode::parse(state.cfg.lock().unwrap().forward_log.as_deref());
    // Before the reply: the record of an access must not wait for the connection to end.
    state.forward_log.opened(mode, &peer, port);
    let (meter, began) = (Meter::default(), Instant::now());
    if write_json(&mut s, &ok(json!({}))).await.is_ok() {
        tokio::select! {
            // However it ends (closed, reset), the line below records what moved.
            _ = splice_metered(&mut s, &mut tcp, &meter) => {}
            _ = cut_of(&mut cuts, port) => {}
        }
    }
    // The meter counts on the visitor's stream: read from it = in, written to it = out.
    let (bytes_in, bytes_out) = meter.get();
    state.forward_log.done(mode, &peer, port, began.elapsed().as_secs_f64(), bytes_in, bytes_out);
    Ok(())
}

async fn refuse(state: &State, mut s: Pipe, peer: &Peer, port: u16, why: &str) -> Result<()> {
    state.forward_log.refused(peer, Some(port), why);
    reply_and_finish(&mut s, &err(why)).await
}

async fn reply_and_finish(s: &mut Pipe, v: &Value) -> Result<()> {
    write_json(s, v).await?;
    s.shutdown().await?;
    Ok(())
}

/// Resolves when `port` is cut. A receiver that fell behind cannot tell which ports it missed,
/// so it ends the forward too: a cut must never be lost.
async fn cut_of(cuts: &mut broadcast::Receiver<u16>, port: u16) {
    loop {
        match cuts.recv().await {
            Ok(p) if p != port => continue,
            Ok(_) | Err(broadcast::error::RecvError::Lagged(_)) => return,
            // The sender lives as long as the state: no more cuts can come.
            Err(broadcast::error::RecvError::Closed) => std::future::pending::<()>().await,
        }
    }
}

/// The only addresses a forward may reach: this device's own loopback, IPv4 first.
pub(crate) fn local_addrs(port: u16) -> [SocketAddr; 2] {
    [SocketAddr::from((Ipv4Addr::LOCALHOST, port)), SocketAddr::from((Ipv6Addr::LOCALHOST, port))]
}

/// The first of `addrs` that accepts within `wait` each.
pub(crate) async fn connect_local(addrs: &[SocketAddr], wait: Duration) -> Option<TcpStream> {
    for a in addrs {
        if let Ok(Ok(t)) = tokio::time::timeout(wait, TcpStream::connect(a)).await {
            return Some(t);
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    fn share(allow: Vec<Fp>) -> Share { Share { port: 8000, note: String::new(), allow, raw: false, open_web: false } }
    const A: Fp = Fp([1; 32]);
    const B: Fp = Fp([2; 32]);

    #[test]
    fn the_five_steps_in_order() {
        let ok = Caller { fp: Some(&A), server: false };
        let open = share(vec![]);
        // allowed: the answer is the caller's fingerprint
        assert_eq!(authorize(&ok, true, Some(&open)), Ok(A));
        // 1: not a key-trusted connection — wins over everything after it
        assert_eq!(authorize(&Caller { fp: None, server: true }, false, None), Err(Deny::NotSupported));
        // 2: a server device
        assert_eq!(authorize(&Caller { fp: Some(&A), server: true }, false, None), Err(Deny::HostOnly));
        // 3: policy
        assert_eq!(authorize(&ok, false, None), Err(Deny::Policy));
        // 4: not shared
        assert_eq!(authorize(&ok, true, None), Err(Deny::NotShared));
        // 5: shared, but not with this device
        assert_eq!(authorize(&ok, true, Some(&share(vec![B]))), Err(Deny::NotAllowed));
        assert_eq!(authorize(&ok, true, Some(&share(vec![B, A]))), Ok(A));
    }

    // The list a device gets goes through the same checkpoint as a forward.
    #[test]
    fn the_shares_offered_to_a_device_honour_allow() {
        let shares = [Share { port: 1, ..share(vec![]) }, Share { port: 2, ..share(vec![A]) }];
        let ports = |caller: &Caller<'_>| offered(caller, true, &shares).map(|v| v.iter().map(|s| s.port).collect::<Vec<_>>());
        assert_eq!(ports(&Caller { fp: Some(&A), server: false }), Ok(vec![1, 2]));
        assert_eq!(ports(&Caller { fp: Some(&B), server: false }), Ok(vec![1]));
        // a caller the checkpoint refuses whatever the port gets the refusal, not an empty list
        assert_eq!(ports(&Caller { fp: None, server: false }), Err(Deny::NotSupported));
        assert_eq!(ports(&Caller { fp: Some(&A), server: true }), Err(Deny::HostOnly));
        assert_eq!(offered(&Caller { fp: Some(&A), server: false }, false, &shares), Err(Deny::Policy));
    }

    #[test]
    fn deny_texts() {
        use Deny::*;
        assert_eq!([NotSupported, HostOnly, Policy, NotShared, NotAllowed].map(Deny::as_str),
                   ["not supported", "host only", "policy", "not shared", "not allowed"]);
    }

    #[test]
    fn the_257th_forward_of_one_device_is_refused_and_slots_come_back() {
        let f = Forwards::new();
        let held: Vec<_> = (0..256).map(|_| f.enter(&A).unwrap()).collect();
        assert!(f.enter(&A).is_none());
        assert!(f.enter(&B).is_some()); // another device has its own count
        drop(held);
        assert!(f.enter(&A).is_some());
    }

    #[test]
    fn only_the_loopback_is_reached() {
        assert_eq!(local_addrs(8000).map(|a| a.to_string()), ["127.0.0.1:8000", "[::1]:8000"]);
    }

    // The `[::1]` fallback itself, with addresses this container has (it has no IPv6 loopback).
    #[tokio::test]
    async fn the_next_address_is_tried_when_one_refuses() {
        let dead = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap().local_addr().unwrap();
        let live = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let t = connect_local(&[dead, live.local_addr().unwrap()], LOCAL_CONNECT_WAIT).await.unwrap();
        assert_eq!(t.peer_addr().unwrap(), live.local_addr().unwrap());
        assert!(connect_local(&[dead], LOCAL_CONNECT_WAIT).await.is_none());
    }

    #[tokio::test]
    async fn a_cut_ends_only_its_port() {
        let f = Forwards::new();
        let mut rx = f.cuts();
        f.cut(9);
        f.cut(8000);
        tokio::time::timeout(Duration::from_secs(1), cut_of(&mut rx, 8000)).await.unwrap();
        let mut rx = f.cuts();
        f.cut(9);
        assert!(tokio::time::timeout(Duration::from_millis(100), cut_of(&mut rx, 8000)).await.is_err());
    }
}
