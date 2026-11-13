//! `hosts.json` (0600): `[{"id","name","password","lan":[...]}]`. Password in clear (D8).

use anyhow::Result;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::path::{Path, PathBuf};
use std::sync::Mutex;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Host {
    pub id: String,
    pub name: String,
    pub password: String,
    #[serde(default)]
    pub lan: Vec<String>,
}

pub struct Hosts {
    path: PathBuf,
    list: Mutex<Vec<Host>>,
}

impl Hosts {
    pub fn load(home: &Path) -> Result<Hosts> {
        let path = home.join("hosts.json");
        let list = rapp_net::config::read_json(&path)?.unwrap_or_default();
        Ok(Hosts { path, list: Mutex::new(list) })
    }

    pub fn get(&self, id: &str) -> Option<Host> {
        self.list.lock().unwrap().iter().find(|h| h.id == id).cloned()
    }

    pub fn all(&self) -> Vec<Host> {
        self.list.lock().unwrap().clone()
    }

    /// `[{"id","name"}]`
    pub fn summary(&self) -> Value {
        let list = self.list.lock().unwrap();
        // `lan` (A's LAN addresses, for 屏幕共享) only when known; the password never leaves the hub.
        let row = |h: &Host| {
            let mut v = json!({"id": h.id, "name": h.name});
            if !h.lan.is_empty() {
                v["lan"] = json!(h.lan);
            }
            v
        };
        Value::Array(list.iter().map(row).collect())
    }

    /// Inserts or replaces by id; saves only when something changed.
    pub fn upsert(&self, host: Host) -> Result<()> {
        let mut list = self.list.lock().unwrap();
        match list.iter_mut().find(|h| h.id == host.id) {
            Some(h) if *h == host => return Ok(()),
            Some(h) => *h = host,
            None => list.push(host),
        }
        rapp_net::config::write_json(&self.path, &*list)
    }

    /// Like `upsert`, but only for a host that is still saved (a removed host stays removed).
    pub fn refresh(&self, host: Host) -> Result<()> {
        let mut list = self.list.lock().unwrap();
        match list.iter_mut().find(|h| h.id == host.id) {
            Some(h) if *h == host => Ok(()),
            Some(h) => {
                *h = host;
                rapp_net::config::write_json(&self.path, &*list)
            }
            None => Ok(()),
        }
    }

    pub fn remove(&self, id: &str) -> Result<()> {
        let mut list = self.list.lock().unwrap();
        let before = list.len();
        list.retain(|h| h.id != id);
        if list.len() == before {
            return Ok(());
        }
        rapp_net::config::write_json(&self.path, &*list)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn host(name: &str) -> Host {
        Host { id: "1".into(), name: name.into(), password: "p".into(), lan: vec![] }
    }

    #[test]
    fn refresh_updates_a_saved_host_but_never_resurrects_a_removed_one() {
        let dir = tempfile::tempdir().unwrap();
        let hosts = Hosts::load(dir.path()).unwrap();
        hosts.refresh(host("a")).unwrap();
        assert!(hosts.all().is_empty());
        hosts.upsert(host("a")).unwrap();
        hosts.refresh(host("b")).unwrap();
        assert_eq!(hosts.get("1").unwrap().name, "b");
        hosts.remove("1").unwrap();
        hosts.refresh(host("c")).unwrap();
        assert!(hosts.all().is_empty());
        assert_eq!(std::fs::read_to_string(dir.path().join("hosts.json")).unwrap().trim(), "[]");
    }

    #[test]
    fn summary_carries_lan_addresses_only_when_known_and_never_the_password() {
        let dir = tempfile::tempdir().unwrap();
        let hosts = Hosts::load(dir.path()).unwrap();
        hosts.upsert(host("a")).unwrap();
        hosts.upsert(Host { id: "2".into(), name: "b".into(), password: "secret".into(), lan: vec!["192.168.1.5:21118".into()] }).unwrap();
        assert_eq!(
            hosts.summary(),
            json!([{"id": "1", "name": "a"}, {"id": "2", "name": "b", "lan": ["192.168.1.5:21118"]}])
        );
        assert!(!hosts.summary().to_string().contains("secret"));
    }
}
