//! Device registry: enrolled fingerprints, the ID each owns, revocations, the join-key hash.
//! Every change reaches the disk before memory (except `seen`, which `flush` persists).
use anyhow::{bail, Context, Result};
use rapp_net::config::{read_json, write_json, write_private};
use rapp_wire::fp::Fp;
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, MutexGuard};
use std::time::SystemTime;

#[derive(Clone, Serialize, Deserialize, Debug, PartialEq)]
pub struct Device {
    pub fp: Fp,
    pub tenant: String,
    pub id: Option<String>,
    /// RFC 3339 UTC.
    pub enrolled_at: String,
    pub revoked: bool,
    /// RFC 3339 UTC; shown as "last online" by `rapp-relay devices`.
    #[serde(default)]
    pub last_seen: Option<String>,
    /// The join key changed after it enrolled: it has to enroll again with the new one, and keeps
    /// its ID meanwhile. Never set on a revoked device.
    #[serde(default)]
    pub stale: bool,
}

#[derive(Debug, PartialEq, Eq, Clone, Copy)]
pub enum Bind {
    New,
    Same,
    Taken,
}

pub trait Registry: Send + Sync {
    fn get(&self, fp: &Fp) -> Option<Device>;
    fn by_id(&self, id: &str) -> Option<Device>;
    fn list(&self) -> Vec<Device>;
    /// Not counting revoked devices.
    fn count(&self) -> usize;
    /// Idempotent for an enrolled device; an error for a revoked one. A stale device is enrolled
    /// again: no longer stale, with the ID it had.
    fn enroll(&self, fp: Fp, tenant: &str) -> Result<()>;
    /// Marks every device that is neither revoked nor stale yet as stale (the join key changed);
    /// how many it marked.
    fn mark_all_stale(&self) -> Result<usize>;
    fn bind_id(&self, fp: &Fp, id: &str) -> Result<Bind>;
    fn unbind(&self, id: &str) -> Result<bool>;
    /// Revokes `fp`. Unlike the other mutations this one is applied in memory even when the write
    /// fails (a revocation must not depend on the disk); see [`Revoked`].
    fn revoke(&self, fp: &Fp) -> Revoked;
    fn revoked(&self) -> Vec<Fp>;
    fn join_hash(&self) -> Option<String>;
    fn set_join_hash(&self, hash: &str) -> Result<()>;
    /// Memory only; `flush` persists it.
    fn seen(&self, fp: &Fp, at: &str);
    fn flush(&self) -> Result<()>;
}

/// The outcome of `Registry::revoke`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Revoked {
    /// False when `fp` was unknown or already revoked.
    pub changed: bool,
    /// Why the change could not be saved; it is in effect in memory anyway.
    pub save_error: Option<String>,
}

#[derive(Serialize, Deserialize)]
struct Disk {
    version: u32,
    devices: Vec<Device>,
}

type Table = BTreeMap<Fp, Device>;

struct Inner {
    table: Table,
    join: Option<String>,
    dirty: bool,
}

pub struct FileRegistry {
    devices_path: PathBuf,
    join_path: PathBuf,
    inner: Mutex<Inner>,
}

impl FileRegistry {
    pub fn open(data: &Path) -> Result<FileRegistry> {
        create_private_dir(data)?;
        let devices_path = data.join("devices.json");
        let join_path = data.join("join");
        let disk: Option<Disk> = read_json(&devices_path)?;
        let table = match disk {
            None => Table::new(),
            Some(d) if d.version == 1 => d.devices.into_iter().map(|x| (x.fp, x)).collect(),
            Some(d) => bail!("{}: unknown version {}", devices_path.display(), d.version),
        };
        let join = match std::fs::read_to_string(&join_path) {
            Ok(s) => Some(s.trim().to_string()).filter(|s| !s.is_empty()),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => None,
            Err(e) => return Err(e).with_context(|| format!("read {}", join_path.display())),
        };
        Ok(FileRegistry { devices_path, join_path, inner: Mutex::new(Inner { table, join, dirty: false }) })
    }

    fn lock(&self) -> MutexGuard<'_, Inner> {
        self.inner.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// Applies `f` to a copy of the table, writes that copy, and only then makes it the live one.
    /// `f` returns whether it changed anything (no write when not) plus the result.
    fn change<T>(&self, f: impl FnOnce(&mut Table) -> Result<(bool, T)>) -> Result<T> {
        let mut g = self.lock();
        let mut next = g.table.clone();
        let (changed, out) = f(&mut next)?;
        if changed {
            let disk = Disk { version: 1, devices: next.values().cloned().collect() };
            write_json(&self.devices_path, &disk)?;
            g.table = next;
            g.dirty = false;
        }
        Ok(out)
    }
}

fn create_private_dir(dir: &Path) -> Result<()> {
    let mut b = std::fs::DirBuilder::new();
    b.recursive(true);
    #[cfg(unix)]
    std::os::unix::fs::DirBuilderExt::mode(&mut b, 0o700);
    b.create(dir).with_context(|| format!("create {}", dir.display()))?;
    if !dir.is_dir() {
        bail!("{} is not a directory", dir.display());
    }
    Ok(())
}

fn holder<'a>(t: &'a Table, id: &str) -> Option<&'a Device> {
    t.values().find(|d| !d.revoked && d.id.as_deref() == Some(id))
}

impl Registry for FileRegistry {
    fn get(&self, fp: &Fp) -> Option<Device> {
        self.lock().table.get(fp).cloned()
    }
    fn by_id(&self, id: &str) -> Option<Device> {
        holder(&self.lock().table, id).cloned()
    }
    fn list(&self) -> Vec<Device> {
        self.lock().table.values().cloned().collect()
    }
    fn count(&self) -> usize {
        self.lock().table.values().filter(|d| !d.revoked).count()
    }
    fn enroll(&self, fp: Fp, tenant: &str) -> Result<()> {
        self.change(|t| match t.get_mut(&fp) {
            Some(d) if d.revoked => bail!("device {fp} is revoked"),
            Some(d) if d.stale => {
                d.stale = false;
                Ok((true, ()))
            }
            Some(_) => Ok((false, ())),
            None => {
                let enrolled_at = rapp_net::log::timestamp(SystemTime::now());
                let d = Device {
                    fp,
                    tenant: tenant.to_string(),
                    id: None,
                    enrolled_at,
                    revoked: false,
                    last_seen: None,
                    stale: false,
                };
                t.insert(fp, d);
                Ok((true, ()))
            }
        })
    }
    fn mark_all_stale(&self) -> Result<usize> {
        self.change(|t| {
            let mut n = 0;
            for d in t.values_mut().filter(|d| !d.revoked && !d.stale) {
                d.stale = true;
                n += 1;
            }
            Ok((n > 0, n))
        })
    }
    fn bind_id(&self, fp: &Fp, id: &str) -> Result<Bind> {
        self.change(|t| {
            match t.get(fp) {
                Some(d) if !d.revoked => {}
                Some(_) => bail!("device {fp} is revoked"),
                None => bail!("device {fp} is not enrolled"),
            }
            if let Some(h) = holder(t, id) {
                return Ok((false, if h.fp == *fp { Bind::Same } else { Bind::Taken }));
            }
            if let Some(d) = t.get_mut(fp) {
                d.id = Some(id.to_string());
            }
            Ok((true, Bind::New))
        })
    }
    fn unbind(&self, id: &str) -> Result<bool> {
        self.change(|t| {
            let Some(owner) = holder(t, id).map(|d| d.fp) else { return Ok((false, false)) };
            if let Some(d) = t.get_mut(&owner) {
                d.id = None;
            }
            Ok((true, true))
        })
    }
    fn revoke(&self, fp: &Fp) -> Revoked {
        let mut g = self.lock();
        let mut next = g.table.clone();
        match next.get_mut(fp) {
            Some(d) if !d.revoked => {
                d.revoked = true;
                d.id = None;
            }
            _ => return Revoked { changed: false, save_error: None },
        }
        let disk = Disk { version: 1, devices: next.values().cloned().collect() };
        let save_error = write_json(&self.devices_path, &disk).err().map(|e| format!("{e:#}"));
        g.table = next;
        // Unsaved: the next `flush` (shutdown) tries again.
        g.dirty = save_error.is_some();
        Revoked { changed: true, save_error }
    }
    fn revoked(&self) -> Vec<Fp> {
        self.lock().table.values().filter(|d| d.revoked).map(|d| d.fp).collect()
    }
    fn join_hash(&self) -> Option<String> {
        self.lock().join.clone()
    }
    fn set_join_hash(&self, hash: &str) -> Result<()> {
        let mut g = self.lock();
        let hash = hash.trim();
        write_private(&self.join_path, format!("{hash}\n").as_bytes())?;
        g.join = Some(hash.to_string());
        Ok(())
    }
    fn seen(&self, fp: &Fp, at: &str) {
        let mut g = self.lock();
        if let Some(d) = g.table.get_mut(fp) {
            d.last_seen = Some(at.to_string());
            g.dirty = true;
        }
    }
    fn flush(&self) -> Result<()> {
        let mut g = self.lock();
        if g.dirty {
            let disk = Disk { version: 1, devices: g.table.values().cloned().collect() };
            write_json(&self.devices_path, &disk)?;
            g.dirty = false;
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;

    fn fp(n: u8) -> Fp {
        Fp([n; 32])
    }
    fn open(d: &tempfile::TempDir) -> FileRegistry {
        FileRegistry::open(&d.path().join("data")).unwrap()
    }

    #[test]
    fn enroll_bind_revoke_persist_across_reopen() {
        let d = tempfile::tempdir().unwrap();
        let r = open(&d);
        r.enroll(fp(1), "t").unwrap();
        assert_eq!(r.bind_id(&fp(1), "123456789").unwrap(), Bind::New);
        drop(r);
        let r = open(&d);
        assert_eq!(r.by_id("123456789").unwrap().fp, fp(1));
        assert_eq!(r.count(), 1);
        assert!(r.revoke(&fp(1)).changed);
        assert_eq!(r.revoked(), vec![fp(1)]);
        assert_eq!(r.count(), 0);
        drop(r);
        let r = open(&d);
        assert_eq!(r.revoked(), vec![fp(1)]);
        assert!(r.by_id("123456789").is_none());
        assert!(r.enroll(fp(1), "t").is_err());
        assert!(!r.revoke(&fp(1)).changed);
        assert!(!r.revoke(&fp(9)).changed);
    }

    #[test]
    fn an_id_belongs_to_the_first_key_that_registers_it() {
        let d = tempfile::tempdir().unwrap();
        let r = open(&d);
        r.enroll(fp(1), "t").unwrap();
        r.enroll(fp(2), "t").unwrap();
        assert_eq!(r.bind_id(&fp(1), "123456789").unwrap(), Bind::New);
        assert_eq!(r.bind_id(&fp(2), "123456789").unwrap(), Bind::Taken);
        assert_eq!(r.bind_id(&fp(1), "123456789").unwrap(), Bind::Same);
        assert!(r.unbind("123456789").unwrap());
        assert!(!r.unbind("123456789").unwrap());
        assert_eq!(r.bind_id(&fp(2), "123456789").unwrap(), Bind::New);
        assert!(r.bind_id(&fp(7), "555555555").is_err());
    }

    #[test]
    fn concurrent_bind_of_one_new_id_has_exactly_one_winner() {
        let d = tempfile::tempdir().unwrap();
        let r = Arc::new(open(&d));
        let hs: Vec<_> = (1..=2u8)
            .map(|n| {
                let r = r.clone();
                std::thread::spawn(move || {
                    r.enroll(fp(n), "t").unwrap();
                    r.bind_id(&fp(n), "123456789").unwrap()
                })
            })
            .collect();
        let mut res: Vec<Bind> = hs.into_iter().map(|h| h.join().unwrap()).collect();
        res.sort_by_key(|b| *b == Bind::Taken);
        assert_eq!(res, vec![Bind::New, Bind::Taken]);
        assert_eq!(r.list().iter().filter(|x| x.id.as_deref() == Some("123456789")).count(), 1);
    }

    #[test]
    fn binding_a_second_id_releases_the_first() {
        let d = tempfile::tempdir().unwrap();
        let r = open(&d);
        r.enroll(fp(1), "t").unwrap();
        r.enroll(fp(2), "t").unwrap();
        assert_eq!(r.bind_id(&fp(1), "111111111").unwrap(), Bind::New);
        assert_eq!(r.bind_id(&fp(1), "222222222").unwrap(), Bind::New);
        assert!(r.by_id("111111111").is_none());
        assert_eq!(r.get(&fp(1)).unwrap().id.as_deref(), Some("222222222"));
        assert_eq!(r.bind_id(&fp(2), "111111111").unwrap(), Bind::New);
    }

    #[test]
    fn last_seen_is_kept_after_flush_and_reopen() {
        let d = tempfile::tempdir().unwrap();
        let r = open(&d);
        r.enroll(fp(1), "t").unwrap();
        r.seen(&fp(1), "2026-01-01T00:00:00Z");
        assert_eq!(open(&d).get(&fp(1)).unwrap().last_seen, None);
        r.flush().unwrap();
        assert_eq!(open(&d).get(&fp(1)).unwrap().last_seen.as_deref(), Some("2026-01-01T00:00:00Z"));
    }

    #[test]
    fn mark_all_stale_skips_revoked_and_persists() {
        let d = tempfile::tempdir().unwrap();
        let r = open(&d);
        for n in 1..=3 {
            r.enroll(fp(n), "t").unwrap();
        }
        assert!(r.revoke(&fp(3)).changed);
        assert_eq!(r.mark_all_stale().unwrap(), 2);
        // Already stale: nothing more to mark.
        assert_eq!(r.mark_all_stale().unwrap(), 0);
        let r = open(&d);
        assert!(r.get(&fp(1)).unwrap().stale && r.get(&fp(2)).unwrap().stale);
        let gone = r.get(&fp(3)).unwrap();
        assert!(gone.revoked && !gone.stale);
        // Stale devices still count and are no revocations.
        assert_eq!(r.count(), 2);
        assert_eq!(r.revoked(), vec![fp(3)]);
    }

    #[test]
    fn enroll_clears_stale_and_keeps_the_id() {
        let d = tempfile::tempdir().unwrap();
        let r = open(&d);
        r.enroll(fp(1), "t").unwrap();
        assert_eq!(r.bind_id(&fp(1), "123456789").unwrap(), Bind::New);
        let before = r.get(&fp(1)).unwrap();
        assert_eq!(r.mark_all_stale().unwrap(), 1);
        // Still holding its ID while stale.
        assert_eq!(r.by_id("123456789").unwrap().fp, fp(1));
        r.enroll(fp(1), "t").unwrap();
        let r = open(&d);
        let after = r.get(&fp(1)).unwrap();
        assert!(!after.stale);
        assert_eq!(after.id.as_deref(), Some("123456789"));
        assert_eq!(after.enrolled_at, before.enrolled_at);
        assert_eq!(r.bind_id(&fp(1), "123456789").unwrap(), Bind::Same);
    }

    #[test]
    fn old_devices_json_without_stale_loads() {
        let d = tempfile::tempdir().unwrap();
        let data = d.path().join("data");
        std::fs::create_dir_all(&data).unwrap();
        let old = format!(
            r#"{{"version":1,"devices":[{{"fp":"{}","tenant":"default","id":"123456789","enrolled_at":"2026-01-01T00:00:00Z","revoked":false}}]}}"#,
            fp(1)
        );
        std::fs::write(data.join("devices.json"), old).unwrap();
        let r = FileRegistry::open(&data).unwrap();
        let dev = r.get(&fp(1)).unwrap();
        assert!(!dev.stale && !dev.revoked);
        assert_eq!(dev.id.as_deref(), Some("123456789"));
    }

    #[test]
    fn join_hash_roundtrip() {
        let d = tempfile::tempdir().unwrap();
        let r = open(&d);
        assert_eq!(r.join_hash(), None);
        r.set_join_hash("abcdef").unwrap();
        assert_eq!(open(&d).join_hash().as_deref(), Some("abcdef"));
    }

    #[cfg(unix)]
    #[test]
    fn write_failure_leaves_memory_and_file_untouched() {
        use std::os::unix::fs::PermissionsExt;
        let d = tempfile::tempdir().unwrap();
        let data = d.path().join("data");
        let r = FileRegistry::open(&data).unwrap();
        r.enroll(fp(1), "t").unwrap();
        std::fs::set_permissions(&data, std::fs::Permissions::from_mode(0o500)).unwrap();
        // As root chmod does not stop writes; then there is nothing to test.
        let writable = std::fs::write(data.join("probe"), b"x").is_ok();
        if !writable {
            assert!(r.enroll(fp(2), "t").is_err());
            assert!(r.get(&fp(2)).is_none());
            assert!(r.bind_id(&fp(1), "123456789").is_err());
            assert!(r.get(&fp(1)).unwrap().id.is_none());
            // Revoke is the exception: in effect in memory, with the write error reported.
            let v = r.revoke(&fp(1));
            assert!(v.changed && v.save_error.is_some());
            assert!(r.get(&fp(1)).unwrap().revoked);
        }
        std::fs::set_permissions(&data, std::fs::Permissions::from_mode(0o700)).unwrap();
        let _ = std::fs::remove_file(data.join("probe"));
        if !writable {
            let r = FileRegistry::open(&data).unwrap();
            assert!(r.get(&fp(1)).is_some());
            assert!(r.get(&fp(2)).is_none());
        }
    }

    #[test]
    fn open_reports_which_directory_failed() {
        let d = tempfile::tempdir().unwrap();
        let f = d.path().join("afile");
        std::fs::write(&f, b"x").unwrap();
        let e = FileRegistry::open(&f).err().unwrap();
        assert!(format!("{e:#}").contains(&f.display().to_string()), "{e:#}");
    }

    #[test]
    fn unknown_version_names_the_file() {
        let d = tempfile::tempdir().unwrap();
        let data = d.path().join("data");
        std::fs::create_dir_all(&data).unwrap();
        std::fs::write(data.join("devices.json"), br#"{"version":2,"devices":[]}"#).unwrap();
        let e = FileRegistry::open(&data).err().unwrap();
        assert!(format!("{e:#}").contains("devices.json"), "{e:#}");
    }

    #[cfg(unix)]
    #[test]
    fn files_are_private() {
        use std::os::unix::fs::PermissionsExt;
        let d = tempfile::tempdir().unwrap();
        let r = open(&d);
        r.enroll(fp(1), "t").unwrap();
        r.set_join_hash("ab").unwrap();
        let data = d.path().join("data");
        let mode = |p: &std::path::Path| std::fs::metadata(p).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode(&data.join("devices.json")), 0o600);
        assert_eq!(mode(&data.join("join")), 0o600);
        assert_eq!(mode(&data), 0o700);
    }
}
