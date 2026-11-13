//! State shared by the peer server, the workers and IPC.

use crate::config::Config;
use crate::workers::Workers;
use rapp_net::log::{Log, Lvl};
use serde_json::{json, Value};
use std::collections::BTreeMap;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::{SystemTime, UNIX_EPOCH};
use tokio::sync::{watch, Notify};

/// Who is on the other end of a request: B's address, its self-declared name, and the path.
#[derive(Clone, Debug)]
pub struct Peer {
    pub addr: String,
    /// "自称" (observability spec §4.1): whatever B sent, never checked.
    pub name: Option<String>,
    /// "lan" | "direct"; "direct" now only shows on `auth_fail` lines (public sources cannot authenticate).
    pub path: &'static str,
}

impl Peer {
    /// `{"peer","name"?,"path"}` plus `more` (an object), for log events.
    /// `session_start` / `session_end` fields (observability spec §4.1).
    pub fn session_fields(&self, app: &str, side: bool, sid: u64) -> Value {
        let mut more = json!({"app": app, "sid": sid});
        if side {
            more["side"] = json!(true);
        }
        self.fields(more)
    }

    pub fn fields(&self, more: Value) -> Value {
        let mut v = json!({"peer": self.addr, "path": self.path});
        if let Some(n) = &self.name {
            v["name"] = json!(n);
        }
        if let Value::Object(m) = more {
            v.as_object_mut().expect("object").extend(m);
        }
        v
    }
}

pub struct Session {
    pub peer: Peer,
    pub app: String,
    /// A file-transfer side connection, not a viewing session.
    pub side: bool,
    pub since: u64,
    pub kick: Arc<Notify>,
    /// Set when the worker said this session was taken over: by whom, if it said.
    pub taken: Option<Option<String>>,
    /// Woken when `taken` is set.
    pub taken_notify: Arc<Notify>,
}

pub struct State {
    pub home: PathBuf,
    pub bin_dir: Option<PathBuf>,
    pub gui: Option<PathBuf>,
    pub endpoint: quinn::Endpoint,
    pub port: u16,
    pub cfg: Mutex<Config>,
    pub sessions: Mutex<(u64, BTreeMap<u64, Session>)>,
    /// `{"screen_recording","accessibility"}` as last checked.
    pub permissions: Mutex<Value>,
    /// An update was installed while both permissions were granted, and now one is missing (K23).
    pub perms_lost: Mutex<bool>,
    pub workers: Workers,
    pub changed: watch::Sender<u64>,
    pub cm: Mutex<Option<std::process::Child>>,
    pub log: Log,
    pub log_dir: PathBuf,
    /// Every external program the updater runs (a FakeRunner in tests).
    pub runner: Arc<dyn rapp_update::Runner>,
    pub update: Mutex<crate::update::UpdState>,
    /// None: not running from a `.app`, so the updater is off.
    pub update_opts: Option<crate::UpdateOpts>,
    /// Set to true once a new version is in place; `main` then stops and exits 0.
    pub restart: watch::Sender<bool>,
}

impl State {
    pub fn notify(&self) {
        self.changed.send_modify(|n| *n += 1);
    }

    /// Stores a fresh permission check; subscribers hear about it only if it changed.
    pub fn set_permissions(&self, v: Value) {
        let changed = std::mem::replace(&mut *self.permissions.lock().unwrap(), v.clone()) != v;
        let all = v["screen_recording"] == true && v["accessibility"] == true;
        let cleared = all && std::mem::replace(&mut *self.perms_lost.lock().unwrap(), false);
        if changed || cleared {
            if changed {
                self.log.event(if all { Lvl::Info } else { Lvl::Warn }, "permissions", v);
            }
            self.notify();
        }
    }

    /// The new session's sid, its kick, and what wakes it when it is marked taken over.
    pub fn add_session(&self, peer: &Peer, app: &str, side: bool) -> (u64, Arc<Notify>, Arc<Notify>) {
        let (kick, taken_notify) = (Arc::new(Notify::new()), Arc::new(Notify::new()));
        let since = SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |d| d.as_secs());
        let mut s = self.sessions.lock().unwrap();
        s.0 += 1;
        let sid = s.0;
        let session = Session {
            peer: peer.clone(),
            app: app.to_string(),
            side,
            since,
            kick: kick.clone(),
            taken: None,
            taken_notify: taken_notify.clone(),
        };
        s.1.insert(sid, session);
        drop(s);
        self.notify();
        (sid, kick, taken_notify)
    }

    /// The worker for `app` ended a session as taken over: marks the newest viewing session on
    /// `app` that is not the newest one (that is the one that took over) and not marked yet.
    pub fn mark_taken_over(&self, app: &str, by: Option<String>) {
        let mut s = self.sessions.lock().unwrap();
        let older = s.1.values_mut().rev().filter(|s| s.app == app && !s.side).skip(1).find(|s| s.taken.is_none());
        if let Some(old) = older {
            old.taken = Some(by);
            old.taken_notify.notify_one();
        }
    }

    /// Whether the worker said `sid` was taken over, and by whom.
    pub fn taken_over(&self, sid: u64) -> Option<Option<String>> {
        self.sessions.lock().unwrap().1.get(&sid).and_then(|s| s.taken.clone())
    }

    /// False when the session was already ended (by `end_all` at stop).
    pub fn end_session(&self, sid: u64) -> bool {
        let found = self.sessions.lock().unwrap().1.remove(&sid).is_some();
        self.notify();
        found
    }

    /// Takes every open session (service stopping).
    pub fn end_all(&self) -> BTreeMap<u64, Session> {
        let all = std::mem::take(&mut self.sessions.lock().unwrap().1);
        self.notify();
        all
    }

    pub fn kick(&self, sid: u64) -> bool {
        let s = self.sessions.lock().unwrap();
        let found = s.1.get(&sid).map(|s| s.kick.notify_one()).is_some();
        drop(s);
        if found {
            self.log.event(Lvl::Info, "kick", json!({"sid": sid}));
        }
        found
    }

    /// The newest viewing session (not a side connection) on `app`.
    pub fn session_for(&self, app: &str) -> Option<u64> {
        self.live_session(app).map(|(sid, _)| sid)
    }

    /// The newest viewing session (not a side connection) on `app`, with its peer.
    pub fn live_session(&self, app: &str) -> Option<(u64, Peer)> {
        let s = self.sessions.lock().unwrap();
        s.1.iter().rev().find(|(_, s)| s.app == app && !s.side).map(|(sid, s)| (*sid, s.peer.clone()))
    }

    /// A viewing session on `app` started after `sid` (the newest one), if any.
    pub fn newer_session(&self, app: &str, sid: u64) -> Option<Peer> {
        let s = self.sessions.lock().unwrap();
        s.1.range(sid + 1..).rev().find(|(_, s)| s.app == app && !s.side).map(|(_, s)| s.peer.clone())
    }

    /// Every app with a viewing session, with the peer of its newest one.
    pub fn live_sessions(&self) -> BTreeMap<String, Peer> {
        let s = self.sessions.lock().unwrap();
        s.1.values().filter(|s| !s.side).map(|s| (s.app.clone(), s.peer.clone())).collect()
    }

    pub fn status(&self) -> Value {
        let cfg = self.cfg.lock().unwrap().clone();
        let sessions: Vec<Value> = self.sessions.lock().unwrap().1.iter()
            .map(|(sid, s)| json!({"sid":sid,"peer":s.peer.addr,"app":s.app,"path":s.peer.path,"since":s.since}))
            .collect();
        let id = cfg.id.clone().unwrap_or_default();
        let lan_ids: Vec<String> =
            rapp_net::addr::local_ipv4s().into_iter().map(|ip| rapp_net::addr::at_address(&id, ip, self.port)).collect();
        json!({
            "ok": true, "id": cfg.id, "name": cfg.name, "password": cfg.password, "lan_ids": lan_ids,
            "permissions": self.permissions.lock().unwrap().clone(),
            "permissions_lost_after_update": *self.perms_lost.lock().unwrap(), "sessions": sessions,
            "log_dir": self.log_dir, "update": crate::update::status_json(self),
        })
    }
}
