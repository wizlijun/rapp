//! The table of ports this device shares with other devices (`local/shares.json`).

use anyhow::{anyhow, Result};
use rapp_net::config::write_json;
use rapp_wire::Fp;
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use std::sync::Mutex;

pub const MAX_SHARES: usize = 64;
const FILE: &str = "shares.json";
/// Where an unreadable `shares.json` goes before the first write replaces it.
const BAD: &str = "shares.json.bad";

/// Ports that usually expose a login, a proxy, a database or a container API.
const SENSITIVE: [u16; 17] = [
    22, 23, 3389, 5900, 5901, 2375, 2376, 1080, 3128, 8118, 3306, 5432, 6379, 27017, 9200, 1433, 1521,
];

/// A field this does not know makes the file unreadable: a misspelt `allow` dropped in silence
/// would share the port with every trusted device.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
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
    /// The table, and whether the file on disk is one `load` could not read (kept until the first write).
    items: Mutex<(Vec<Share>, bool)>,
}

impl Shares {
    /// `home` is the device's `local/`. A missing file is an empty table. So is an unreadable one;
    /// the second field then carries why, so the caller can log it. The file is left as it was
    /// until the first write, which first moves it to `shares.json.bad`.
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
        let bad = why.is_some();
        (Shares { path, items: Mutex::new((items, bad)) }, why)
    }

    /// Sorted by port.
    pub fn list(&self) -> Vec<Share> {
        let mut v = self.items.lock().unwrap().0.clone();
        v.sort_by_key(|s| s.port);
        v
    }

    pub fn get(&self, port: u16) -> Option<Share> {
        self.items.lock().unwrap().0.iter().find(|s| s.port == port).cloned()
    }

    /// Adds, or replaces the share of the same port. Err("limit") at MAX_SHARES; Err("bad port") for 0.
    pub fn add(&self, share: Share) -> Result<()> {
        self.add_all(vec![share])
    }

    /// `add` for each, saved as one write: either all of them are in the table, or none.
    /// A port given twice is added once, the later one winning.
    pub fn add_all(&self, shares: Vec<Share>) -> Result<()> {
        if shares.iter().any(|s| s.port == 0) {
            return Err(anyhow!("bad port"));
        }
        let mut items = self.items.lock().unwrap();
        let mut next = items.0.clone();
        for share in shares {
            match next.iter().position(|s| s.port == share.port) {
                Some(i) => next[i] = share,
                None => next.push(share),
            }
        }
        // A table that is over the limit already (written by hand) may still have its shares replaced.
        if next.len() > MAX_SHARES.max(items.0.len()) {
            return Err(anyhow!("limit"));
        }
        next.sort_by_key(|s| s.port);
        self.save(&mut items, next)
    }

    /// True when there was one.
    pub fn remove(&self, port: u16) -> Result<bool> {
        let mut items = self.items.lock().unwrap();
        if !items.0.iter().any(|s| s.port == port) {
            return Ok(false);
        }
        let next: Vec<Share> = items.0.iter().filter(|s| s.port != port).cloned().collect();
        self.save(&mut items, next)?;
        Ok(true)
    }

    /// Writes `next` and makes it the table. An unreadable file is first kept as `shares.json.bad`
    /// (replacing an older one), so the user's content is not lost.
    fn save(&self, items: &mut (Vec<Share>, bool), next: Vec<Share>) -> Result<()> {
        if items.1 {
            match std::fs::rename(&self.path, self.path.with_file_name(BAD)) {
                Err(e) if e.kind() != std::io::ErrorKind::NotFound => return Err(e.into()),
                _ => items.1 = false,
            }
        }
        write_json(&self.path, &next)?;
        items.0 = next;
        Ok(())
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
    fn add_all_saves_all_or_none() {
        let d = tempfile::tempdir().unwrap();
        let (s, _) = Shares::load(d.path());
        for p in 1..=62 { s.add(share(p)).unwrap(); }
        // 62 + two new ones is 64; 62 replaced plus two new is also 64
        s.add_all(vec![Share { note: "x".into(), ..share(62) }, share(100), share(101)]).unwrap();
        assert_eq!(s.list().len(), 64);
        assert_eq!(s.get(62).unwrap().note, "x");
        assert_eq!(Shares::load(d.path()).0.list().len(), 64);
        // a 65th is refused and nothing of the batch is kept
        s.remove(100).unwrap();
        assert_eq!(s.add_all(vec![share(200), share(201)]).unwrap_err().to_string(), "limit");
        assert_eq!(s.add_all(vec![share(200), share(0)]).unwrap_err().to_string(), "bad port");
        assert!(s.get(200).is_none());
        assert!(Shares::load(d.path()).0.get(200).is_none());
        // the same port twice counts once
        s.add_all(vec![share(300), Share { note: "y".into(), ..share(300) }]).unwrap();
        assert_eq!(s.get(300).unwrap().note, "y");
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
    fn an_unreadable_file_is_an_empty_table() {
        let d = tempfile::tempdir().unwrap();
        std::fs::write(d.path().join("shares.json"), b"{not json").unwrap();
        let (s, why) = Shares::load(d.path());
        assert!(s.list().is_empty());
        assert!(why.is_some());
        assert_eq!(std::fs::read(d.path().join("shares.json")).unwrap(), b"{not json"); // left as it was
    }

    // A misspelt field must not be dropped: `alow` would otherwise share the port with everyone.
    #[test]
    fn a_field_it_does_not_know_makes_the_file_unreadable() {
        let d = tempfile::tempdir().unwrap();
        let text = format!(r#"[{{"port":8000,"alow":["{}"]}}]"#, fp(1));
        std::fs::write(d.path().join("shares.json"), &text).unwrap();
        let (s, why) = Shares::load(d.path());
        assert!(s.list().is_empty(), "{:?}", s.list());
        assert!(why.is_some_and(|w| w.contains("alow")));
        // kept as `.bad` on the first write, like any unreadable file
        s.add(share(8001)).unwrap();
        assert_eq!(std::fs::read_to_string(d.path().join("shares.json.bad")).unwrap(), text);
        assert_eq!(Shares::load(d.path()).0.list(), [share(8001)]);
    }

    #[test]
    fn an_unreadable_file_is_kept_as_bad_on_the_first_write() {
        let d = tempfile::tempdir().unwrap();
        std::fs::write(d.path().join("shares.json.bad"), b"older").unwrap();
        std::fs::write(d.path().join("shares.json"), b"{not json").unwrap();
        let (s, _) = Shares::load(d.path());
        s.add(share(8000)).unwrap();
        assert_eq!(std::fs::read(d.path().join("shares.json.bad")).unwrap(), b"{not json");
        let (again, why) = Shares::load(d.path());
        assert!(why.is_none());
        assert_eq!(again.list(), [share(8000)]);
        // only the first write keeps it: a later one leaves the .bad alone
        s.add(share(8001)).unwrap();
        assert_eq!(std::fs::read(d.path().join("shares.json.bad")).unwrap(), b"{not json");
    }

    #[test]
    fn a_remove_that_changes_nothing_keeps_the_unreadable_file() {
        let d = tempfile::tempdir().unwrap();
        std::fs::write(d.path().join("shares.json"), b"{not json").unwrap();
        let (s, _) = Shares::load(d.path());
        assert!(!s.remove(8000).unwrap());
        assert_eq!(std::fs::read(d.path().join("shares.json")).unwrap(), b"{not json");
        assert!(!d.path().join("shares.json.bad").exists());
    }

    #[test]
    fn sensitive_ports() {
        for p in [22, 23, 3389, 5900, 5901, 2375, 2376, 1080, 3128, 8118, 3306, 5432, 6379, 27017, 9200, 1433, 1521] {
            assert!(sensitive(p), "{p}");
        }
        assert!(!sensitive(8000) && !sensitive(11434));
    }
}
