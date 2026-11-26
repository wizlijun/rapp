//! `load` and `watch_load` (device-load spec §10): this device's load as a reply, or as a stream that follows the
//! sampler. Asked by other devices (`peer.rs`) and on the local IPC (`ipc.rs`). Polled, like `ping`: never logged
//! on success.

use crate::state::State;
use anyhow::Result;
use rapp_net::line::{err, write_json};
use serde_json::{Map, Value};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};

/// Whether this device's text terminals can be used now (`snapshot.term`).
fn term(state: &State) -> bool {
    crate::term::allowed(state).is_ok()
}

/// `{"ok":true, ..snapshot}` with `"history":[..]` when asked; `no data` before the first sample, `unknown op`
/// when sampling is off. `top` is accepted, but no sampler gives one in this version, so it is never in the reply.
pub fn reply(state: &State, history: bool, _top: bool) -> Value {
    let Some(load) = &state.load else { return err("unknown op") };
    let term = term(state);
    let hist = load.hist.lock().unwrap();
    if hist.point_json().is_null() {
        return err("no data");
    }
    let mut o = with_ok(hist.snapshot(term));
    if history {
        o.insert("history".into(), hist.history_json());
    }
    o.into()
}

/// One line after a tick: the snapshot and the newest point.
fn line(state: &State) -> Value {
    let Some(load) = &state.load else { return err("unknown op") };
    let term = term(state);
    let hist = load.hist.lock().unwrap();
    let mut o = with_ok(hist.snapshot(term));
    o.insert("point".into(), hist.point_json());
    o.into()
}

/// `{"ok":true}` first, then the snapshot's keys.
fn with_ok(snapshot: Value) -> Map<String, Value> {
    let mut o = Map::new();
    o.insert("ok".into(), true.into());
    if let Value::Object(m) = snapshot {
        o.extend(m);
    }
    o
}

/// The first line is `reply(true, false)`; then one line per sample, until the other side closes (what it writes
/// is ignored). A first line that is an error ends the stream.
pub async fn follow<S: AsyncRead + AsyncWrite + Unpin>(state: &State, s: &mut S) -> Result<()> {
    // Subscribed before the first line is made, so no sample falls between the two.
    let mut tick = state.load.as_ref().map(|l| {
        let mut rx = l.tick.subscribe();
        rx.mark_unchanged();
        rx
    });
    let first = reply(state, true, false);
    write_json(s, &first).await?;
    let Some(tick) = tick.as_mut().filter(|_| first["ok"] == true) else {
        s.shutdown().await?;
        return Ok(());
    };
    let mut buf = [0u8; 256];
    loop {
        tokio::select! {
            n = s.read(&mut buf) => if !matches!(n, Ok(1..)) {
                break;
            },
            changed = tick.changed() => {
                if changed.is_err() || write_json(s, &line(state)).await.is_err() {
                    break;
                }
            }
        }
    }
    // The other side may be gone already.
    let _ = s.shutdown().await;
    Ok(())
}
