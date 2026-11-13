//! `<home>/paired.json`: the devices this one has accepted, by fingerprint.

use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::{SystemTime, UNIX_EPOCH};

use anyhow::{Context, Result};
use rapp_wire::Fp;
use serde::{Deserialize, Serialize};

#[derive(Clone, Serialize, Deserialize)]
struct Entry {
    fp: Fp,
    name: String,
    since: String,
}

pub struct Paired {
    path: PathBuf,
    list: Mutex<Vec<Entry>>,
}

impl Paired {
    /// A missing file is an empty list; a file that does not parse is an error (the caller
    /// decides whether to log it and carry on with an empty list).
    pub fn load(home: &Path) -> Result<Paired> {
        let path = home.join("paired.json");
        let list = match std::fs::read(&path) {
            Ok(b) => serde_json::from_slice(&b).with_context(|| format!("parse {}", path.display()))?,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Vec::new(),
            Err(e) => return Err(e).with_context(|| format!("read {}", path.display())),
        };
        Ok(Paired { path, list: Mutex::new(list) })
    }

    pub fn contains(&self, fp: &Fp) -> bool {
        self.list.lock().unwrap().iter().any(|e| e.fp == *fp)
    }

    /// Adds the device, or updates the name of one already there; writes the file.
    pub fn add(&self, fp: &Fp, name: &str) -> Result<()> {
        let mut list = self.list.lock().unwrap();
        let mut next = list.clone();
        match next.iter_mut().find(|e| e.fp == *fp) {
            Some(e) => e.name = name.to_string(),
            None => next.push(Entry { fp: *fp, name: name.to_string(), since: now_rfc3339() }),
        }
        rapp_net::config::write_private(&self.path, &serde_json::to_vec_pretty(&next)?)?;
        *list = next;
        Ok(())
    }
}

fn now_rfc3339() -> String {
    rfc3339(SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0))
}

/// UTC seconds since the epoch as `YYYY-MM-DDTHH:MM:SSZ` (civil-from-days).
fn rfc3339(secs: u64) -> String {
    let (days, rem) = ((secs / 86400) as i64, secs % 86400);
    let z = days + 719468;
    let era = z.div_euclid(146097);
    let doe = z.rem_euclid(146097);
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = yoe + era * 400 + i64::from(m <= 2);
    format!("{y:04}-{m:02}-{d:02}T{:02}:{:02}:{:02}Z", rem / 3600, rem % 3600 / 60, rem % 60)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn add_then_load() {
        let dir = tempfile::tempdir().unwrap();
        let p = Paired::load(dir.path()).unwrap();
        assert!(!p.contains(&Fp([1; 32])));
        p.add(&Fp([1; 32]), "laptop").unwrap();
        let q = Paired::load(dir.path()).unwrap();
        assert!(q.contains(&Fp([1; 32])));
        assert!(!q.contains(&Fp([2; 32])));
        let v: serde_json::Value = serde_json::from_slice(&std::fs::read(dir.path().join("paired.json")).unwrap()).unwrap();
        assert_eq!(v[0]["fp"], Fp([1; 32]).to_string());
        assert_eq!(v[0]["name"], "laptop");
        assert!(v[0]["since"].as_str().unwrap().ends_with('Z'));
    }

    #[cfg(unix)]
    #[test]
    fn file_is_private() {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::tempdir().unwrap();
        Paired::load(dir.path()).unwrap().add(&Fp([1; 32]), "x").unwrap();
        let mode = std::fs::metadata(dir.path().join("paired.json")).unwrap().permissions().mode();
        assert_eq!(mode & 0o777, 0o600);
    }

    #[test]
    fn add_twice_keeps_one_entry() {
        let dir = tempfile::tempdir().unwrap();
        let p = Paired::load(dir.path()).unwrap();
        p.add(&Fp([1; 32]), "old").unwrap();
        p.add(&Fp([1; 32]), "new").unwrap();
        let v: serde_json::Value = serde_json::from_slice(&std::fs::read(dir.path().join("paired.json")).unwrap()).unwrap();
        assert_eq!(v.as_array().unwrap().len(), 1);
        assert_eq!(v[0]["name"], "new");
    }

    #[test]
    fn corrupt_file_is_an_error_missing_is_empty() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join("paired.json"), "{nope").unwrap();
        assert!(Paired::load(dir.path()).is_err());
    }

    #[test]
    fn formats_utc_time() {
        assert_eq!(rfc3339(0), "1970-01-01T00:00:00Z");
        assert_eq!(rfc3339(1_709_164_800 + 86399), "2024-02-29T23:59:59Z");
    }
}
