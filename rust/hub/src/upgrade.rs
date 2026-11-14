//! Moving relay and direct links to the LAN (relay connect UX spec §3). A host whose cached link is on
//! the relay or direct is tried on its LAN `first` after the link is cached, then every `every`, and at
//! once when this machine's addresses change; `route_failed` (a session did not reopen on the LAN)
//! holds it off for `hold`, link failures or not. A host whose hold ends with its link on the LAN
//! already is announced again (`path lan`): the sessions left on the old route get another go. Only
//! an unforced host with a stored fingerprint is tried, only on private addresses, and the LAN link
//! replaces the cached one only when nothing changed meanwhile. The old link is not closed: sessions
//! on it run until the GUI reopens them.

use crate::hosts::Host;
use crate::link::Link;
use crate::Hub;
use rapp_net::log::Lvl;
use serde_json::json;
use std::collections::HashMap;
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::time::{interval, MissedTickBehavior};

#[derive(Debug, Clone, Copy)]
pub struct UpgradeTimes {
    /// After a link is cached on the relay or direct.
    pub first: Duration,
    /// Between tries that found no LAN.
    pub every: Duration,
    /// After `route_failed`.
    pub hold: Duration,
    /// How often the loop looks.
    pub tick: Duration,
}

impl Default for UpgradeTimes {
    fn default() -> Self {
        let s = Duration::from_secs;
        UpgradeTimes { first: s(2), every: s(30), hold: s(300), tick: s(1) }
    }
}

struct Entry {
    at: Instant,
    hold: Option<Instant>,
    /// Put here or held by `failed_move`.
    failed: bool,
}

/// When each host is next tried. Plain data; the caller gives the time.
pub(crate) struct Schedule {
    times: UpgradeTimes,
    hosts: HashMap<String, Entry>,
}

impl Schedule {
    pub(crate) fn new(times: UpgradeTimes) -> Schedule {
        Schedule { times, hosts: HashMap::new() }
    }

    /// A link to `id` was cached: off the LAN it is tried `first` from now; on the LAN it leaves.
    pub(crate) fn linked(&mut self, id: &str, path: &str, now: Instant) {
        if path == "lan" {
            self.hosts.remove(id);
            return;
        }
        let at = now + self.times.first;
        self.hosts.entry(id.to_string()).and_modify(|e| e.at = at).or_insert(Entry { at, hold: None, failed: false });
    }

    /// A try found no LAN.
    pub(crate) fn tried(&mut self, id: &str, now: Instant) {
        if let Some(e) = self.hosts.get_mut(id) {
            e.at = now + self.times.every;
        }
    }

    /// A move did not take (`route_failed`): no tries for `hold`. The GUI says so once the LAN link
    /// is cached, which takes the host out of the schedule; it comes back here to be due after `hold`.
    pub(crate) fn failed_move(&mut self, id: &str, now: Instant) {
        let hold = Some(now + self.times.hold);
        let e = self.hosts.entry(id.to_string()).or_insert(Entry { at: now, hold, failed: true });
        (e.hold, e.failed) = (hold, true);
    }

    /// Due now, hold or not (`set_route auto`).
    pub(crate) fn now_for(&mut self, id: &str, now: Instant) {
        self.hosts.insert(id.to_string(), Entry { at: now, hold: None, failed: false });
    }

    /// This machine's addresses changed: every host is due (those held stay held).
    pub(crate) fn net_changed(&mut self, now: Instant) {
        for e in self.hosts.values_mut() {
            e.at = e.at.min(now);
        }
    }

    /// The link to `id` failed. A held host stays, hold and all: a flaky LAN is what the hold is for
    /// (one whose hold is over goes at its next due try).
    pub(crate) fn forget(&mut self, id: &str) {
        if self.hosts.get(id).is_some_and(|e| e.hold.is_none()) {
            self.hosts.remove(id);
        }
    }

    /// `id` is no longer saved: gone, hold and all.
    pub(crate) fn remove(&mut self, id: &str) {
        self.hosts.remove(id);
    }

    /// A due host that no try can move leaves; true when a failed move had put or held it here.
    pub(crate) fn settle(&mut self, id: &str) -> bool {
        self.hosts.remove(id).is_some_and(|e| e.failed)
    }

    pub(crate) fn clear(&mut self) {
        self.hosts.clear();
    }

    pub(crate) fn due(&self, now: Instant) -> Vec<String> {
        let due = |e: &Entry| e.at <= now && e.hold.is_none_or(|h| h <= now);
        self.hosts.iter().filter(|(_, e)| due(e)).map(|(id, _)| id.clone()).collect()
    }
}

/// Whether a try may move `host` to its LAN: it is still saved, not forced onto the relay, has shown
/// a fingerprint (the LAN answer is checked against it), and its cached link is off the LAN.
pub(crate) fn worth_trying(host: Option<&Host>, cached_path: Option<&str>) -> bool {
    let Some(host) = host else { return false };
    !host.forced_relay() && host.fp.is_some() && cached_path.is_some_and(|p| p != "lan")
}

/// This machine's IPv4 addresses, in a fixed order.
fn local_addrs() -> Vec<std::net::Ipv4Addr> {
    let mut v = rapp_net::addr::local_ipv4s();
    v.sort();
    v
}

pub(crate) async fn run(hub: Arc<Hub>) {
    let mut tick = interval(hub.times.tick);
    tick.set_missed_tick_behavior(MissedTickBehavior::Delay);
    let mut addrs = local_addrs();
    loop {
        tick.tick().await;
        let now = local_addrs();
        if now != addrs {
            addrs = now;
            hub.schedule.lock().unwrap().net_changed(Instant::now());
        }
        let due = hub.schedule.lock().unwrap().due(Instant::now());
        for id in due {
            try_one(&hub, &id).await;
        }
    }
}

/// One try of `id`'s LAN; the LAN link goes into the cache only if the host, the home and the cached
/// link are all still the ones the try started from.
async fn try_one(hub: &Hub, id: &str) {
    let host = hub.hosts.get(id);
    let cached = hub.links.lock().unwrap().get(id).cloned();
    let path = cached.as_ref().map(Link::path);
    if !worth_trying(host.as_ref(), path) {
        let failed = hub.schedule.lock().unwrap().settle(id);
        if failed && path == Some("lan") && host.is_some_and(|h| !h.forced_relay()) {
            // A move onto this LAN link failed, and its hold is over: the GUI tries the sessions again.
            hub.emit(json!({"event":"path","id":id,"path":"lan"}), &None).await;
        }
        return;
    }
    let (Some(host), Some(old)) = (host, cached) else { return };
    let home = hub.at_home().0;
    match hub.try_lan(&host).await {
        Ok(Some(link)) => {
            if hub.swap_link(id, &old, link.clone(), &home).await {
                hub.log.msg(Lvl::Info, format_args!("{id}: path {}→lan", old.path()));
            } else {
                link.close(b"not needed");
            }
        }
        Ok(None) => hub.schedule.lock().unwrap().tried(id, Instant::now()),
        Err(e) => {
            hub.log.msg(Lvl::Debug, format_args!("{id}: no LAN: {e:#}"));
            hub.schedule.lock().unwrap().tried(id, Instant::now());
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{worth_trying, Schedule, UpgradeTimes};
    use crate::hosts::Host;
    use rapp_wire::Fp;
    use std::time::{Duration, Instant};

    const S: Duration = Duration::from_secs(1);
    const MS: Duration = Duration::from_millis(1);

    fn schedule() -> Schedule {
        Schedule::new(UpgradeTimes::default())
    }

    #[test]
    fn relay_link_is_tried_after_first_then_every() {
        let (mut s, t0) = (schedule(), Instant::now());
        s.linked("a", "relay", t0);
        assert!(s.due(t0 + 1900 * MS).is_empty());
        assert_eq!(s.due(t0 + 2 * S), ["a"]);
        let t1 = t0 + 3 * S;
        s.tried("a", t1);
        assert!(s.due(t1 + 29_900 * MS).is_empty());
        assert_eq!(s.due(t1 + 30 * S), ["a"]);
    }

    #[test]
    fn direct_counts_like_relay() {
        let (mut s, t0) = (schedule(), Instant::now());
        s.linked("a", "direct", t0);
        assert!(s.due(t0 + 1900 * MS).is_empty());
        assert_eq!(s.due(t0 + 2 * S), ["a"]);
    }

    #[test]
    fn lan_link_leaves_the_schedule() {
        let (mut s, t0) = (schedule(), Instant::now());
        s.linked("a", "relay", t0);
        s.linked("a", "lan", t0 + S);
        s.net_changed(t0 + 2 * S);
        assert!(s.due(t0 + 3600 * S).is_empty());
    }

    #[test]
    fn failed_move_holds_five_minutes_even_on_net_change() {
        let (mut s, t0) = (schedule(), Instant::now());
        s.linked("a", "relay", t0);
        s.failed_move("a", t0);
        s.net_changed(t0 + S);
        assert!(s.due(t0 + S).is_empty());
        assert!(s.due(t0 + 299 * S).is_empty());
        assert_eq!(s.due(t0 + 300 * S), ["a"]);
    }

    #[test]
    fn net_change_makes_everyone_due() {
        let (mut s, t0) = (schedule(), Instant::now());
        s.linked("a", "relay", t0);
        s.linked("b", "direct", t0);
        s.net_changed(t0 + 100 * MS);
        let mut due = s.due(t0 + 100 * MS);
        due.sort();
        assert_eq!(due, ["a", "b"]);
    }

    #[test]
    fn now_for_clears_the_hold() {
        let (mut s, t0) = (schedule(), Instant::now());
        s.linked("a", "relay", t0);
        s.failed_move("a", t0);
        s.now_for("a", t0 + S);
        assert_eq!(s.due(t0 + S), ["a"]);
        // Also for a host the schedule had dropped (a forced host set back to auto).
        s.forget("a");
        s.now_for("a", t0 + 2 * S);
        assert_eq!(s.due(t0 + 2 * S), ["a"]);
    }

    #[test]
    fn forget_and_clear_drop_hosts() {
        let (mut s, t0) = (schedule(), Instant::now());
        s.linked("a", "relay", t0);
        s.linked("b", "relay", t0);
        s.forget("a");
        assert_eq!(s.due(t0 + 2 * S), ["b"]);
        s.clear();
        assert!(s.due(t0 + 2 * S).is_empty());
        // A try that ends after its host was dropped does not bring it back.
        s.tried("b", t0 + 3 * S);
        assert!(s.due(t0 + 3600 * S).is_empty());
    }

    #[test]
    fn a_link_failure_keeps_the_hold() {
        let (mut s, t0) = (schedule(), Instant::now());
        s.linked("a", "relay", t0);
        s.failed_move("a", t0);
        // The link died, and the next request went over the relay again.
        s.forget("a");
        s.linked("a", "relay", t0 + S);
        assert!(s.due(t0 + 3 * S).is_empty());
        assert!(s.due(t0 + 299 * S).is_empty());
        assert_eq!(s.due(t0 + 300 * S), ["a"]);
        // Also with no new link at all.
        s.failed_move("a", t0);
        s.forget("a");
        assert!(s.due(t0 + 299 * S).is_empty());
        assert_eq!(s.due(t0 + 300 * S), ["a"]);
    }

    #[test]
    fn remove_drops_a_held_host() {
        let (mut s, t0) = (schedule(), Instant::now());
        s.failed_move("a", t0);
        s.remove("a");
        assert!(s.due(t0 + 3600 * S).is_empty());
    }

    #[test]
    fn a_due_host_says_whether_a_move_failed() {
        let (mut s, t0) = (schedule(), Instant::now());
        s.failed_move("a", t0);
        s.linked("b", "relay", t0);
        assert!(s.settle("a"), "held after a failed move");
        assert!(!s.settle("b"));
        assert!(!s.settle("a"), "settled: gone");
        assert!(s.due(t0 + 3600 * S).is_empty());
    }

    #[test]
    fn defaults_match_the_spec() {
        let t = UpgradeTimes::default();
        assert_eq!((t.first, t.every, t.hold, t.tick), (2 * S, 30 * S, 300 * S, S));
    }

    #[test]
    fn worth_trying_only_unforced_hosts_with_a_fingerprint_off_the_lan() {
        let host = Host {
            id: "100000001".into(),
            name: "a".into(),
            password: String::new(),
            lan: vec!["192.168.1.5:22028".into()],
            fp: Some(Fp([7; 32])),
            route: None,
        };
        assert!(worth_trying(Some(&host), Some("relay")));
        assert!(worth_trying(Some(&host), Some("direct")));
        assert!(!worth_trying(Some(&host), Some("lan")));
        assert!(!worth_trying(Some(&host), None), "no cached link");
        assert!(!worth_trying(None, Some("relay")), "host removed");
        let forced = Host { route: Some("relay".into()), ..host.clone() };
        assert!(!worth_trying(Some(&forced), Some("relay")));
        let old = Host { fp: None, password: "pw".into(), ..host };
        assert!(!worth_trying(Some(&old), Some("relay")), "a password host never seen with a key");
    }
}
