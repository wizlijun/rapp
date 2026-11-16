//! The share numbers of this device's shares, kept so that one number means the same share on
//! every device: a number is given out only when no other device is seen to use it.

use crate::maps;
use crate::pipe::{known_hosts, shares_of};
use crate::state::State;
use rapp_net::log::Lvl;
use serde_json::json;
use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::task::JoinSet;

/// How long the devices are given, all together, to say which numbers they use at start.
const ASK_WAIT: Duration = Duration::from_secs(5);

/// What this device knows of the numbers in use elsewhere.
pub struct Numbers {
    /// The share numbers each device (by ID) was last seen with.
    seen: Mutex<HashMap<String, Vec<u16>>>,
    /// The shares (by port) that gave their number up to another sharer, until the user has seen it.
    /// In memory only: after a restart the notice is gone, the new number stays.
    renumbered: Mutex<HashMap<u16, Renumbered>>,
}

/// A share that moved off a number it held together with another device's share.
#[derive(Clone, Debug, PartialEq)]
pub struct Renumbered {
    /// The number the share had.
    pub from: u16,
    /// The device it clashed with, as this device names it.
    pub with: String,
}

impl Numbers {
    pub fn new() -> Numbers {
        Numbers { seen: Mutex::new(HashMap::new()), renumbered: Mutex::new(HashMap::new()) }
    }

    /// Replaces the numbers the device `id` is seen with: a share it dropped frees its number.
    pub fn set_seen(&self, id: &str, numbers: Vec<u16>) {
        self.seen.lock().unwrap().insert(id.to_string(), numbers);
    }

    /// Remembers that the share of `port` moved off `r.from`, so the panel can say why.
    pub fn set_renumbered(&self, port: u16, r: Renumbered) {
        self.renumbered.lock().unwrap().insert(port, r);
    }

    /// The notice of the share of `port`, while it is kept.
    pub fn renumbered(&self, port: u16) -> Option<Renumbered> {
        self.renumbered.lock().unwrap().get(&port).cloned()
    }

    /// Drops the notice of `port`: the user has seen it (or the share was set again).
    pub fn clear_renumbered(&self, port: u16) {
        self.renumbered.lock().unwrap().remove(&port);
    }

    /// Every number any device is seen with, each once.
    pub fn seen(&self) -> Vec<u16> {
        let mut all: Vec<u16> = self.seen.lock().unwrap().values().flatten().copied().collect();
        all.sort_unstable();
        all.dedup();
        all
    }
}

/// Another device's table was read: remember its numbers, so that numbers given out here and
/// ports visitors yield to stay clear of them.
pub fn saw(state: &Arc<State>, id: &str, name: &str, numbers: &[u16]) {
    state.numbers.set_seen(id, numbers.to_vec());
    // A number this device's share holds together with that device is given up by the larger ID,
    // so that exactly one of the two moves. No ID here: nothing to compare, so nothing moves.
    let Some(me) = state.cfg.lock().unwrap().id.clone() else { return };
    if !yields(&me, id) {
        return;
    }
    let mut moved = false;
    for s in state.shares.list() {
        if !s.local.is_some_and(|l| numbers.contains(&l)) {
            continue;
        }
        match state.shares.renumber(s.port, &|used| pick(state, used)) {
            Ok(Some((from, to))) => {
                state.log.event(Lvl::Info, "share_renumbered", json!({"port": s.port, "from": from, "to": to, "with": id}));
                state.numbers.set_renumbered(s.port, Renumbered { from, with: name.to_string() });
                moved = true;
            }
            Ok(None) => {}
            Err(e) => state.log.event(Lvl::Warn, "shares_error", json!({"err": format!("{e:#}")})),
        }
    }
    if moved {
        crate::sharing::sync_own(state);
    }
}

/// The lowest number of `state.maps.range()` that is not in `used`, not a local of `maps.json`
/// (this device's own visitors sit there), not seen on another device, and `maps::free`.
pub fn pick(state: &State, used: &[u16]) -> Option<u16> {
    let (first, count) = state.maps.range();
    let end = first.saturating_add(count.saturating_sub(1));
    let taken: Vec<u16> = state.maps.list().iter().map(|m| m.local).chain(state.numbers.seen()).collect();
    (first..=end).filter(|_| count > 0).find(|n| !used.contains(n) && !taken.contains(n) && maps::free(*n))
}

/// At start: numbers the shares that have none (a table from before numbers), then listens on
/// every number. The devices in `hosts.json` are asked at once which numbers they use, so that
/// one already in use is not given out again; one that does not answer in time is skipped (a
/// clash with it is settled when it is seen later).
pub async fn on_start(state: Arc<State>) {
    if state.shares.list().iter().any(|s| s.local.is_none()) {
        let me = state.cfg.lock().unwrap().id.clone();
        let mut asks = JoinSet::new();
        for h in known_hosts(&state.home).into_iter().filter(|h| Some(&h.id) != me.as_ref()) {
            let state = state.clone();
            asks.spawn(async move { (h.id.clone(), shares_of(&state, &h.id).await) });
        }
        let deadline = tokio::time::Instant::now() + ASK_WAIT;
        while let Ok(Some(done)) = tokio::time::timeout_at(deadline, asks.join_next()).await {
            // A device that is offline, refuses or is too old to say has no numbers to count.
            if let Ok((id, Ok(shares))) = done {
                let locals = shares.as_array().into_iter().flatten().filter_map(|s| s["local"].as_u64()?.try_into().ok()).collect();
                state.numbers.set_seen(&id, locals);
            }
        }
        asks.abort_all();
        match state.shares.number_all(&|used| pick(&state, used)) {
            Ok(done) => {
                for s in done {
                    state.log.event(Lvl::Info, "share_numbered", json!({"port": s.port, "local": s.local}));
                }
            }
            Err(e) => state.log.event(Lvl::Warn, "shares_error", json!({"err": format!("{e:#}")})),
        }
    }
    crate::sharing::sync_own(&state);
}

/// Of two sharers holding the same number, whether `me` gives it up: the larger ID, compared as
/// numbers (as strings when either is not a number).
pub fn yields(me: &str, other: &str) -> bool {
    match (me.parse::<u64>(), other.parse::<u64>()) {
        (Ok(a), Ok(b)) => a > b,
        _ => me > other,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_larger_id_yields() {
        assert!(yields("343758121", "297283213"));
        assert!(!yields("297283213", "343758121"));
        // as numbers, not as text: "9" is smaller than "10"
        assert!(yields("10", "9"));
        assert!(yields("b", "a") && !yields("a", "b"));
        assert!(!yields("5", "5"));
    }

    #[test]
    fn seen_lists_are_replaced_per_device_and_deduplicated() {
        let n = Numbers::new();
        n.set_seen("1", vec![28002, 28000]);
        n.set_seen("2", vec![28000, 28001]);
        assert_eq!(n.seen(), [28000, 28001, 28002]);
        n.set_seen("1", vec![28005]);
        assert_eq!(n.seen(), [28000, 28001, 28005]);
        n.set_seen("2", vec![]);
        assert_eq!(n.seen(), [28005]);
    }
}
