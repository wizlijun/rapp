//! The snapshot a holder keeps of its terminal (`saved/<key>.json`), so the terminal can be restored after an upgrade
//! or a reboot: directory, environments, title and the last command. Secrets never reach the file: `clean_cmd` drops
//! any command line that might hold one (over-blocking is intended).

use serde::{Deserialize, Serialize};
use std::collections::HashSet;
use std::io::{Read as _, Write as _};
use std::os::unix::fs::{OpenOptionsExt as _, PermissionsExt as _};
use std::path::{Path, PathBuf};

const DAY: u64 = 86_400;
const MAX_AGE: u64 = 30 * DAY;
const MAX_KEPT: usize = 50;
const MAX_CMD: usize = 1000;
const MAX_FILE: u64 = 64 * 1024;

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq, Default)]
pub struct Snapshot {
    #[serde(default)]
    pub v: u32,
    #[serde(default)]
    pub key: String,
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub named: bool,
    #[serde(default)]
    pub shell: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cwd: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub venv: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub conda: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub conda_name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cmd: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub prog: Option<String>,
    #[serde(default)]
    pub started: u64,
    #[serde(default)]
    pub saved: u64,
}

/// A terminal key: 16 lowercase hex characters. Guards file names against `../x`.
pub fn key_ok(key: &str) -> bool {
    key.len() == 16 && key.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

/// Option-name parts that mark the value as a secret.
const SECRET_NAMES: [&str; 9] = ["key", "token", "secret", "password", "passwd", "pass", "pwd", "auth", "credential"];
/// Programs whose `-p…` is a password.
const PASSWORD_P: [&str; 5] = ["mysql", "mysqldump", "mysqladmin", "psql", "sshpass"];
/// Word prefixes of well-known token formats.
const SECRET_PREFIXES: [&str; 8] = ["sk-", "ghp_", "gho_", "github_pat_", "xox", "AKIA", "eyJ", "Bearer"];

/// Removes leading `NAME=value` words (values may be quoted), also after a leading `env`.
fn strip_assignments(line: &str) -> &str {
    let mut rest = line.trim_start();
    loop {
        if let Some(r) = rest.strip_prefix("env") {
            if r.starts_with(char::is_whitespace) {
                rest = r.trim_start();
                continue;
            }
        }
        let b = rest.as_bytes();
        let mut i = 0;
        while i < b.len() && (b[i] == b'_' || b[i].is_ascii_alphanumeric()) {
            i += 1;
        }
        if i == 0 || b[0].is_ascii_digit() || i >= b.len() || b[i] != b'=' {
            return rest;
        }
        i += 1;
        while i < b.len() && !b[i].is_ascii_whitespace() {
            if b[i] == b'\'' || b[i] == b'"' {
                let q = b[i];
                i += 1;
                while i < b.len() && b[i] != q {
                    i += 1;
                }
            }
            i += 1;
        }
        rest = rest.get(i.min(rest.len())..).unwrap_or("").trim_start();
    }
}

fn has_url_password(line: &str) -> bool {
    line.match_indices("://").any(|(i, _)| {
        let rest = &line[i + 3..];
        let auth = rest.split(|c: char| c == '/' || c.is_whitespace()).next().unwrap_or("");
        auth.split_once('@').is_some_and(|(user, _)| user.contains(':'))
    })
}

fn token_like(w: &str) -> bool {
    let w = w.trim_matches(|c| c == '\'' || c == '"');
    SECRET_PREFIXES.iter().any(|p| w.starts_with(p))
        || (w.len() >= 32 && w.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-'))
}

fn secret_name(name: &str) -> bool {
    let name = name.trim_start_matches('-').to_ascii_lowercase();
    SECRET_NAMES.iter().any(|s| name.contains(s))
}

fn is_secret(line: &str) -> bool {
    let lower = line.to_ascii_lowercase();
    if lower.contains("authorization:") || lower.contains("bearer ") || has_url_password(line) {
        return true;
    }
    let words: Vec<&str> =
        line.split_whitespace().map(|w| w.trim_matches(|c| c == '\'' || c == '"')).collect();
    let base = |w: &str| w.rsplit('/').next().unwrap_or(w).to_string();
    let has_prog = |names: &[&str]| words.iter().any(|w| names.contains(&base(w).as_str()));
    let pass_p = has_prog(&PASSWORD_P);
    let curl = has_prog(&["curl"]);
    let redis = has_prog(&["redis-cli"]);
    for w in &words {
        if token_like(w) {
            return true;
        }
        if pass_p && w.starts_with("-p") {
            return true;
        }
        if curl && (w.starts_with("-u") || *w == "--user") {
            return true;
        }
        if redis && *w == "-a" {
            return true;
        }
        if let Some(h) = w.strip_suffix(':') {
            if secret_name(h) {
                return true;
            }
        }
        if let Some((name, value)) = w.split_once('=') {
            if secret_name(name) || token_like(value) {
                return true;
            }
        } else if w.starts_with('-') && secret_name(w) {
            return true;
        }
    }
    false
}

/// `(cmd, prog)` for a command line about to be saved: leading assignments stripped; `cmd` is None when the line may hold
/// a secret or is not a plain line; `prog` is the basename of the first word (none for an empty line).
pub fn clean_cmd(raw: &str) -> (Option<String>, Option<String>) {
    let bad_chars = raw.chars().any(|c| c.is_control());
    let line = strip_assignments(raw).trim();
    let first = line.split_whitespace().next().map(|w| w.trim_matches(|c| c == '\'' || c == '"'));
    let prog = first.map(|w| w.rsplit('/').next().unwrap_or(w).chars().filter(|c| !c.is_control()).collect::<String>())
        .filter(|p| !p.is_empty());
    if line.is_empty() {
        return (None, None);
    }
    if bad_chars || raw.chars().count() > MAX_CMD || is_secret(line) {
        return (None, prog);
    }
    (Some(line.to_string()), prog)
}

fn dir(term_dir: &Path) -> PathBuf {
    term_dir.join("saved")
}

pub fn path(term_dir: &Path, key: &str) -> PathBuf {
    dir(term_dir).join(format!("{key}.json"))
}

/// Writes the snapshot to a 0600 temporary file in `saved/` and renames it over `saved/<key>.json`.
pub fn write(term_dir: &Path, s: &Snapshot) -> std::io::Result<()> {
    if !key_ok(&s.key) {
        return Err(std::io::Error::new(std::io::ErrorKind::InvalidInput, "bad key"));
    }
    let d = dir(term_dir);
    std::fs::create_dir_all(&d)?;
    if !std::fs::symlink_metadata(&d)?.file_type().is_dir() {
        return Err(std::io::Error::new(std::io::ErrorKind::InvalidInput, "saved/ is not a real directory"));
    }
    std::fs::set_permissions(&d, std::fs::Permissions::from_mode(0o700))?;
    let tmp = d.join(format!(".{}.{}.tmp", s.key, std::process::id()));
    let _ = std::fs::remove_file(&tmp);
    let res = (|| {
        let mut s = s.clone();
        s.prog = s.prog.map(|p| p.chars().filter(|c| !c.is_control()).collect());
        let mut f = std::fs::OpenOptions::new().write(true).create_new(true).mode(0o600).open(&tmp)?;
        f.write_all(&serde_json::to_vec(&s).map_err(std::io::Error::other)?)?;
        f.sync_all()?;
        std::fs::rename(&tmp, path(term_dir, &s.key))
    })();
    if res.is_err() {
        let _ = std::fs::remove_file(&tmp);
    }
    res
}

/// The snapshot of `key`; a missing or unreadable file is None.
pub fn read(term_dir: &Path, key: &str) -> Option<Snapshot> {
    if !key_ok(key) {
        return None;
    }
    let f = std::fs::File::open(path(term_dir, key)).ok()?;
    let mut buf = Vec::new();
    std::io::Read::take(f, MAX_FILE + 1).read_to_end(&mut buf).ok()?;
    if buf.len() as u64 > MAX_FILE {
        return None;
    }
    serde_json::from_slice(&buf).ok()
}

pub fn remove(term_dir: &Path, key: &str) {
    if key_ok(key) {
        let _ = std::fs::remove_file(path(term_dir, key));
    }
}

/// The snapshots of terminals that are not alive, oldest `started` first. Prunes as it goes: files older than 30 days
/// and those beyond the 50 newest are deleted, as are junk files. A live key's file is never touched.
pub fn restorable(term_dir: &Path, live: &HashSet<String>, now: u64) -> Vec<Snapshot> {
    let Ok(rd) = std::fs::read_dir(dir(term_dir)) else { return Vec::new() };
    let mut out = Vec::new();
    for e in rd.flatten() {
        let p = e.path();
        let name = e.file_name().to_string_lossy().into_owned();
        if name.starts_with('.') {
            // A write in progress; one left over for an hour is dead.
            let old = e.metadata().and_then(|m| m.modified()).ok().and_then(|t| t.elapsed().ok());
            if old.is_some_and(|a| a.as_secs() > 3600) {
                let _ = std::fs::remove_file(&p);
            }
            continue;
        }
        let key = name.strip_suffix(".json").filter(|k| key_ok(k));
        let Some(key) = key else {
            let _ = std::fs::remove_file(&p);
            continue;
        };
        if live.contains(key) {
            continue;
        }
        match read(term_dir, key) {
            Some(s) if s.key == key && now.saturating_sub(s.saved) <= MAX_AGE => out.push(s),
            _ => {
                let _ = std::fs::remove_file(&p);
            }
        }
    }
    out.sort_by_key(|a| std::cmp::Reverse(a.saved));
    for s in out.split_off(out.len().min(MAX_KEPT)) {
        remove(term_dir, &s.key);
    }
    out.sort_by_key(|s| s.started);
    out
}

/// The Unix second the machine started.
#[cfg(target_os = "macos")]
pub fn boot_time() -> Option<u64> {
    let mut tv = libc::timeval { tv_sec: 0, tv_usec: 0 };
    let mut len = std::mem::size_of::<libc::timeval>();
    let name = std::ffi::CString::new("kern.boottime").ok()?;
    // SAFETY: `tv` and `len` are valid for the size given; the name is NUL-terminated.
    let r = unsafe {
        libc::sysctlbyname(name.as_ptr(), &mut tv as *mut _ as *mut libc::c_void, &mut len, std::ptr::null_mut(), 0)
    };
    (r == 0 && tv.tv_sec > 0).then_some(tv.tv_sec as u64)
}

#[cfg(not(target_os = "macos"))]
pub fn boot_time() -> Option<u64> {
    let s = std::fs::read_to_string("/proc/stat").ok()?;
    s.lines().find_map(|l| l.strip_prefix("btime ")?.trim().parse().ok())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn snap(key: &str, started: u64, saved: u64) -> Snapshot {
        Snapshot { v: 1, key: key.into(), name: "t".into(), shell: "/bin/zsh".into(), started, saved, ..Default::default() }
    }
    fn k(n: u64) -> String {
        format!("{n:016x}")
    }
    fn mode(p: &Path) -> u32 {
        std::fs::metadata(p).unwrap().permissions().mode() & 0o777
    }

    #[test]
    fn clean_cmd_strips_assignments() {
        assert_eq!(
            clean_cmd("KEY=xx FOO='a b' claude --model x"),
            (Some("claude --model x".into()), Some("claude".into()))
        );
    }

    #[test]
    fn clean_cmd_drops_and_keeps_prog() {
        let long_word = format!("x {}", "a".repeat(32));
        let long_line = format!("echo {}", "a b ".repeat(251));
        let cases: Vec<(&str, &str)> = vec![
            ("claude --api-key x", "claude"),
            ("tool --token=x", "tool"),
            ("mysql -u r -p", "mysql"),
            ("psql -p 5432 -U x", "psql"),
            ("curl -H 'Authorization: Bearer abc' u", "curl"),
            ("git clone https://u:p@h/r", "git"),
            ("x sk-abc", "x"),
            ("x ghp_abc", "x"),
            ("x github_pat_1", "x"),
            ("x xoxb-1", "x"),
            ("x AKIAABC", "x"),
            ("x eyJhbGci", "x"),
            (&long_word, "x"),
            ("a\nb", "a"),
            ("a\x1bb", "ab"),
            (&long_line, "echo"),
        ];
        assert!(long_line.len() > 1000);
        for (line, prog) in cases {
            assert_eq!(clean_cmd(line), (None, Some(prog.into())), "{line:?}");
        }
    }

    #[test]
    fn clean_cmd_closes_realistic_leaks() {
        let rows = [
            ("a", "curl -H \"X-Api-Key: abc\" u", "curl"),
            ("b", "curl -H 'x: BEARER abc' u", "curl"),
            ("c", "curl -u user:pass u", "curl"),
            ("c2", "curl --user user:pass u", "curl"),
            ("d", "sudo mysql -psecret", "sudo"),
            ("d2", "env X=1 psql -p", "psql"),
            ("d3", "sshpass -p x ssh h", "sshpass"),
            ("e", "redis-cli -a hunter2", "redis-cli"),
            ("f", "export DB_PASS=x", "export"),
            ("h", &format!("tool --opt={}", "a".repeat(40)), "tool"),
            ("h2", "export X=ghp_abc", "export"),
            ("i", "psql -p5432", "psql"),
            ("j", "ls --keyboard", "ls"),
        ];
        for (id, line, prog) in rows {
            assert_eq!(clean_cmd(line), (None, Some(prog.into())), "{id} {line:?}");
        }
        // (g) assignments after env are assignments.
        assert_eq!(clean_cmd("env FOO=x ls -l"), (Some("ls -l".into()), Some("ls".into())));
    }

    #[test]
    fn snapshot_hardening() {
        let d = tempfile::tempdir().unwrap();
        // a symlinked saved/ is refused
        let real = d.path().join("elsewhere");
        std::fs::create_dir(&real).unwrap();
        std::os::unix::fs::symlink(&real, d.path().join("saved")).unwrap();
        assert!(write(d.path(), &snap(&k(1), 1, 2)).is_err());
        std::fs::remove_file(d.path().join("saved")).unwrap();
        // control chars leave prog; an oversized file is junk
        let s = Snapshot { prog: Some("a\x1bb".into()), ..snap(&k(1), 1, 2) };
        write(d.path(), &s).unwrap();
        assert_eq!(read(d.path(), &k(1)).unwrap().prog.as_deref(), Some("ab"));
        let big = format!("{{\"v\":1,\"key\":\"{}\",\"name\":\"{}\"}}", k(2), "x".repeat(70_000));
        std::fs::write(path(d.path(), &k(2)), big).unwrap();
        assert_eq!(read(d.path(), &k(2)), None);
        // a stale temp is swept, a fresh one stays
        let old = d.path().join("saved/.old.tmp");
        let fresh = d.path().join("saved/.fresh.tmp");
        std::fs::write(&old, "x").unwrap();
        std::fs::write(&fresh, "x").unwrap();
        let t = std::time::SystemTime::now() - std::time::Duration::from_secs(7200);
        std::fs::File::options().write(true).open(&old).unwrap().set_modified(t).unwrap();
        restorable(d.path(), &HashSet::new(), 10);
        assert!(!old.exists() && fresh.exists());
    }

    #[test]
    fn clean_cmd_keeps_ordinary_lines() {
        for l in ["npm run dev", "python train.py --epochs 3", "cd ~/git/x", &format!("x {}", "a".repeat(31))] {
            assert_eq!(clean_cmd(l).0.as_deref(), Some(l));
        }
        assert_eq!(clean_cmd("  "), (None, None));
    }

    #[test]
    fn secrets_never_reach_disk() {
        let d = tempfile::tempdir().unwrap();
        let (cmd, prog) = clean_cmd("KEY=s3cr3tvalue claude --api-key sk-zzz");
        let s = Snapshot { cmd, prog, ..snap(&k(1), 1, 2) };
        write(d.path(), &s).unwrap();
        let bytes = std::fs::read(path(d.path(), &s.key)).unwrap();
        let text = String::from_utf8_lossy(&bytes);
        assert!(!text.contains("s3cr3tvalue") && !text.contains("sk-"));
        assert_eq!(mode(&path(d.path(), &s.key)), 0o600);
        assert_eq!(mode(&d.path().join("saved")), 0o700);
    }

    #[test]
    fn write_is_atomic_and_read_roundtrips() {
        let d = tempfile::tempdir().unwrap();
        let mut s = snap(&k(1), 5, 6);
        s.cwd = Some("/tmp/x".into());
        s.cmd = Some("npm run dev".into());
        write(d.path(), &s).unwrap();
        assert_eq!(read(d.path(), &s.key), Some(s.clone()));
        let names: Vec<_> = std::fs::read_dir(d.path().join("saved")).unwrap().flatten().collect();
        assert_eq!(names.len(), 1, "no temp file left");
        s.name = "other".into();
        write(d.path(), &s).unwrap();
        assert_eq!(read(d.path(), &s.key).unwrap().name, "other");
        remove(d.path(), &s.key);
        assert_eq!(read(d.path(), &s.key), None);
    }

    #[test]
    fn read_bad_json_is_none() {
        let d = tempfile::tempdir().unwrap();
        std::fs::create_dir_all(d.path().join("saved")).unwrap();
        std::fs::write(path(d.path(), &k(1)), "{").unwrap();
        assert_eq!(read(d.path(), &k(1)), None);
        assert_eq!(read(d.path(), "../x"), None);
    }

    #[test]
    fn restorable_excludes_live_keys() {
        let d = tempfile::tempdir().unwrap();
        write(d.path(), &snap(&k(1), 1, 100)).unwrap();
        write(d.path(), &snap(&k(2), 2, 100)).unwrap();
        let live: HashSet<String> = [k(1)].into();
        let got = restorable(d.path(), &live, 200);
        assert_eq!(got.iter().map(|s| s.key.clone()).collect::<Vec<_>>(), vec![k(2)]);
        assert!(path(d.path(), &k(1)).exists());
    }

    #[test]
    fn prune_over_30_days() {
        let d = tempfile::tempdir().unwrap();
        let now = 100 * DAY;
        write(d.path(), &snap(&k(1), 1, now - 31 * DAY)).unwrap();
        write(d.path(), &snap(&k(2), 2, now - 29 * DAY)).unwrap();
        let got = restorable(d.path(), &HashSet::new(), now);
        assert_eq!(got.len(), 1);
        assert!(!path(d.path(), &k(1)).exists());
    }

    #[test]
    fn prune_keeps_50_newest() {
        let d = tempfile::tempdir().unwrap();
        for n in 0..55u64 {
            write(d.path(), &snap(&k(n + 1), n, 1000 + n)).unwrap();
        }
        let got = restorable(d.path(), &HashSet::new(), 2000);
        assert_eq!(got.len(), 50);
        for n in 0..5u64 {
            assert!(!path(d.path(), &k(n + 1)).exists());
        }
        assert!(path(d.path(), &k(6)).exists());
    }

    #[test]
    fn prune_never_touches_live_keys() {
        let d = tempfile::tempdir().unwrap();
        let now = 100 * DAY;
        write(d.path(), &snap(&k(1), 1, now - 40 * DAY)).unwrap();
        let live: HashSet<String> = [k(1)].into();
        assert!(restorable(d.path(), &live, now).is_empty());
        assert!(path(d.path(), &k(1)).exists());
    }

    #[test]
    fn restorable_sorted_by_started() {
        let d = tempfile::tempdir().unwrap();
        write(d.path(), &snap(&k(1), 30, 100)).unwrap();
        write(d.path(), &snap(&k(2), 10, 100)).unwrap();
        write(d.path(), &snap(&k(3), 20, 100)).unwrap();
        let got: Vec<u64> = restorable(d.path(), &HashSet::new(), 200).iter().map(|s| s.started).collect();
        assert_eq!(got, vec![10, 20, 30]);
    }

    #[test]
    fn junk_files_removed() {
        let d = tempfile::tempdir().unwrap();
        std::fs::create_dir_all(d.path().join("saved")).unwrap();
        std::fs::write(d.path().join("saved/notakey.json"), "{}").unwrap();
        std::fs::write(path(d.path(), &k(1)), "{").unwrap();
        assert!(restorable(d.path(), &HashSet::new(), 200).is_empty());
        assert_eq!(std::fs::read_dir(d.path().join("saved")).unwrap().count(), 0);
    }

    #[test]
    fn key_ok_rejects_paths() {
        assert!(key_ok("0123456789abcdef"));
        for b in ["../../etc", "ABCDEF0123456789", "0123456789abcde", "0123456789abcdeg"] {
            assert!(!key_ok(b), "{b}");
        }
    }

    #[test]
    fn boot_time_is_in_the_past() {
        let t = boot_time().unwrap();
        let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_secs();
        assert!(t > 1_000_000_000 && t <= now);
    }
}
