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
        Value::Array(list.iter().map(|h| json!({"id": h.id, "name": h.name})).collect())
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
