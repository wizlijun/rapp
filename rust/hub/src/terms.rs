//! Terminal sessions (spec §6): `terms`, `add_term_target`, `remove_term_target` and `new_term` are asked of the
//! device; each online device has one `watch_terms` stream, every line of it a `terms` event without `req`.
//! Opening one goes the embedded `open` path unchanged.

use crate::hosts::Host;
use crate::link::QUIET;
use crate::Hub;
use anyhow::{Context, Result};
use rapp_net::line::{check, read_json};
use rapp_net::msg::Op;
use rapp_term::config::OFF;
use serde_json::{json, Value};
use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use tokio::task::JoinHandle;

/// host id → its watch.
#[derive(Default)]
pub(crate) struct Watches(Mutex<HashMap<String, Watch>>);

enum Watch {
    Running(JoinHandle<()>),
    /// The device predates `watch_terms`: kept until the host is removed or goes offline, so an older device is
    /// not sent a request it refuses every round.
    Unsupported,
}

/// What follows a watch that ended with `error`.
#[derive(Debug, PartialEq)]
pub(crate) enum Next {
    /// Started again on the next presence round.
    Retry,
    /// Terminal sessions are off on the device.
    Off,
    Unsupported,
}

pub(crate) fn after_end(error: &str) -> Next {
    match error {
        OFF => Next::Off,
        "unknown op" => Next::Unsupported,
        _ => Next::Retry,
    }
}

/// The terminal commands; `cmd` is one of `terms`, `add_term_target`, `remove_term_target`, `new_term`, whose
/// fields (other than `cmd`, `id`, `req`) are the device request's.
pub(crate) async fn command(hub: &Arc<Hub>, cmd: &str, v: &Value) -> Result<Value> {
    let id = v.get("id").and_then(Value::as_str).context("missing id")?;
    let host = hub.host(id)?;
    if cmd == "terms" {
        return match hub.request(&host, &Op::ListTerms).await {
            Ok((_, r, path)) => Ok(json!({"event":"terms","id":id,"path":path,"terms":r["terms"],"hosts":r["hosts"]})),
            Err(e) if e.to_string() == OFF => Ok(json!({"event":"terms","id":id,"off":true})),
            Err(e) => Err(e),
        };
    }
    // The command names are the requests' own.
    let mut op = v.clone();
    op["op"] = json!(cmd);
    let op: Op = serde_json::from_value(op).with_context(|| format!("bad {cmd}"))?;
    let (_, r, _) = hub.request(&host, &op).await?;
    Ok(match op {
        Op::NewTerm { .. } => json!({"event":"term_created","id":id,"term":r["id"]}),
        _ => json!({"event":"term_targets","id":id,"targets":r["targets"]}),
    })
}

/// Starts `host`'s watch unless one is running or the device does not have it.
pub(crate) fn ensure_watch(hub: &Arc<Hub>, host: &Host) {
    let mut watches = hub.terms.0.lock().unwrap();
    match watches.get(&host.id) {
        Some(Watch::Unsupported) => return,
        Some(Watch::Running(task)) if !task.is_finished() => return,
        _ => {}
    }
    let task = tokio::spawn(watch(hub.clone(), host.clone()));
    watches.insert(host.id.clone(), Watch::Running(task));
}

pub(crate) fn stop_watch(hub: &Hub, id: &str) {
    if let Some(Watch::Running(task)) = hub.terms.0.lock().unwrap().remove(id) {
        task.abort();
    }
}

/// Stops the watches of hosts no longer in `hosts`.
pub(crate) fn stop_gone(hub: &Hub, hosts: &[Host]) {
    hub.terms.0.lock().unwrap().retain(|id, w| {
        let kept = hosts.iter().any(|h| h.id == *id);
        if let (false, Watch::Running(task)) = (kept, w) {
            task.abort();
        }
        kept
    });
}

/// One watch: each list it brings is a `terms` event; how it ended decides what follows (`after_end`).
/// Quiet as the presence probe that starts it: no `route` or `reconnecting` lines in hub.log.
async fn watch(hub: Arc<Hub>, host: Host) {
    let id = host.id.as_str();
    let Err(e) = QUIET.scope(true, follow(&hub, &host)).await;
    if hub.hosts.get(id).is_none() {
        return; // removed meanwhile: nothing more about it
    }
    let error = format!("{e:#}");
    match after_end(&error) {
        Next::Off => hub.emit(json!({"event":"terms","id":id,"off":true}), &None).await,
        Next::Retry => hub.emit(json!({"event":"terms","id":id,"error":error}), &None).await,
        Next::Unsupported => {
            if let Some(w) = hub.terms.0.lock().unwrap().get_mut(id) {
                *w = Watch::Unsupported;
            }
        }
    }
}

/// Emits every list on the watch until it ends; only ever returns how it ended.
async fn follow(hub: &Hub, host: &Host) -> Result<std::convert::Infallible> {
    let (mut s, mut r, _) = hub.request(host, &Op::WatchTerms).await?;
    loop {
        hub.emit(json!({"event":"terms","id":host.id,"terms":r["terms"],"hosts":r["hosts"]}), &None).await;
        r = check(read_json(&mut s).await?)?;
    }
}

#[cfg(test)]
mod tests {
    use super::{after_end, Next};

    #[test]
    fn what_a_watch_does_after_it_ends() {
        assert_eq!(after_end("terminal sessions are off"), Next::Off);
        assert_eq!(after_end("unknown op"), Next::Unsupported);
        assert_eq!(after_end("timed out"), Next::Retry);
    }
}
