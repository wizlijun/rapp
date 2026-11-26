//! Device load (spec 2026-11-26 §10): each online device has one `watch_load` stream, every line of it a `load`
//! event without `req`; `{"cmd":"load"}` asks one device once. The retry and Unsupported state machine is
//! `terms`'s (`after_end`, `ended`, `due`); a device that says `unknown op` is not asked again while it stays online.

use crate::hosts::Host;
use crate::link::QUIET;
use crate::terms::{after_end, due, ended, Next, Watch};
use crate::Hub;
use anyhow::{Context, Result};
use rapp_net::line::{check, read_json};
use rapp_net::msg::Op;
use serde_json::{json, Value};
use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

/// host id → its watch.
#[derive(Default)]
pub(crate) struct Watches(Mutex<HashMap<String, Watch>>);

/// `{"cmd":"load","id":..,"top"?:bool}`: the device's load once (no history).
pub(crate) async fn command(hub: &Arc<Hub>, v: &Value) -> Result<Value> {
    let id = v.get("id").and_then(Value::as_str).context("missing id")?;
    let top = v.get("top").and_then(Value::as_bool).unwrap_or(false);
    let host = hub.host(id)?;
    let (_, r, _) = hub.request(&host, &Op::Load { history: false, top }).await?;
    Ok(event(id, r))
}

/// A device's reply or stream line as a `load` event.
fn event(id: &str, mut line: Value) -> Value {
    if let Some(o) = line.as_object_mut() {
        o.remove("ok");
        o.insert("event".into(), json!("load"));
        o.insert("id".into(), json!(id));
    }
    line
}

/// Starts `host`'s watch if one is due (`due`).
pub(crate) fn ensure_watch(hub: &Arc<Hub>, host: &Host) {
    let mut watches = hub.load.0.lock().unwrap();
    if let Some(delay) = due(watches.get(&host.id), Instant::now()) {
        let task = tokio::spawn(watch(hub.clone(), host.clone(), delay));
        watches.insert(host.id.clone(), Watch::Running(task));
    }
}

/// Forgets `id`'s watch, whatever its state, and tells the GUI to drop the device's numbers (`gone`).
pub(crate) async fn stop_watch(hub: &Hub, id: &str) {
    let removed = hub.load.0.lock().unwrap().remove(id);
    if let Some(w) = removed {
        if let Watch::Running(task) = w {
            task.abort();
        }
        hub.emit(json!({"event":"load","id":id,"gone":true}), &None).await;
    }
}

/// Stops the watches of hosts no longer in `hosts`.
pub(crate) async fn stop_gone(hub: &Hub, hosts: &[Host]) {
    let gone: Vec<String> =
        hub.load.0.lock().unwrap().keys().filter(|id| !hosts.iter().any(|h| h.id == **id)).cloned().collect();
    for id in gone {
        stop_watch(hub, &id).await;
    }
}

/// One watch: each line it brings is a `load` event; how it ended decides what follows. Quiet like the presence probe.
async fn watch(hub: Arc<Hub>, host: Host, delay: Option<Duration>) {
    let id = host.id.as_str();
    let mut streamed = false;
    let Err(e) = QUIET.scope(true, follow(&hub, &host, &mut streamed)).await;
    if hub.hosts.get(id).is_none() {
        return; // removed meanwhile: nothing more about it
    }
    let error = format!("{e:#}");
    // `load` has no off switch: anything but `unknown op` is a failure to wait out.
    let (next, event) = match after_end(&error) {
        Next::Unsupported => (Next::Unsupported, json!({"event":"load","id":id,"unsupported":true})),
        _ => (Next::Retry, json!({"event":"load","id":id,"error":error})),
    };
    if let Some(w) = hub.load.0.lock().unwrap().get_mut(id) {
        *w = ended(next, delay.filter(|_| !streamed), Instant::now());
    }
    hub.emit(event, &None).await;
}

/// Emits every line on the watch until it ends, setting `streamed` at the first; only ever returns how it ended.
async fn follow(hub: &Hub, host: &Host, streamed: &mut bool) -> Result<std::convert::Infallible> {
    let (mut s, mut r, _) = hub.request(host, &Op::WatchLoad).await?;
    loop {
        *streamed = true;
        hub.emit(event(&host.id, r), &None).await;
        r = check(read_json(&mut s).await?)?;
    }
}
