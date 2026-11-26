//! `<dir>/state.json`: file 0600, directory 0700. Writes go to `state.json.tmp` and are renamed over.

use std::fs;
use std::io::{ErrorKind, Write};
#[cfg(unix)]
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt, PermissionsExt};
use std::path::Path;

use crate::store::Store;

const FILE: &str = "state.json";

/// `(None, None)`: no file. A file that cannot be read or parsed is moved to `state.json.bad`
/// and the reason (an error kind, never file contents) is returned.
pub fn load(dir: &Path) -> (Option<Store>, Option<String>) {
    let path = dir.join(FILE);
    let loaded = match fs::read(&path) {
        Ok(bytes) => serde_json::from_slice::<Store>(&bytes).map_err(|_| "parse".to_string()),
        Err(e) if e.kind() == ErrorKind::NotFound => return (None, None),
        Err(e) => Err(format!("{:?}", e.kind())),
    };
    match loaded {
        Ok(store) => (Some(store), None),
        Err(why) => {
            let _ = fs::rename(&path, dir.join(format!("{FILE}.bad")));
            (None, Some(why))
        }
    }
}

pub fn save(dir: &Path, store: &Store) -> std::io::Result<u64> {
    let json = serde_json::to_vec(store).map_err(std::io::Error::other)?;
    write_bytes(dir, &json)
}

/// Writes already-serialized store JSON; lets the saver serialize under the lock and write after.
pub fn write_bytes(dir: &Path, json: &[u8]) -> std::io::Result<u64> {
    // On Windows there are no mode bits: the directory sits under the service's home
    // (`<data root>\local`), whose private access list (only the user, SYSTEM and
    // Administrators) new files inherit.
    let mut b = fs::DirBuilder::new();
    b.recursive(true);
    #[cfg(unix)]
    b.mode(0o700);
    b.create(dir)?;
    // `mode` above and below only applies to what is created now: a directory or a left-over
    // tmp file that is already there keeps its mode unless it is set (spec §8.2).
    #[cfg(unix)]
    private(dir, 0o700)?;
    let tmp = dir.join(format!("{FILE}.tmp"));
    let mut opts = fs::OpenOptions::new();
    opts.write(true).create(true).truncate(true);
    #[cfg(unix)]
    opts.mode(0o600);
    let mut f = opts.open(&tmp)?;
    #[cfg(unix)]
    if f.metadata()?.permissions().mode() & 0o777 != 0o600 {
        f.set_permissions(fs::Permissions::from_mode(0o600))?;
    }
    f.write_all(json)?;
    f.sync_all()?;
    drop(f);
    fs::rename(&tmp, dir.join(FILE))?;
    Ok(json.len() as u64)
}

/// Sets `path` to `mode` when it has another.
#[cfg(unix)]
fn private(path: &Path, mode: u32) -> std::io::Result<()> {
    if fs::metadata(path)?.permissions().mode() & 0o777 != mode {
        fs::set_permissions(path, fs::Permissions::from_mode(mode))?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::event::parse_line;

    fn filled() -> Store {
        let mut s = Store::new(100_000, 1000);
        for l in include_str!("../api/samples/term-events.ndjson").lines().filter(|l| !l.trim().is_empty()) {
            s.apply(parse_line(l).unwrap(), 0);
        }
        s
    }

    #[test]
    fn saved_and_loaded_are_the_same() {
        let d = tempfile::tempdir().unwrap();
        let mut s = filled();
        s.put_desk("appA", &serde_json::json!({"device":"iPad","sessions":[{"id":"111111111","app":"x","name":"X"}]}), 5).unwrap();
        assert!(save(d.path(), &s).unwrap() > 0);
        let (back, why) = load(d.path());
        let back = back.unwrap();
        assert_eq!(why, None);
        assert_eq!(back.state(), s.state());
        assert_eq!(back.state()["desks"], s.state()["desks"]);
        assert_eq!(back.state()["desks"][0]["fp"], "appA");
        assert_eq!(back.queue(None, 50).unwrap(), s.queue(None, 50).unwrap());
        let (none, why) = load(&d.path().join("none"));
        assert!(none.is_none() && why.is_none());
    }

    #[test]
    fn an_old_file_without_desks_loads() {
        let d = tempfile::tempdir().unwrap();
        let mut v = serde_json::to_value(filled()).unwrap();
        assert!(v.as_object_mut().unwrap().remove("desks").is_some());
        fs::write(d.path().join("state.json"), v.to_string()).unwrap();
        let (s, why) = load(d.path());
        assert_eq!(why, None);
        assert_eq!(s.unwrap().state()["desks"], serde_json::json!([]));
        assert!(!d.path().join("state.json.bad").exists());
    }

    #[test]
    #[cfg(unix)]
    fn files_are_private() {
        let d = tempfile::tempdir().unwrap();
        let dir = d.path().join("data");
        save(&dir, &filled()).unwrap();
        let mode = |p: &Path| fs::metadata(p).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode(&dir), 0o700);
        assert_eq!(mode(&dir.join("state.json")), 0o600);
        assert!(!dir.join("state.json.tmp").exists());
    }

    #[test]
    #[cfg(unix)]
    fn loose_modes_are_made_private() {
        let d = tempfile::tempdir().unwrap();
        let dir = d.path().join("data");
        fs::create_dir(&dir).unwrap();
        fs::set_permissions(&dir, fs::Permissions::from_mode(0o755)).unwrap();
        for f in ["state.json", "state.json.tmp"] {
            fs::write(dir.join(f), "{}").unwrap();
            fs::set_permissions(dir.join(f), fs::Permissions::from_mode(0o644)).unwrap();
        }
        save(&dir, &filled()).unwrap();
        let mode = |p: &Path| fs::metadata(p).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode(&dir), 0o700);
        assert_eq!(mode(&dir.join("state.json")), 0o600);
        assert!(!dir.join("state.json.tmp").exists());
    }

    #[test]
    fn a_broken_file_is_moved_aside() {
        let d = tempfile::tempdir().unwrap();
        fs::write(d.path().join("state.json"), "{not json").unwrap();
        let (s, why) = load(d.path());
        assert!(s.is_none() && why.is_some());
        assert!(d.path().join("state.json.bad").exists());
        assert!(!d.path().join("state.json").exists());
    }
}
