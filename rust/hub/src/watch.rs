//! Waiting for an offline host (spec 2026-11-14-rapp-network-status §5.3 rule 3): while the GUI
//! has a session waiting for it (`{"cmd":"watch","id","on":true}`), the host is asked after every
//! 5 s, after a minute every 15 s, after five minutes every 30 s; the 30 s presence round skips it.
//! The relay's per-target limit is shared by everyone asking, so `limit` pauses 60 s, quietly.
//! While the link to the relay is down nothing is asked. The first answer pushes
//! `presence{online:true}` and ends the watch; the GUI starts another if its session fails again.

use crate::link::QUIET;
use crate::presence::online;
use crate::Hub;
use rapp_conn::netq::Level;
use rapp_net::log::Lvl;
use serde_json::json;
use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tokio::task::JoinHandle;

/// One watch task per host, with a number telling it from a later one for the same host.
#[derive(Default)]
pub(crate) struct Watches(Mutex<(u64, Tasks)>);
type Tasks = HashMap<String, (u64, JoinHandle<()>)>;

impl Watches {
    pub(crate) fn has(&self, id: &str) -> bool {
        self.0.lock().unwrap().1.contains_key(id)
    }

    fn stop(&self, id: &str) {
        if let Some((_, t)) = self.0.lock().unwrap().1.remove(id) {
            t.abort();
        }
    }

    /// The watch numbered `n` ended by itself: forgotten, unless a newer one took its place.
    fn ended(&self, id: &str, n: u64) {
        let mut w = self.0.lock().unwrap();
        if w.1.get(id).is_some_and(|(m, _)| *m == n) {
            w.1.remove(id);
        }
    }
}

/// How long until the next ask, `elapsed` into the watch, after an ask that said `limit` or not.
fn next_wait(elapsed: Duration, limited: bool) -> Duration {
    if limited {
        return Duration::from_secs(60);
    }
    Duration::from_secs(match elapsed.as_secs() {
        0..60 => 5,
        60..300 => 15,
        _ => 30,
    })
}

/// The relay said its limit was hit (for this target, or for us).
fn is_limit(e: &anyhow::Error) -> bool {
    format!("{e:#}").split(": ").any(|p| p == "limit")
}

/// `{"cmd":"watch"}`: starts (again from 5 s) or stops watching `id`.
pub(crate) fn set(hub: &Arc<Hub>, id: &str, on: bool) {
    hub.watches.stop(id);
    if !on {
        return;
    }
    let mut w = hub.watches.0.lock().unwrap();
    w.0 += 1;
    let n = w.0;
    let (h, id2) = (hub.clone(), id.to_string());
    let task = tokio::spawn(async move {
        watch(&h, &id2).await;
        h.watches.ended(&id2, n);
    });
    w.1.insert(id.to_string(), (n, task));
}

async fn watch(hub: &Arc<Hub>, id: &str) {
    let start = Instant::now();
    let mut limited = false;
    loop {
        tokio::time::sleep(next_wait(start.elapsed(), limited)).await;
        limited = false;
        if hub.net_level() == Some(Level::Down) {
            continue;
        }
        let Some(host) = hub.hosts.get(id) else { return };
        let r = QUIET.scope(true, hub.probe(&host)).await;
        if online(&r) {
            hub.log.event(Lvl::Info, "presence", json!({"id":id,"online":true,"by":"watch"}));
            crate::terms::ensure_watch(hub, &host);
            hub.emit(json!({"event":"presence","id":id,"online":true}), &None).await;
            return;
        }
        if let Err(e) = &r {
            limited = is_limit(e);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use anyhow::anyhow;

    #[test]
    fn cadence_five_then_fifteen_then_thirty() {
        let s = Duration::from_secs;
        assert_eq!(next_wait(s(0), false), s(5));
        assert_eq!(next_wait(s(59), false), s(5));
        assert_eq!(next_wait(s(60), false), s(15));
        assert_eq!(next_wait(s(299), false), s(15));
        assert_eq!(next_wait(s(300), false), s(30));
        assert_eq!(next_wait(s(10), true), s(60));
    }

    #[test]
    fn limit_is_told_apart() {
        assert!(is_limit(&anyhow!("limit")));
        assert!(is_limit(&anyhow!("limit").context("relay")));
        assert!(!is_limit(&anyhow!("offline")));
        assert!(!is_limit(&anyhow!("unknown id")));
    }
}
