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

/// What a `share` request sets. A field left out keeps what the port's share has now; a port
/// that is not shared yet starts with no note, every trusted device and not raw.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Patch {
    pub note: Option<String>,
    pub allow: Option<Vec<Fp>>,
    pub raw: Option<bool>,
}

/// One port after `share_all`.
#[derive(Debug, Clone, PartialEq)]
pub struct Shared {
    pub share: Share,
    /// The port was shared before, with other devices than now.
    pub allow_changed: bool,
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
        self.put(&mut self.items.lock().unwrap(), shares)
    }

    /// Shares every port of `ports` as `patch` says, saved as one write: either all of them are
    /// in the table, or none. One entry per port, in the order given. Each port's share is read
    /// and replaced under one lock, so a field the patch leaves out is the one it has now.
    pub fn share_all(&self, ports: &[u16], patch: &Patch) -> Result<Vec<Shared>> {
        let mut items = self.items.lock().unwrap();
        let mut done: Vec<Shared> = Vec::new();
        for &port in ports {
            // A port given twice: the second time it has what the first gave it.
            let now = done.iter().find(|d| d.share.port == port).map(|d| &d.share);
            let was = now.or_else(|| items.0.iter().find(|s| s.port == port));
            let mut share = was.cloned().unwrap_or(Share { port, note: String::new(), allow: Vec::new(), raw: false, open_web: false });
            if let Some(note) = &patch.note {
                share.note = note.clone();
            }
            if let Some(allow) = &patch.allow {
                share.allow = allow.clone();
            }
            if let Some(raw) = patch.raw {
                share.raw = raw;
            }
            let allow_changed = was.is_some_and(|w| !same_devices(&w.allow, &share.allow));
            done.push(Shared { share, allow_changed });
        }
        self.put(&mut items, done.iter().map(|d| d.share.clone()).collect())?;
        Ok(done)
    }

    /// `shares` into the table (each replacing the share of its port) and into the file.
    fn put(&self, items: &mut (Vec<Share>, bool), shares: Vec<Share>) -> Result<()> {
        if shares.iter().any(|s| s.port == 0) {
            return Err(anyhow!("bad port"));
        }
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
        self.save(items, next)
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

/// The two lists name the same devices, in whatever order.
fn same_devices(a: &[Fp], b: &[Fp]) -> bool {
    a.iter().all(|f| b.contains(f)) && b.iter().all(|f| a.contains(f))
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
    fn share_all_keeps_what_the_patch_leaves_out() {
        let d = tempfile::tempdir().unwrap();
        let (s, _) = Shares::load(d.path());
        let only = |fps: &[Fp]| Patch { allow: Some(fps.to_vec()), ..Patch::default() };
        // a port not shared yet starts with no note, every trusted device, not raw
        let done = s.share_all(&[8000], &Patch::default()).unwrap();
        assert_eq!((&done[0].share, done[0].allow_changed), (&share(8000), false));
        let full = Patch { note: Some("模型".into()), allow: Some(vec![fp(1)]), raw: Some(true) };
        let done = s.share_all(&[8000, 8001], &full).unwrap();
        let want = |port| Share { note: "模型".into(), allow: vec![fp(1)], raw: true, ..share(port) };
        assert_eq!(done.iter().map(|d| d.share.clone()).collect::<Vec<_>>(), [want(8000), want(8001)]);
        // 8000 was shared with everyone before; 8001 was not shared at all
        assert_eq!(done.iter().map(|d| d.allow_changed).collect::<Vec<_>>(), [true, false]);

        // nothing given: nothing changes, in the table and in the file
        let done = s.share_all(&[8000], &Patch::default()).unwrap();
        assert_eq!((&done[0].share, done[0].allow_changed), (&want(8000), false));
        assert_eq!(Shares::load(d.path()).0.get(8000), Some(want(8000)));
        // one field given: only that one changes
        let done = s.share_all(&[8000], &Patch { note: Some(String::new()), ..Patch::default() }).unwrap();
        assert_eq!((&done[0].share, done[0].allow_changed), (&Share { note: String::new(), ..want(8000) }, false));
        let done = s.share_all(&[8000], &Patch { raw: Some(false), ..Patch::default() }).unwrap();
        assert_eq!(done[0].share, Share { allow: vec![fp(1)], ..share(8000) });

        // the same devices in another order are not a change; other devices are, and so is everyone
        s.share_all(&[8000], &only(&[fp(1), fp(2)])).unwrap();
        assert!(!s.share_all(&[8000], &only(&[fp(2), fp(1)])).unwrap()[0].allow_changed);
        assert!(s.share_all(&[8000], &only(&[fp(2)])).unwrap()[0].allow_changed);
        assert!(s.share_all(&[8000], &only(&[fp(2), fp(3)])).unwrap()[0].allow_changed);
        assert!(s.share_all(&[8000], &only(&[])).unwrap()[0].allow_changed);
        assert_eq!(s.get(8000), Some(share(8000)));
    }

    #[test]
    fn share_all_shares_all_or_none() {
        let d = tempfile::tempdir().unwrap();
        let (s, _) = Shares::load(d.path());
        let ports: Vec<u16> = (1..=63).collect();
        s.share_all(&ports, &Patch::default()).unwrap();
        assert_eq!(s.share_all(&[100, 101], &Patch::default()).unwrap_err().to_string(), "limit");
        assert_eq!(s.share_all(&[100, 0], &Patch::default()).unwrap_err().to_string(), "bad port");
        assert!(s.get(100).is_none() && Shares::load(d.path()).0.get(100).is_none());
        // one that is shared already and a new one make 64; a port given twice counts once
        assert_eq!(s.share_all(&[63, 100, 100], &Patch::default()).unwrap().len(), 3);
        assert_eq!(s.list().len(), 64);
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
