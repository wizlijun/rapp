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
use std::time::{Duration, Instant};
use tokio::task::JoinHandle;

/// How long a device that said terminal sessions are off is left alone before it is asked again.
const OFF_RECHECK: Duration = Duration::from_secs(10 * 60);
/// The wait after a first failed watch; it doubles with each failure in a row, up to `RETRY_MAX`.
const RETRY_FIRST: Duration = Duration::from_secs(30);
const RETRY_MAX: Duration = Duration::from_secs(10 * 60);

/// host id → its watch.
#[derive(Default)]
pub(crate) struct Watches(Mutex<HashMap<String, Watch>>);

/// A host offline or removed has no entry (`stop_watch`, `stop_gone`). `Off` and `Failed` hold back the next watch
/// until it is due (`due`), so a device is not sent a request it refuses every round; a GUI `terms` starts one at
/// once (`restart`).
enum Watch {
    /// A watch is open, or being opened.
    Running(JoinHandle<()>),
    /// Terminal sessions are off on the device: asked again after `OFF_RECHECK`.
    Off { since: Instant },
    /// The watch failed: started again from `until`.
    Failed { until: Instant, delay: Duration },
    /// The device predates `watch_terms`.
    Unsupported,
}

/// What follows a watch that ended with `error`.
#[derive(Debug, PartialEq)]
pub(crate) enum Next {
    /// Started again once its wait is over.
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

/// The state a watch leaves when it ends at `now`; `delay` is the last failure's wait, `None` if there was none
/// since a list.
fn ended(next: Next, delay: Option<Duration>, now: Instant) -> Watch {
    match next {
        Next::Off => Watch::Off { since: now },
        Next::Retry => {
            let delay = delay.map_or(RETRY_FIRST, |d| (d * 2).min(RETRY_MAX));
            Watch::Failed { until: now + delay, delay }
        }
        Next::Unsupported => Watch::Unsupported,
    }
}

/// Whether a presence round at `now` starts a watch: `Some` with the last failure's wait to carry, or `None`.
fn due(w: Option<&Watch>, now: Instant) -> Option<Option<Duration>> {
    match w {
        None => Some(None),
        Some(Watch::Running(task)) => task.is_finished().then_some(None),
        Some(Watch::Off { since }) => (now.duration_since(*since) >= OFF_RECHECK).then_some(None),
        Some(Watch::Failed { until, delay }) => (now >= *until).then_some(Some(*delay)),
        Some(Watch::Unsupported) => None,
    }
}

/// The terminal commands; `cmd` is one of `terms`, `add_term_target`, `remove_term_target`, `new_term`, whose
/// fields (other than `cmd`, `id`, `req`) are the device request's.
pub(crate) async fn command(hub: &Arc<Hub>, cmd: &str, v: &Value) -> Result<Value> {
    let id = v.get("id").and_then(Value::as_str).context("missing id")?;
    let host = hub.host(id)?;
    if cmd == "terms" {
        restart(hub, &host);
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

/// Starts `host`'s watch if one is due (`due`).
pub(crate) fn ensure_watch(hub: &Arc<Hub>, host: &Host) {
    let mut watches = hub.terms.0.lock().unwrap();
    if let Some(delay) = due(watches.get(&host.id), Instant::now()) {
        start(&mut watches, hub, host, delay);
    }
}

/// The GUI asked for `host`'s list: a watch left `Off` or `Failed` starts again now, not when due.
fn restart(hub: &Arc<Hub>, host: &Host) {
    let mut watches = hub.terms.0.lock().unwrap();
    let delay = match watches.get(&host.id) {
        Some(Watch::Off { .. }) => None,
        Some(Watch::Failed { delay, .. }) => Some(*delay),
        _ => return,
    };
    start(&mut watches, hub, host, delay);
}

fn start(watches: &mut HashMap<String, Watch>, hub: &Arc<Hub>, host: &Host, delay: Option<Duration>) {
    let task = tokio::spawn(watch(hub.clone(), host.clone(), delay));
    watches.insert(host.id.clone(), Watch::Running(task));
}

/// Forgets `id`'s watch, whatever its state: the next round that finds the host online asks again at once.
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

/// One watch: each list it brings is a `terms` event; how it ended decides what follows (`after_end`, `ended`).
/// `delay` is the last failure's wait. Quiet as the presence probe that starts it: no `route` or `reconnecting`
/// lines in hub.log.
async fn watch(hub: Arc<Hub>, host: Host, delay: Option<Duration>) {
    let id = host.id.as_str();
    let mut listed = false;
    let Err(e) = QUIET.scope(true, follow(&hub, &host, &mut listed)).await;
    if hub.hosts.get(id).is_none() {
        return; // removed meanwhile: nothing more about it
    }
    let error = format!("{e:#}");
    let next = after_end(&error);
    let event = match next {
        Next::Off => Some(json!({"event":"terms","id":id,"off":true})),
        Next::Retry => Some(json!({"event":"terms","id":id,"error":error})),
        Next::Unsupported => None,
    };
    if let Some(w) = hub.terms.0.lock().unwrap().get_mut(id) {
        *w = ended(next, delay.filter(|_| !listed), Instant::now());
    }
    if let Some(event) = event {
        hub.emit(event, &None).await;
    }
}

/// Emits every list on the watch until it ends, setting `listed` at the first; only ever returns how it ended.
async fn follow(hub: &Hub, host: &Host, listed: &mut bool) -> Result<std::convert::Infallible> {
    let (mut s, mut r, _) = hub.request(host, &Op::WatchTerms).await?;
    loop {
        *listed = true;
        hub.emit(json!({"event":"terms","id":host.id,"terms":r["terms"],"hosts":r["hosts"]}), &None).await;
        r = check(read_json(&mut s).await?)?;
    }
}

#[cfg(test)]
mod tests {
    use super::{after_end, due, ended, Next, Watch, OFF_RECHECK};
    use std::time::{Duration, Instant};

    const S: Duration = Duration::from_secs(1);

    #[test]
    fn what_a_watch_does_after_it_ends() {
        assert_eq!(after_end("terminal sessions are off"), Next::Off);
        assert_eq!(after_end("unknown op"), Next::Unsupported);
        assert_eq!(after_end("timed out"), Next::Retry);

        let t0 = Instant::now();
        assert!(matches!(ended(Next::Off, Some(60 * S), t0), Watch::Off { since } if since == t0));
        assert!(matches!(ended(Next::Unsupported, None, t0), Watch::Unsupported));
        // Each failure in a row waits twice the one before, from 30 s up to 10 min; a list resets it (`None`).
        let mut delay = None;
        let mut waits = Vec::new();
        for _ in 0..7 {
            let Watch::Failed { until, delay: d } = ended(Next::Retry, delay, t0) else { panic!("not Failed") };
            assert_eq!(until, t0 + d);
            waits.push(d.as_secs());
            delay = Some(d);
        }
        assert_eq!(waits, [30, 60, 120, 240, 480, 600, 600]);
    }

    #[test]
    fn when_a_presence_round_starts_a_watch() {
        let t0 = Instant::now();
        assert_eq!(due(None, t0), Some(None));
        assert_eq!(due(Some(&Watch::Unsupported), t0 + OFF_RECHECK * 10), None);

        let off = Watch::Off { since: t0 };
        assert_eq!(due(Some(&off), t0 + 30 * S), None);
        assert_eq!(due(Some(&off), t0 + OFF_RECHECK - S), None);
        assert_eq!(due(Some(&off), t0 + OFF_RECHECK), Some(None));

        let failed = Watch::Failed { until: t0 + 60 * S, delay: 60 * S };
        assert_eq!(due(Some(&failed), t0 + 30 * S), None);
        assert_eq!(due(Some(&failed), t0 + 60 * S), Some(Some(60 * S)));
    }

    #[tokio::test]
    async fn a_running_watch_is_due_again_only_once_it_ended() {
        let t0 = Instant::now();
        let running = Watch::Running(tokio::spawn(std::future::pending()));
        assert_eq!(due(Some(&running), t0), None);

        let done = tokio::spawn(async {});
        let deadline = Instant::now() + 5 * S;
        while !done.is_finished() {
            assert!(Instant::now() < deadline, "the task did not finish");
            tokio::task::yield_now().await;
        }
        assert_eq!(due(Some(&Watch::Running(done)), t0), Some(None));
    }
}
