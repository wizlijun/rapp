//! Local ports for other devices' shares in an app with no service (iOS, later Android): the hub
//! listens on `localhost:<share number>` itself, by the same table and rules as the service on a
//! PC (`rapp_ports`), so the address is the same everywhere. Only reachable from inside the app.
//!
//! The maps of the last run listen at start, from `maps.json`, before anyone is asked. Then every
//! known device is asked for its shares every `ASK_EVERY`, when the host list changes (`poke`)
//! and when the network changes (`net.wake`; the listeners are opened again first). A device
//! that does not answer keeps its maps. A listener whose accept keeps failing ends, and all are
//! opened again (`dead`); a port that could not be listened on is tried again on every ask. Each change of the table is the `ports` event and a
//! `ports` line in hub.log.

use crate::Hub;
use rapp_conn::dial::Outbound;
use rapp_conn::Pipe;
use rapp_net::log::{Log, Lvl};
use rapp_ports::{Carrier, Map, Maps, Way};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::sync::Notify;
use tokio::time::{interval, MissedTickBehavior};

/// How often every known device is asked for its shares.
const ASK_EVERY: Duration = Duration::from_secs(60);
/// How long one device is waited for.
const ASK_WAIT: Duration = Duration::from_secs(5);

pub(crate) struct HubPorts {
    /// The home the hub started on; the table stays there (`set_home` does not move it).
    home: PathBuf,
    maps: Maps,
    out: Outbound,
    log: Log,
    /// The share numbers each device answered with last, kept clear of by the others' maps.
    seen: Mutex<HashMap<String, Vec<u16>>>,
    poke: Notify,
    /// A listener ended (`OnDead`): open them again.
    dead: Notify,
    /// The table as last told (event and log).
    told: Mutex<Option<Vec<Value>>>,
    /// What kind each device's shares said they were, by (device, port).
    kinds: Mutex<HashMap<(String, u16), String>>,
}

/// The table as told in the `ports` event: each map with its `kind` when the device's share list
/// gave one.
pub(crate) fn told(maps: &[Map], kinds: &HashMap<(String, u16), String>) -> Vec<Value> {
    maps.iter()
        .map(|m| {
            let mut v = json!({"id": m.id, "port": m.port, "local": m.local});
            if let Some(k) = kinds.get(&(m.id.clone(), m.port)) {
                v["kind"] = json!(k);
            }
            v
        })
        .collect()
}

impl Carrier for HubPorts {
    fn maps(&self) -> &Maps {
        &self.maps
    }

    fn log(&self) -> &Log {
        &self.log
    }

    async fn open(&self, id: &str, port: u16) -> Result<Pipe, String> {
        let s = rapp_conn::settings::load(&self.home);
        let way = Way { out: &self.out, home: &self.home, relay: s.relay.as_deref(), key: s.key.as_ref() };
        rapp_ports::open(&way, id, port).await.map(|(pipe, _)| pipe).map_err(|e| e.as_str().to_string())
    }
}

/// Reads the table of the hub's home and listens for it. The connections go out on the hub's own
/// endpoint, as its device.
pub(crate) fn start(hub: &Arc<Hub>, (first, count): (u16, u16)) -> Arc<HubPorts> {
    let (home, identity) = hub.at_home();
    let (maps, unreadable) = Maps::load(&home, first, count);
    if let Some(why) = unreadable {
        hub.log.event(Lvl::Warn, "maps_unreadable", json!({"error": why}));
    }
    let ports = Arc::new(HubPorts {
        out: Outbound::new(hub.ep.clone(), identity, hub.name.clone()),
        home,
        maps,
        log: hub.log.clone(),
        seen: Default::default(),
        poke: Notify::new(),
        dead: Notify::new(),
        told: Default::default(),
        kinds: Default::default(),
    });
    let known = rapp_ports::known_ids(&ports.home);
    ports.taken(ports.maps.start(known.as_deref(), &ports.serve()));
    ports
}

impl HubPorts {
    /// Ask every device now (the host list changed).
    pub(crate) fn poke(&self) {
        self.poke.notify_one();
    }

    /// Stops listening (the hub exits); the table and the file stay.
    pub(crate) fn stop(&self) {
        self.maps.stop();
    }

    /// The accept loop for the listeners, which tells `dead` when one ends.
    fn serve(self: &Arc<Self>) -> impl Fn(tokio::net::TcpListener, u16) -> tokio::task::JoinHandle<()> + Send + Sync + 'static {
        let me = Arc::downgrade(self);
        let on_dead: rapp_ports::OnDead = Arc::new(move |local| {
            if let Some(me) = me.upgrade() {
                me.log.event(Lvl::Warn, "map_listener_dead", json!({"local": local}));
                me.dead.notify_one();
            }
        });
        rapp_ports::serve(self.clone(), Some(on_dead))
    }

    fn taken(&self, failed: Vec<Map>) {
        for m in failed {
            self.log.event(Lvl::Warn, "map_port_taken", json!({"id": m.id, "port": m.port, "local": m.local}));
        }
    }

    /// Closes every listener and opens it again.
    async fn relisten(self: &Arc<Self>) {
        let failed = self.maps.relisten(&self.serve()).await;
        let failed: Vec<Value> = failed.iter().map(|m| json!(m.local)).collect();
        self.log.event(Lvl::Info, "ports_relisten", json!({"failed": failed}));
    }

    /// Asks every known device for its shares, at once, and puts each answer in the table.
    async fn ask_all(self: &Arc<Self>) {
        if let Some(ids) = rapp_ports::known_ids(&self.home) {
            self.maps.keep_devices(&ids);
            self.seen.lock().unwrap().retain(|id, _| ids.contains(id));
        }
        // The maps whose port could not be had before.
        self.taken(self.maps.start(None, &self.serve()));
        let hosts = rapp_ports::known_hosts(&self.home);
        let mut asks = tokio::task::JoinSet::new();
        for h in &hosts {
            let (me, id) = (self.clone(), h.id.clone());
            asks.spawn(async move {
                let s = rapp_conn::settings::load(&me.home);
                let way = Way { out: &me.out, home: &me.home, relay: s.relay.as_deref(), key: s.key.as_ref() };
                let got = tokio::time::timeout(ASK_WAIT, rapp_ports::shares_of(&way, &id)).await;
                (id, got.ok().and_then(Result::ok))
            });
        }
        let mut answered = 0;
        let serve = self.serve();
        while let Some(Ok((id, got))) = asks.join_next().await {
            let Some(shares) = got else { continue };
            answered += 1;
            let items = shares.as_array().cloned().unwrap_or_default();
            let avoid: Vec<u16> = {
                let mut seen = self.seen.lock().unwrap();
                seen.insert(id.clone(), rapp_ports::numbers(&items));
                seen.iter().filter(|(k, _)| **k != id).flat_map(|(_, v)| v.iter().copied()).collect()
            };
            {
                let mut kinds = self.kinds.lock().unwrap();
                kinds.retain(|(d, _), _| *d != id);
                for it in &items {
                    if let (Some(port), Some(kind)) = (it["port"].as_u64().and_then(|p| u16::try_from(p).ok()), it["kind"].as_str()) {
                        kinds.insert((id.clone(), port), kind.to_string());
                    }
                }
            }
            let wants = rapp_ports::wants(&items);
            self.maps.keep(&id, &wants.iter().map(|(port, _)| *port).collect::<Vec<u16>>());
            rapp_ports::ensure_all(&self.maps, &id, &wants, &avoid, &[], &serve).await;
        }
        self.log.event(Lvl::Info, "ports_asked", json!({"asked": hosts.len(), "answered": answered}));
    }

    /// The `ports` event and log line, when the table is not what was told last.
    async fn tell(&self, hub: &Hub) {
        let maps = told(&self.maps.list(), &self.kinds.lock().unwrap());
        {
            let mut told = self.told.lock().unwrap();
            if told.as_ref() == Some(&maps) {
                return;
            }
            *told = Some(maps.clone());
        }
        self.log.event(Lvl::Info, "ports", json!({"maps": maps}));
        hub.emit(json!({"event": "ports", "maps": maps}), &None).await;
    }
}

/// How long to wait before opening the listeners again after one ended: at once, then doubling
/// while they keep ending (an accept that fails for good, out of file descriptors) up to
/// `ASK_EVERY`; at once again after a quiet spell of two `ASK_EVERY`.
#[derive(Default)]
struct Backoff {
    last: Option<tokio::time::Instant>,
    delay: Duration,
}

impl Backoff {
    fn next(&mut self, now: tokio::time::Instant) -> Duration {
        let quiet = self.last.is_none_or(|last| now.duration_since(last) > ASK_EVERY * 2);
        self.delay = if quiet {
            Duration::ZERO
        } else if self.delay.is_zero() {
            Duration::from_secs(1)
        } else {
            (self.delay * 2).min(ASK_EVERY)
        };
        self.last = Some(now);
        self.delay
    }
}

/// Tells the table read from the file, then asks on every tick, poke and network change.
pub(crate) async fn run(hub: Arc<Hub>, ports: Arc<HubPorts>) {
    ports.tell(&hub).await;
    let mut tick = interval(ASK_EVERY);
    tick.set_missed_tick_behavior(MissedTickBehavior::Delay);
    let mut wake = hub.net.wake.subscribe();
    let mut backoff = Backoff::default();
    loop {
        tokio::select! {
            _ = tick.tick() => {}
            _ = ports.poke.notified() => {}
            _ = wake.changed() => {
                // Connections being carried move to the new socket with the endpoint.
                ports.relisten().await;
                tick.reset();
            }
            _ = ports.dead.notified() => {
                tokio::time::sleep(backoff.next(tokio::time::Instant::now())).await;
                ports.relisten().await;
                // A listener ending says nothing about the devices' shares: no ask.
                continue;
            }
        }
        ports.ask_all().await;
        ports.tell(&hub).await;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::time::Instant;

    #[test]
    fn told_maps_carry_kind_when_known() {
        let maps = vec![Map { id: "222".into(), port: 8102, local: 28003, wanted: None }, Map { id: "222".into(), port: 3000, local: 28000, wanted: None }];
        let kinds = HashMap::from([(("222".to_string(), 8102), "state".to_string())]);
        assert_eq!(
            told(&maps, &kinds),
            vec![json!({"id":"222","port":8102,"local":28003,"kind":"state"}), json!({"id":"222","port":3000,"local":28000})]
        );
    }

    #[test]
    fn listeners_dying_one_after_another_are_opened_again_ever_later() {
        let t0 = Instant::now();
        let mut b = Backoff::default();
        let s = Duration::from_secs;
        assert_eq!(b.next(t0), Duration::ZERO, "the first is opened again at once");
        let waits: Vec<Duration> = (1..10).map(|i| b.next(t0 + s(i))).collect();
        assert_eq!(&waits[..7], &[s(1), s(2), s(4), s(8), s(16), s(32), ASK_EVERY]);
        assert_eq!(waits[8], ASK_EVERY, "never longer than an ask");
        // A while without one: at once again.
        assert_eq!(b.next(t0 + s(10) + ASK_EVERY * 2 + s(600)), Duration::ZERO);
    }
}
