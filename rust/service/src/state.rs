//! State shared by the relay link, the peer server, the workers and IPC.

use crate::config::Config;
use crate::workers::Workers;
use rapp_net::log::{Log, Lvl};
use serde_json::{json, Value};
use std::collections::{BTreeMap, HashMap};
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use tokio::sync::{mpsc, watch, Notify};

pub const TOKEN_TTL: Duration = Duration::from_secs(24 * 3600);

/// What the IPC tells the relay link.
pub enum RelayCmd {
    /// Password changed: register again on the current connection.
    Reregister,
    /// Relay address or key changed: drop the connection and start over.
    Reconnect,
}

/// Who is on the other end of a request: B's address, its self-declared name, and the path.
#[derive(Clone, Debug)]
pub struct Peer {
    pub addr: String,
    /// "自称" (observability spec §4.1): whatever B sent, never checked.
    pub name: Option<String>,
    /// "lan" | "direct" | "relay"
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

/// A relay token's (B's public address, B's self-declared name, expiry).
pub type Token = (String, Option<String>, Instant);

pub struct Session {
    pub peer: Peer,
    pub app: String,
    /// A file-transfer side connection, not a viewing session.
    pub side: bool,
    pub since: u64,
    pub kick: Arc<Notify>,
}

pub struct State {
    pub home: PathBuf,
    pub bin_dir: Option<PathBuf>,
    pub gui: Option<PathBuf>,
    pub endpoint: quinn::Endpoint,
    pub port: u16,
    pub cfg: Mutex<Config>,
    pub tokens: Mutex<HashMap<String, Token>>,
    pub sessions: Mutex<(u64, BTreeMap<u64, Session>)>,
    /// ("off" | "connecting" | "connected", last error)
    pub relay: Mutex<(&'static str, Option<String>)>,
    /// `{"screen_recording","accessibility"}` as last checked.
    pub permissions: Mutex<Value>,
    /// An update was installed while both permissions were granted, and now one is missing (K23).
    pub perms_lost: Mutex<bool>,
    pub workers: Workers,
    pub changed: watch::Sender<u64>,
    pub relay_cmd: mpsc::UnboundedSender<RelayCmd>,
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

    pub fn set_relay_status(&self, status: &'static str, error: Option<String>) {
        let mut r = self.relay.lock().unwrap();
        if r.0 != status || r.1 != error {
            let mut fields = json!({"state": status});
            if let Some(e) = &error {
                fields["error"] = json!(e);
            }
            *r = (status, error);
            drop(r);
            let lvl = if fields.get("error").is_some() { Lvl::Warn } else { Lvl::Info };
            self.log.event(lvl, "relay", fields);
            self.notify();
        }
    }

    pub fn add_token(&self, token: String, peer: String, name: Option<String>) {
        let now = Instant::now();
        let mut t = self.tokens.lock().unwrap();
        t.retain(|_, (_, _, exp)| *exp > now);
        t.insert(token, (peer, name, now + TOKEN_TTL));
    }

    /// B's address and self-declared name for a valid token.
    pub fn token_peer(&self, token: &str) -> Option<(String, Option<String>)> {
        let t = self.tokens.lock().unwrap();
        t.get(token).filter(|(_, _, exp)| *exp > Instant::now()).map(|(p, n, _)| (p.clone(), n.clone()))
    }

    pub fn add_session(&self, peer: &Peer, app: &str, side: bool) -> (u64, Arc<Notify>) {
        let kick = Arc::new(Notify::new());
        let since = SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |d| d.as_secs());
        let mut s = self.sessions.lock().unwrap();
        s.0 += 1;
        let sid = s.0;
        s.1.insert(sid, Session { peer: peer.clone(), app: app.to_string(), side, since, kick: kick.clone() });
        drop(s);
        self.notify();
        (sid, kick)
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
        let s = self.sessions.lock().unwrap();
        s.1.iter().rev().find(|(_, s)| s.app == app && !s.side).map(|(sid, _)| *sid)
    }

    pub fn status(&self) -> Value {
        let cfg = self.cfg.lock().unwrap().clone();
        let (relay, relay_error) = self.relay.lock().unwrap().clone();
        let sessions: Vec<Value> = self.sessions.lock().unwrap().1.iter()
            .map(|(sid, s)| json!({"sid":sid,"peer":s.peer.addr,"app":s.app,"path":s.peer.path,"since":s.since}))
            .collect();
        let id = cfg.id.clone().unwrap_or_default();
        let lan_ids: Vec<String> =
            rapp_net::addr::local_ipv4s().into_iter().map(|ip| rapp_net::addr::at_address(&id, ip, self.port)).collect();
        let mut v = json!({
            "ok": true, "id": cfg.id, "name": cfg.name, "password": cfg.password, "lan_ids": lan_ids,
            "relay": relay, "permissions": self.permissions.lock().unwrap().clone(),
            "permissions_lost_after_update": *self.perms_lost.lock().unwrap(), "sessions": sessions,
            "log_dir": self.log_dir, "update": crate::update::status_json(self),
        });
        if let Some(e) = relay_error {
            v["relay_error"] = json!(e);
        }
        v
    }
}
