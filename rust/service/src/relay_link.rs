//! The service's standing connection to the relay: registers this device's ID there, answers the
//! relay's pushes, and serves the streams other devices relay to it. Restarts when the settings
//! change and reconnects with a growing pause when the relay cannot be reached.

use crate::peer::{greet, serve_request};
use crate::state::{Peer, State};
use rand::Rng;
use rapp_conn::relay::{is_key_changed, Pushed, RelayConn, CLOSE_KEY_CHANGED};
use rapp_conn::{e2e_accept, Pipe};
use rapp_net::log::Lvl;
use rapp_wire::{join_hash, Key};
use serde_json::json;
use std::sync::Arc;
use std::time::Duration;
use tokio::io::AsyncWriteExt;
use tokio::task::JoinHandle;

const BACKOFF_START: Duration = Duration::from_secs(1);
const BACKOFF_MAX: Duration = Duration::from_secs(60);
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
    /// The relay is restarting: come back after this many ms (plus a little).
    GoingAway(u64),
    /// Could not connect or register, or the relay closed the connection.
    Failed { err: String, registered: bool },
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
            End::GoingAway(ms) => {
                last_err = None;
                Duration::from_millis(ms.saturating_add(rand::rng().random_range(0..=1000)))
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
    let refused = |e: &anyhow::Error| if is_key_changed(e) { End::KeyChanged } else { failed(e, false) };
    let conn = match RelayConn::dial(&state.endpoint, addr, key, &state.identity).await {
        Ok(c) => slot.insert(c),
        Err(e) => return refused(&e),
    };
    if let Err(e) = conn.register(id, lan).await {
        return refused(&e);
    }
    *changed_from = None;
    state.set_relay_status("connected", None);
    loop {
        match conn.next_push().await {
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
            Ok(Pushed::Closed { reason, .. }) => {
                let err = if reason.is_empty() { "relay closed the connection".to_string() } else { reason };
                return failed(&err, true);
            }
            Err(e) => return failed(&e, true),
        }
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

/// The next wait after a failed attempt: doubled, at most [`BACKOFF_MAX`] (spec §9.3).
fn grow(backoff: Duration) -> Duration {
    (backoff * 2).min(BACKOFF_MAX)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn backoff_doubles_up_to_a_minute() {
        let mut b = BACKOFF_START;
        let mut seen = vec![b.as_secs()];
        for _ in 0..7 {
            b = grow(b);
            seen.push(b.as_secs());
        }
        assert_eq!(seen, [1, 2, 4, 8, 16, 32, 60, 60]);
    }
}
