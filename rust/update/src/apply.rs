//! Verifying a downloaded app, swapping it into place, and the marker the next service reads.

use crate::fetch::{Failure, Stage};
use crate::runner::{Runner, CODESIGN, DITTO, PLUTIL};
use crate::{canonical_version, parse_dr};
use serde::{Deserialize, Serialize};
use std::io;
use std::path::{Path, PathBuf};

pub const MARKER: &str = "update-applied.json";

fn s(p: &Path) -> String {
    p.display().to_string()
}

fn fail(reason: impl Into<String>) -> Failure {
    Failure { stage: Stage::Verify, reason: reason.into() }
}

fn remove_dir(p: &Path) -> io::Result<()> {
    match std::fs::remove_dir_all(p) {
        Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(()),
        r => r,
    }
}

/// `CFBundleShortVersionString` via plutil (works on binary plists too).
pub fn bundle_version(r: &dyn Runner, app: &Path) -> Option<String> {
    let plist = app.join("Contents/Info.plist");
    let args = ["-extract", "CFBundleShortVersionString", "raw", "-o", "-"].iter().map(|a| a.to_string());
    let o = r.run(PLUTIL, &args.chain([s(&plist)]).collect::<Vec<_>>()).ok().filter(|o| o.code == 0)?;
    let v = o.stdout.trim();
    (!v.is_empty()).then(|| v.to_string())
}

/// The designated requirement; codesign prints it on either stream depending on version.
pub fn designated(r: &dyn Runner, app: &Path) -> Option<String> {
    let o = r.run(CODESIGN, &["-d".into(), "-r-".into(), s(app)]).ok()?;
    parse_dr(&format!("{}\n{}", o.stdout, o.stderr))
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Verified {
    pub app: PathBuf,
    /// The new app's designated requirement differs from the running one: manual install only.
    pub signature_changed: bool,
}

/// Unpacks `zip` into `<dir>/<x.y.z>/` and checks signature, version and designated requirement.
pub fn verify(r: &dyn Runner, zip: &Path, dir: &Path, version: &str, current_dr: &str) -> Result<Verified, Failure> {
    let v = canonical_version(version).ok_or_else(|| fail("版本号无法解析"))?;
    let dest = dir.join(&v);
    remove_dir(&dest).map_err(|_| fail("清不掉旧的解压目录"))?;
    let o = r.run(DITTO, &["-x".into(), "-k".into(), s(zip), s(&dest)]).map_err(|_| fail("无法运行 ditto"))?;
    if o.code != 0 {
        return Err(fail(format!("解压失败（ditto 退出码 {}）", o.code)));
    }
    let app = dest.join("rapp.app");
    if !app.is_dir() {
        return Err(fail("包里没有 rapp.app"));
    }
    verify_local(r, &app)?;
    let got = bundle_version(r, &app).ok_or_else(|| fail("读不到新版的版本号"))?;
    if got != v {
        let got: String = got.chars().take(32).collect();
        return Err(fail(format!("包里的版本是 {got}，不是 {v}")));
    }
    let signature_changed = designated(r, &app).as_deref() != Some(current_dr);
    Ok(Verified { app, signature_changed })
}

/// Signature check only: used for going back to `previous/`, an app this machine already ran.
pub fn verify_local(r: &dyn Runner, app: &Path) -> Result<(), Failure> {
    let args = ["--verify".into(), "--deep".into(), "--strict".into(), s(app)];
    let o = r.run(CODESIGN, &args).map_err(|_| fail("无法运行 codesign"))?;
    if o.code != 0 {
        return Err(fail("签名校验没通过"));
    }
    Ok(())
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum InstallError {
    /// The bundle or its folder is not writable by this user.
    NeedsAdmin,
    Failed(String),
}

/// Rename; across volumes (EXDEV) copy with ditto and delete the source. If the source can't be
/// fully deleted, the copy is put back over it and removed, so `from` stays whole.
fn move_dir(r: &dyn Runner, from: &Path, to: &Path) -> io::Result<()> {
    match r.rename(from, to) {
        Err(e) if e.raw_os_error() == Some(18) => {
            let o = r.run(DITTO, &[s(from), s(to)])?;
            if o.code != 0 {
                let _ = remove_dir(to);
                return Err(io::Error::other(format!("ditto 退出码 {}", o.code)));
            }
            if let Err(e) = std::fs::remove_dir_all(from) {
                if matches!(r.run(DITTO, &[s(to), s(from)]), Ok(o) if o.code == 0) {
                    let _ = remove_dir(to);
                }
                return Err(e);
            }
            Ok(())
        }
        res => res,
    }
}

/// Swaps `new_app` into `bundle`, keeping the replaced app as `<previous_dir>/rapp.app` (K12).
/// Rolling back is the same call with `new_app = <previous_dir>/rapp.app` (K13).
/// Any failure leaves `bundle` as it was and no `.rapp-new.app` behind; `new_app` is moved back
/// where it came from when possible.
pub fn install(r: &dyn Runner, new_app: &Path, bundle: &Path, previous_dir: &Path) -> Result<(), InstallError> {
    let failed = |m: &str| InstallError::Failed(m.to_string());
    let admin_or = |e: &io::Error, m: &str| {
        if e.kind() == io::ErrorKind::PermissionDenied {
            InstallError::NeedsAdmin
        } else {
            failed(m)
        }
    };
    let staging = bundle.parent().ok_or_else(|| failed("安装位置不对"))?.join(".rapp-new.app");
    let prev = previous_dir.join("rapp.app");

    // ① stage the new app next to the bundle, on the same volume.
    remove_dir(&staging).map_err(|e| admin_or(&e, "清不掉上次留下的 .rapp-new.app"))?;
    if let Err(e) = move_dir(r, new_app, &staging) {
        let _ = remove_dir(&staging);
        return Err(admin_or(&e, "搬不动新版"));
    }
    let unstage = || {
        if move_dir(r, &staging, new_app).is_err() {
            let _ = remove_dir(&staging);
        }
    };

    // ② keep only one previous version.
    if remove_dir(&prev).and_then(|_| std::fs::create_dir_all(previous_dir)).is_err() {
        unstage();
        return Err(failed("清不掉 previous 里的旧版"));
    }

    // ③ move the current app aside.
    if let Err(e) = move_dir(r, bundle, &prev) {
        unstage();
        return Err(admin_or(&e, "搬不动当前版"));
    }

    // ④ the atomic swap; on failure put ③ back.
    if r.rename(&staging, bundle).is_err() {
        let restored = move_dir(r, &prev, bundle).is_ok();
        unstage();
        return Err(failed(if restored {
            "换上新版失败，已还原"
        } else {
            "换上新版失败，当前版留在 previous 里"
        }));
    }
    Ok(())
}

/// `<configDir>/update-applied.json`, read by the service that starts after the swap.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Marker {
    pub from: String,
    pub to: String,
    pub at: u64,
    pub gui_was_open: bool,
    pub mode: String,
    #[serde(default)]
    pub perms_before: serde_json::Value,
}

pub fn write_marker(home: &Path, m: &Marker) -> io::Result<()> {
    rapp_net::config::write_json(&home.join(MARKER), m).map_err(|e| io::Error::other(e.to_string()))
}

/// A marker that can't be parsed is deleted.
pub fn read_marker(home: &Path) -> Option<Marker> {
    let p = home.join(MARKER);
    let b = std::fs::read(&p).ok()?;
    let m = serde_json::from_slice(&b).ok();
    if m.is_none() {
        let _ = std::fs::remove_file(&p);
    }
    m
}

pub fn clear_marker(home: &Path) {
    let _ = std::fs::remove_file(home.join(MARKER));
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fake::FakeRunner;
    use crate::runner::{Out, CODESIGN, DITTO, PLUTIL};
    use std::path::PathBuf;

    const DR: &str = "identifier \"com.rapp.rapp\" and certificate leaf[subject.CN] = \"Apple Development: a (B)\"";

    fn make_app(app: &Path, marker: &str) {
        std::fs::create_dir_all(app.join("Contents")).unwrap();
        std::fs::write(app.join("Contents/marker"), marker).unwrap();
    }

    fn marker_of(app: &Path) -> String {
        std::fs::read_to_string(app.join("Contents/marker")).unwrap()
    }

    struct Env {
        _d: tempfile::TempDir,
        bundle: PathBuf,
        previous: PathBuf,
        new_app: PathBuf,
    }

    impl Env {
        fn new() -> Env {
            let d = tempfile::tempdir().unwrap();
            let bundle = d.path().join("Applications/rapp.app");
            let previous = d.path().join("home/previous");
            let new_app = d.path().join("cache/0.5.0/rapp.app");
            make_app(&bundle, "current");
            make_app(&new_app, "new");
            Env { _d: d, bundle, previous, new_app }
        }

        fn staging(&self) -> PathBuf {
            self.bundle.parent().unwrap().join(".rapp-new.app")
        }
    }

    fn copy_dir(from: &Path, to: &Path) {
        std::fs::create_dir_all(to).unwrap();
        for e in std::fs::read_dir(from).unwrap() {
            let e = e.unwrap();
            let dest = to.join(e.file_name());
            if e.file_type().unwrap().is_dir() {
                copy_dir(&e.path(), &dest);
            } else {
                std::fs::copy(e.path(), dest).unwrap();
            }
        }
    }

    /// ditto that unpacks a fake rapp.app, codesign whose verify exits `verify_code`
    /// and whose designated requirement is `dr`, plutil that reports `version`.
    fn verifier(verify_code: i32, dr: &'static str, version: &'static str) -> FakeRunner {
        FakeRunner::new()
            .on(DITTO, |a| {
                assert_eq!(&a[..2], ["-x", "-k"]);
                std::fs::create_dir_all(Path::new(&a[3]).join("rapp.app/Contents")).unwrap();
                Out::ok("")
            })
            .on(CODESIGN, move |a| match a[0].as_str() {
                "--verify" => {
                    assert_eq!(&a[..3], ["--verify", "--deep", "--strict"]);
                    Out { code: verify_code, ..Default::default() }
                }
                "-d" => Out {
                    code: 0,
                    stdout: String::new(),
                    stderr: format!("Executable=/x/rapp.app/Contents/MacOS/rapp\ndesignated => {dr}\n"),
                },
                _ => Out::fail(2, "bad args"),
            })
            .on(PLUTIL, move |a| {
                assert_eq!(&a[..5], ["-extract", "CFBundleShortVersionString", "raw", "-o", "-"]);
                assert!(a[5].ends_with("rapp.app/Contents/Info.plist"), "{a:?}");
                Out::ok(format!("{version}\n"))
            })
    }

    #[test]
    fn verify_happy_path() {
        let d = tempfile::tempdir().unwrap();
        let stale = d.path().join("0.5.0/stale");
        std::fs::create_dir_all(&stale).unwrap();
        let r = verifier(0, DR, "0.5.0");
        let v = verify(&r, &d.path().join("rapp-0.5.0.zip"), d.path(), "0.5.0", DR).unwrap();
        assert_eq!(v, Verified { app: d.path().join("0.5.0/rapp.app"), signature_changed: false });
        assert!(!stale.exists(), "the old unpack dir is removed first");
    }

    #[test]
    fn verify_uses_canonical_version() {
        let d = tempfile::tempdir().unwrap();
        let r = verifier(0, DR, "0.5.0");
        let v = verify(&r, &d.path().join("rapp-0.5.0.zip"), d.path(), "v0.05.0", DR).unwrap();
        assert_eq!(v.app, d.path().join("0.5.0/rapp.app"));
    }

    #[test]
    fn different_dr_needs_confirm() {
        let d = tempfile::tempdir().unwrap();
        let r = verifier(0, "cdhash H\"dee3c9\"", "0.5.0");
        let v = verify(&r, &d.path().join("rapp-0.5.0.zip"), d.path(), "0.5.0", DR).unwrap();
        assert!(v.signature_changed);
    }

    #[test]
    fn verify_rejects_bad_signature_and_wrong_version() {
        let d = tempfile::tempdir().unwrap();
        let zip = d.path().join("rapp-0.5.0.zip");
        let f = verify(&verifier(1, DR, "0.5.0"), &zip, d.path(), "0.5.0", DR).unwrap_err();
        assert_eq!(f.stage, Stage::Verify);
        let f = verify(&verifier(0, DR, "0.4.9"), &zip, d.path(), "0.5.0", DR).unwrap_err();
        assert_eq!(f.stage, Stage::Verify);
        assert!(f.reason.contains("0.4.9"), "{}", f.reason);
    }

    #[test]
    fn verify_rejects_zip_without_app() {
        let d = tempfile::tempdir().unwrap();
        let r = FakeRunner::new().on(DITTO, |a| {
            std::fs::create_dir_all(Path::new(&a[3]).join("other.app")).unwrap();
            Out::ok("")
        });
        let f = verify(&r, &d.path().join("rapp-0.5.0.zip"), d.path(), "0.5.0", DR).unwrap_err();
        assert_eq!(f.stage, Stage::Verify);
    }

    #[test]
    fn verify_local_only_runs_codesign_verify() {
        let d = tempfile::tempdir().unwrap();
        let app = d.path().join("rapp.app");
        let r = verifier(0, DR, "9.9.9");
        verify_local(&r, &app).unwrap();
        let calls = r.calls();
        assert_eq!(calls.len(), 1);
        assert_eq!(calls[0].1[..3], ["--verify", "--deep", "--strict"]);
        assert_eq!(verify_local(&verifier(1, DR, "0.5.0"), &app).unwrap_err().stage, Stage::Verify);
    }

    #[test]
    fn bundle_version_and_designated() {
        let d = tempfile::tempdir().unwrap();
        let r = verifier(0, DR, "0.5.0");
        assert_eq!(bundle_version(&r, &d.path().join("rapp.app")).as_deref(), Some("0.5.0"));
        assert_eq!(designated(&r, &d.path().join("rapp.app")).as_deref(), Some(DR));
        assert_eq!(bundle_version(&FakeRunner::new(), d.path()), None);
        assert_eq!(designated(&FakeRunner::new(), d.path()), None);
    }

    #[test]
    fn install_swaps_and_keeps_one_previous() {
        let e = Env::new();
        make_app(&e.previous.join("rapp.app"), "old0");
        install(&FakeRunner::new(), &e.new_app, &e.bundle, &e.previous).unwrap();
        assert_eq!(marker_of(&e.bundle), "new");
        assert_eq!(marker_of(&e.previous.join("rapp.app")), "current");
        assert!(!e.staging().exists());
        assert!(!e.new_app.exists());
    }

    #[test]
    fn second_rename_failure_restores_old_app() {
        let e = Env::new();
        let r = FakeRunner::new().rename_fails(3, io::Error::other("boom"));
        let err = install(&r, &e.new_app, &e.bundle, &e.previous).unwrap_err();
        assert!(matches!(err, InstallError::Failed(_)), "{err:?}");
        assert_eq!(marker_of(&e.bundle), "current");
        assert!(!e.staging().exists());
    }

    #[test]
    fn exdev_falls_back_to_ditto() {
        let e = Env::new();
        let r = FakeRunner::new().rename_fails(2, io::Error::from_raw_os_error(18)).on(DITTO, |a| {
            copy_dir(Path::new(&a[0]), Path::new(&a[1]));
            Out::ok("")
        });
        install(&r, &e.new_app, &e.bundle, &e.previous).unwrap();
        let prev = e.previous.join("rapp.app");
        let want = (DITTO.to_string(), vec![e.bundle.display().to_string(), prev.display().to_string()]);
        assert!(r.calls().contains(&want), "{:?}", r.calls());
        assert_eq!(marker_of(&prev), "current");
        assert_eq!(marker_of(&e.bundle), "new", "the old bundle was removed and the new one renamed in");
        assert!(!e.staging().exists());
    }

    #[test]
    fn exdev_copy_with_failed_delete_keeps_bundle_whole() {
        use std::os::unix::fs::PermissionsExt;
        let e = Env::new();
        let locked = e.bundle.join("Contents/locked");
        make_app(&locked, "x");
        std::fs::set_permissions(&locked, std::fs::Permissions::from_mode(0o555)).unwrap();
        let r = FakeRunner::new().rename_fails(2, io::Error::from_raw_os_error(18)).on(DITTO, |a| {
            copy_dir(Path::new(&a[0]), Path::new(&a[1]));
            Out::ok("")
        });
        let res = install(&r, &e.new_app, &e.bundle, &e.previous);
        std::fs::set_permissions(&locked, std::fs::Permissions::from_mode(0o755)).unwrap();
        assert_eq!(res, Err(InstallError::NeedsAdmin));
        assert_eq!(marker_of(&e.bundle), "current");
        assert_eq!(marker_of(&locked), "x");
        assert!(!e.previous.join("rapp.app").exists());
        assert!(!e.staging().exists());
        assert_eq!(marker_of(&e.new_app), "new");
    }

    #[test]
    fn permission_denied_is_needs_admin_and_cleans_up() {
        let e = Env::new();
        let r = FakeRunner::new().rename_fails(2, io::Error::from(io::ErrorKind::PermissionDenied));
        assert_eq!(install(&r, &e.new_app, &e.bundle, &e.previous), Err(InstallError::NeedsAdmin));
        assert_eq!(marker_of(&e.bundle), "current");
        assert!(!e.staging().exists());
    }

    #[test]
    fn permission_denied_on_first_move_is_needs_admin() {
        let e = Env::new();
        let r = FakeRunner::new().rename_fails(1, io::Error::from(io::ErrorKind::PermissionDenied));
        assert_eq!(install(&r, &e.new_app, &e.bundle, &e.previous), Err(InstallError::NeedsAdmin));
        assert_eq!(marker_of(&e.bundle), "current");
        assert!(!e.staging().exists());
    }

    #[test]
    fn rollback_swaps_current_and_previous() {
        let e = Env::new();
        let prev = e.previous.join("rapp.app");
        make_app(&prev, "old");
        install(&FakeRunner::new(), &prev, &e.bundle, &e.previous).unwrap();
        assert_eq!(marker_of(&e.bundle), "old");
        assert_eq!(marker_of(&prev), "current");
        assert!(!e.staging().exists());
    }

    #[test]
    fn marker_roundtrip_and_corrupt_is_removed() {
        let d = tempfile::tempdir().unwrap();
        let m = Marker {
            from: "0.4.1".into(),
            to: "0.5.0".into(),
            at: 42,
            gui_was_open: true,
            mode: "auto".into(),
            perms_before: serde_json::json!({"screen": true}),
        };
        write_marker(d.path(), &m).unwrap();
        assert_eq!(read_marker(d.path()), Some(m));
        clear_marker(d.path());
        assert_eq!(read_marker(d.path()), None);
        let p = d.path().join(MARKER);
        std::fs::write(&p, "{x").unwrap();
        assert_eq!(read_marker(d.path()), None);
        assert!(!p.exists());
    }

    #[test]
    fn marker_without_perms_before_reads() {
        let d = tempfile::tempdir().unwrap();
        std::fs::write(
            d.path().join(MARKER),
            r#"{"from":"0.4.1","to":"0.5.0","at":1,"gui_was_open":false,"mode":"rollback"}"#,
        )
        .unwrap();
        let m = read_marker(d.path()).unwrap();
        assert_eq!(m.perms_before, serde_json::Value::Null);
        assert_eq!(m.mode, "rollback");
    }
}
