//! Config directory and private (0600) JSON files (spec §3).

use anyhow::{Context, Result};
use serde::{de::DeserializeOwned, Serialize};
use std::path::{Path, PathBuf};

/// `RAPP_HOME`, else the platform config dir + `rapp`.
pub fn home() -> PathBuf {
    if let Some(h) = std::env::var_os("RAPP_HOME") {
        return PathBuf::from(h);
    }
    let env = |k| std::env::var_os(k).map(PathBuf::from);
    let user = env("HOME").unwrap_or_else(|| PathBuf::from("."));
    let base = if cfg!(target_os = "macos") {
        user.join("Library/Application Support")
    } else if cfg!(windows) {
        env("APPDATA").unwrap_or(user)
    } else {
        env("XDG_CONFIG_HOME").unwrap_or_else(|| user.join(".config"))
    };
    base.join("rapp")
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
