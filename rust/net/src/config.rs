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
    f.write_all(data)?;
    f.sync_all()?;
    std::fs::rename(&tmp, path).with_context(|| format!("rename to {}", path.display()))?;
    Ok(())
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
pub fn hostname() -> String {
    std::process::Command::new("hostname")
        .output()
        .ok()
        .and_then(|o| String::from_utf8(o.stdout).ok())
        .map(|s| s.trim().trim_end_matches(".local").to_string())
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
}
