//! `service.json` (0600): relay, key, id, secret, name, password, optional ports (spec §3).

use anyhow::Result;
use rapp_net::crypto::{is_valid_id, random_hex, random_id, random_password};
use serde::{Deserialize, Serialize};
use std::path::Path;

pub const DEFAULT_PORT: u16 = rapp_net::addr::DEFAULT_PEER_PORT;
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
    /// Where `latest.json` is fetched from; `rapp_update::DEFAULT_URL` when unset.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub update_url: Option<String>,
    /// Install by itself when nobody is using rapp (default true).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub auto_update: Option<bool>,
    /// The scheduled checks (default true); the 检查更新 button works either way.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub check_updates: Option<bool>,
}

impl Config {
    /// Reads `service.json`, filling in id / secret / password / name on first start.
    /// The ID is picked here, not by the relay, so it exists before any relay is set;
    /// the relay accepts a valid ID it has not seen (spec §2.2).
    pub fn load_or_init(home: &Path) -> Result<Config> {
        let path = home.join("service.json");
        let mut cfg: Config = rapp_net::config::read_json(&path)?.unwrap_or_default();
        let has_id = cfg.id.as_deref().is_some_and(is_valid_id);
        let fresh = !has_id || cfg.secret.is_empty() || cfg.password.is_empty() || cfg.name.is_empty();
        if !has_id {
            cfg.id = Some(random_id());
        }
        if cfg.secret.is_empty() {
            cfg.secret = random_hex(32);
        }
        if cfg.password.is_empty() {
            cfg.password = random_password();
        }
        if cfg.name.is_empty() {
            cfg.name = rapp_net::config::hostname();
        }
        if fresh {
            cfg.save(home)?;
        }
        Ok(cfg)
    }

    pub fn save(&self, home: &Path) -> Result<()> {
        rapp_net::config::write_json(&home.join("service.json"), self)
    }

    pub fn update_url(&self) -> String {
        self.update_url.clone().unwrap_or_else(|| rapp_update::DEFAULT_URL.to_string())
    }

    pub fn auto_update(&self) -> bool {
        self.auto_update.unwrap_or(true)
    }

    pub fn check_updates(&self) -> bool {
        self.check_updates.unwrap_or(true)
    }

    /// `(relay, key)` when a relay is configured.
    pub fn relay(&self) -> Option<(String, String)> {
        let relay = self.relay.clone().filter(|r| !r.is_empty())?;
        Some((relay, self.key.clone().unwrap_or_default()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use rapp_net::crypto::is_valid_id;

    #[test]
    fn first_start_picks_its_own_id_and_keeps_it() {
        let dir = tempfile::tempdir().unwrap();
        let cfg = Config::load_or_init(dir.path()).unwrap();
        let id = cfg.id.clone().expect("an ID without any relay");
        assert!(is_valid_id(&id));
        assert_eq!(Config::load_or_init(dir.path()).unwrap().id, Some(id));
    }

    #[test]
    fn existing_id_is_kept() {
        let dir = tempfile::tempdir().unwrap();
        let old = Config { id: Some("123456789".into()), ..Default::default() };
        old.save(dir.path()).unwrap();
        assert_eq!(Config::load_or_init(dir.path()).unwrap().id.as_deref(), Some("123456789"));
    }
}
