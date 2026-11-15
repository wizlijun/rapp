//! The table of ports this device shares with other devices (`local/shares.json`).

use anyhow::{anyhow, Result};
use rapp_net::config::write_json;
use rapp_wire::Fp;
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use std::sync::Mutex;

pub const MAX_SHARES: usize = 64;
const FILE: &str = "shares.json";

/// Ports that usually expose a login, a proxy, a database or a container API.
const SENSITIVE: [u16; 17] = [
    22, 23, 3389, 5900, 5901, 2375, 2376, 1080, 3128, 8118, 3306, 5432, 6379, 27017, 9200, 1433, 1521,
];

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Share {
    pub port: u16,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub note: String,
    /// Empty: every trusted device. Otherwise only these.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub allow: Vec<Fp>,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub raw: bool,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub open_web: bool,
}

/// The shares of this device, kept in `local/shares.json` as a JSON array.
pub struct Shares {
    path: PathBuf,
    items: Mutex<Vec<Share>>,
}

impl Shares {
    /// `home` is the device's `local/`. A missing file is an empty table. So is an unreadable one;
    /// the second field then carries why, so the caller can log it. The file is left as it was.
    pub fn load(home: &Path) -> (Shares, Option<String>) {
        let path = home.join(FILE);
        let (items, why) = match std::fs::read(&path) {
            Ok(b) => match serde_json::from_slice::<Vec<Share>>(&b) {
                Ok(v) => (v, None),
                Err(e) => (Vec::new(), Some(e.to_string())),
            },
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => (Vec::new(), None),
            Err(e) => (Vec::new(), Some(e.to_string())),
        };
        (Shares { path, items: Mutex::new(items) }, why)
    }

    /// Sorted by port.
    pub fn list(&self) -> Vec<Share> {
        let mut v = self.items.lock().unwrap().clone();
        v.sort_by_key(|s| s.port);
        v
    }

    pub fn get(&self, port: u16) -> Option<Share> {
        self.items.lock().unwrap().iter().find(|s| s.port == port).cloned()
    }

    /// Adds, or replaces the share of the same port. Err("limit") at MAX_SHARES; Err("bad port") for 0.
    pub fn add(&self, share: Share) -> Result<()> {
        if share.port == 0 {
            return Err(anyhow!("bad port"));
        }
        let mut items = self.items.lock().unwrap();
        let mut next = items.clone();
        match next.iter().position(|s| s.port == share.port) {
            Some(i) => next[i] = share,
            None if next.len() >= MAX_SHARES => return Err(anyhow!("limit")),
            None => next.push(share),
        }
        next.sort_by_key(|s| s.port);
        write_json(&self.path, &next)?;
        *items = next;
        Ok(())
    }

    /// True when there was one.
    pub fn remove(&self, port: u16) -> Result<bool> {
        let mut items = self.items.lock().unwrap();
        if !items.iter().any(|s| s.port == port) {
            return Ok(false);
        }
        let next: Vec<Share> = items.iter().filter(|s| s.port != port).cloned().collect();
        write_json(&self.path, &next)?;
        *items = next;
        Ok(true)
    }

    /// The shares `fp` may use: `allow` empty or containing it. Sorted by port.
    pub fn visible_to(&self, fp: &Fp) -> Vec<Share> {
        let mut v = self.list();
        v.retain(|s| s.allow.is_empty() || s.allow.contains(fp));
        v
    }
}

/// Ports the user should be warned about before sharing them.
pub fn sensitive(port: u16) -> bool {
    SENSITIVE.contains(&port)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fp(b: u8) -> Fp { Fp([b; 32]) }
    fn share(port: u16) -> Share { Share { port, note: String::new(), allow: vec![], raw: false, open_web: false } }

    #[test]
    fn a_missing_file_is_an_empty_table() {
        let d = tempfile::tempdir().unwrap();
        let (s, why) = Shares::load(d.path());
        assert!(s.list().is_empty() && why.is_none());
    }

    #[test]
    fn add_saves_and_load_reads_it_back() {
        let d = tempfile::tempdir().unwrap();
        let (s, _) = Shares::load(d.path());
        s.add(Share { note: "模型".into(), allow: vec![fp(1)], ..share(11434) }).unwrap();
        s.add(share(22)).unwrap();
        let (again, why) = Shares::load(d.path());
        assert!(why.is_none());
        assert_eq!(again.list().iter().map(|s| s.port).collect::<Vec<_>>(), [22, 11434]);
        assert_eq!(again.get(11434).unwrap().note, "模型");
        let mode = std::os::unix::fs::PermissionsExt::mode(&std::fs::metadata(d.path().join("shares.json")).unwrap().permissions());
        assert_eq!(mode & 0o777, 0o600);
    }

    #[test]
    fn add_replaces_the_same_port() {
        let d = tempfile::tempdir().unwrap();
        let (s, _) = Shares::load(d.path());
        s.add(share(8000)).unwrap();
        s.add(Share { note: "x".into(), ..share(8000) }).unwrap();
        assert_eq!(s.list().len(), 1);
        assert_eq!(s.get(8000).unwrap().note, "x");
    }

    #[test]
    fn port_zero_and_the_65th_share_are_refused() {
        let d = tempfile::tempdir().unwrap();
        let (s, _) = Shares::load(d.path());
        assert_eq!(s.add(share(0)).unwrap_err().to_string(), "bad port");
        for p in 1..=64 { s.add(share(p)).unwrap(); }
        assert_eq!(s.add(share(65)).unwrap_err().to_string(), "limit");
        s.add(share(64)).unwrap(); // replacing one that exists is not a 65th
    }

    #[test]
    fn remove_says_whether_there_was_one() {
        let d = tempfile::tempdir().unwrap();
        let (s, _) = Shares::load(d.path());
        s.add(share(8000)).unwrap();
        assert!(s.remove(8000).unwrap());
        assert!(!s.remove(8000).unwrap());
        assert!(Shares::load(d.path()).0.list().is_empty());
    }

    #[test]
    fn visible_to_honours_allow() {
        let d = tempfile::tempdir().unwrap();
        let (s, _) = Shares::load(d.path());
        s.add(share(1)).unwrap();
        s.add(Share { allow: vec![fp(1)], ..share(2) }).unwrap();
        assert_eq!(s.visible_to(&fp(1)).len(), 2);
        assert_eq!(s.visible_to(&fp(9)).iter().map(|s| s.port).collect::<Vec<_>>(), [1]);
    }

    #[test]
    fn an_unreadable_file_is_an_empty_table() {
        let d = tempfile::tempdir().unwrap();
        std::fs::write(d.path().join("shares.json"), b"{not json").unwrap();
        let (s, why) = Shares::load(d.path());
        assert!(s.list().is_empty());
        assert!(why.is_some());
        assert_eq!(std::fs::read(d.path().join("shares.json")).unwrap(), b"{not json"); // left as it was
    }

    #[test]
    fn sensitive_ports() {
        for p in [22, 23, 3389, 5900, 5901, 2375, 2376, 1080, 3128, 8118, 3306, 5432, 6379, 27017, 9200, 1433, 1521] {
            assert!(sensitive(p), "{p}");
        }
        assert!(!sensitive(8000) && !sensitive(11434));
    }
}
