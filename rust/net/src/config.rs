//! Data root, its subdirectories and private (0600) JSON files (spec §3).

use anyhow::{Context, Result};
use serde::{de::DeserializeOwned, Serialize};
use std::ffi::OsString;
use std::path::{Path, PathBuf};

/// Name of the data-root pointer file, kept in the platform config dir.
pub const POINTER_FILE: &str = "data-root";

type Var<'a> = &'a dyn Fn(&str) -> Option<OsString>;

/// An environment variable, with empty meaning unset (R6).
fn nonempty(var: Var, k: &str) -> Option<PathBuf> {
    var(k).filter(|v| !v.is_empty()).map(PathBuf::from)
}

fn user_dir(var: Var, os: &str) -> PathBuf {
    let k = if os == "windows" { "USERPROFILE" } else { "HOME" };
    nonempty(var, k).unwrap_or_else(|| PathBuf::from("."))
}

/// The data root: `RAPP_HOME`, else the pointer file's path, else `~/rapp`.
pub fn home() -> PathBuf {
    home_from(&|k| std::env::var_os(k), std::env::consts::OS, &|p| std::fs::read_to_string(p).ok())
}

/// `home` with the environment and file reads passed in, so tests touch neither.
pub fn home_from(var: Var, os: &str, read: &dyn Fn(&Path) -> Option<String>) -> PathBuf {
    if let Some(h) = nonempty(var, "RAPP_HOME") {
        return h;
    }
    let pointer = platform_config_dir_from(var, os).join(POINTER_FILE);
    if let Some(p) = read(&pointer).as_deref().and_then(parse_pointer) {
        return p;
    }
    user_dir(var, os).join("rapp")
}

/// First line, trimmed; only an absolute path (`/…`, `X:\…`, `\\…`) counts (R6).
fn parse_pointer(text: &str) -> Option<PathBuf> {
    let line = text.lines().next()?.trim();
    let b = line.as_bytes();
    let abs = line.starts_with('/')
        || line.starts_with("\\\\")
        || (b.len() >= 3 && b[0].is_ascii_alphabetic() && b[1] == b':' && (b[2] == b'\\' || b[2] == b'/'));
    abs.then(|| PathBuf::from(line))
}

/// The old per-platform config dir (ignores `RAPP_HOME`).
pub fn platform_config_dir() -> PathBuf {
    platform_config_dir_from(&|k| std::env::var_os(k), std::env::consts::OS)
}

pub fn platform_config_dir_from(var: Var, os: &str) -> PathBuf {
    let user = user_dir(var, os);
    let base = match os {
        "macos" => user.join("Library/Application Support"),
        "windows" => nonempty(var, "APPDATA").unwrap_or(user),
        _ => nonempty(var, "XDG_CONFIG_HOME").unwrap_or_else(|| user.join(".config")),
    };
    base.join("rapp")
}

/// Where an upgrade copies old data from (R2): `RAPP_HOME`, else the old platform dir.
pub fn legacy_dir() -> PathBuf {
    legacy_dir_from(&|k| std::env::var_os(k), std::env::consts::OS)
}

pub fn legacy_dir_from(var: Var, os: &str) -> PathBuf {
    nonempty(var, "RAPP_HOME").unwrap_or_else(|| platform_config_dir_from(var, os))
}

pub fn pointer_file() -> PathBuf {
    platform_config_dir().join(POINTER_FILE)
}

/// This device's private dir (secrets, logs, state); never in git.
pub fn local(root: &Path) -> PathBuf {
    root.join("local")
}

pub fn shared(root: &Path) -> PathBuf {
    root.join("shared")
}

pub fn device(root: &Path, id: &str) -> PathBuf {
    root.join("devices").join(id)
}

pub fn files(root: &Path) -> PathBuf {
    root.join("files")
}

/// Writes `data` with mode 0600 (via a temp file + rename, so readers never see half a file).
pub fn write_private(path: &Path, data: &[u8]) -> Result<()> {
    use std::io::Write;
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir).with_context(|| format!("create {}", dir.display()))?;
    }
    let tmp = path.with_extension("tmp");
    let mut opts = std::fs::OpenOptions::new();
    opts.write(true).create(true).truncate(true);
    #[cfg(unix)]
    std::os::unix::fs::OpenOptionsExt::mode(&mut opts, 0o600);
    let mut f = opts.open(&tmp).with_context(|| format!("write {}", tmp.display()))?;
    // Made private while still empty, so no secret is ever in a broader file (Review Focus 3).
    #[cfg(windows)]
    crate::private::file(&tmp).with_context(|| format!("make private {}", tmp.display()))?;
    f.write_all(data)?;
    f.sync_all()?;
    #[cfg(not(windows))]
    std::fs::rename(&tmp, path).with_context(|| format!("rename to {}", path.display()))?;
    #[cfg(windows)]
    rename_retrying(&tmp, path).with_context(|| format!("rename to {}", path.display()))?;
    Ok(())
}

/// `rename`, retried while another program (antivirus, indexer) holds `to` open for a moment:
/// 10 tries, 20 ms apart. The old `to` stays whole until one succeeds; on the last failure the
/// temporary file is removed.
#[cfg(windows)]
fn rename_retrying(from: &Path, to: &Path) -> std::io::Result<()> {
    const TRIES: u32 = 10;
    // ERROR_ACCESS_DENIED, ERROR_SHARING_VIOLATION, ERROR_LOCK_VIOLATION.
    let busy = |e: &std::io::Error| e.kind() == std::io::ErrorKind::PermissionDenied || matches!(e.raw_os_error(), Some(5 | 32 | 33));
    let mut tried = 1;
    loop {
        match std::fs::rename(from, to) {
            Ok(()) => return Ok(()),
            Err(e) if busy(&e) && tried < TRIES => {
                tried += 1;
                std::thread::sleep(std::time::Duration::from_millis(20));
            }
            Err(e) => {
                let _ = std::fs::remove_file(from);
                return Err(e);
            }
        }
    }
}

/// `Ok(None)` when the file does not exist.
pub fn read_json<T: DeserializeOwned>(path: &Path) -> Result<Option<T>> {
    match std::fs::read(path) {
        Ok(b) => Ok(Some(serde_json::from_slice(&b).with_context(|| format!("parse {}", path.display()))?)),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(e) => Err(e).with_context(|| format!("read {}", path.display())),
    }
}

pub fn write_json<T: Serialize>(path: &Path, value: &T) -> Result<()> {
    let mut b = serde_json::to_vec_pretty(value)?;
    b.push(b'\n');
    write_private(path, &b)
}

/// This machine's name (`hostname`, without `.local`); "rapp" when unknown.
/// A's default device name and the name B introduces itself with.
#[cfg(not(windows))]
pub fn hostname() -> String {
    std::process::Command::new("hostname")
        .output()
        .ok()
        .and_then(|o| String::from_utf8(o.stdout).ok())
        .map(|s| s.trim().trim_end_matches(".local").to_string())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "rapp".into())
}

/// This machine's name from `COMPUTERNAME` (no child process, so no console window); "rapp" when
/// it is missing or empty.
#[cfg(windows)]
pub fn hostname() -> String {
    std::env::var("COMPUTERNAME")
        .ok()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "rapp".into())
}

#[cfg(test)]
mod tests {
    use super::*;

    type Env = Box<dyn Fn(&str) -> Option<std::ffi::OsString>>;
    fn env(vars: &'static [(&'static str, &'static str)]) -> Env {
        Box::new(move |k: &str| vars.iter().find(|(n, _)| *n == k).map(|(_, v)| std::ffi::OsString::from(v)))
    }

    #[test]
    fn data_root_rapp_home_then_pointer_then_home_rapp() {
        let none = |_: &Path| None;
        let ptr_at = PathBuf::from("/Users/u/Library/Application Support/rapp/data-root");
        let ptr = |p: &Path| (p == ptr_at).then(|| "/Volumes/D/rapp\n".to_string());
        assert_eq!(home_from(&env(&[("RAPP_HOME", "/h"), ("HOME", "/Users/u")]), "macos", &ptr), PathBuf::from("/h"));
        assert_eq!(home_from(&env(&[("HOME", "/Users/u")]), "macos", &ptr), PathBuf::from("/Volumes/D/rapp"));
        assert_eq!(home_from(&env(&[("HOME", "/Users/u")]), "macos", &none), PathBuf::from("/Users/u/rapp"));
        assert_eq!(home_from(&env(&[("RAPP_HOME", ""), ("HOME", "/Users/u")]), "macos", &none), PathBuf::from("/Users/u/rapp"));
    }

    #[test]
    fn a_bad_pointer_is_ignored() {
        for text in ["", "  \n", "rapp\n", "~/x"] {
            let read = |_: &Path| Some(text.to_string());
            assert_eq!(home_from(&env(&[("HOME", "/Users/u")]), "macos", &read), PathBuf::from("/Users/u/rapp"), "{text:?}");
        }
        let read = |_: &Path| Some("/a/b\nextra\n".to_string());
        assert_eq!(home_from(&env(&[("HOME", "/Users/u")]), "macos", &read), PathBuf::from("/a/b"));
    }

    #[test]
    fn three_systems() {
        let none = |_: &Path| None;
        let lin = env(&[("HOME", "/home/u"), ("XDG_CONFIG_HOME", "/xdg")]);
        assert_eq!(home_from(&lin, "linux", &none), PathBuf::from("/home/u/rapp"));
        assert_eq!(platform_config_dir_from(&lin, "linux"), PathBuf::from("/xdg/rapp"));
        assert_eq!(platform_config_dir_from(&env(&[("HOME", "/home/u")]), "linux"), PathBuf::from("/home/u/.config/rapp"));
        let win = env(&[("USERPROFILE", r"C:\Users\u"), ("APPDATA", r"C:\R")]);
        assert_eq!(home_from(&win, "windows", &none), PathBuf::from(r"C:\Users\u").join("rapp"));
        assert_eq!(platform_config_dir_from(&win, "windows"), PathBuf::from(r"C:\R").join("rapp"));
        let read = |p: &Path| (p == PathBuf::from(r"C:\R").join("rapp").join("data-root")).then(|| r"D:\rapp".to_string());
        assert_eq!(home_from(&win, "windows", &read), PathBuf::from(r"D:\rapp"));
    }

    #[test]
    fn legacy_dir_is_rapp_home_or_the_old_config_dir() {
        assert_eq!(legacy_dir_from(&env(&[("RAPP_HOME", "/h"), ("HOME", "/Users/u")]), "macos"), PathBuf::from("/h"));
        assert_eq!(
            legacy_dir_from(&env(&[("HOME", "/Users/u")]), "macos"),
            PathBuf::from("/Users/u/Library/Application Support/rapp")
        );
    }

    #[test]
    fn sub_dirs() {
        let r = Path::new("/r");
        assert_eq!(
            (local(r), shared(r), device(r, "123456789"), files(r)),
            (PathBuf::from("/r/local"), PathBuf::from("/r/shared"), PathBuf::from("/r/devices/123456789"), PathBuf::from("/r/files"))
        );
    }

    #[test]
    fn json_roundtrip_private() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("sub/x.json");
        assert_eq!(read_json::<Vec<u32>>(&path).unwrap(), None);
        write_json(&path, &vec![1u32, 2]).unwrap();
        assert_eq!(read_json::<Vec<u32>>(&path).unwrap(), Some(vec![1, 2]));
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mode = std::fs::metadata(&path).unwrap().permissions().mode();
            assert_eq!(mode & 0o777, 0o600);
        }
    }

    #[test]
    fn bad_json_is_an_error() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("x.json");
        std::fs::write(&path, "{").unwrap();
        assert!(read_json::<Vec<u32>>(&path).is_err());
    }

    /// `<tmp>/张 三` (Review Focus 1), created.
    fn named_dir() -> (tempfile::TempDir, PathBuf) {
        let t = tempfile::tempdir().unwrap();
        let d = t.path().join("张 三");
        std::fs::create_dir(&d).unwrap();
        (t, d)
    }

    #[test]
    fn write_private_replaces_and_stays_private() {
        let (_t, d) = named_dir();
        let path = d.join("k.json");
        write_private(&path, b"first").unwrap();
        write_private(&path, b"second").unwrap();
        assert_eq!(std::fs::read(&path).unwrap(), b"second");
        assert!(!d.join("k.tmp").exists());
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(std::fs::metadata(&path).unwrap().permissions().mode() & 0o777, 0o600);
        }
        #[cfg(windows)]
        assert_eq!(crate::private::acl(&path).unwrap(), crate::private::expected_acl());
    }

    /// Opens `path` the way a scanner might: readable, but without delete sharing, so it cannot be
    /// replaced while this handle is open.
    #[cfg(windows)]
    fn lock(path: &Path) -> std::fs::File {
        use std::os::windows::fs::OpenOptionsExt;
        const FILE_SHARE_READ: u32 = 1;
        std::fs::OpenOptions::new().read(true).share_mode(FILE_SHARE_READ).open(path).unwrap()
    }

    #[cfg(windows)]
    #[test]
    fn write_private_waits_out_a_short_lock() {
        // Review Focus 3.
        let (_t, d) = named_dir();
        let path = d.join("k.json");
        write_private(&path, b"old").unwrap();
        let held = lock(&path);
        let release = std::thread::spawn(move || {
            std::thread::sleep(std::time::Duration::from_millis(60));
            drop(held);
        });
        write_private(&path, b"new").unwrap();
        release.join().unwrap();
        assert_eq!(std::fs::read(&path).unwrap(), b"new");
        assert!(!d.join("k.tmp").exists());
    }

    #[cfg(windows)]
    #[test]
    fn write_private_keeps_the_old_file_when_the_lock_stays() {
        let (_t, d) = named_dir();
        let path = d.join("k.json");
        write_private(&path, b"old").unwrap();
        let held = lock(&path);
        assert!(write_private(&path, b"new").is_err());
        assert!(!d.join("k.tmp").exists());
        drop(held);
        assert_eq!(std::fs::read(&path).unwrap(), b"old");
    }

    #[cfg(windows)]
    #[test]
    fn hostname_comes_from_the_environment() {
        let want = std::env::var("COMPUTERNAME").unwrap();
        assert!(!want.is_empty());
        assert_eq!(hostname(), want.trim());
    }
}
