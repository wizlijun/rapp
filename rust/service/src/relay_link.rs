//! The service's standing connection to the relay: registers this device's ID there, answers the
//! relay's pushes, and serves the streams other devices relay to it. Restarts when the settings
//! change and reconnects with a growing pause when the relay cannot be reached.
//!
//! While connected it looks every 2 s (spec 2026-11-14-rapp-network-status §5.2): a change of
//! this machine's addresses ends the connection and dials again at once; no datagram for 12 s
//! (keep-alives go every 10 s) starts probing, and three probes without an answer end it.

use crate::peer::{greet, serve_request};
use crate::state::{Peer, State};
use rand::Rng;
use rapp_conn::netq::{Stall, MISSES_DOWN};
use rapp_conn::relay::{refused_key, Pushed, RelayConn, BAD_KEY, CLOSE_BAD_KEY, CLOSE_KEY_CHANGED, KEY_CHANGED};
use rapp_conn::{e2e_accept, Pipe};
use rapp_net::log::Lvl;
use rapp_wire::{join_hash, Key};
use serde_json::json;
use std::sync::Arc;
use std::net::Ipv4Addr;
use std::time::{Duration, Instant};
use tokio::io::AsyncWriteExt;
use tokio::task::JoinHandle;

const BACKOFF_START: Duration = Duration::from_secs(1);
const BACKOFF_MAX: Duration = Duration::from_secs(10);
/// How often a standing connection is looked at, and how long a probe waits for its answer.
const GUARD_EVERY: Duration = Duration::from_secs(2);
const PROBE_WAIT: Duration = Duration::from_secs(2);
/// How long a relayed stream has to finish the TLS handshake and the hello.
const HELLO_WAIT: Duration = Duration::from_secs(10);
const REPLY_WAIT: Duration = Duration::from_secs(5);

/// `lan` are the addresses registered on the relay (None: this machine's own).
pub fn spawn(state: Arc<State>, lan: Option<Vec<String>>) -> JoinHandle<()> {
    tokio::spawn(run(state, lan))
}

/// How one connection to the relay ended.
enum End {
    /// The settings changed (or the service is stopping).
    Settings,
    /// The relay revoked this device: stay down until the settings change.
    Revoked,
    /// The relay changed its key and this one is not the new one: stay down until the settings change.
    KeyChanged,
    /// The relay does not take this key: stay down until the settings change (dialing again with
    /// it would only be locked out).
    BadKey,
    /// The relay is restarting: come back after this many ms (plus a little).
    GoingAway(u64),
    /// Could not connect or register, or the relay closed the connection.
    Failed { err: String, registered: bool },
    /// This machine's addresses changed, so the old path is likely gone: dial again at once.
    Moved,
}

async fn run(state: Arc<State>, lan: Option<Vec<String>>) {
    let mut settings = state.relay_settings.subscribe();
    let mut backoff = BACKOFF_START;
    let mut last_err: Option<String> = None;
    // The hash of the key in use when the relay first said `key changed` (never the key itself),
    // until a register succeeds: another key that gets `key changed` too is a wrong new key.
    let mut changed_from: Option<String> = None;
    loop {
        // Marks the current settings as seen before they are read: a later change wakes every wait.
        settings.borrow_and_update();
        let Some((addr, key, id)) = target(&state) else {
            state.set_relay_status("off", None);
            (backoff, last_err) = (BACKOFF_START, None);
            if settings.changed().await.is_err() {
                return;
            }
            continue;
        };
        state.set_relay_status("connecting", last_err.clone());
        let mut slot = None;
        let lan = lan.clone().unwrap_or_else(|| rapp_net::addr::lan_addrs(state.port));
        let end = tokio::select! {
            _ = settings.changed() => End::Settings,
            end = session(&state, &addr, &key, &id, &lan, &mut slot, &mut changed_from) => end,
        };
        if let Some(conn) = slot.take() {
            conn.close();
        }
        let wait = match end {
            End::Settings => {
                (backoff, last_err) = (BACKOFF_START, None);
                continue;
            }
            End::Revoked => {
                state.set_relay_status("error", Some("revoked".into()));
                (backoff, last_err) = (BACKOFF_START, None);
                if settings.changed().await.is_err() {
                    return;
                }
                continue;
            }
            End::KeyChanged => {
                state.log.event(Lvl::Warn, "relay_key_changed", json!({}));
                let hash = join_hash(&key.join());
                let err = match &changed_from {
                    Some(first) if *first != hash => "bad key",
                    _ => {
                        changed_from = Some(hash);
                        "key changed"
                    }
                };
                state.set_relay_status("error", Some(err.into()));
                (backoff, last_err) = (BACKOFF_START, None);
                if settings.changed().await.is_err() {
                    return;
                }
                continue;
            }
            End::BadKey => {
                state.log.event(Lvl::Warn, "relay_bad_key", json!({}));
                state.set_relay_status("error", Some(BAD_KEY.into()));
                (backoff, last_err) = (BACKOFF_START, None);
                if settings.changed().await.is_err() {
                    return;
                }
                continue;
            }
            End::GoingAway(ms) => {
                last_err = None;
                Duration::from_millis(ms.saturating_add(rand::rng().random_range(0..=1000)))
            }
            End::Moved => {
                state.log.event(Lvl::Info, "relay_redial", json!({"reason": "address changed"}));
                (backoff, last_err) = (BACKOFF_START, Some("address changed".into()));
                continue;
            }
            End::Failed { err, registered } => {
                if registered {
                    backoff = BACKOFF_START;
                }
                let wait = backoff.mul_f64(1.0 + rand::rng().random_range(0.0..=0.2));
                backoff = grow(backoff);
                last_err = Some(err);
                wait
            }
        };
        state.set_relay_status("connecting", last_err.clone());
        tokio::select! {
            _ = settings.changed() => (backoff, last_err) = (BACKOFF_START, None),
            _ = tokio::time::sleep(wait) => {}
        }
    }
}

/// The relay address, the key and this device's ID, when all are set.
fn target(state: &State) -> Option<(String, Key, String)> {
    let cfg = state.cfg.lock().unwrap();
    let key = cfg.key.as_deref()?.parse::<Key>().ok()?;
    Some((cfg.relay.clone()?, key, cfg.id.clone()?))
}

/// Connects, registers, then handles pushes until the connection ends. The connection is left in
/// `slot` so the caller can close it if this future is dropped. A register that succeeds clears
/// `changed_from`.
async fn session(
    state: &Arc<State>,
    addr: &str,
    key: &Key,
    id: &str,
    lan: &[String],
    slot: &mut Option<RelayConn>,
    changed_from: &mut Option<String>,
) -> End {
    let failed = |e: &dyn std::fmt::Display, registered| End::Failed { err: e.to_string(), registered };
    let refused = |e: &anyhow::Error| match refused_key(e) {
        Some(KEY_CHANGED) => End::KeyChanged,
        Some(_) => End::BadKey,
        None => failed(e, false),
    };
    let conn = match RelayConn::dial(&state.endpoint, addr, key, &state.identity).await {
        Ok(c) => slot.insert(c),
        Err(e) => return refused(&e),
    };
    if let Err(e) = conn.register(id, lan).await {
        return refused(&e);
    }
    *changed_from = None;
    state.set_relay_status("connected", None);
    let mut guard = Guard::new(local_addrs());
    let mut every = tokio::time::interval(GUARD_EVERY);
    every.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    every.tick().await;
    loop {
        let push = tokio::select! {
            p = conn.next_push() => p,
            _ = every.tick() => {
                match guard.check(Instant::now(), conn.stats().rx_datagrams, local_addrs()) {
                    Check::Fine => {}
                    Check::Moved => {
                        if conn.probe(PROBE_WAIT).await.is_err() {
                            return End::Moved;
                        }
                    }
                    Check::Probe => {
                        if guard.probed(conn.probe(PROBE_WAIT).await.is_ok()) {
                            return failed(&"relay not answering", true);
                        }
                    }
                }
                continue;
            }
        };
        match push {
            Ok(Pushed::Incoming { reply, .. }) => {
                tokio::spawn(answer(reply));
            }
            Ok(Pushed::Relayed { peer, stream }) => {
                tokio::spawn(serve_relayed(state.clone(), stream, peer));
            }
            Ok(Pushed::Revoked(fps)) => {
                state.log.event(Lvl::Info, "relay_revoked", json!({"count": fps.len()}));
            }
            Ok(Pushed::GoingAway { after_ms }) => return End::GoingAway(after_ms),
            // The first `Closed` is the end; a bad push may be followed by a second.
            Ok(Pushed::Closed { code: 2, .. }) => return End::Revoked,
            Ok(Pushed::Closed { code: CLOSE_KEY_CHANGED, .. }) => return End::KeyChanged,
            Ok(Pushed::Closed { code: CLOSE_BAD_KEY, .. }) => return End::BadKey,
            Ok(Pushed::Closed { reason, .. }) => {
                let err = if reason.is_empty() { "relay closed the connection".to_string() } else { reason };
                return failed(&err, true);
            }
            Err(e) => return failed(&e, true),
        }
    }
}

fn local_addrs() -> Vec<Ipv4Addr> {
    let mut v = rapp_net::addr::local_ipv4s();
    v.sort();
    v
}

#[derive(Debug, PartialEq)]
enum Check {
    Fine,
    /// The local addresses changed: probe once (QUIC may have moved the connection over);
    /// no answer ends it and dials again at once.
    Moved,
    /// Nothing came in for a while: probe; three misses in a row end the connection.
    Probe,
}

/// Watches a standing connection to the relay: the local addresses, and the datagrams coming in.
struct Guard {
    addrs: Vec<Ipv4Addr>,
    stall: Stall,
    misses: u32,
}

impl Guard {
    fn new(addrs: Vec<Ipv4Addr>) -> Guard {
        Guard { addrs, stall: Stall::new(), misses: 0 }
    }

    /// `rx` is the connection's count of datagrams received, `addrs` the local addresses now.
    /// A change is reported once; the new addresses are the ones compared from then on.
    fn check(&mut self, now: Instant, rx: u64, addrs: Vec<Ipv4Addr>) -> Check {
        if addrs != self.addrs {
            self.addrs = addrs;
            return Check::Moved;
        }
        if self.stall.observe(now, rx) {
            Check::Probe
        } else {
            self.misses = 0;
            Check::Fine
        }
    }

    /// A probe was answered or not. True when that was the third miss in a row.
    fn probed(&mut self, answered: bool) -> bool {
        if answered {
            self.misses = 0;
            return false;
        }
        self.misses += 1;
        self.misses >= MISSES_DOWN
    }
}

/// Another device looked this one up; hole punching is plan 2c.
async fn answer(mut reply: Pipe) {
    let _ = tokio::time::timeout(REPLY_WAIT, async {
        reply.write_all(b"{\"ok\":true}\n").await?;
        reply.flush().await
    })
    .await;
}

/// One stream a device relayed to this one: TLS, the hello, then one request.
async fn serve_relayed(state: Arc<State>, stream: Pipe, from: String) {
    let mut peer = Peer { addr: from, name: None, path: "relay", fp: None };
    let hello = async {
        let (mut pipe, facts) = e2e_accept(stream, &state.identity).await?;
        peer.fp = Some(facts.peer);
        greet(&state, &mut pipe, &facts, &mut peer).await?;
        anyhow::Ok(pipe)
    };
    let pipe = match tokio::time::timeout(HELLO_WAIT, hello).await {
        Ok(Ok(p)) => p,
        failed => {
            let reason = match failed {
                Ok(Err(e)) => format!("{e:#}"),
                _ => "timeout".to_string(),
            };
            state.log.event(Lvl::Warn, "trust", peer.fields(json!({"result": "refused", "reason": reason})));
            return;
        }
    };
    if let Err(e) = serve_request(&state, pipe, peer.clone()).await {
        state.log.msg(Lvl::Warn, format!("{}: {e:#}", peer.addr));
    }
}

/// The next wait after a failed attempt: doubled, at most [`BACKOFF_MAX`] (spec §9.3; 10 s since
/// the network-status spec §5.2).
fn grow(backoff: Duration) -> Duration {
    (backoff * 2).min(BACKOFF_MAX)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn backoff_doubles_up_to_ten_seconds() {
        let mut b = BACKOFF_START;
        let mut seen = vec![b.as_secs()];
        for _ in 0..5 {
            b = grow(b);
            seen.push(b.as_secs());
        }
        assert_eq!(seen, [1, 2, 4, 8, 10, 10]);
    }

    #[test]
    fn guard_reports_an_address_change_once() {
        let ip = |n| std::net::Ipv4Addr::new(10, 0, 0, n);
        let t = Instant::now();
        let mut g = Guard::new(vec![ip(1)]);
        assert_eq!(g.check(t + Duration::from_secs(2), 5, vec![ip(1)]), Check::Fine);
        assert_eq!(g.check(t + Duration::from_secs(4), 6, vec![ip(2)]), Check::Moved);
        assert_eq!(g.check(t + Duration::from_secs(6), 7, vec![ip(2)]), Check::Fine);
    }

    #[test]
    fn guard_probes_a_stall_and_gives_up_after_three_misses() {
        let t = Instant::now();
        let s = Duration::from_secs;
        let mut g = Guard::new(vec![]);
        assert_eq!(g.check(t, 7, vec![]), Check::Fine);
        assert_eq!(g.check(t + s(10), 7, vec![]), Check::Fine);
        assert_eq!(g.check(t + s(12), 7, vec![]), Check::Probe);
        assert!(!g.probed(false));
        // An answer clears the misses.
        assert!(!g.probed(true));
        assert!(!g.probed(false));
        assert!(!g.probed(false));
        assert!(g.probed(false));
        // Datagrams moving again: fine.
        let mut g = Guard::new(vec![]);
        g.check(t, 7, vec![]);
        assert_eq!(g.check(t + s(14), 8, vec![]), Check::Fine);
    }
}
