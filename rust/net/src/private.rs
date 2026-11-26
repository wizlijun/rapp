//! “设成私有” (spec §13.2): a directory or file only this user can open. unix: mode 0700 / 0600.
//! Windows: the inherited entries are dropped and full control is left to this user, SYSTEM and
//! Administrators; a directory passes that on to everything created inside.

use std::path::Path;

/// `NT AUTHORITY\SYSTEM`.
pub const SID_SYSTEM: &str = "S-1-5-18";
/// `BUILTIN\Administrators`.
pub const SID_ADMINS: &str = "S-1-5-32-544";

/// unix: mode 0700. Windows: inheritance off; full control for this user, SYSTEM, Administrators,
/// inherited by everything created inside.
pub fn dir(path: &Path) -> std::io::Result<()> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o700))
    }
    #[cfg(windows)]
    {
        crate::win::set_private(path, &[SID_SYSTEM, SID_ADMINS], true)
    }
    #[cfg(not(any(unix, windows)))]
    {
        let _ = path;
        Ok(())
    }
}

/// unix: mode 0600. Windows: inheritance off; full control for the same three.
pub fn file(path: &Path) -> std::io::Result<()> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))
    }
    #[cfg(windows)]
    {
        crate::win::set_private(path, &[SID_SYSTEM, SID_ADMINS], false)
    }
    #[cfg(not(any(unix, windows)))]
    {
        let _ = path;
        Ok(())
    }
}

/// Who may open a file or directory, as `acl` reads it back.
#[cfg(windows)]
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Acl {
    /// Nothing is inherited from the parent.
    pub protected: bool,
    /// The SIDs of the access-allowed entries, sorted, no duplicates.
    pub sids: Vec<String>,
}

#[cfg(windows)]
pub fn acl(path: &Path) -> std::io::Result<Acl> {
    let (protected, mut sids) = crate::win::read_acl(path)?;
    sids.sort();
    sids.dedup();
    Ok(Acl { protected, sids })
}

#[cfg(windows)]
pub fn current_user_sid() -> std::io::Result<String> {
    crate::win::current_user_sid()
}

/// What `dir` and `file` leave behind: protected, and only this user, SYSTEM and Administrators.
/// Public so the tests of other crates can check a file their code made private.
#[cfg(windows)]
pub fn private_acl() -> std::io::Result<Acl> {
    let mut sids = vec![current_user_sid()?, SID_SYSTEM.to_string(), SID_ADMINS.to_string()];
    sids.sort();
    sids.dedup();
    Ok(Acl { protected: true, sids })
}

/// `private_acl`, for tests here and in `config`.
#[cfg(all(test, windows))]
pub(crate) fn expected_acl() -> Acl {
    private_acl().unwrap()
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A directory under a name that is neither ASCII nor free of spaces (Review Focus 1).
    fn named_dir() -> (tempfile::TempDir, std::path::PathBuf) {
        let t = tempfile::tempdir().unwrap();
        let d = t.path().join("张 三");
        std::fs::create_dir(&d).unwrap();
        (t, d)
    }

    #[test]
    fn dir_and_file_are_private() {
        let (_t, d) = named_dir();
        let f = d.join("k");
        std::fs::write(&f, b"x").unwrap();
        dir(&d).unwrap();
        file(&f).unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(std::fs::metadata(&d).unwrap().permissions().mode() & 0o777, 0o700);
            assert_eq!(std::fs::metadata(&f).unwrap().permissions().mode() & 0o777, 0o600);
        }
        #[cfg(windows)]
        {
            assert_eq!(acl(&d).unwrap(), expected_acl());
            assert_eq!(acl(&f).unwrap(), expected_acl());
        }
    }

    #[cfg(windows)]
    #[test]
    fn dir_drops_what_it_inherited() {
        // Review Focus 2: a folder that grants `Users` (as `D:\` does) must not keep it.
        const USERS: &str = "S-1-5-32-545";
        const EVERYONE: &str = "S-1-1-0";
        let (_t, d) = named_dir();
        let root = std::env::var_os("SystemRoot").expect("SystemRoot");
        let icacls = std::path::Path::new(&root).join("System32").join("icacls.exe");
        let out = crate::proc::command(&icacls)
            .arg(&d)
            .args(["/grant", &format!("*{USERS}:(OI)(CI)F")])
            .output()
            .unwrap();
        assert!(out.status.success(), "icacls: {}", String::from_utf8_lossy(&out.stderr));
        assert!(acl(&d).unwrap().sids.iter().any(|s| s == USERS), "the grant must have landed for this test to mean anything");
        dir(&d).unwrap();
        let a = acl(&d).unwrap();
        assert!(a.protected);
        assert!(!a.sids.iter().any(|s| s == USERS || s == EVERYONE), "{:?}", a.sids);
        assert_eq!(a, expected_acl());
    }

    #[cfg(windows)]
    #[test]
    fn files_made_inside_a_private_dir_are_private() {
        let (_t, d) = named_dir();
        dir(&d).unwrap();
        std::fs::write(d.join("k"), b"x").unwrap();
        std::fs::create_dir(d.join("sub")).unwrap();
        assert_eq!(acl(&d.join("k")).unwrap().sids, expected_acl().sids);
        assert_eq!(acl(&d.join("sub")).unwrap().sids, expected_acl().sids);
    }
}
