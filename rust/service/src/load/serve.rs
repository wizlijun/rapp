//! `load` and `watch_load` (device-load spec §10): this device's load as a reply, or as a stream that follows the
//! sampler. Asked by other devices (`peer.rs`) and on the local IPC (`ipc.rs`). Polled, like `ping`: never logged
//! on success.

use super::Load;
use crate::state::State;
use anyhow::Result;
use rapp_net::line::{err, write_json};
use serde_json::{Map, Value};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};

/// Whether this device's text terminals can be used now (`snapshot.term`). Asked on every reply and every line, so
/// it never logs: a broken `term.json` would otherwise add a warning per watcher every sample.
fn term(state: &State) -> bool {
    crate::term::usable(state)
}

/// Whether the sampler has given anything yet.
fn has_data(load: &Load) -> bool {
    !load.hist.lock().unwrap().point_json().is_null()
}

/// `{"ok":true, ..snapshot}` with `"history":[..]` when asked; `no data` before the first sample, `unknown op`
/// when sampling is off. `top` is accepted, but no sampler gives one in this version, so it is never in the reply.
pub fn reply(state: &State, history: bool, _top: bool) -> Value {
    let Some(load) = &state.load else { return err("unknown op") };
    let term = term(state);
    if !has_data(load) {
        return err("no data");
    }
    let hist = load.hist.lock().unwrap();
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
/// is ignored). Before the first sample it waits for one, so a watch opened as the service starts gets data, not
/// `no data`; the other side closing meanwhile still ends it. A first line that is an error ends the stream.
pub async fn follow<S: AsyncRead + AsyncWrite + Unpin>(state: &State, s: &mut S) -> Result<()> {
    let Some(load) = &state.load else {
        write_json(s, &err("unknown op")).await?;
        s.shutdown().await?;
        return Ok(());
    };
    // Subscribed before the first line is made, so no sample falls between the two.
    let mut tick = load.tick.subscribe();
    tick.mark_unchanged();
    let mut buf = [0u8; 256];
    while !has_data(load) {
        tokio::select! {
            n = s.read(&mut buf) => if !matches!(n, Ok(1..)) {
                let _ = s.shutdown().await;
                return Ok(());
            },
            changed = tick.changed() => if changed.is_err() {
                let _ = s.shutdown().await;
                return Ok(());
            }
        }
    }
    let first = reply(state, true, false);
    write_json(s, &first).await?;
    if first["ok"] != true {
        s.shutdown().await?;
        return Ok(());
    }
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
