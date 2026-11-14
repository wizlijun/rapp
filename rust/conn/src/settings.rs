//! The relay and key a device is set up with, as `service.json` keeps them. The service owns the file;
//! the hub only reads it (every time it needs it, so a change takes effect without a restart).

use std::path::Path;

use rapp_wire::Key;
use serde::Deserialize;

#[derive(Default)]
pub struct Settings {
    /// The relay as `host:port`.
    pub relay: Option<String>,
    pub key: Option<Key>,
}

#[derive(Deserialize, Default)]
struct File {
    relay: Option<String>,
    key: Option<String>,
}

/// `<home>/service.json`'s `relay` and `key`; a file that cannot be read or parsed, an empty value or
/// a key that does not parse counts as not set.
pub fn load(home: &Path) -> Settings {
    let file: File = rapp_net::config::read_json(&home.join("service.json")).ok().flatten().unwrap_or_default();
    Settings {
        relay: file.relay.filter(|r| !r.is_empty()),
        key: file.key.filter(|k| !k.is_empty()).and_then(|k| k.parse().ok()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn with(json: &str) -> Settings {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join("service.json"), json).unwrap();
        load(dir.path())
    }

    #[test]
    fn reads_relay_and_key_and_treats_anything_unusable_as_unset() {
        let key = Key::new_local();
        let s = with(&format!(r#"{{"id":"1","relay":"vps:22026","key":"{key}"}}"#));
        assert_eq!(s.relay.as_deref(), Some("vps:22026"));
        assert_eq!(s.key.map(|k| k.to_string()), Some(key.to_string()));
        for bad in [r#"{"relay":"","key":""}"#, r#"{"key":"rappxyz"}"#, "{not json", "{}", r#"{"relay":7}"#] {
            let s = with(bad);
            assert!(s.relay.is_none() && s.key.is_none(), "{bad}");
        }
        assert!(load(tempfile::tempdir().unwrap().path()).key.is_none());
    }
}
