//! The data root as a git repository (data-dir spec §1, R8, R9, R12, R13): `device.json`, and a commit
//! of whatever changed every `commit_every`. Logs carry counts and step names only, never git output.

use anyhow::Result;
use rapp_net::config::{device, local, read_json, write_json, write_private};
use rapp_net::log::{timestamp, Log, Lvl};
use serde::{Deserialize, Serialize};
use serde_json::json;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::{Duration, Instant, SystemTime};
use tokio::task::JoinHandle;

/// This device's sync state, in `local/`; the GUI reads it.
pub const SYNC_FILE: &str = "sync.json";
/// Longest a single git command may run.
const GIT_TIMEOUT: Duration = Duration::from_secs(120);

#[derive(Clone, Debug)]
pub struct DataOpts {
    pub root: PathBuf,
    pub git: PathBuf,
    pub commit_every: Duration,
    pub pull_every: Duration,
    /// Added to every git child's environment, after the cleaning.
    pub git_env: Vec<(String, String)>,
}

impl DataOpts {
    pub fn system(root: PathBuf) -> Self {
        DataOpts {
            root,
            git: "git".into(),
            commit_every: Duration::from_secs(60),
            pull_every: Duration::from_secs(300),
            git_env: Vec::new(),
        }
    }
}

/// `local/sync.json` (R12). `git` is "missing", "local", "synced", "conflict" or "error".
#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
pub struct SyncStatus {
    pub git: String,
    pub last_commit: Option<String>,
    pub last_sync: Option<String>,
    pub error: Option<String>,
}

pub struct DataGit {
    root: PathBuf,
    git: PathBuf,
    env: Vec<(String, String)>,
    email: String,
    message: String,
    log: Log,
    status: SyncStatus,
    pull_every: Duration,
    last_pull: Option<Instant>,
    /// A rebase hit a conflict; only commit until the next start (R11).
    conflict: bool,
}

impl DataGit {
    pub fn new(opts: &DataOpts, device_name: &str, log: Log) -> DataGit {
        let clean: String = device_name.chars().filter(|c| !matches!(c, '<' | '>' | '\n' | '\r')).collect();
        let email = if clean.trim().is_empty() { "rapp".to_string() } else { clean.trim().to_string() };
        let status = read_json(&local(&opts.root).join(SYNC_FILE)).ok().flatten().unwrap_or_default();
        DataGit {
            root: opts.root.clone(),
            git: opts.git.clone(),
            env: opts.git_env.clone(),
            message: format!("自动保存（{email}）"),
            email,
            log,
            status,
            pull_every: opts.pull_every,
            last_pull: None,
            conflict: false,
        }
    }

    /// One round: make sure there is a repository, commit what changed. Saves `local/sync.json`.
    pub async fn tick(&mut self) -> SyncStatus {
        match self.round().await {
            Ok(git) => (self.status.git, self.status.error) = (git.into(), None),
            Err(Fail(step, msg)) => {
                self.log.event(Lvl::Warn, "data_error", json!({"step": step}));
                (self.status.git, self.status.error) =
                    ("error".into(), Some(msg.unwrap_or_else(|| format!("git {step} failed"))));
            }
        }
        if let Err(e) = write_json(&local(&self.root).join(SYNC_FILE), &self.status) {
            self.log.event(Lvl::Warn, "data_error", json!({"step": "save sync.json", "err": format!("{e:#}")}));
        }
        self.status.clone()
    }

    /// The step that failed is the error; a fetch/push failure also carries the scrubbed last stderr line.
    async fn round(&mut self) -> Result<&'static str, Fail> {
        if self.run(&["--version"]).await.is_none() {
            return Ok("missing");
        }
        if !self.root.join(".git").exists() {
            self.run(&["init", "-b", "main"]).await.ok_or("init")?;
        }
        let committed = self.commit_changes().await?;
        let remotes = self.run(&["remote"]).await.ok_or("remote")?;
        let Some(remote) = remotes
            .lines()
            .map(str::trim)
            .find(|r| *r == "origin")
            .or_else(|| remotes.lines().map(str::trim).find(|r| !r.is_empty()))
        else {
            return Ok("local");
        };
        if self.conflict {
            return Ok("conflict");
        }
        let due = committed || self.last_pull.is_none_or(|t| t.elapsed() >= self.pull_every);
        if !due {
            return Ok(if self.status.git == "synced" { "synced" } else { "local" });
        }
        self.last_pull = Some(Instant::now());
        self.sync(remote).await
    }

    /// Fetch, rebase onto the remote branch, push (R10).
    async fn sync(&mut self, remote: &str) -> Result<&'static str, Fail> {
        let branch = self.run(&["symbolic-ref", "--short", "HEAD"]).await.ok_or("branch")?.trim().to_string();
        let o = self.exec(&["fetch", remote]).await;
        self.log_sync("fetch", &o);
        if !o.ok() {
            return Err(Fail::net("fetch", &o));
        }
        let theirs = format!("{remote}/{branch}");
        if self.run(&["rev-parse", "--verify", "-q", &format!("refs/remotes/{theirs}")]).await.is_some() {
            let email = format!("user.email={}", self.email);
            let o = self
                .exec(&["-c", "user.name=rapp", "-c", &email, "-c", "commit.gpgsign=false", "rebase", &theirs])
                .await;
            self.log_sync("rebase", &o);
            if !o.ok() {
                self.run(&["rebase", "--abort"]).await;
                self.conflict = true;
                return Ok("conflict");
            }
        }
        let o = self.exec(&["push", remote, &format!("HEAD:refs/heads/{branch}")]).await;
        self.log_sync("push", &o);
        if !o.ok() {
            return Err(Fail::net("push", &o));
        }
        self.status.last_sync = Some(timestamp(SystemTime::now()));
        Ok("synced")
    }

    fn log_sync(&self, step: &str, o: &Out) {
        self.log.event(Lvl::Info, "data_sync", json!({"ok": o.ok(), "step": step, "code": o.code}));
    }

    async fn commit_changes(&mut self) -> Result<bool, &'static str> {
        let changed = self.run(&["status", "--porcelain", "--untracked-files=all"]).await.ok_or("status")?;
        let files = changed.lines().filter(|l| !l.is_empty()).count();
        if files == 0 {
            return Ok(false);
        }
        self.run(&["add", "-A"]).await.ok_or("add")?;
        let (email, message) = (format!("user.email={}", self.email), self.message.clone());
        let args = [
            "-c",
            "user.name=rapp",
            "-c",
            &email,
            "-c",
            "commit.gpgsign=false",
            "commit",
            "--no-verify",
            "-m",
            &message,
        ];
        self.run(&args).await.ok_or("commit")?;
        self.status.last_commit = Some(timestamp(SystemTime::now()));
        self.log.event(Lvl::Info, "data_commit", json!({"files": files}));
        Ok(true)
    }

    /// Runs git in the root; its stdout when it exits 0, None otherwise (output is never logged).
    async fn run(&self, args: &[&str]) -> Option<String> {
        let o = self.exec(args).await;
        o.ok().then_some(o.stdout)
    }

    async fn exec(&self, args: &[&str]) -> Out {
        let mut cmd = tokio::process::Command::new(&self.git);
        cmd.current_dir(&self.root).args(["-c", "core.hooksPath=/dev/null"]).args(args);
        for (k, _) in std::env::vars_os() {
            if k.to_string_lossy().starts_with("GIT_") {
                cmd.env_remove(k);
            }
        }
        cmd.env("GIT_TERMINAL_PROMPT", "0").envs(self.env.iter().map(|(k, v)| (k, v)));
        cmd.stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::piped()).kill_on_drop(true);
        match tokio::time::timeout(GIT_TIMEOUT, cmd.output()).await {
            Ok(Ok(out)) => Out {
                code: out.status.code(),
                stdout: String::from_utf8_lossy(&out.stdout).into_owned(),
                last_err: String::from_utf8_lossy(&out.stderr)
                    .lines()
                    .rev()
                    .find(|l| !l.trim().is_empty())
                    .unwrap_or("")
                    .to_string(),
            },
            _ => Out { code: None, stdout: String::new(), last_err: String::new() },
        }
    }
}

struct Out {
    code: Option<i32>,
    stdout: String,
    /// Last non-empty stderr line; only ever shown through `scrub`, never logged.
    last_err: String,
}

impl Out {
    fn ok(&self) -> bool {
        self.code == Some(0)
    }
}

/// Why a round failed: the step, and for network steps the scrubbed message for `sync.json`.
struct Fail(&'static str, Option<String>);

impl Fail {
    fn net(step: &'static str, o: &Out) -> Fail {
        Fail(step, Some(scrub(&o.last_err)))
    }
}

impl From<&'static str> for Fail {
    fn from(step: &'static str) -> Fail {
        Fail(step, None)
    }
}

/// `scheme://user[:pass]@` becomes `scheme://***@`; one line, at most 200 characters.
pub fn scrub(s: &str) -> String {
    let mut out = String::new();
    let mut rest = s.lines().next().unwrap_or("");
    while let Some(i) = rest.find("://") {
        let (head, tail) = rest.split_at(i + 3);
        out.push_str(head);
        let end = tail.find(|c: char| c == '/' || c == '\'' || c == '"' || c.is_whitespace()).unwrap_or(tail.len());
        match tail[..end].rfind('@') {
            Some(at) => {
                out.push_str("***@");
                rest = &tail[at + 1..];
            }
            None => rest = tail,
        }
    }
    out.push_str(rest);
    out.chars().take(200).collect()
}

/// `devices/<id>/device.json` (R23); not rewritten when the content is the same.
pub fn write_device_json(root: &Path, id: &str, name: &str) -> Result<()> {
    let v = json!({"id": id, "name": name, "os": std::env::consts::OS, "version": env!("CARGO_PKG_VERSION")});
    let mut bytes = serde_json::to_vec_pretty(&v)?;
    bytes.push(b'\n');
    let path = device(root, id).join("device.json");
    if std::fs::read(&path).is_ok_and(|old| old == bytes) {
        return Ok(());
    }
    write_private(&path, &bytes)
}

/// Ticks at once, then every `commit_every`.
pub fn spawn(opts: DataOpts, name: String, log: Log) -> JoinHandle<()> {
    tokio::spawn(async move {
        let mut g = DataGit::new(&opts, &name, log);
        let mut every = tokio::time::interval(opts.commit_every);
        every.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        loop {
            every.tick().await;
            g.tick().await;
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use rapp_net::datadir::prepare;

    const GIT_ENV: [(&str, &str); 2] = [("GIT_CONFIG_GLOBAL", "/dev/null"), ("GIT_CONFIG_NOSYSTEM", "1")];

    fn have_git() -> bool {
        std::process::Command::new("git").arg("--version").output().is_ok_and(|o| o.status.success())
    }

    fn prepared() -> (tempfile::TempDir, PathBuf) {
        let t = tempfile::tempdir().unwrap();
        let root = t.path().join("rapp");
        prepare(&root, &t.path().join("no-legacy")).unwrap();
        (t, root)
    }

    fn opts(root: &Path) -> DataOpts {
        DataOpts {
            git_env: GIT_ENV.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect(),
            ..DataOpts::system(root.to_path_buf())
        }
    }

    fn log(t: &tempfile::TempDir) -> Log {
        Log::file(&t.path().join("logs"), "service.log")
    }

    fn git(dir: &Path, args: &[&str]) -> String {
        let out = std::process::Command::new("git")
            .current_dir(dir)
            .args(args)
            .envs(GIT_ENV)
            .env("GIT_AUTHOR_NAME", "t")
            .env("GIT_AUTHOR_EMAIL", "t@t")
            .env("GIT_COMMITTER_NAME", "t")
            .env("GIT_COMMITTER_EMAIL", "t@t")
            .output()
            .unwrap();
        assert!(out.status.success(), "git {args:?}");
        String::from_utf8(out.stdout).unwrap()
    }

    #[tokio::test]
    async fn two_changes_in_one_interval_make_one_commit() {
        if !have_git() {
            return;
        }
        let (t, root) = prepared();
        let mut g = DataGit::new(&opts(&root), "test-a", log(&t));
        std::fs::write(root.join("shared/workspace.json"), "{}").unwrap();
        std::fs::write(root.join("clipboard/a.md"), "x").unwrap();
        let s = g.tick().await;
        assert_eq!((s.git.as_str(), s.last_commit.is_some()), ("local", true));
        assert_eq!(git(&root, &["rev-list", "--count", "HEAD"]).trim(), "1");
        assert_eq!(git(&root, &["log", "-1", "--format=%an <%ae>"]).trim(), "rapp <test-a>");
        g.tick().await;
        assert_eq!(git(&root, &["rev-list", "--count", "HEAD"]).trim(), "1", "nothing changed, no commit");
        let saved: SyncStatus = read_json(&root.join("local/sync.json")).unwrap().unwrap();
        assert_eq!(saved.git, "local");
        let logged = std::fs::read_to_string(t.path().join("logs/service.log")).unwrap();
        assert!(logged.contains(r#""ev":"data_commit""#) && logged.contains(r#""files":5"#), "{logged}");
    }

    #[tokio::test]
    async fn ignored_paths_never_get_committed() {
        if !have_git() {
            return;
        }
        let (t, root) = prepared();
        std::fs::write(root.join("service.json"), "{}").unwrap();
        std::fs::write(root.join("local/service.json"), "{}").unwrap();
        std::fs::write(root.join("local/hosts.json"), "[]").unwrap();
        std::fs::write(root.join("files/x.png"), "x").unwrap();
        std::fs::write(root.join("shared/a.tmp"), "x").unwrap();
        std::fs::write(root.join("shared/ok.json"), "{}").unwrap();
        DataGit::new(&opts(&root), "test-a", log(&t)).tick().await;
        let files = git(&root, &["ls-files"]);
        assert_eq!(files.lines().collect::<Vec<_>>(), [".gitignore", "README.md", "agent/README.md", "shared/ok.json"]);
    }

    #[tokio::test]
    async fn no_git_is_not_an_error() {
        let (t, root) = prepared();
        let mut o = opts(&root);
        o.git = "/nonexistent/git".into();
        let s = DataGit::new(&o, "test-a", log(&t)).tick().await;
        assert_eq!(s.git, "missing");
        assert!(!root.join(".git").exists());
        let saved: SyncStatus = read_json(&root.join("local/sync.json")).unwrap().unwrap();
        assert_eq!(saved.git, "missing");
    }

    #[tokio::test]
    async fn commit_ignores_the_users_signing_config() {
        if !have_git() {
            return;
        }
        let (t, root) = prepared();
        let mut g = DataGit::new(&opts(&root), "test-a", log(&t));
        g.tick().await;
        let before: u32 = git(&root, &["rev-list", "--count", "HEAD"]).trim().parse().unwrap();
        git(&root, &["config", "commit.gpgsign", "true"]);
        git(&root, &["config", "gpg.program", "/nonexistent"]);
        std::fs::write(root.join("shared/a.json"), "{}").unwrap();
        g.tick().await;
        let after: u32 = git(&root, &["rev-list", "--count", "HEAD"]).trim().parse().unwrap();
        assert_eq!(after, before + 1);
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn commit_ignores_hooks() {
        use std::os::unix::fs::PermissionsExt;
        if !have_git() {
            return;
        }
        let (t, root) = prepared();
        let mut g = DataGit::new(&opts(&root), "test-a", log(&t));
        g.tick().await;
        let before: u32 = git(&root, &["rev-list", "--count", "HEAD"]).trim().parse().unwrap();
        let hooks = t.path().join("hooks");
        std::fs::create_dir(&hooks).unwrap();
        std::fs::write(hooks.join("pre-commit"), "#!/bin/sh\nexit 1\n").unwrap();
        std::fs::set_permissions(hooks.join("pre-commit"), std::fs::Permissions::from_mode(0o755)).unwrap();
        git(&root, &["config", "core.hooksPath", hooks.to_str().unwrap()]);
        std::fs::write(root.join("shared/a.json"), "{}").unwrap();
        g.tick().await;
        let after: u32 = git(&root, &["rev-list", "--count", "HEAD"]).trim().parse().unwrap();
        assert_eq!(after, before + 1);
    }

    #[tokio::test]
    async fn a_failing_git_step_is_an_error_and_keeps_last_commit() {
        if !have_git() {
            return;
        }
        let (t, root) = prepared();
        let mut g = DataGit::new(&opts(&root), "test-a", log(&t));
        let first = g.tick().await;
        assert!(first.last_commit.is_some());
        std::fs::write(root.join(".git/index.lock"), "").unwrap();
        std::fs::write(root.join("shared/a.json"), "{}").unwrap();
        let s = g.tick().await;
        assert_eq!(s.git, "error");
        assert_eq!(s.error.as_deref(), Some("git add failed"));
        assert_eq!(s.last_commit, first.last_commit);
    }

    fn bare(t: &tempfile::TempDir) -> PathBuf {
        let b = t.path().join("bare.git");
        std::fs::create_dir(&b).unwrap();
        git(&b, &["init", "--bare", "-b", "main"]);
        b
    }

    fn id(args: &[&str]) -> Vec<String> {
        ["-c", "user.name=t", "-c", "user.email=t"].iter().chain(args).map(|s| s.to_string()).collect()
    }

    fn tgit(dir: &Path, args: &[&str]) -> String {
        let a = id(args);
        git(dir, &a.iter().map(|s| s.as_str()).collect::<Vec<_>>())
    }

    fn other_device(t: &tempfile::TempDir, bare: &Path) -> PathBuf {
        let d = t.path().join("other");
        tgit(t.path(), &["clone", bare.to_str().unwrap(), d.to_str().unwrap()]);
        d
    }

    /// A's root with a repository whose `origin` is `remote`.
    fn with_remote(root: &Path, remote: &str) -> DataOpts {
        git(root, &["init", "-b", "main"]);
        git(root, &["remote", "add", "origin", remote]);
        DataOpts { pull_every: Duration::ZERO, ..opts(root) }
    }

    #[tokio::test]
    async fn push_and_pull_through_a_bare_repo() {
        if !have_git() {
            return;
        }
        let (t, root) = prepared();
        let b = bare(&t);
        let mut g = DataGit::new(&with_remote(&root, b.to_str().unwrap()), "test-a", log(&t));
        std::fs::write(root.join("shared/a.json"), "{}").unwrap();
        assert_eq!(g.tick().await.git, "synced");
        assert!(git(&b, &["log", "--format=%s"]).contains("自动保存（test-a）"));
        let o = other_device(&t, &b);
        std::fs::write(o.join("shared/b.json"), "{}").unwrap();
        tgit(&o, &["add", "shared/b.json"]);
        tgit(&o, &["commit", "-m", "b"]);
        tgit(&o, &["push", "origin", "HEAD:refs/heads/main"]);
        let s = g.tick().await;
        assert!(root.join("shared/b.json").exists());
        assert_eq!((s.git.as_str(), s.last_sync.is_some(), s.error), ("synced", true, None));
    }

    async fn conflicting(t: &tempfile::TempDir, root: &Path, file: &str) -> (DataGit, DataOpts, PathBuf) {
        let b = bare(t);
        let o = with_remote(root, b.to_str().unwrap());
        let mut g = DataGit::new(&o, "test-a", log(t));
        std::fs::write(root.join(file), "base").unwrap();
        assert_eq!(g.tick().await.git, "synced");
        let other = other_device(t, &b);
        std::fs::write(other.join(file), "theirs").unwrap();
        tgit(&other, &["add", file]);
        tgit(&other, &["commit", "-m", "theirs"]);
        tgit(&other, &["push", "origin", "HEAD:refs/heads/main"]);
        std::fs::write(root.join(file), "mine").unwrap();
        (g, o, b)
    }

    #[tokio::test]
    async fn conflict_aborts_the_rebase_and_stops_syncing() {
        if !have_git() {
            return;
        }
        let (t, root) = prepared();
        let (mut g, o, b) = conflicting(&t, &root, "shared/workspace.json").await;
        assert_eq!(g.tick().await.git, "conflict");
        assert!(!root.join(".git/rebase-merge").exists() && !root.join(".git/rebase-apply").exists());
        assert_eq!(git(&root, &["log", "-1", "--format=%s"]).trim(), "自动保存（test-a）");
        assert_eq!(git(&root, &["status", "--porcelain"]).trim(), "");
        let count = |d: &Path| git(d, &["rev-list", "--count", "HEAD"]).trim().parse::<u32>().unwrap();
        let (before, main) = (count(&root), git(&b, &["rev-parse", "main"]));
        std::fs::write(root.join("shared/c.json"), "{}").unwrap();
        assert_eq!(g.tick().await.git, "conflict");
        assert_eq!(count(&root), before + 1);
        assert_eq!(git(&b, &["rev-parse", "main"]), main);
        let mut again = DataGit::new(&o, "test-a", log(&t));
        assert_eq!(again.tick().await.git, "conflict");
    }

    #[tokio::test]
    async fn a_failed_push_is_an_error_and_keeps_the_commit() {
        if !have_git() {
            return;
        }
        let (t, root) = prepared();
        let mut o = with_remote(&root, "https://user:s3cret@127.0.0.1:9/x.git");
        for (k, v) in [("GIT_CONFIG_COUNT", "1"), ("GIT_CONFIG_KEY_0", "credential.helper"), ("GIT_CONFIG_VALUE_0", "")]
        {
            o.git_env.push((k.into(), v.into()));
        }
        let mut g = DataGit::new(&o, "test-a", log(&t));
        std::fs::write(root.join("shared/a.json"), "{}").unwrap();
        let s = g.tick().await;
        let e = s.error.clone().unwrap_or_default();
        assert_eq!(s.git, "error");
        assert!(!e.is_empty() && !e.contains("s3cret") && !e.contains("user:"), "{e}");
        assert_eq!(git(&root, &["log", "-1", "--format=%s"]).trim(), "自动保存（test-a）");
        let saved = std::fs::read_to_string(root.join("local/sync.json")).unwrap();
        let logged = std::fs::read_to_string(t.path().join("logs/service.log")).unwrap();
        assert!(!saved.contains("s3cret") && !logged.contains("s3cret"));
    }

    #[tokio::test]
    async fn logs_carry_no_file_names() {
        if !have_git() {
            return;
        }
        let (t, root) = prepared();
        let (mut g, _, _) = conflicting(&t, &root, "clipboard/20261113-120000-我的密码.md").await;
        assert_eq!(g.tick().await.git, "conflict");
        let logged = std::fs::read_to_string(t.path().join("logs/service.log")).unwrap();
        assert!(!logged.contains("我的密码") && !logged.contains("clipboard/"), "{logged}");
        assert!(logged.contains(r#""ev":"data_sync""#) && logged.contains(r#""step":"rebase""#), "{logged}");
    }

    #[test]
    fn scrub_removes_credentials() {
        assert_eq!(
            scrub("fatal: unable to access 'https://u:p@h/x.git/': refused"),
            "fatal: unable to access 'https://***@h/x.git/': refused"
        );
        assert_eq!(scrub("ssh://git@host/x"), "ssh://***@host/x");
        assert_eq!(scrub("a\nb"), "a");
        assert_eq!(scrub(&"x".repeat(300)).chars().count(), 200);
    }

    #[test]
    fn device_json_is_written_only_when_it_changes() {
        let t = tempfile::tempdir().unwrap();
        let root = t.path();
        write_device_json(root, "123456789", "test-a").unwrap();
        let p = root.join("devices/123456789/device.json");
        let v: serde_json::Value = serde_json::from_slice(&std::fs::read(&p).unwrap()).unwrap();
        let want = json!({"id": "123456789", "name": "test-a", "os": std::env::consts::OS, "version": env!("CARGO_PKG_VERSION")});
        assert_eq!(v, want);
        let before = std::fs::metadata(&p).unwrap().modified().unwrap();
        std::thread::sleep(Duration::from_millis(20));
        write_device_json(root, "123456789", "test-a").unwrap();
        assert_eq!(std::fs::metadata(&p).unwrap().modified().unwrap(), before);
    }
}
