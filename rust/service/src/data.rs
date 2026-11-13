//! The data root as a git repository (data-dir spec §1, R8, R9, R12, R13): `device.json`, and a commit
//! of whatever changed every `commit_every`. Logs carry counts and step names only, never git output.

use anyhow::Result;
use rapp_net::config::{device, local, read_json, write_json, write_private};
use rapp_net::datadir::README_MARKER;
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
/// A missing git is looked for again at most this often (D6).
const REPROBE: Duration = Duration::from_secs(600);
/// Paths (relative to the root, need not exist) that must be git-ignored before anything is added (D4).
const SECRETS: [&str; 4] = ["local/service.json", "local/hosts.json", "local/ipc.token", "files/x"];

#[derive(Clone, Debug)]
pub struct DataOpts {
    pub root: PathBuf,
    pub git: PathBuf,
    pub commit_every: Duration,
    pub pull_every: Duration,
    /// Added to every git child's environment, after the cleaning.
    pub git_env: Vec<(String, String)>,
    /// True when running `git` would only pop up macOS's "install developer tools" dialog.
    pub no_dev_tools: fn(&Path) -> bool,
}

impl DataOpts {
    pub fn system(root: PathBuf) -> Self {
        DataOpts {
            root,
            git: "git".into(),
            commit_every: Duration::from_secs(60),
            pull_every: Duration::from_secs(300),
            git_env: Vec::new(),
            no_dev_tools,
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
    no_dev_tools: fn(&Path) -> bool,
    /// When git was last found missing; it is probed again only after `REPROBE`.
    missing_at: Option<Instant>,
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
            no_dev_tools: opts.no_dev_tools,
            missing_at: None,
            conflict: false,
        }
    }

    /// One round: make sure there is a repository, commit what changed. Saves `local/sync.json`.
    pub async fn tick(&mut self) -> SyncStatus {
        match self.round().await {
            Ok(Some(git)) => (self.status.git, self.status.error) = (git.into(), None),
            Ok(None) => {}
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
    /// `Ok(None)`: nothing to do this round, keep the previous status.
    async fn round(&mut self) -> Result<Option<&'static str>, Fail> {
        if self.missing_at.is_some_and(|t| t.elapsed() < REPROBE) {
            return Ok(Some("missing"));
        }
        if (self.no_dev_tools)(&self.git) || self.run(&["--version"]).await.is_none() {
            self.missing_at = Some(Instant::now());
            return Ok(Some("missing"));
        }
        self.missing_at = None;
        if !is_rapp_root(&self.root) {
            return Err(Fail("readme", Some("这个文件夹不是 rapp 的数据目录".into())));
        }
        if !self.root.join(".git").exists() {
            self.run(&["init", "-b", "main"]).await.ok_or("init")?;
        }
        if self.rebase_in_progress() {
            return Err(Fail("rebase --abort", Some("git rebase --abort failed".into())));
        }
        let committed = self.commit_changes().await?;
        let remotes = self.run(&["remote"]).await.ok_or("remote")?;
        let Some(remote) = remotes
            .lines()
            .map(str::trim)
            .find(|r| *r == "origin")
            .or_else(|| remotes.lines().map(str::trim).find(|r| !r.is_empty()))
        else {
            return Ok(Some("local"));
        };
        if self.conflict {
            return Ok(Some("conflict"));
        }
        let due = committed || self.last_pull.is_none_or(|t| t.elapsed() >= self.pull_every);
        if !due {
            return Ok(None);
        }
        self.last_pull = Some(Instant::now());
        let r = self.sync(remote).await;
        if r.is_err() {
            self.last_pull = None; // retry next round (R11)
        }
        r.map(Some)
    }

    fn rebase_in_progress(&self) -> bool {
        ["rebase-merge", "rebase-apply"].iter().any(|d| self.root.join(".git").join(d).exists())
    }

    /// Fetch, rebase onto the remote branch, push (R10).
    async fn sync(&mut self, remote: &str) -> Result<&'static str, Fail> {
        let branch = self.run(&["symbolic-ref", "--short", "HEAD"]).await.ok_or("branch")?.trim().to_string();
        let o = self.exec_net(&["fetch", remote]).await;
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
                if !self.rebase_in_progress() {
                    return Err(Fail("rebase", Some("git rebase failed".into())));
                }
                if self.run(&["rebase", "--abort"]).await.is_none() {
                    return Err(Fail("rebase --abort", Some("git rebase --abort failed".into())));
                }
                self.conflict = true;
                return Ok("conflict");
            }
        }
        let o = self.exec_net(&["push", remote, &format!("HEAD:refs/heads/{branch}")]).await;
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

    async fn commit_changes(&mut self) -> Result<bool, Fail> {
        let changed = self.run(&["status", "--porcelain", "--untracked-files=all"]).await.ok_or("status")?;
        let files = changed.lines().filter(|l| !l.is_empty()).count();
        if files == 0 {
            return Ok(false);
        }
        for path in SECRETS {
            if self.run(&["check-ignore", "-q", path]).await.is_none() {
                return Err(Fail("check-ignore", Some("机密文件没被 .gitignore 挡住，已停止自动保存".into())));
            }
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
        self.exec_with(args, None).await
    }

    /// fetch/push: ssh must never prompt or hang, unless the user set `core.sshCommand`.
    async fn exec_net(&self, args: &[&str]) -> Out {
        let configured = self.run(&["config", "--get", "core.sshCommand"]).await.unwrap_or_default();
        self.exec_with(args, ssh_env(&configured)).await
    }

    async fn exec_with(&self, args: &[&str], ssh: Option<(&str, &str)>) -> Out {
        let mut cmd = tokio::process::Command::new(&self.git);
        cmd.current_dir(&self.root).args(["-c", "core.hooksPath=/dev/null"]).args(args);
        for (k, _) in std::env::vars_os() {
            if k.to_string_lossy().starts_with("GIT_") {
                cmd.env_remove(k);
            }
        }
        cmd.env("GIT_TERMINAL_PROMPT", "0");
        if let Some((k, v)) = ssh {
            cmd.env(k, v);
        }
        cmd.envs(self.env.iter().map(|(k, v)| (k, v)));
        cmd.stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::piped()).kill_on_drop(true);
        match tokio::time::timeout(GIT_TIMEOUT, cmd.output()).await {
            Ok(Ok(out)) => Out {
                code: out.status.code(),
                timed_out: false,
                stdout: String::from_utf8_lossy(&out.stdout).into_owned(),
                last_err: String::from_utf8_lossy(&out.stderr)
                    .lines()
                    .rev()
                    .find(|l| !l.trim().is_empty())
                    .unwrap_or("")
                    .to_string(),
            },
            r => Out { code: None, timed_out: r.is_err(), stdout: String::new(), last_err: String::new() },
        }
    }
}

struct Out {
    code: Option<i32>,
    timed_out: bool,
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
        Fail(step, Some(net_message(step, o)))
    }
}

impl From<&'static str> for Fail {
    fn from(step: &'static str) -> Fail {
        Fail(step, None)
    }
}

fn net_message(step: &str, o: &Out) -> String {
    let line = scrub(&o.last_err);
    match (line.trim().is_empty(), o.timed_out) {
        (false, _) => line,
        (true, true) => format!("git {step} timed out"),
        (true, false) => format!("git {step} failed"),
    }
}

/// The real probe: on macOS, `git` is `/usr/bin/git` (the xcode-select shim) and `xcode-select -p` fails.
fn no_dev_tools(git: &Path) -> bool {
    let quiet = || Stdio::null();
    cfg!(target_os = "macos")
        && is_shim(git, &std::env::var_os("PATH").unwrap_or_default())
        && !std::process::Command::new("/usr/bin/xcode-select")
            .arg("-p")
            .stdin(quiet())
            .stdout(quiet())
            .stderr(quiet())
            .status()
            .is_ok_and(|s| s.success())
}

/// `git` resolves, through `path` when it is a bare name, to macOS's `/usr/bin/git`.
fn is_shim(git: &Path, path: &std::ffi::OsStr) -> bool {
    let resolved = if git.components().count() > 1 {
        Some(git.to_path_buf())
    } else {
        std::env::split_paths(path).map(|d| d.join(git)).find(|p| p.is_file())
    };
    resolved.as_deref() == Some(Path::new("/usr/bin/git"))
}

/// `README.md` starts with rapp's marker; anything else is someone else's folder and git stays away.
fn is_rapp_root(root: &Path) -> bool {
    std::fs::read_to_string(root.join("README.md"))
        .is_ok_and(|t| t.lines().next().is_some_and(|l| l.trim_end() == README_MARKER))
}

/// The ssh command that keeps fetch/push from hanging, when the user has not chosen their own.
fn ssh_env(configured: &str) -> Option<(&'static str, &'static str)> {
    configured.trim().is_empty().then_some(("GIT_SSH_COMMAND", "ssh -o BatchMode=yes -o ConnectTimeout=20"))
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
            no_dev_tools: |_| false,
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
    async fn a_root_that_is_not_rapps_is_never_committed() {
        if !have_git() {
            return;
        }
        let t = tempfile::tempdir().unwrap();
        let root = t.path().join("rapp");
        std::fs::create_dir(&root).unwrap();
        std::fs::write(root.join("README.md"), "# my project\n").unwrap();
        std::fs::write(root.join(".gitignore"), "target/\n").unwrap();
        git(&root, &["init", "-b", "main"]);
        tgit(&root, &["add", "README.md", ".gitignore"]);
        tgit(&root, &["commit", "-m", "mine"]);
        prepare(&root, &t.path().join("no-legacy")).unwrap();
        std::fs::write(root.join("local/service.json"), "{}").unwrap();
        std::fs::write(root.join("local/hosts.json"), "[]").unwrap();
        let s = DataGit::new(&opts(&root), "test-a", log(&t)).tick().await;
        assert_eq!((s.git.as_str(), s.error.as_deref()), ("error", Some("这个文件夹不是 rapp 的数据目录")));
        assert_eq!(git(&root, &["log", "--format=%s"]).trim(), "mine");
        assert!(!git(&root, &["ls-files"]).contains("local/"));
        let logged = std::fs::read_to_string(t.path().join("logs/service.log")).unwrap_or_default();
        assert!(!logged.contains("service.json") && !logged.contains("local/"), "{logged}");
        let bare_dir = t.path().join("plain");
        prepare(&bare_dir, &t.path().join("no-legacy")).unwrap();
        std::fs::write(bare_dir.join("README.md"), "# notes\n").unwrap();
        assert_eq!(DataGit::new(&opts(&bare_dir), "test-a", log(&t)).tick().await.git, "error");
        assert!(!bare_dir.join(".git").exists(), "no git init in a folder that is not rapp's");
    }

    #[tokio::test]
    async fn a_gitignore_that_lets_secrets_through_stops_commits() {
        if !have_git() {
            return;
        }
        let (t, root) = prepared();
        std::fs::write(root.join(".gitignore"), "files/\n").unwrap();
        std::fs::write(root.join("local/service.json"), "{}").unwrap();
        let s = DataGit::new(&opts(&root), "test-a", log(&t)).tick().await;
        assert_eq!(
            (s.git.as_str(), s.error.as_deref()),
            ("error", Some("机密文件没被 .gitignore 挡住，已停止自动保存"))
        );
        assert_eq!(git(&root, &["rev-list", "--all", "--count"]).trim(), "0");
        assert_eq!(git(&root, &["ls-files"]).trim(), "");
        let logged = std::fs::read_to_string(t.path().join("logs/service.log")).unwrap_or_default();
        assert!(!logged.contains("service.json") && !logged.contains("local/"), "{logged}");
    }

    static PROBES: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);

    fn counted_shim(_: &Path) -> bool {
        PROBES.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        true
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn without_dev_tools_git_is_never_run_and_probed_again_after_10_minutes() {
        use std::os::unix::fs::PermissionsExt;
        let (t, root) = prepared();
        let ran = t.path().join("ran");
        let fake = t.path().join("git");
        std::fs::write(&fake, format!("#!/bin/sh\necho x >> '{}'\n", ran.display())).unwrap();
        std::fs::set_permissions(&fake, std::fs::Permissions::from_mode(0o755)).unwrap();
        let o = DataOpts { git: fake, no_dev_tools: counted_shim, ..opts(&root) };
        let mut g = DataGit::new(&o, "test-a", log(&t));
        let probes = || PROBES.load(std::sync::atomic::Ordering::SeqCst);
        assert_eq!(g.tick().await.git, "missing");
        assert_eq!(g.tick().await.git, "missing");
        assert_eq!(probes(), 1, "a missing result is cached");
        g.missing_at = Instant::now().checked_sub(Duration::from_secs(9 * 60));
        assert_eq!(g.tick().await.git, "missing");
        assert_eq!(probes(), 1, "not yet 10 minutes");
        g.missing_at = Instant::now().checked_sub(Duration::from_secs(10 * 60 + 1));
        assert_eq!(g.tick().await.git, "missing");
        assert_eq!(probes(), 2, "probed again after 10 minutes");
        assert!(!ran.exists(), "git was never run");
        assert!(!root.join(".git").exists());
    }

    #[test]
    fn only_usr_bin_git_is_the_shim() {
        let t = tempfile::tempdir().unwrap();
        std::fs::write(t.path().join("git"), "").unwrap();
        assert!(is_shim(Path::new("/usr/bin/git"), "".as_ref()));
        assert!(!is_shim(Path::new("git"), t.path().as_os_str()));
        assert!(!is_shim(&t.path().join("git"), "".as_ref()));
        assert!(!is_shim(Path::new("git"), "".as_ref()));
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
    fn net_errors_are_never_empty() {
        let o = |timed_out| Out { code: None, timed_out, stdout: String::new(), last_err: String::new() };
        assert_eq!(net_message("fetch", &o(false)), "git fetch failed");
        assert_eq!(net_message("push", &o(true)), "git push timed out");
        let mut e = o(false);
        e.last_err = "fatal: boom".into();
        assert_eq!(net_message("push", &e), "fatal: boom");
    }

    #[test]
    fn ssh_is_batched_unless_the_user_chose() {
        assert_eq!(ssh_env("").map(|e| e.0), Some("GIT_SSH_COMMAND"));
        assert!(ssh_env("").unwrap().1.contains("BatchMode=yes"));
        assert_eq!(ssh_env("ssh -i k\n"), None);
    }

    #[tokio::test]
    async fn a_stuck_rebase_blocks_commits() {
        if !have_git() {
            return;
        }
        let (t, root) = prepared();
        let mut g = DataGit::new(&opts(&root), "test-a", log(&t));
        g.tick().await;
        let before = git(&root, &["rev-list", "--count", "HEAD"]);
        std::fs::create_dir(root.join(".git/rebase-merge")).unwrap();
        std::fs::write(root.join("shared/a.json"), "{}").unwrap();
        let s = g.tick().await;
        assert_eq!((s.git.as_str(), s.error.as_deref()), ("error", Some("git rebase --abort failed")));
        assert_eq!(git(&root, &["rev-list", "--count", "HEAD"]), before);
        assert!(
            git(&root, &["status", "--porcelain", "--untracked-files=all"]).contains("shared/a.json"),
            "nothing staged or committed"
        );
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn a_rebase_that_cannot_start_is_an_error_and_retried() {
        if !have_git() {
            return;
        }
        let (t, root) = prepared();
        let b = bare(&t);
        let o = with_remote(&root, b.to_str().unwrap());
        let mut g = DataGit::new(&o, "test-a", log(&t));
        assert_eq!(g.tick().await.git, "synced");
        let other = other_device(&t, &b);
        std::fs::create_dir_all(other.join("shared/sub")).unwrap();
        std::fs::write(other.join("shared/sub/x.json"), "theirs").unwrap();
        tgit(&other, &["add", "shared/sub/x.json"]);
        tgit(&other, &["commit", "-m", "x"]);
        tgit(&other, &["push", "origin", "HEAD:refs/heads/main"]);
        // an empty, read-only directory is not committed, but blocks checking out their file
        std::fs::create_dir(root.join("shared/sub")).unwrap();
        std::fs::set_permissions(root.join("shared/sub"), std::os::unix::fs::PermissionsExt::from_mode(0o555)).unwrap();
        std::fs::write(root.join("shared/a.json"), "{}").unwrap();
        let s = g.tick().await;
        assert_eq!((s.git.as_str(), s.error.as_deref()), ("error", Some("git rebase failed")), "{s:?}");
        assert!(!root.join(".git/rebase-merge").exists() && !root.join(".git/rebase-apply").exists());
        std::fs::set_permissions(root.join("shared/sub"), std::os::unix::fs::PermissionsExt::from_mode(0o755)).unwrap();
        assert_eq!(g.tick().await.git, "synced", "retried, not stopped");
    }

    #[tokio::test]
    async fn a_failed_fetch_is_retried_next_round_and_a_quiet_round_keeps_status() {
        if !have_git() {
            return;
        }
        let (t, root) = prepared();
        let b = bare(&t);
        let mut o = with_remote(&root, "/nonexistent/remote.git");
        o.pull_every = Duration::from_secs(3600);
        let mut g = DataGit::new(&o, "test-a", log(&t));
        assert_eq!(g.tick().await.git, "error");
        git(&root, &["remote", "set-url", "origin", b.to_str().unwrap()]);
        let s = g.tick().await;
        assert_eq!(s.git, "synced", "retried although pull_every has not passed");
        let again = g.tick().await;
        assert_eq!(again, s, "nothing due, status kept");
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
