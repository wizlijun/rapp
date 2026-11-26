//! Session labels (spec `2026-11-26-rapp-session-labels-design.md` §4.4): each online device has one `watch_labels`
//! stream alongside its terminal watch, every line of it a `labels` event (the device's whole table); `set_label` and
//! `reset_label` are asked of the device. A device that predates labels gets one `labels` event with `unsupported`.

use crate::hosts::Host;
use crate::link::QUIET;
use crate::terms::{after_end, Next};
use crate::Hub;
use anyhow::{Context, Result};
use rapp_net::line::{check, read_json};
use rapp_net::msg::Op;
use serde_json::{json, Value};
use std::sync::Arc;
use std::time::Duration;

/// `set_label {id, app, title, note}` → `label_set`; `reset_label {id, app}` → `label_reset`.
pub(crate) async fn command(hub: &Arc<Hub>, cmd: &str, v: &Value) -> Result<Value> {
    let id = v.get("id").and_then(Value::as_str).context("missing id")?;
    let host = hub.host(id)?;
    let mut op = v.clone();
    op["op"] = json!(cmd);
    let op: Op = serde_json::from_value(op).with_context(|| format!("bad {cmd}"))?;
    let (_, r, _) = hub.request(&host, &op).await?;
    Ok(event(&op, id, &r))
}

fn event(op: &Op, id: &str, r: &Value) -> Value {
    match op {
        Op::SetLabel { app, .. } => json!({"event":"label_set","id":id,"app":app,"rev":r["rev"]}),
        Op::ResetLabel { app } => json!({"event":"label_reset","id":id,"app":app,"rev":r["rev"]}),
        _ => json!({}),
    }
}

/// Starts `host`'s labels watch if one is due.
pub(crate) fn ensure_watch(hub: &Arc<Hub>, host: &Host) {
    hub.labels.ensure(&host.id, |delay| tokio::spawn(watch(hub.clone(), host.clone(), delay)));
}

pub(crate) fn stop_watch(hub: &Hub, id: &str) {
    hub.labels.stop(id);
}

pub(crate) fn stop_gone(hub: &Hub, hosts: &[Host]) {
    hub.labels.retain(hosts);
}

/// What the GUI hears when the watch on `id` ended with `error`.
fn ended_event(id: &str, next: &Next, error: &str) -> Value {
    match next {
        Next::Unsupported => json!({"event":"labels","id":id,"unsupported":true}),
        _ => json!({"event":"labels","id":id,"error":error}),
    }
}

/// One watch: each table it brings is a `labels` event. Quiet, as the terminal watch is.
async fn watch(hub: Arc<Hub>, host: Host, delay: Option<Duration>) {
    let id = host.id.as_str();
    let mut listed = false;
    let Err(e) = QUIET.scope(true, follow(&hub, &host, &mut listed)).await;
    if hub.hosts.get(id).is_none() {
        return;
    }
    let error = format!("{e:#}");
    // Labels are never off: an `off` answer would be an odd device, retried like any failure.
    let next = match after_end(&error) {
        Next::Unsupported => Next::Unsupported,
        _ => Next::Retry,
    };
    let event = ended_event(id, &next, &error);
    hub.labels.ended(id, next, delay.filter(|_| !listed));
    hub.emit(event, &None).await;
}

async fn follow(hub: &Hub, host: &Host, listed: &mut bool) -> Result<std::convert::Infallible> {
    let (mut s, mut r, _) = hub.request(host, &Op::WatchLabels).await?;
    loop {
        *listed = true;
        hub.emit(json!({"event":"labels","id":host.id,"rev":r["rev"],"labels":r["labels"]}), &None).await;
        r = check(read_json(&mut s).await?)?;
    }
}

#[cfg(test)]
mod tests {
    use super::{ended_event, event, Next};
    use rapp_net::msg::Op;
    use serde_json::json;

    #[test]
    fn label_commands_are_answered_with_their_events() {
        let op = Op::SetLabel { app: "term:pty:k".into(), title: "t".into(), note: String::new() };
        assert_eq!(event(&op, "d1", &json!({"ok":true,"rev":3})), json!({"event":"label_set","id":"d1","app":"term:pty:k","rev":3}));
        let op = Op::ResetLabel { app: "a".into() };
        assert_eq!(event(&op, "d1", &json!({"ok":true,"rev":4})), json!({"event":"label_reset","id":"d1","app":"a","rev":4}));
    }

    #[test]
    fn an_old_device_is_said_to_be_unsupported() {
        assert_eq!(ended_event("d1", &Next::Unsupported, "unknown op"), json!({"event":"labels","id":"d1","unsupported":true}));
        assert_eq!(ended_event("d1", &Next::Retry, "timed out"), json!({"event":"labels","id":"d1","error":"timed out"}));
    }
}
