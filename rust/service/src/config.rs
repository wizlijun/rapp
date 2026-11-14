//! `service.json` (0600): id, name, password, optional ports (spec §3).

use anyhow::Result;
use rapp_net::crypto::{is_valid_id, random_id, random_password};
use serde::{Deserialize, Serialize};
use std::path::Path;

pub const DEFAULT_PORT: u16 = rapp_net::addr::DEFAULT_PEER_PORT;
pub const DEFAULT_IPC_PORT: u16 = 22029;

#[derive(Clone, Default, Serialize, Deserialize)]
pub struct Config {
    #[serde(default)]
    pub id: Option<String>,
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
    /// The relay as `host:port`; with `key`, the service keeps a connection to it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub relay: Option<String>,
    /// The key text (`rapp…`); devices holding the same key trust each other.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub key: Option<String>,
    /// Set by `load_or_init` when it dropped a 0.5.5 (relay1) `relay` + `key`; never saved.
    #[serde(skip)]
    pub legacy_dropped: bool,
}

impl Config {
    /// Reads `service.json`, filling in id / password / name on first start.
    /// An old `secret` field is ignored and drops out on the next save; empty `relay` / `key` count as unset.
    /// A `key` that is not a 0.6 key (0.5.5's relay1 key) is dropped with its `relay`, and the file saved.
    pub fn load_or_init(home: &Path) -> Result<Config> {
        let path = home.join("service.json");
        let mut cfg: Config = rapp_net::config::read_json(&path)?.unwrap_or_default();
        cfg.relay = cfg.relay.take().filter(|s| !s.is_empty());
        cfg.key = cfg.key.take().filter(|s| !s.is_empty());
        if cfg.key.as_deref().is_some_and(|k| k.parse::<rapp_wire::Key>().is_err()) {
            (cfg.relay, cfg.key, cfg.legacy_dropped) = (None, None, true);
        }
        let has_id = cfg.id.as_deref().is_some_and(is_valid_id);
        let fresh = !has_id || cfg.password.is_empty() || cfg.name.is_empty() || cfg.legacy_dropped;
        if !has_id {
            cfg.id = Some(random_id());
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
}

#[cfg(test)]
mod tests {
    use super::*;
    use rapp_net::crypto::is_valid_id;

    #[test]
    fn first_start_picks_its_own_id_and_keeps_it() {
        let dir = tempfile::tempdir().unwrap();
        let cfg = Config::load_or_init(dir.path()).unwrap();
        let id = cfg.id.clone().expect("an ID of its own");
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

    #[test]
    fn a_relay1_key_is_dropped_with_its_relay_and_a_0_6_key_kept() {
        let dir = tempfile::tempdir().unwrap();
        let key = rapp_wire::Key::new_local().to_string();
        let good = Config { relay: Some("vps:22026".into()), key: Some(key.clone()), ..Default::default() };
        good.save(dir.path()).unwrap();
        let cfg = Config::load_or_init(dir.path()).unwrap();
        assert_eq!(
            (cfg.relay.as_deref(), cfg.key.as_deref(), cfg.legacy_dropped),
            (Some("vps:22026"), Some(&*key), false)
        );
        let old = Config { relay: Some("vps:21116".into()), key: Some("relay1-key".into()), ..Default::default() };
        old.save(dir.path()).unwrap();
        let cfg = Config::load_or_init(dir.path()).unwrap();
        assert_eq!((cfg.relay.as_deref(), cfg.key.as_deref(), cfg.legacy_dropped), (None, None, true));
        let again = Config::load_or_init(dir.path()).unwrap();
        assert!(!again.legacy_dropped && again.relay.is_none(), "saved without them");
    }
}
