//! Locating worker binaries: `RAPP_BIN_DIR` → own dir → `PATH` (spec §3).

use std::path::{Path, PathBuf};

pub fn bin_dir_from_env() -> Option<PathBuf> {
    std::env::var_os("RAPP_BIN_DIR").map(PathBuf::from)
}

pub fn find(name: &str, bin_dir: Option<&Path>) -> Option<PathBuf> {
    let file = format!("{name}{}", std::env::consts::EXE_SUFFIX);
    let own = std::env::current_exe().ok().and_then(|p| p.parent().map(Path::to_path_buf));
    #[cfg(not(windows))]
    let path = std::env::var_os("PATH").map(|p| std::env::split_paths(&p).collect()).unwrap_or_default();
    // Sibling programs are found by full path only, never through `PATH` (spec §8.2 rule 3).
    #[cfg(windows)]
    let path: Vec<PathBuf> = Vec::new();
    bin_dir
        .map(Path::to_path_buf)
        .into_iter()
        .chain(own)
        .chain::<Vec<PathBuf>>(path)
        .map(|d| d.join(&file))
        .find(|p| p.is_file())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bin_dir_wins_then_path() {
        let dir = tempfile::tempdir().unwrap();
        let fake = dir.path().join(format!("rapp-zz-test{}", std::env::consts::EXE_SUFFIX));
        std::fs::write(&fake, "").unwrap();
        assert_eq!(find("rapp-zz-test", Some(dir.path())), Some(fake));
        assert_eq!(find("rapp-zz-missing", Some(dir.path())), None);
        // `sh` lives on PATH on every unix box.
        #[cfg(unix)]
        assert!(find("sh", Some(dir.path())).is_some());
    }

    #[cfg(windows)]
    #[test]
    fn never_looks_in_path() {
        // cmd.exe is on every PATH.
        assert!(find("cmd", None).is_none());
        let t = tempfile::tempdir().unwrap();
        let dir = t.path().join("张 三");
        std::fs::create_dir(&dir).unwrap();
        std::fs::write(dir.join("x.exe"), "").unwrap();
        assert_eq!(find("x", Some(&dir)), Some(dir.join("x.exe")));
    }
}
