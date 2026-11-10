//! State shared by the relay link, the peer server, the workers and IPC.

use crate::config::Config;
use crate::workers::Workers;
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

pub struct Session {
    pub peer: String,
    pub app: String,
    pub path: &'static str,
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
    /// relay token → (B's public address, expiry)
    pub tokens: Mutex<HashMap<String, (String, Instant)>>,
    pub sessions: Mutex<(u64, BTreeMap<u64, Session>)>,
    /// ("off" | "connecting" | "connected", last error)
    pub relay: Mutex<(&'static str, Option<String>)>,
    pub permissions: Value,
    pub workers: Workers,
    pub changed: watch::Sender<u64>,
    pub relay_cmd: mpsc::UnboundedSender<RelayCmd>,
    pub cm: Mutex<Option<std::process::Child>>,
}

impl State {
    pub fn notify(&self) {
        self.changed.send_modify(|n| *n += 1);
    }

    pub fn set_relay_status(&self, status: &'static str, error: Option<String>) {
        let mut r = self.relay.lock().unwrap();
        if r.0 != status || r.1 != error {
            *r = (status, error);
            drop(r);
            self.notify();
        }
    }

    pub fn add_token(&self, token: String, peer: String) {
        let now = Instant::now();
        let mut t = self.tokens.lock().unwrap();
        t.retain(|_, (_, exp)| *exp > now);
        t.insert(token, (peer, now + TOKEN_TTL));
    }

    /// B's address for a valid token.
    pub fn token_peer(&self, token: &str) -> Option<String> {
        let t = self.tokens.lock().unwrap();
        t.get(token).filter(|(_, exp)| *exp > Instant::now()).map(|(p, _)| p.clone())
    }

    pub fn add_session(&self, peer: String, app: &str, path: &'static str) -> (u64, Arc<Notify>) {
        let kick = Arc::new(Notify::new());
        let since = SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |d| d.as_secs());
        let mut s = self.sessions.lock().unwrap();
        s.0 += 1;
        let sid = s.0;
        s.1.insert(sid, Session { peer, app: app.to_string(), path, since, kick: kick.clone() });
        drop(s);
        self.notify();
        (sid, kick)
    }

    pub fn end_session(&self, sid: u64) {
        self.sessions.lock().unwrap().1.remove(&sid);
        self.notify();
    }

    pub fn kick(&self, sid: u64) -> bool {
        let s = self.sessions.lock().unwrap();
        s.1.get(&sid).map(|s| s.kick.notify_one()).is_some()
    }

    pub fn status(&self) -> Value {
        let cfg = self.cfg.lock().unwrap().clone();
        let (relay, relay_error) = self.relay.lock().unwrap().clone();
        let sessions: Vec<Value> = self.sessions.lock().unwrap().1.iter()
            .map(|(sid, s)| json!({"sid":sid,"peer":s.peer,"app":s.app,"path":s.path,"since":s.since}))
            .collect();
        let id = cfg.id.clone().unwrap_or_default();
        let lan_ids: Vec<String> =
            rapp_net::addr::local_ipv4s().into_iter().map(|ip| rapp_net::addr::at_address(&id, ip, self.port)).collect();
        let mut v = json!({
            "ok": true, "id": cfg.id, "name": cfg.name, "password": cfg.password, "lan_ids": lan_ids,
            "relay": relay, "permissions": self.permissions, "sessions": sessions,
        });
        if let Some(e) = relay_error {
            v["relay_error"] = json!(e);
        }
        v
    }
}
