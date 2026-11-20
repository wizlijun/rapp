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
    told: Mutex<Option<Vec<Map>>>,
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
            let wants = rapp_ports::wants(&items);
            self.maps.keep(&id, &wants.iter().map(|(port, _)| *port).collect::<Vec<u16>>());
            rapp_ports::ensure_all(&self.maps, &id, &wants, &avoid, &[], &serve).await;
        }
        self.log.event(Lvl::Info, "ports_asked", json!({"asked": hosts.len(), "answered": answered}));
    }

    /// The `ports` event and log line, when the table is not what was told last.
    async fn tell(&self, hub: &Hub) {
        let now = self.maps.list();
        {
            let mut told = self.told.lock().unwrap();
            if told.as_ref() == Some(&now) {
                return;
            }
            *told = Some(now.clone());
        }
        let maps: Vec<Value> = now.iter().map(|m| json!({"id": m.id, "port": m.port, "local": m.local})).collect();
        self.log.event(Lvl::Info, "ports", json!({"maps": maps}));
        hub.emit(json!({"event": "ports", "maps": maps}), &None).await;
    }
}

/// Tells the table read from the file, then asks on every tick, poke and network change.
pub(crate) async fn run(hub: Arc<Hub>, ports: Arc<HubPorts>) {
    ports.tell(&hub).await;
    let mut tick = interval(ASK_EVERY);
    tick.set_missed_tick_behavior(MissedTickBehavior::Delay);
    let mut wake = hub.net.wake.subscribe();
    loop {
        tokio::select! {
            _ = tick.tick() => {}
            _ = ports.poke.notified() => {}
            _ = wake.changed() => {
                // Connections being carried move to the new socket with the endpoint.
                ports.relisten().await;
                tick.reset();
            }
            _ = ports.dead.notified() => ports.relisten().await,
        }
        ports.ask_all().await;
        ports.tell(&hub).await;
    }
}
