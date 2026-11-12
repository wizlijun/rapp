//! Presence probe: every `every`, ask each saved host `Op::Ping` and emit `presence`.
//! Quiet by design: no `route`/`reconnecting` lines, and hub.log gets one `presence` line only when
//! a host's state changes. A host whose probe fails on auth (bad password, unknown id, locked) is
//! left alone, shown offline, until the user acts on it, so probes never feed the relay's limiter.
//! A host with LAN addresses that the relay calls "unknown id" (`id@ip`) is probed over LAN only
//! from then on; no answer there is offline, not a halt, so it is seen when it comes back.
//! A does not log pings either.

use crate::link::{is_auth_failure, QUIET};
use crate::Hub;
use rapp_net::log::Lvl;
use rapp_net::msg::Op;
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
        for host in hub.hosts.all() {
            if hub.probe_halt.lock().unwrap().contains(&host.id) {
                continue;
            }
            let r = QUIET.scope(true, hub.request(&host, &Op::Ping)).await;
            if hub.hosts.get(&host.id).is_none() {
                last.remove(&host.id);
                continue; // removed while the probe was in flight
            }
            if let Err(e) = &r {
                if is_auth_failure(e) {
                    hub.probe_halt.lock().unwrap().insert(host.id.clone());
                }
            }
            let online = online(&r);
            if last.insert(host.id.clone(), online) != Some(online) {
                hub.log.event(Lvl::Info, "presence", json!({"id":host.id,"online":online}));
            }
            hub.emit(json!({"event":"presence","id":host.id,"online":online}), &None).await;
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
