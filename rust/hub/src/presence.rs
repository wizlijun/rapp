//! Presence probe: every `every`, ask each saved host `Op::Ping` and emit `presence`.
//! Nothing is logged per tick, and A does not log pings either.

use crate::Hub;
use rapp_net::msg::Op;
use serde_json::json;
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
    loop {
        tick.tick().await;
        for host in hub.hosts.all() {
            let online = online(&hub.request(&host, &Op::Ping).await);
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
