//! Creates the data root layout and copies the old config into it (spec §1–§2, R1–R5).

use crate::config::{device, local, read_json, shared, write_private};
use anyhow::{Context, Result};
use std::path::Path;

pub const README: &str = include_str!("datadir/README.md");
pub const AGENT_README: &str = include_str!("datadir/agent-README.md");
pub const GITIGNORE: &str = include_str!("datadir/gitignore");
/// First line of `README.md`; how other code recognises a rapp data dir.
pub const README_MARKER: &str = "# rapp 数据目录";
pub const MIGRATED_FROM: &str = "migrated-from";

/// Makes the layout, writes the texts that are missing, and copies the old config in once.
/// Returns whether this call migrated. Copies only; `legacy` is never changed.
pub fn prepare(root: &Path, legacy: &Path) -> Result<bool> {
    for d in ["shared", "devices", "agent", "clipboard", "files/transfers", "files/clipboard"] {
        mkdir(&root.join(d))?;
    }
    let loc = local(root);
    mkdir(&loc)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&loc, std::fs::Permissions::from_mode(0o700))
            .with_context(|| format!("chmod {}", loc.display()))?;
    }
    for (path, text) in [
        (root.join("README.md"), README),
        (root.join(".gitignore"), GITIGNORE),
        (root.join("agent/README.md"), AGENT_README),
    ] {
        if !path.exists() {
            std::fs::write(&path, text).with_context(|| format!("write {}", path.display()))?;
        }
    }
    let old_service = legacy.join("service.json");
    let current_id = service_id(&loc.join("service.json"));
    if let Some(id) = &current_id {
        copy_if_missing(&loc.join("gui.json"), &device(root, id).join("gui.json"))?;
    }
    // A Linux client may have saved hosts and projects without ever running a
    // local service. A separate completion marker also covers that migration.
    if loc.join(MIGRATED_FROM).exists() {
        return Ok(false);
    }
    let mut table: Vec<(&str, std::path::PathBuf)> = vec![
        ("hosts.json", loc.join("hosts.json")),
        ("update.json", loc.join("update.json")),
        ("update-applied.json", loc.join("update-applied.json")),
        ("permission-guide-shown", loc.join("permission-guide-shown")),
        ("workspace.json", shared(root).join("workspace.json")),
        ("apps.json", shared(root).join("apps.json")),
    ];
    let id = current_id.or_else(|| service_id(&old_service));
    table.push(("gui.json", id.map_or_else(|| loc.join("gui.json"), |id| device(root, &id).join("gui.json"))));
    table.push(("service.json", loc.join("service.json")));
    if !table.iter().any(|(old, _)| legacy.join(old).is_file()) {
        return Ok(false);
    }
    for (old, new) in table {
        copy_if_missing(&legacy.join(old), &new)?;
    }
    write_private(&loc.join(MIGRATED_FROM), format!("{}\n", legacy.display()).as_bytes())?;
    Ok(true)
}

fn service_id(path: &Path) -> Option<String> {
    read_json::<serde_json::Value>(path)
        .ok()
        .flatten()
        .and_then(|v| v.get("id").and_then(|i| i.as_str().map(String::from)))
        .filter(|i| !i.is_empty() && i.chars().all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_'))
}

fn mkdir(p: &Path) -> Result<()> {
    std::fs::create_dir_all(p).with_context(|| format!("create {}", p.display()))
}

fn copy_if_missing(from: &Path, to: &Path) -> Result<()> {
    if to.exists() || !from.is_file() {
        return Ok(());
    }
    let data = std::fs::read(from).with_context(|| format!("read {}", from.display()))?;
    write_private(to, &data)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    fn dirs() -> (tempfile::TempDir, PathBuf, PathBuf) {
        let t = tempfile::tempdir().unwrap();
        let (root, legacy) = (t.path().join("root"), t.path().join("legacy"));
        std::fs::create_dir_all(&legacy).unwrap();
        (t, root, legacy)
    }

    fn read(p: &Path) -> String {
        std::fs::read_to_string(p).unwrap_or_else(|e| panic!("{}: {e}", p.display()))
    }

    #[cfg(unix)]
    fn mode(p: &Path) -> u32 {
        use std::os::unix::fs::PermissionsExt;
        std::fs::metadata(p).unwrap().permissions().mode() & 0o777
    }

    fn put(p: &Path, s: &str) {
        std::fs::create_dir_all(p.parent().unwrap()).unwrap();
        std::fs::write(p, s).unwrap();
    }

    fn old_config(legacy: &Path) {
        put(&legacy.join("service.json"), r#"{"id":"123456789","secret":"s"}"#);
        for f in [
            "hosts.json",
            "update.json",
            "update-applied.json",
            "workspace.json",
            "apps.json",
            "gui.json",
            "permission-guide-shown",
            "ipc.token",
        ] {
            put(&legacy.join(f), &format!("old {f}"));
        }
        put(&legacy.join("previous/rapp.app/x"), "x");
    }

    #[test]
    fn fresh_root_gets_the_layout() {
        let (_t, root, legacy) = dirs();
        assert!(!prepare(&root, &legacy).unwrap());
        for d in ["shared", "devices", "agent", "clipboard", "files/transfers", "files/clipboard", "local"] {
            assert!(root.join(d).is_dir(), "{d}");
        }
        assert!(read(&root.join("README.md")).starts_with(README_MARKER));
        assert_eq!(read(&root.join(".gitignore")), GITIGNORE);
        assert_eq!(read(&root.join("agent/README.md")), AGENT_README);
        #[cfg(unix)]
        assert_eq!(mode(&root.join("local")), 0o700);
    }

    #[test]
    fn existing_texts_are_kept() {
        let (_t, root, legacy) = dirs();
        put(&root.join("README.md"), "mine");
        put(&root.join("agent/README.md"), "mine too");
        prepare(&root, &legacy).unwrap();
        assert_eq!(read(&root.join("README.md")), "mine");
        assert_eq!(read(&root.join("agent/README.md")), "mine too");
    }

    #[test]
    fn migrates_by_the_table_and_copies_only() {
        let (_t, root, legacy) = dirs();
        old_config(&legacy);
        assert!(prepare(&root, &legacy).unwrap());
        for (old, new) in [
            ("service.json", "local/service.json"),
            ("hosts.json", "local/hosts.json"),
            ("update.json", "local/update.json"),
            ("update-applied.json", "local/update-applied.json"),
            ("permission-guide-shown", "local/permission-guide-shown"),
            ("workspace.json", "shared/workspace.json"),
            ("apps.json", "shared/apps.json"),
            ("gui.json", "devices/123456789/gui.json"),
        ] {
            assert_eq!(read(&legacy.join(old)), read(&root.join(new)), "{new}");
            assert!(legacy.join(old).exists(), "old {old} kept");
        }
        assert!(!root.join("local/ipc.token").exists() && !root.join("local/previous").exists());
        assert_eq!(read(&root.join("local/migrated-from")).trim(), legacy.to_str().unwrap());
        #[cfg(unix)]
        assert_eq!(mode(&root.join("local/service.json")), 0o600);
    }

    #[test]
    fn second_run_is_a_no_op() {
        let (_t, root, legacy) = dirs();
        old_config(&legacy);
        assert!(prepare(&root, &legacy).unwrap());
        put(&root.join("shared/workspace.json"), "edited");
        assert!(!prepare(&root, &legacy).unwrap());
        assert_eq!(read(&root.join("shared/workspace.json")), "edited");
    }

    #[test]
    fn never_overwrites_an_existing_file() {
        let (_t, root, legacy) = dirs();
        old_config(&legacy);
        put(&root.join("local/hosts.json"), "local one");
        assert!(prepare(&root, &legacy).unwrap());
        assert_eq!(read(&root.join("local/hosts.json")), "local one");
        assert_eq!(read(&root.join("local/service.json")), read(&legacy.join("service.json")));
    }

    #[test]
    fn rapp_home_flat_layout_migrates_into_local() {
        let t = tempfile::tempdir().unwrap();
        let root = t.path().join("home");
        old_config(&root);
        assert!(prepare(&root, &root).unwrap());
        assert_eq!(read(&root.join("local/service.json")), read(&root.join("service.json")));
        assert_eq!(read(&root.join("shared/apps.json")), "old apps.json");
    }

    #[test]
    fn client_only_migration_preserves_hosts_projects_and_pending_preferences() {
        let (_t, root, legacy) = dirs();
        put(&legacy.join("workspace.json"), "w");
        put(&legacy.join("hosts.json"), "h");
        put(&legacy.join("gui.json"), "g");
        assert!(prepare(&root, &legacy).unwrap());
        assert_eq!(read(&root.join("shared/workspace.json")), "w");
        assert_eq!(read(&root.join("local/hosts.json")), "h");
        assert_eq!(read(&root.join("local/gui.json")), "g");
        assert!(!root.join("local/service.json").exists());
        assert_eq!(read(&legacy.join("hosts.json")), "h");
        std::fs::remove_file(root.join("shared/workspace.json")).unwrap();
        assert!(!prepare(&root, &legacy).unwrap());
        assert!(!root.join("shared/workspace.json").exists());
        put(&root.join("local/service.json"), r#"{"id":"123456789"}"#);
        assert!(!prepare(&root, &legacy).unwrap());
        assert_eq!(read(&root.join("devices/123456789/gui.json")), "g");
        put(&root.join("devices/123456789/gui.json"), "edited");
        prepare(&root, &legacy).unwrap();
        assert_eq!(read(&root.join("devices/123456789/gui.json")), "edited");
    }

    #[test]
    fn a_new_service_identity_does_not_prevent_client_migration() {
        let (_t, root, legacy) = dirs();
        put(&root.join("local/service.json"), r#"{"id":"987654321"}"#);
        put(&legacy.join("hosts.json"), "h");
        put(&legacy.join("gui.json"), "g");
        assert!(prepare(&root, &legacy).unwrap());
        assert_eq!(read(&root.join("local/hosts.json")), "h");
        assert_eq!(read(&root.join("devices/987654321/gui.json")), "g");
        assert_eq!(read(&root.join("local/service.json")), r#"{"id":"987654321"}"#);
    }

    #[cfg(unix)]
    #[test]
    fn a_failed_copy_leaves_no_service_json() {
        use std::os::unix::fs::PermissionsExt;
        let (_t, root, legacy) = dirs();
        old_config(&legacy);
        let hosts = legacy.join("hosts.json");
        std::fs::set_permissions(&hosts, std::fs::Permissions::from_mode(0o000)).unwrap();
        if std::fs::read(&hosts).is_ok() {
            eprintln!("running as root; skipping");
            return;
        }
        let r = prepare(&root, &legacy);
        std::fs::set_permissions(&hosts, std::fs::Permissions::from_mode(0o600)).unwrap();
        assert!(r.is_err());
        assert!(!root.join("local/service.json").exists());
    }

    #[test]
    fn gitignore_keeps_secrets_and_binaries_out() {
        use std::process::Command;
        let git = |dir: &Path, args: &[&str]| {
            Command::new("git")
                .current_dir(dir)
                .env("GIT_CONFIG_GLOBAL", "/dev/null")
                .env("GIT_CONFIG_NOSYSTEM", "1")
                .args(["-c", "user.name=t", "-c", "user.email=t"])
                .args(args)
                .output()
        };
        let (_t, root, legacy) = dirs();
        prepare(&root, &legacy).unwrap();
        match git(&root, &["init", "-b", "main"]) {
            Ok(o) if o.status.success() => {}
            _ => {
                eprintln!("git not available; skipping");
                return;
            }
        }
        for f in [
            "service.json",
            "hosts.json",
            "local/service.json",
            "files/transfers/a.bin",
            "shared/x.tmp",
            "shared/workspace.json.bad",
            "shared/workspace.json",
            "clipboard/a.md",
            "devices/1/gui.json",
        ] {
            put(&root.join(f), "x");
        }
        let out = git(&root, &["status", "--porcelain", "--untracked-files=all"]).unwrap();
        let got: std::collections::BTreeSet<String> =
            String::from_utf8(out.stdout).unwrap().lines().map(|l| l[3..].to_string()).collect();
        let want: std::collections::BTreeSet<String> = [
            ".gitignore",
            "README.md",
            "agent/README.md",
            "shared/workspace.json",
            "clipboard/a.md",
            "devices/1/gui.json",
        ]
        .into_iter()
        .map(String::from)
        .collect();
        assert_eq!(got, want);
    }
}
