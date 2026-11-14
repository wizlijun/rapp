//! Presence probe: every `every`, ask each saved host `Op::Ping` and emit `presence`.
//! Quiet by design: no `route`/`reconnecting` lines, and hub.log gets one `presence` line only when
//! a host's state changes. A host whose probe fails on auth (bad password) is left alone, shown
//! offline, until the user acts on it, so probes never pile up `auth_fail` lines on A. A host that
//! does not answer, or has no saved address, is offline, not a halt, so it is seen when it comes back.
//! A does not log pings either. A host reached through the relay is probed with the relay's `connect`
//! (online iff it answers ok), never with a relayed stream. The relay counts `unknown id` against
//! this device, so a probe asks it only about hosts it may know (`link::probe_asks_relay`), and not
//! again in this run about one it said it does not know. An offline `presence` carries the `error`
//! that says why.

use crate::link::QUIET;
use crate::terms;
use crate::Hub;
use rapp_net::log::Lvl;
use serde_json::json;
use std::collections::HashMap;
use std::sync::Arc;
use std::time::Duration;
use tokio::time::{interval, MissedTickBehavior};

/// Online = A answered, or an older A said "unknown op" (it is there, it just predates `ping`).
pub(crate) fn online<T>(r: &anyhow::Result<T>) -> bool {
    match r {
        Ok(_) => true,
        Err(e) => e.to_string() == "unknown op",
    }
}

pub(crate) async fn run(hub: Arc<Hub>, every: Duration) {
    let mut tick = interval(every);
    tick.set_missed_tick_behavior(MissedTickBehavior::Delay);
    let mut last: HashMap<String, bool> = HashMap::new();
    loop {
        tick.tick().await;
        let hosts = hub.hosts.all();
        terms::stop_gone(&hub, &hosts);
        for host in hosts {
            // A host a session waits for is asked by its watch, on its own cadence.
            if hub.probe_halt.lock().unwrap().contains(&host.id) || hub.watches.has(&host.id) {
                continue;
            }
            let r = QUIET.scope(true, hub.probe(&host)).await;
            if hub.hosts.get(&host.id).is_none() {
                last.remove(&host.id);
                continue; // removed while the probe was in flight
            }
            let online = online(&r);
            if online {
                terms::ensure_watch(&hub, &host);
            } else {
                terms::stop_watch(&hub, &host.id);
            }
            if last.insert(host.id.clone(), online) != Some(online) {
                hub.log.event(Lvl::Info, "presence", json!({"id":host.id,"online":online}));
            }
            let mut ev = json!({"event":"presence","id":host.id,"online":online});
            if let (false, Err(e)) = (online, &r) {
                ev["error"] = format!("{e:#}").into();
            }
            hub.emit(ev, &None).await;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::online;
    use anyhow::anyhow;

    #[test]
    fn unknown_op_counts_as_online() {
        assert!(online(&Ok(())));
        assert!(online::<()>(&Err(anyhow!("unknown op"))));
        assert!(!online::<()>(&Err(anyhow!("offline"))));
        assert!(!online::<()>(&Err(anyhow!("timed out"))));
    }
}
