//! `service.json` (0600): relay, key, id, secret, name, password, optional ports (spec §3).

use anyhow::Result;
use rapp_net::crypto::{random_hex, random_password};
use serde::{Deserialize, Serialize};
use std::path::Path;

pub const DEFAULT_PORT: u16 = 21118;
pub const DEFAULT_IPC_PORT: u16 = 21119;

#[derive(Clone, Default, Serialize, Deserialize)]
pub struct Config {
    #[serde(default)]
    pub relay: Option<String>,
    #[serde(default)]
    pub key: Option<String>,
    #[serde(default)]
    pub id: Option<String>,
    #[serde(default)]
    pub secret: String,
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub password: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub port: Option<u16>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ipc_port: Option<u16>,
}

impl Config {
    /// Reads `service.json`, filling in secret / password / name on first start.
    pub fn load_or_init(home: &Path) -> Result<Config> {
        let path = home.join("service.json");
        let mut cfg: Config = rapp_net::config::read_json(&path)?.unwrap_or_default();
        let fresh = cfg.secret.is_empty() || cfg.password.is_empty() || cfg.name.is_empty();
        if cfg.secret.is_empty() {
            cfg.secret = random_hex(32);
        }
        if cfg.password.is_empty() {
            cfg.password = random_password();
        }
        if cfg.name.is_empty() {
            cfg.name = hostname();
        }
        if fresh {
            cfg.save(home)?;
        }
        Ok(cfg)
    }

    pub fn save(&self, home: &Path) -> Result<()> {
        rapp_net::config::write_json(&home.join("service.json"), self)
    }

    /// `(relay, key)` when a relay is configured.
    pub fn relay(&self) -> Option<(String, String)> {
        let relay = self.relay.clone().filter(|r| !r.is_empty())?;
        Some((relay, self.key.clone().unwrap_or_default()))
    }
}

fn hostname() -> String {
    std::process::Command::new("hostname")
        .output()
        .ok()
        .and_then(|o| String::from_utf8(o.stdout).ok())
        .map(|s| s.trim().trim_end_matches(".local").to_string())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "rapp".into())
}
