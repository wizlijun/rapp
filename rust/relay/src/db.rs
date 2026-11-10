//! `relay.json`: `{id: {secret_hash, pw_salt, pw_hash, name}}`, rewritten whole on change.

use anyhow::Result;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::Path;

#[derive(Clone, Serialize, Deserialize)]
pub struct Device {
    pub secret_hash: String,
    pub pw_salt: String,
    pub pw_hash: String,
    pub name: String,
}

pub type Db = HashMap<String, Device>;

pub fn load(path: &Path) -> Result<Db> {
    Ok(rapp_net::config::read_json(path)?.unwrap_or_default())
}

pub fn save(path: &Path, db: &Db) -> Result<()> {
    rapp_net::config::write_json(path, db)
}
