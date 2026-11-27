//! `<dir>/<file>`, one file per builtin: file 0600, directory 0700. Writes go to `<file>.tmp` and
//! are renamed over.

use std::fs;
use std::io::{ErrorKind, Write};
#[cfg(unix)]
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt, PermissionsExt};
use std::path::Path;

/// The bytes of `<dir>/<file>`; `Ok(None)` when there is none. Err: why it cannot be read (an
/// error kind, never file contents).
pub fn read(dir: &Path, file: &str) -> Result<Option<Vec<u8>>, String> {
    match fs::read(dir.join(file)) {
        Ok(bytes) => Ok(Some(bytes)),
        Err(e) if e.kind() == ErrorKind::NotFound => Ok(None),
        Err(e) => Err(format!("{:?}", e.kind())),
    }
}

/// Moves a file that cannot be read or loaded to `<file>.bad`, so the next save does not
/// overwrite what may still be rescued by hand.
pub fn move_aside(dir: &Path, file: &str) {
    let _ = fs::rename(dir.join(file), dir.join(format!("{file}.bad")));
}

/// Writes `bytes` to `<dir>/<file>` (via `<file>.tmp`), the directory made if needed.
pub fn write(dir: &Path, file: &str, bytes: &[u8]) -> std::io::Result<u64> {
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
    let tmp = dir.join(format!("{file}.tmp"));
    let mut opts = fs::OpenOptions::new();
    opts.write(true).create(true).truncate(true);
    #[cfg(unix)]
    opts.mode(0o600);
    let mut f = opts.open(&tmp)?;
    #[cfg(unix)]
    if f.metadata()?.permissions().mode() & 0o777 != 0o600 {
        f.set_permissions(fs::Permissions::from_mode(0o600))?;
    }
    f.write_all(bytes)?;
    f.sync_all()?;
    drop(f);
    fs::rename(&tmp, dir.join(file))?;
    Ok(bytes.len() as u64)
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

    const FILE: &str = "state.json";
    const DATA: &[u8] = br#"{"some":"bytes"}"#;

    #[test]
    fn saved_and_loaded_are_the_same() {
        let d = tempfile::tempdir().unwrap();
        assert_eq!(write(d.path(), FILE, DATA).unwrap(), DATA.len() as u64);
        assert_eq!(read(d.path(), FILE), Ok(Some(DATA.to_vec())));
        assert_eq!(read(&d.path().join("none"), FILE), Ok(None));
    }

    #[test]
    #[cfg(unix)]
    fn files_are_private() {
        let d = tempfile::tempdir().unwrap();
        let dir = d.path().join("data");
        write(&dir, FILE, DATA).unwrap();
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
        write(&dir, FILE, DATA).unwrap();
        let mode = |p: &Path| fs::metadata(p).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode(&dir), 0o700);
        assert_eq!(mode(&dir.join("state.json")), 0o600);
        assert!(!dir.join("state.json.tmp").exists());
    }

    #[test]
    fn a_broken_file_is_moved_aside() {
        let d = tempfile::tempdir().unwrap();
        fs::write(d.path().join("state.json"), "{not json").unwrap();
        move_aside(d.path(), FILE);
        assert!(d.path().join("state.json.bad").exists());
        assert!(!d.path().join("state.json").exists());
        assert_eq!(read(d.path(), FILE), Ok(None));
    }

    #[test]
    #[cfg(unix)]
    fn an_unreadable_file_is_an_error_kind() {
        let d = tempfile::tempdir().unwrap();
        fs::create_dir(d.path().join("state.json")).unwrap();
        assert!(read(d.path(), FILE).is_err());
    }

    #[test]
    fn each_file_is_its_own() {
        let dir = tempfile::tempdir().unwrap();
        write(dir.path(), "a.json", b"1").unwrap();
        write(dir.path(), "b.json", b"2").unwrap();
        move_aside(dir.path(), "a.json");
        assert_eq!(read(dir.path(), "a.json"), Ok(None));
        assert_eq!(read(dir.path(), "b.json"), Ok(Some(b"2".to_vec())));
    }
}
