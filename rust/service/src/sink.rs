//! Where the state service (`rapp-state`, a "sink") is, and telling the devices this one knows.
//!
//! A device learns of a sink from a share list carrying `kind: "state"` (`saw`), from another
//! device's `StateSink` notice (`serve`), or from its own companion (`set_local`). Each change
//! is told to every device in `hosts.json` (`spawn`), once: what each device was told lives in
//! that loop only. Every device picks the sink with the smallest device ID (`Sinks::dest`).

use crate::pipe::{self, known_hosts, known_ids, PipeErr};
use crate::state::{Peer, State};
use rapp_conn::Pipe;
use rapp_net::line::{err, ok, write_json};
use rapp_net::log::Lvl;
use rapp_net::msg::Op;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::{BTreeMap, HashMap};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::io::AsyncWriteExt;
use tokio::sync::watch;
use tokio::task::{JoinHandle, JoinSet};

/// While a sink is known (or an `on: false` is still to be told), the known devices are looked
/// at this often: new ones, and ones not reached last time, are told then.
pub const TELL_EVERY: Duration = Duration::from_secs(300);
/// The learned sinks, in the device's `local/`.
const FILE: &str = "state-sinks.json";

/// Where the chosen sink is: this device's own port, or a port of another device.
#[derive(Clone, PartialEq, Debug)]
pub enum Dest {
    Local(u16),
    Remote { id: String, port: u16 },
}

#[derive(Serialize, Deserialize)]
struct Saved {
    id: String,
    port: u16,
}

#[derive(Default)]
struct Inner {
    /// This device's own sink (the companion's port).
    local: Option<u16>,
    /// Other devices' sinks, by device ID.
    remote: BTreeMap<String, u16>,
    /// Notices that changed the table, not yet seen by the tell loop: (from host, id, port, on).
    heard: Vec<Heard>,
}

type Heard = (String, String, u16, bool);
/// One thing to say of a sink: (sink id, port, on).
pub type Say = (String, u16, bool);
/// What was told to each device, all `on` (an `on: false` told removes the sink's entry).
type Told = HashMap<String, Vec<Say>>;

/// The sinks this device knows.
pub struct Sinks {
    path: PathBuf,
    inner: Mutex<Inner>,
    changed: watch::Sender<u64>,
}

impl Sinks {
    /// Reads `<home>/state-sinks.json` (`[{"id","port"}]`). A missing file is no sinks; so is an
    /// unreadable one, and the second value then says why (the next change overwrites it).
    pub fn load(home: &Path) -> (Sinks, Option<String>) {
        let path = home.join(FILE);
        let (remote, why) = match std::fs::read(&path) {
            Ok(b) => match serde_json::from_slice::<Vec<Saved>>(&b) {
                Ok(v) => (v.into_iter().map(|s| (s.id, s.port)).collect(), None),
                Err(e) => (BTreeMap::new(), Some(e.to_string())),
            },
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => (BTreeMap::new(), None),
            Err(e) => (BTreeMap::new(), Some(e.to_string())),
        };
        let inner = Inner { remote, ..Default::default() };
        (Sinks { path, inner: Mutex::new(inner), changed: watch::channel(0).0 }, why)
    }

    /// Sets this device's own sink (None: there is none). True when it changed.
    pub fn set_local(&self, port: Option<u16>) -> bool {
        let mut inner = self.inner.lock().unwrap();
        if inner.local == port {
            return false;
        }
        inner.local = port;
        drop(inner);
        self.bump();
        true
    }

    /// Device `id` has a sink on `port`. True when that is new (then it is saved).
    pub fn learn(&self, id: &str, port: u16) -> bool {
        self.change(id, Some(port), None).is_some()
    }

    /// Device `id` has no sink. True when one was known (then it is saved).
    pub fn forget(&self, id: &str) -> bool {
        self.change(id, None, None).is_some()
    }

    /// Sets (`Some`) or drops (`None`) the sink of `id`. When that changed the table, it is saved
    /// and the port involved is returned (the new one, or the one dropped). `heard` is the notice
    /// behind the change, if any: the tell loop then counts its sender as knowing it.
    fn change(&self, id: &str, port: Option<u16>, heard: Option<Heard>) -> Option<u16> {
        let mut inner = self.inner.lock().unwrap();
        let was = match port {
            Some(p) => inner.remote.insert(id.to_string(), p),
            None => inner.remote.remove(id),
        };
        if was == port {
            return None;
        }
        inner.heard.extend(heard);
        let saved: Vec<Saved> = inner.remote.iter().map(|(id, port)| Saved { id: id.clone(), port: *port }).collect();
        // A failed write keeps the table in memory; the next change writes it again.
        let _ = rapp_net::config::write_json(&self.path, &saved);
        drop(inner);
        self.bump();
        port.or(was)
    }

    fn bump(&self) {
        self.changed.send_modify(|n| *n += 1);
    }

    /// Other devices' sinks, by ID.
    pub fn remote(&self) -> Vec<(String, u16)> {
        self.inner.lock().unwrap().remote.iter().map(|(id, port)| (id.clone(), *port)).collect()
    }

    fn local(&self) -> Option<u16> {
        self.inner.lock().unwrap().local
    }

    fn take_heard(&self) -> Vec<Heard> {
        std::mem::take(&mut self.inner.lock().unwrap().heard)
    }

    /// Every sink, smallest ID first: this device's own one under `own_id` (first when there is
    /// no ID), then the others'.
    fn candidates(&self, own_id: Option<&str>) -> Vec<(Option<String>, Dest)> {
        let inner = self.inner.lock().unwrap();
        let mut all: Vec<(Option<String>, Dest)> = inner.local.map(|p| (own_id.map(str::to_string), Dest::Local(p))).into_iter().collect();
        all.extend(inner.remote.iter().map(|(id, port)| (Some(id.clone()), Dest::Remote { id: id.clone(), port: *port })));
        // Stable: on an equal ID this device's own one stays first.
        all.sort_by(|a, b| a.0.as_deref().unwrap_or("").cmp(b.0.as_deref().unwrap_or("")));
        all
    }

    /// The sink to send to: the one with the smallest device ID.
    pub fn dest(&self, own_id: Option<&str>) -> Option<Dest> {
        self.candidates(own_id).into_iter().next().map(|(_, d)| d)
    }

    /// Bumped on every change.
    pub fn subscribe(&self) -> watch::Receiver<u64> {
        self.changed.subscribe()
    }
}

/// A 9-digit device ID.
fn is_id(id: &str) -> bool {
    id.len() == 9 && id.bytes().all(|b| b.is_ascii_digit())
}

fn own_id(state: &State) -> Option<String> {
    state.cfg.lock().unwrap().id.clone()
}

fn logged(state: &State, id: &str, port: u16, on: bool, from: &str) {
    state.log.event(Lvl::Info, "state_sink", json!({"id": id, "port": port, "on": on, "from": from}));
}

/// `Sinks::change`, logged (`from`: what told) when it changed anything.
fn change(state: &State, id: &str, port: Option<u16>, heard: Option<Heard>, from: &str) -> bool {
    match state.sinks.change(id, port, heard) {
        Some(p) => {
            logged(state, id, p, port.is_some(), from);
            true
        }
        None => false,
    }
}

/// `Sinks::forget`, logged (`from`: what told) when it changed anything.
pub fn forget(state: &State, id: &str, from: &str) -> bool {
    change(state, id, None, None, from)
}

/// `Sinks::set_local`, logged when it changed anything. For the companion that runs this
/// device's own state service (it is not wired in yet).
#[allow(dead_code)]
pub fn set_local(state: &State, port: Option<u16>) -> bool {
    let was = state.sinks.local();
    let changed = state.sinks.set_local(port);
    if let (true, Some(p)) = (changed, port.or(was)) {
        logged(state, &own_id(state).unwrap_or_default(), p, port.is_some(), "local");
    }
    changed
}

/// What the share list `items` of device `id` says of its sink: `Some(port)` of an item of kind
/// `"state"`, `Some(None)` when there is none, and None when the list is not looked at: `id` is
/// not a device ID, or is this device (`own`; the companion says what runs here).
fn seen(own: Option<&str>, id: &str, items: &[Value]) -> Option<Option<u16>> {
    if !is_id(id) || own == Some(id) {
        return None;
    }
    Some(items.iter().filter(|s| s["kind"] == "state").find_map(|s| crate::sharing::port_of(&s["port"])))
}

/// The share list of device `id` was read: an item of kind `"state"` is a sink on its port; none,
/// and a sink known on `id` is gone.
pub fn saw(state: &Arc<State>, id: &str, items: &[Value]) {
    if let Some(port) = seen(own_id(state).as_deref(), id, items) {
        change(state, id, port, None, "shares");
    }
}

/// Answers another device's `StateSink` with one line, then closes the stream.
pub async fn serve(state: &Arc<State>, mut s: Pipe, op: Op, peer: Peer) -> anyhow::Result<()> {
    let reply = answer(state, op, &peer);
    write_json(&mut s, &reply).await?;
    s.shutdown().await?;
    Ok(())
}

fn answer(state: &State, op: Op, peer: &Peer) -> Value {
    let Op::StateSink { id, port, on } = op else { return err("unknown op") };
    if peer.fp.is_none() {
        return err("not supported");
    }
    if !is_id(&id) || port == 0 {
        return err("bad request");
    }
    // Nobody tells a device about its own sink; one that does is ignored.
    if own_id(state).as_deref() == Some(id.as_str()) {
        return ok(json!({}));
    }
    // The device that told is counted as knowing it, so the notice is not sent back.
    let from = known_hosts(&state.home).into_iter().find(|h| h.fp.is_some() && h.fp == peer.fp).map(|h| h.id);
    let heard = from.map(|f| (f, id.clone(), port, on));
    change(state, &id, on.then_some(port), heard, "notice");
    ok(json!({}))
}

/// The IPC `state` reply: every sink known here, and which one is chosen.
pub fn ipc(state: &State) -> Value {
    let own = own_id(state);
    let all = state.sinks.candidates(own.as_deref());
    let chosen = all.first().map(|(_, d)| d.clone());
    let sinks: Vec<Value> = all
        .into_iter()
        .map(|(id, d)| {
            let is_chosen = Some(&d) == chosen.as_ref();
            match d {
                Dest::Local(port) => json!({"id": id, "port": port, "local": true, "chosen": is_chosen}),
                Dest::Remote { id, port } => json!({"id": id, "port": port, "local": false, "chosen": is_chosen}),
            }
        })
        .collect();
    ok(json!({"sinks": sinks}))
}

/// What to tell each of `hosts`: the sinks of `sinks` not on that host that it was not told
/// (`on: true`), and the ones it was told that are gone (`on: false`). A host with nothing to
/// be told is left out.
pub fn tell_plan(hosts: &[String], sinks: &[(String, u16)], told: &Told) -> Vec<(String, Vec<Say>)> {
    let mut plan = Vec::new();
    for host in hosts {
        let knows: &[Say] = told.get(host).map(Vec::as_slice).unwrap_or_default();
        let want: Vec<&(String, u16)> = sinks.iter().filter(|(id, _)| id != host).collect();
        let mut say: Vec<Say> = knows
            .iter()
            .filter(|(id, _, _)| !want.iter().any(|(w, _)| w == id))
            .map(|(id, port, _)| (id.clone(), *port, false))
            .collect();
        say.extend(
            want.iter().filter(|(id, port)| !knows.iter().any(|(k, p, _)| k == id && p == port)).map(|(id, port)| (id.clone(), *port, true)),
        );
        if !say.is_empty() {
            plan.push((host.clone(), say));
        }
    }
    plan
}

/// `host` now knows `(id, port, on)`.
fn note(told: &mut Told, host: &str, id: &str, port: u16, on: bool) {
    let knows = told.entry(host.to_string()).or_default();
    knows.retain(|(k, _, _)| k != id);
    if on {
        knows.push((id.to_string(), port, true));
    }
}

/// The tell loop: a round at start when a sink is known, at every change, and every
/// `TELL_EVERY` while a sink is known or an `on: false` is still to be told. With neither, it
/// only waits for a change: no file is read, nothing is sent.
pub fn spawn(state: Arc<State>) -> JoinHandle<()> {
    tokio::spawn(async move {
        let mut changes = state.sinks.subscribe();
        let mut told = Told::new();
        let mut due = any(&state);
        loop {
            if due {
                round(&state, &mut told, &mut changes).await;
            }
            let periodic = any(&state) || told.values().any(|v| !v.is_empty());
            tokio::select! {
                changed = changes.changed() => if changed.is_err() { return },
                _ = tokio::time::sleep(TELL_EVERY), if periodic => {}
            }
            due = true;
        }
    })
}

fn any(state: &State) -> bool {
    state.sinks.local().is_some() || !state.sinks.remote().is_empty()
}

/// One round: drops the sinks of devices taken off `hosts.json`, then tells every known device
/// what it was not told yet.
async fn round(state: &Arc<State>, told: &mut Told, changes: &mut watch::Receiver<u64>) {
    let own = own_id(state);
    if let Some(ids) = known_ids(&state.home) {
        for (id, _) in state.sinks.remote() {
            if !ids.contains(&id) {
                forget(state, &id, "hosts");
            }
        }
    }
    // This round sees the table as it is now, the forgets above included: they do not call for
    // another round. A change from here on does.
    changes.borrow_and_update();
    for (from, id, port, on) in state.sinks.take_heard() {
        note(told, &from, &id, port, on);
    }
    let hosts: Vec<String> = known_hosts(&state.home).into_iter().map(|h| h.id).filter(|h| Some(h) != own.as_ref()).collect();
    told.retain(|h, _| hosts.contains(h));
    let mut sinks = state.sinks.remote();
    if let (Some(own), Some(port)) = (&own, state.sinks.local()) {
        sinks.push((own.clone(), port));
    }
    let plan = tell_plan(&hosts, &sinks, told);
    if plan.is_empty() {
        return;
    }
    let mut sends = JoinSet::new();
    for (host, say) in plan {
        let state = state.clone();
        sends.spawn(async move {
            let mut done = Vec::new();
            for (id, port, on) in say {
                let op = Op::StateSink { id: id.clone(), port, on };
                let got = tokio::time::timeout(crate::ipc::HOSTS_WAIT, pipe::set(&state, &host, &op)).await;
                done.push(((id, port, on), matches!(got, Ok(Ok(_)) | Ok(Err(PipeErr::Old)))));
            }
            (host, done)
        });
    }
    let (mut sent, mut failed) = (0, 0);
    while let Some(Ok((host, done))) = sends.join_next().await {
        for ((id, port, on), told_it) in done {
            if told_it {
                sent += 1;
                note(told, &host, &id, port, on);
            } else {
                failed += 1;
            }
        }
    }
    state.log.event(Lvl::Info, "state_sink_told", json!({"sent": sent, "failed": failed}));
}

#[cfg(test)]
mod tests {
    use super::*;

    fn s(id: &str, port: u16) -> (String, u16) {
        (id.to_string(), port)
    }

    #[test]
    fn the_smallest_id_wins() {
        let dir = tempfile::tempdir().unwrap();
        let (sinks, why) = Sinks::load(dir.path());
        assert_eq!(why, None);
        assert_eq!(sinks.dest(Some("333333333")), None);
        assert!(sinks.learn("222222222", 1));
        assert!(sinks.learn("111111111", 2));
        assert!(sinks.set_local(Some(3)));
        assert!(!sinks.set_local(Some(3)));
        assert_eq!(sinks.dest(Some("333333333")), Some(Dest::Remote { id: "111111111".into(), port: 2 }));
        assert_eq!(sinks.dest(Some("000000001")), Some(Dest::Local(3)));
        assert_eq!(sinks.dest(None), Some(Dest::Local(3)));
        assert!(sinks.set_local(None));
        assert_eq!(sinks.dest(None), Some(Dest::Remote { id: "111111111".into(), port: 2 }));
    }

    #[test]
    fn learned_sinks_survive_a_restart() {
        let dir = tempfile::tempdir().unwrap();
        let (sinks, _) = Sinks::load(dir.path());
        let mut rx = sinks.subscribe();
        assert!(sinks.learn("222222222", 8102));
        assert!(rx.has_changed().unwrap());
        rx.borrow_and_update();
        assert!(!sinks.learn("222222222", 8102), "the same again is no change");
        assert!(!rx.has_changed().unwrap());
        assert!(sinks.learn("111111111", 8103));
        let (again, why) = Sinks::load(dir.path());
        assert_eq!(why, None);
        assert_eq!(again.remote(), sinks.remote());
        assert_eq!(again.remote(), [s("111111111", 8103), s("222222222", 8102)]);
        assert!(sinks.forget("111111111") && sinks.forget("222222222"));
        assert!(!sinks.forget("222222222"));
        let text: Value = serde_json::from_slice(&std::fs::read(dir.path().join(FILE)).unwrap()).unwrap();
        assert_eq!(text, json!([]));
        // An unreadable file is no sinks, and says why.
        std::fs::write(dir.path().join(FILE), "{ not json").unwrap();
        let (bad, why) = Sinks::load(dir.path());
        assert!(why.is_some() && bad.remote().is_empty());
    }

    #[test]
    fn a_share_list_without_the_kind_forgets() {
        let dir = tempfile::tempdir().unwrap();
        let (sinks, _) = Sinks::load(dir.path());
        let (me, id) = (Some("999999999"), "222222222");
        // What `saw` does with what `seen` says.
        let saw = |id: &str, items: &[Value]| {
            if let Some(port) = seen(me, id, items) {
                sinks.change(id, port, None);
            }
        };
        saw(id, &[json!({"port": 8000}), json!({"port": 8102, "kind": "state"})]);
        assert_eq!(sinks.remote(), [s(id, 8102)]);
        saw(id, &[json!({"port": 8102})]);
        assert!(sinks.remote().is_empty());
        // Not a device ID, or this device itself: the list is not looked at.
        assert_eq!(seen(me, "gpu1", &[json!({"port": 8102, "kind": "state"})]), None);
        assert_eq!(seen(me, "999999999", &[json!({"port": 8102, "kind": "state"})]), None);
        assert_eq!(seen(me, id, &[json!({"port": 0, "kind": "state"})]), Some(None));
    }

    #[test]
    fn what_to_tell_each_host() {
        let hosts = ["111111111".to_string(), "222222222".to_string()];
        let on = |id: &str, port| (id.to_string(), port, true);
        let off = |id: &str, port| (id.to_string(), port, false);
        let mut told = Told::new();
        // Nothing known, nothing told: nothing to say.
        assert!(tell_plan(&hosts, &[], &told).is_empty());
        // A sink on 222222222: the other host is told, 222222222 is not told about itself.
        let sinks = [s("222222222", 8102)];
        assert_eq!(tell_plan(&hosts, &sinks, &told), [("111111111".to_string(), vec![on("222222222", 8102)])]);
        // Told the same before: nothing to say.
        told.insert("111111111".into(), vec![on("222222222", 8102)]);
        assert!(tell_plan(&hosts, &sinks, &told).is_empty());
        // A second sink elsewhere: both hosts hear of it, the sink's host too.
        let sinks = [s("222222222", 8102), s("333333333", 8102)];
        assert_eq!(
            tell_plan(&hosts, &sinks, &told),
            [("111111111".to_string(), vec![on("333333333", 8102)]), ("222222222".to_string(), vec![on("333333333", 8102)])]
        );
        // A new port is told as `on` (the receiver replaces the old one), not `off` first.
        let moved = [s("222222222", 9000)];
        assert_eq!(tell_plan(&hosts[..1], &moved, &told), [("111111111".to_string(), vec![on("222222222", 9000)])]);
        // Gone: the host told of it hears `off`.
        assert_eq!(tell_plan(&hosts, &[], &told), [("111111111".to_string(), vec![off("222222222", 8102)])]);
        // Once `off` is told, nothing is left to say.
        note(&mut told, "111111111", "222222222", 8102, false);
        assert!(tell_plan(&hosts, &[], &told).is_empty());
    }
}
