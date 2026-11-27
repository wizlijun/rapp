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

/// How a share is reached, and so how a visitor is told to reach it (`share_cmds::addr`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Proto {
    Http,
    Https,
    Tcp,
    Ssh,
}

impl Proto {
    /// What a port is taken for until something better is known: 22 is SSH, anything else a web page.
    pub fn guess(port: u16) -> Proto {
        if port == 22 { Proto::Ssh } else { Proto::Http }
    }

    /// The spelling used on the wire, in files and on the command line.
    pub fn parse(s: &str) -> Option<Proto> {
        match s {
            "http" => Some(Proto::Http),
            "https" => Some(Proto::Https),
            "tcp" => Some(Proto::Tcp),
            "ssh" => Some(Proto::Ssh),
            _ => None,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Proto::Http => "http",
            Proto::Https => "https",
            Proto::Tcp => "tcp",
            Proto::Ssh => "ssh",
        }
    }

    /// A browser can open it.
    pub fn web(self) -> bool {
        matches!(self, Proto::Http | Proto::Https)
    }
}

/// serde default for `proto_auto`: a share written before protocols existed has none chosen.
fn yes() -> bool {
    true
}

fn is_true(b: &bool) -> bool {
    *b
}

/// serde for `Share.proto`: a known spelling, else None (see the field).
fn proto_or_none<'de, D: serde::Deserializer<'de>>(d: D) -> Result<Option<Proto>, D::Error> {
    Ok(Option::<String>::deserialize(d)?.as_deref().and_then(Proto::parse))
}

/// Gives a share number: the lowest one free, given the numbers the share table already uses.
/// None when there is none left.
pub type Pick<'a> = &'a dyn Fn(&[u16]) -> Option<u16>;

/// A field this does not know is ignored (and dropped on the next write), so that rolling back
/// from a later version that added one keeps the shares instead of reading the whole file as
/// broken. The file is written by rApp; a field misspelt by hand is not caught.
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
    /// The number (28000-28999) this share has on every device: visitors reach it on that
    /// local port. None while the range had none to give; it is filled in later.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub local: Option<u16>,
    /// What the share speaks, as the sharer set it or detection found it. None: not known, so
    /// `protocol` guesses from the port. A spelling this does not know (one a later version added)
    /// reads as None rather than making the whole file unreadable, so a rollback keeps the share.
    #[serde(default, deserialize_with = "proto_or_none", skip_serializing_if = "Option::is_none")]
    pub proto: Option<Proto>,
    /// True: `proto` was detected (or never set) and may be replaced by a later detection;
    /// false: the sharer chose it and it stays.
    #[serde(default = "yes", skip_serializing_if = "is_true")]
    pub proto_auto: bool,
    /// What kind of service this is, when it is one other devices look for ("state": a
    /// `rapp-center` service). None for an ordinary share.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub kind: Option<String>,
}

impl Share {
    /// A share of `port` with no note, every trusted device, not raw, no number and no protocol chosen.
    pub fn new(port: u16) -> Share {
        Share { port, note: String::new(), allow: Vec::new(), raw: false, open_web: false, local: None, proto: None, proto_auto: true, kind: None }
    }

    /// The protocol to tell visitors: the one stored, or the guess from the port.
    pub fn protocol(&self) -> Proto {
        self.proto.unwrap_or_else(|| Proto::guess(self.port))
    }
}

/// What a `share` request sets. A field left out keeps what the port's share has now; a port
/// that is not shared yet starts with no note, every trusted device and not raw.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Patch {
    pub note: Option<String>,
    pub allow: Option<Vec<Fp>>,
    pub raw: Option<bool>,
    /// Some: the sharer chose it, so it stops being detected (`proto_auto` becomes false).
    pub proto: Option<Proto>,
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
    /// A port that is new, or shared without a number, gets one from `pick`, given the numbers
    /// of the rest of the table and those given earlier in this call; one that has a number keeps it.
    pub fn share_all(&self, ports: &[u16], patch: &Patch, pick: Pick) -> Result<Vec<Shared>> {
        let mut items = self.items.lock().unwrap();
        let mut done: Vec<Shared> = Vec::new();
        for &port in ports {
            // A port given twice: the second time it has what the first gave it.
            let now = done.iter().find(|d| d.share.port == port).map(|d| &d.share);
            let was = now.or_else(|| items.0.iter().find(|s| s.port == port));
            let mut share = was.cloned().unwrap_or_else(|| Share::new(port));
            if let Some(note) = &patch.note {
                share.note = note.clone();
            }
            if let Some(allow) = &patch.allow {
                share.allow = allow.clone();
            }
            if let Some(raw) = patch.raw {
                share.raw = raw;
            }
            if let Some(proto) = patch.proto {
                (share.proto, share.proto_auto) = (Some(proto), false);
            }
            if share.local.is_none() {
                let used: Vec<u16> = items.0.iter().chain(done.iter().map(|d| &d.share)).filter(|s| s.port != port).filter_map(|s| s.local).collect();
                share.local = pick(&used);
            }
            let allow_changed = was.is_some_and(|w| !same_devices(&w.allow, &share.allow));
            done.push(Shared { share, allow_changed });
        }
        self.put(&mut items, done.iter().map(|d| d.share.clone()).collect())?;
        Ok(done)
    }

    /// Sets (or clears) the `kind` of the share of `port`. True when it changed (and is saved);
    /// false when there is no such share or it already has that kind.
    pub fn set_kind(&self, port: u16, kind: Option<&str>) -> Result<bool> {
        let mut items = self.items.lock().unwrap();
        let mut next = items.0.clone();
        let Some(share) = next.iter_mut().find(|s| s.port == port) else { return Ok(false) };
        if share.kind.as_deref() == kind {
            return Ok(false);
        }
        share.kind = kind.map(str::to_string);
        self.save(&mut items, next)?;
        Ok(true)
    }

    /// Gives a number to every share that has none, saved as one write (none when every share
    /// has one). The shares numbered are returned.
    pub fn number_all(&self, pick: Pick) -> Result<Vec<Share>> {
        let mut items = self.items.lock().unwrap();
        let mut next = items.0.clone();
        let mut used: Vec<u16> = next.iter().filter_map(|s| s.local).collect();
        let mut numbered = Vec::new();
        next.sort_by_key(|s| s.port);
        for s in next.iter_mut().filter(|s| s.local.is_none()) {
            if let Some(n) = pick(&used) {
                s.local = Some(n);
                used.push(n);
                numbered.push(s.clone());
            }
        }
        if !numbered.is_empty() {
            self.save(&mut items, next)?;
        }
        Ok(numbered)
    }

    /// Gives the share of `port` another number than `from`, as `(old, new)`. Its current number
    /// counts as used, so the new one differs. None when it is not shared, has no number, has
    /// another number than `from` now, or none is left. `from` is the number the caller saw
    /// clash: two calls that saw the same clash at once then move the share once, not twice.
    pub fn renumber(&self, port: u16, from: u16, pick: Pick) -> Result<Option<(u16, u16)>> {
        let mut items = self.items.lock().unwrap();
        let now = items.0.iter().find(|s| s.port == port).and_then(|s| s.local);
        let Some(old) = now.filter(|&l| l == from) else { return Ok(None) };
        let used: Vec<u16> = items.0.iter().filter_map(|s| s.local).collect();
        let Some(new) = pick(&used) else { return Ok(None) };
        let mut next = items.0.clone();
        if let Some(s) = next.iter_mut().find(|s| s.port == port) {
            s.local = Some(new);
        }
        self.save(&mut items, next)?;
        Ok(Some((old, new)))
    }

    /// Records what the share of `port` speaks and whether that was detected (`auto`). True when
    /// that changed the share; false (and no write) when it already was so, or is not shared.
    /// A detection (`auto`) never replaces a protocol the sharer chose: the check is made under
    /// the same lock as the write, since the sharer may choose one while a detection runs.
    pub fn set_proto(&self, port: u16, proto: Proto, auto: bool) -> Result<bool> {
        let mut items = self.items.lock().unwrap();
        let Some(now) = items.0.iter().find(|s| s.port == port) else { return Ok(false) };
        if (now.protocol() == proto && now.proto_auto == auto) || (auto && !now.proto_auto) {
            return Ok(false);
        }
        let mut next = items.0.clone();
        if let Some(s) = next.iter_mut().find(|s| s.port == port) {
            (s.proto, s.proto_auto) = (Some(proto), auto);
        }
        self.save(&mut items, next)?;
        Ok(true)
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
    fn share(port: u16) -> Share { Share::new(port) }

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
        #[cfg(unix)]
        {
            let mode = std::os::unix::fs::PermissionsExt::mode(&std::fs::metadata(d.path().join("shares.json")).unwrap().permissions());
            assert_eq!(mode & 0o777, 0o600);
        }
        #[cfg(windows)]
        assert_eq!(rapp_net::private::acl(&d.path().join("shares.json")).unwrap(), rapp_net::private::private_acl().unwrap());
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
    fn kind_is_kept_and_written_only_when_set() {
        let d = tempfile::tempdir().unwrap();
        let (s, _) = Shares::load(d.path());
        s.add_all(vec![share(8102), share(8103)]).unwrap();
        assert!(!s.set_kind(9, Some("state")).unwrap());
        assert!(s.set_kind(8102, Some("state")).unwrap());
        assert!(!s.set_kind(8102, Some("state")).unwrap());
        let (s, _) = Shares::load(d.path());
        assert_eq!(s.get(8102).unwrap().kind.as_deref(), Some("state"));
        let text: serde_json::Value = serde_json::from_slice(&std::fs::read(d.path().join("shares.json")).unwrap()).unwrap();
        assert_eq!(text[0]["kind"], "state");
        assert!(text[1].get("kind").is_none(), "{text}");
        s.share_all(&[8102], &Patch { note: Some("x".into()), ..Patch::default() }, &|_| None).unwrap();
        assert_eq!(s.get(8102).unwrap().kind.as_deref(), Some("state"));
    }

    #[test]
    fn share_all_keeps_what_the_patch_leaves_out() {
        let d = tempfile::tempdir().unwrap();
        let (s, _) = Shares::load(d.path());
        let only = |fps: &[Fp]| Patch { allow: Some(fps.to_vec()), ..Patch::default() };
        // a port not shared yet starts with no note, every trusted device, not raw
        let done = s.share_all(&[8000], &Patch::default(), &|_| None).unwrap();
        assert_eq!((&done[0].share, done[0].allow_changed), (&share(8000), false));
        let full = Patch { note: Some("模型".into()), allow: Some(vec![fp(1)]), raw: Some(true), proto: None };
        let done = s.share_all(&[8000, 8001], &full, &|_| None).unwrap();
        let want = |port| Share { note: "模型".into(), allow: vec![fp(1)], raw: true, ..share(port) };
        assert_eq!(done.iter().map(|d| d.share.clone()).collect::<Vec<_>>(), [want(8000), want(8001)]);
        // 8000 was shared with everyone before; 8001 was not shared at all
        assert_eq!(done.iter().map(|d| d.allow_changed).collect::<Vec<_>>(), [true, false]);

        // nothing given: nothing changes, in the table and in the file
        let done = s.share_all(&[8000], &Patch::default(), &|_| None).unwrap();
        assert_eq!((&done[0].share, done[0].allow_changed), (&want(8000), false));
        assert_eq!(Shares::load(d.path()).0.get(8000), Some(want(8000)));
        // one field given: only that one changes
        let done = s.share_all(&[8000], &Patch { note: Some(String::new()), ..Patch::default() }, &|_| None).unwrap();
        assert_eq!((&done[0].share, done[0].allow_changed), (&Share { note: String::new(), ..want(8000) }, false));
        let done = s.share_all(&[8000], &Patch { raw: Some(false), ..Patch::default() }, &|_| None).unwrap();
        assert_eq!(done[0].share, Share { allow: vec![fp(1)], ..share(8000) });

        // the same devices in another order are not a change; other devices are, and so is everyone
        s.share_all(&[8000], &only(&[fp(1), fp(2)]), &|_| None).unwrap();
        assert!(!s.share_all(&[8000], &only(&[fp(2), fp(1)]), &|_| None).unwrap()[0].allow_changed);
        assert!(s.share_all(&[8000], &only(&[fp(2)]), &|_| None).unwrap()[0].allow_changed);
        assert!(s.share_all(&[8000], &only(&[fp(2), fp(3)]), &|_| None).unwrap()[0].allow_changed);
        assert!(s.share_all(&[8000], &only(&[]), &|_| None).unwrap()[0].allow_changed);
        assert_eq!(s.get(8000), Some(share(8000)));
    }

    #[test]
    fn share_all_shares_all_or_none() {
        let d = tempfile::tempdir().unwrap();
        let (s, _) = Shares::load(d.path());
        let ports: Vec<u16> = (1..=63).collect();
        s.share_all(&ports, &Patch::default(), &|_| None).unwrap();
        assert_eq!(s.share_all(&[100, 101], &Patch::default(), &|_| None).unwrap_err().to_string(), "limit");
        assert_eq!(s.share_all(&[100, 0], &Patch::default(), &|_| None).unwrap_err().to_string(), "bad port");
        assert!(s.get(100).is_none() && Shares::load(d.path()).0.get(100).is_none());
        // one that is shared already and a new one make 64; a port given twice counts once
        assert_eq!(s.share_all(&[63, 100, 100], &Patch::default(), &|_| None).unwrap().len(), 3);
        assert_eq!(s.list().len(), 64);
    }

    fn lowest(used: &[u16]) -> Option<u16> {
        (29000..).find(|n| !used.contains(n))
    }

    #[test]
    fn an_old_file_loads_and_writes_back_unchanged() {
        let d = tempfile::tempdir().unwrap();
        std::fs::write(d.path().join("shares.json"), r#"[{"port":8000,"note":"x"},{"port":22}]"#).unwrap();
        let (s, why) = Shares::load(d.path());
        assert!(why.is_none());
        s.share_all(&[8000], &Patch::default(), &|_| None).unwrap();
        let text = std::fs::read_to_string(d.path().join("shares.json")).unwrap();
        assert!(!text.contains("proto") && !text.contains("local"), "{text}");
        let (again, why) = Shares::load(d.path());
        assert!(why.is_none());
        assert_eq!(again.get(22).unwrap().protocol(), Proto::Ssh);
        assert_eq!(again.get(8000).unwrap().protocol(), Proto::Http);
        assert_eq!(again.get(8000).unwrap().local, None);
    }

    #[test]
    fn a_new_share_gets_a_number_and_keeps_it() {
        let d = tempfile::tempdir().unwrap();
        let (s, _) = Shares::load(d.path());
        s.share_all(&[8000], &Patch::default(), &lowest).unwrap();
        s.share_all(&[8001], &Patch::default(), &lowest).unwrap();
        assert_eq!((s.get(8000).unwrap().local, s.get(8001).unwrap().local), (Some(29000), Some(29001)));
        s.share_all(&[8000], &Patch { note: Some("new".into()), ..Patch::default() }, &lowest).unwrap();
        assert_eq!(s.get(8000).unwrap().local, Some(29000));
        // several ports in one call do not get the same number
        let done = s.share_all(&[9000, 9001], &Patch::default(), &lowest).unwrap();
        assert_eq!((done[0].share.local, done[1].share.local), (Some(29002), Some(29003)));
        assert_eq!(Shares::load(d.path()).0.get(9001).unwrap().local, Some(29003));
    }

    #[test]
    fn a_full_range_shares_without_a_number() {
        let d = tempfile::tempdir().unwrap();
        let (s, _) = Shares::load(d.path());
        let done = s.share_all(&[8000], &Patch::default(), &|_| None).unwrap();
        assert_eq!(done[0].share.local, None);
    }

    #[test]
    fn proto_from_a_patch_is_not_auto() {
        let d = tempfile::tempdir().unwrap();
        let (s, _) = Shares::load(d.path());
        let done = s.share_all(&[8000], &Patch { proto: Some(Proto::Tcp), ..Patch::default() }, &|_| None).unwrap();
        assert_eq!((done[0].share.proto, done[0].share.proto_auto), (Some(Proto::Tcp), false));
        s.share_all(&[8000], &Patch::default(), &|_| None).unwrap();
        let got = s.get(8000).unwrap();
        assert_eq!((got.proto, got.proto_auto), (Some(Proto::Tcp), false));
        let again = Shares::load(d.path()).0.get(8000).unwrap();
        assert_eq!((again.proto, again.proto_auto), (Some(Proto::Tcp), false));
    }

    #[test]
    fn number_all_fills_only_the_missing() {
        let d = tempfile::tempdir().unwrap();
        let (s, _) = Shares::load(d.path());
        s.add_all(vec![Share { local: Some(29005), ..share(8000) }, share(8001)]).unwrap();
        let got = s.number_all(&lowest).unwrap();
        assert_eq!(got.iter().map(|g| (g.port, g.local)).collect::<Vec<_>>(), [(8001, Some(29000))]);
        assert_eq!(s.get(8000).unwrap().local, Some(29005));
        assert!(s.number_all(&lowest).unwrap().is_empty());
        assert_eq!(Shares::load(d.path()).0.get(8001).unwrap().local, Some(29000));
    }

    #[test]
    fn renumber_gives_another_number() {
        let d = tempfile::tempdir().unwrap();
        let (s, _) = Shares::load(d.path());
        s.add(Share { local: Some(29000), ..share(8000) }).unwrap();
        assert_eq!(s.renumber(8000, 29000, &lowest).unwrap(), Some((29000, 29001)));
        assert_eq!(Shares::load(d.path()).0.get(8000).unwrap().local, Some(29001));
        assert_eq!(s.renumber(8000, 29001, &|_| None).unwrap(), None);
        assert_eq!(s.renumber(9, 29000, &lowest).unwrap(), None);
    }

    /// Two reads of the other device's table saw the same clash on 29000: the second finds the
    /// share on 29001 already and leaves it there.
    #[test]
    fn renumber_moves_only_off_the_number_given() {
        let d = tempfile::tempdir().unwrap();
        let (s, _) = Shares::load(d.path());
        s.add(Share { local: Some(29000), ..share(8000) }).unwrap();
        assert_eq!(s.renumber(8000, 29000, &lowest).unwrap(), Some((29000, 29001)));
        assert_eq!(s.renumber(8000, 29000, &lowest).unwrap(), None);
        assert_eq!(s.get(8000).unwrap().local, Some(29001));
        assert_eq!(Shares::load(d.path()).0.get(8000).unwrap().local, Some(29001));
    }

    #[test]
    fn set_proto_says_whether_it_changed() {
        let d = tempfile::tempdir().unwrap();
        let (s, _) = Shares::load(d.path());
        s.add(share(8000)).unwrap();
        assert!(!s.set_proto(8000, Proto::Http, true).unwrap()); // already the guess
        assert!(s.set_proto(8000, Proto::Https, true).unwrap());
        assert!(!s.set_proto(8000, Proto::Https, true).unwrap());
        assert!(s.set_proto(8000, Proto::Https, false).unwrap());
        assert!(!s.set_proto(8000, Proto::Tcp, true).unwrap()); // the sharer chose
        assert!(!s.set_proto(9, Proto::Tcp, true).unwrap()); // not shared
        let got = Shares::load(d.path()).0.get(8000).unwrap();
        assert_eq!((got.proto, got.proto_auto), (Some(Proto::Https), false));
    }

    #[test]
    fn proto_spellings() {
        for p in [Proto::Http, Proto::Https, Proto::Tcp, Proto::Ssh] {
            assert_eq!(Proto::parse(p.as_str()), Some(p));
        }
        assert_eq!(Proto::parse("udp"), None);
        assert_eq!((Proto::guess(22), Proto::guess(80)), (Proto::Ssh, Proto::Http));
        assert!(Proto::Https.web() && !Proto::Tcp.web());
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

    /// A later version may add a field; rolling back to this one must keep the shares. The
    /// field this one does not know is dropped on the next write, the share stays.
    #[test]
    fn a_field_it_does_not_know_is_ignored_and_the_share_kept() {
        let d = tempfile::tempdir().unwrap();
        let text = format!(r#"[{{"port":8000,"allow":["{}"],"local":29000,"later":{{"x":1}}}}]"#, fp(1));
        std::fs::write(d.path().join("shares.json"), &text).unwrap();
        let (s, why) = Shares::load(d.path());
        assert_eq!(why, None);
        let kept = Share { allow: vec![fp(1)], local: Some(29000), ..share(8000) };
        assert_eq!(s.list(), std::slice::from_ref(&kept));
        s.add(share(8001)).unwrap();
        assert!(!d.path().join("shares.json.bad").exists());
        assert_eq!(Shares::load(d.path()).0.list(), [kept, share(8001)]);
    }

    #[test]
    fn a_protocol_it_does_not_know_is_dropped_and_the_share_kept() {
        let d = tempfile::tempdir().unwrap();
        std::fs::write(d.path().join("shares.json"), r#"[{"port":8000,"proto":"udp","local":29000}]"#).unwrap();
        let (s, why) = Shares::load(d.path());
        assert_eq!(why, None);
        assert_eq!(s.list(), [Share { local: Some(29000), ..share(8000) }]);
        assert_eq!(s.list()[0].protocol(), Proto::Http);
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
