//! `hosts.json` (0600): `[{"id","name","password","lan":[...],"fp"?}]`. Password in clear (D8); `""` for a host
//! added over `rapp/2`. `fp` is the fingerprint of the host's device key, once seen.

use anyhow::Result;
use rapp_wire::Fp;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::path::{Path, PathBuf};
use std::sync::Mutex;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Host {
    pub id: String,
    pub name: String,
    #[serde(default)]
    pub password: String,
    #[serde(default)]
    pub lan: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fp: Option<Fp>,
}

pub struct Hosts {
    /// The file and the list swap together (reload), so one lock.
    state: Mutex<(PathBuf, Vec<Host>)>,
}

impl Hosts {
    pub fn load(home: &Path) -> Result<Hosts> {
        let path = home.join("hosts.json");
        let list = rapp_net::config::read_json(&path)?.unwrap_or_default();
        Ok(Hosts { state: Mutex::new((path, list)) })
    }

    /// Switches to `<dir>/hosts.json` (absent = empty); on error the old file and list stay.
    pub fn reload(&self, dir: &Path) -> Result<()> {
        let path = dir.join("hosts.json");
        let list = rapp_net::config::read_json(&path)?.unwrap_or_default();
        *self.state.lock().unwrap() = (path, list);
        Ok(())
    }

    pub fn get(&self, id: &str) -> Option<Host> {
        self.state.lock().unwrap().1.iter().find(|h| h.id == id).cloned()
    }

    pub fn all(&self) -> Vec<Host> {
        self.state.lock().unwrap().1.clone()
    }

    /// `[{"id","name"}]`
    pub fn summary(&self) -> Value {
        let state = self.state.lock().unwrap();
        let list = &state.1;
        // `lan` (A's LAN addresses, for 屏幕共享) only when known; the password never leaves the hub.
        let row = |h: &Host| {
            let mut v = json!({"id": h.id, "name": h.name});
            if !h.lan.is_empty() {
                v["lan"] = json!(h.lan);
            }
            if let Some(fp) = &h.fp {
                v["fp"] = fp.to_string().into();
            }
            v
        };
        Value::Array(list.iter().map(row).collect())
    }

    /// Inserts or replaces by id; saves only when something changed.
    pub fn upsert(&self, host: Host) -> Result<()> {
        let mut state = self.state.lock().unwrap();
        let (path, list) = &mut *state;
        match list.iter_mut().find(|h| h.id == host.id) {
            Some(h) if *h == host => return Ok(()),
            Some(h) => *h = host,
            None => list.push(host),
        }
        rapp_net::config::write_json(path, &*list)
    }

    /// Remembers `fp` for a host that is still saved; true when that changed the file.
    pub fn set_fp(&self, id: &str, fp: Fp) -> Result<bool> {
        let mut state = self.state.lock().unwrap();
        let (path, list) = &mut *state;
        match list.iter_mut().find(|h| h.id == id) {
            Some(h) if h.fp != Some(fp) => h.fp = Some(fp),
            _ => return Ok(false),
        }
        rapp_net::config::write_json(path, &*list)?;
        Ok(true)
    }

    pub fn remove(&self, id: &str) -> Result<()> {
        let mut state = self.state.lock().unwrap();
        let (path, list) = &mut *state;
        let before = list.len();
        list.retain(|h| h.id != id);
        if list.len() == before {
            return Ok(());
        }
        rapp_net::config::write_json(path, &*list)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn host(name: &str) -> Host {
        Host { id: "1".into(), name: name.into(), password: "p".into(), lan: vec![], fp: None }
    }

    #[test]
    fn summary_carries_lan_addresses_only_when_known_and_never_the_password() {
        let dir = tempfile::tempdir().unwrap();
        let hosts = Hosts::load(dir.path()).unwrap();
        hosts.upsert(host("a")).unwrap();
        hosts
            .upsert(Host {
                id: "2".into(),
                name: "b".into(),
                password: "secret".into(),
                lan: vec!["192.168.1.5:22028".into()],
                fp: None,
            })
            .unwrap();
        assert_eq!(
            hosts.summary(),
            json!([{"id": "1", "name": "a"}, {"id": "2", "name": "b", "lan": ["192.168.1.5:22028"]}])
        );
        assert!(!hosts.summary().to_string().contains("secret"));
    }

    #[test]
    fn fp_is_listed_saved_and_set_only_on_a_saved_host() {
        let dir = tempfile::tempdir().unwrap();
        let hosts = Hosts::load(dir.path()).unwrap();
        hosts.upsert(host("a")).unwrap();
        let fp: Fp = "ab".repeat(32).parse().unwrap();
        assert!(hosts.set_fp("1", fp).unwrap());
        assert!(!hosts.set_fp("1", fp).unwrap());
        assert!(!hosts.set_fp("gone", fp).unwrap());
        assert_eq!(hosts.summary(), json!([{"id": "1", "name": "a", "fp": "ab".repeat(32)}]));
        assert_eq!(Hosts::load(dir.path()).unwrap().get("1").unwrap().fp, Some(fp));
        // A host without a password reads (`password` is written, not required).
        let h: Host = serde_json::from_str(r#"{"id":"2","name":"b"}"#).unwrap();
        assert_eq!((h.password.as_str(), h.fp), ("", None));
    }

    #[test]
    fn reload_switches_the_file() {
        let (a, b) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
        let h = |id: &str| Host { id: id.into(), name: id.into(), password: "p".into(), lan: vec![], fp: None };
        rapp_net::config::write_json(&a.path().join("hosts.json"), &[h("x")]).unwrap();
        rapp_net::config::write_json(&b.path().join("hosts.json"), &[h("y")]).unwrap();
        let hosts = Hosts::load(a.path()).unwrap();
        hosts.reload(b.path()).unwrap();
        assert_eq!(hosts.all(), vec![h("y")]);
        let a_before = std::fs::read(a.path().join("hosts.json")).unwrap();
        hosts.upsert(h("z")).unwrap();
        assert_eq!(std::fs::read(a.path().join("hosts.json")).unwrap(), a_before);
        let saved: Vec<Host> = rapp_net::config::read_json(&b.path().join("hosts.json")).unwrap().unwrap();
        assert_eq!(saved, vec![h("y"), h("z")]);
        let bad = tempfile::tempdir().unwrap();
        std::fs::write(bad.path().join("hosts.json"), "{not json").unwrap();
        assert!(hosts.reload(bad.path()).is_err());
        assert_eq!(hosts.all(), vec![h("y"), h("z")]);
    }
}
