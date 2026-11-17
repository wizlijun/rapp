//! The relay and key as `service.json` keeps them, for a hub that owns them (iOS: no service
//! process). `access` reads, `set_access` writes. The key is never logged or echoed.

use anyhow::{bail, Context, Result};
use rapp_wire::Key;
use serde_json::{json, Map, Value};
use std::path::Path;

/// The `access` event.
pub fn read(home: &Path, name: &str) -> Value {
    let s = rapp_conn::settings::load(home);
    json!({"event":"access","relay":s.relay,"has_key":s.key.is_some(),"name":name})
}

/// Sets `relay` and `key` in `<home>/service.json`, keeping its other fields. Nothing is written
/// when either is empty or the key does not parse.
pub fn write(home: &Path, relay: &str, key: &str) -> Result<()> {
    let (relay, key) = (relay.trim(), key.trim());
    if relay.is_empty() {
        bail!("missing relay");
    }
    if key.is_empty() || key.parse::<Key>().is_err() {
        bail!("bad key");
    }
    let path = home.join("service.json");
    let mut map: Map<String, Value> = rapp_net::config::read_json(&path).context("read service.json")?.unwrap_or_default();
    map.insert("relay".into(), relay.into());
    map.insert("key".into(), key.into());
    // Atomic and 0600: a temp file, then rename.
    rapp_net::config::write_json(&path, &map)
}
