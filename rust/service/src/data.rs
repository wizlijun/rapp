//! The data root as a git repository (data-dir spec §1, R8, R9, R12, R13): `device.json`, and a commit
//! of whatever changed every `commit_every`. Logs carry counts and step names only, never git output.

use anyhow::Result;
use rapp_net::config::{device, local, read_json, write_json, write_private};
use rapp_net::log::{timestamp, Log, Lvl};
use serde::{Deserialize, Serialize};
use serde_json::json;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::{Duration, SystemTime};
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
        }
    }

    /// One round: make sure there is a repository, commit what changed. Saves `local/sync.json`.
    pub async fn tick(&mut self) -> SyncStatus {
        match self.round().await {
            Ok(git) => (self.status.git, self.status.error) = (git.into(), None),
            Err(step) => {
                self.log.event(Lvl::Warn, "data_error", json!({"step": step}));
                (self.status.git, self.status.error) = ("error".into(), Some(format!("git {step} failed")));
            }
        }
        if let Err(e) = write_json(&local(&self.root).join(SYNC_FILE), &self.status) {
            self.log.event(Lvl::Warn, "data_error", json!({"step": "save sync.json", "err": format!("{e:#}")}));
        }
        self.status.clone()
    }

    /// The step that failed is the error.
    async fn round(&mut self) -> Result<&'static str, &'static str> {
        if self.run(&["--version"]).await.is_none() {
            return Ok("missing");
        }
        if !self.root.join(".git").exists() {
            self.run(&["init", "-b", "main"]).await.ok_or("init")?;
        }
        self.commit_changes().await?;
        Ok("local")
    }

    async fn commit_changes(&mut self) -> Result<(), &'static str> {
        let changed = self.run(&["status", "--porcelain", "--untracked-files=all"]).await.ok_or("status")?;
        let files = changed.lines().filter(|l| !l.is_empty()).count();
        if files == 0 {
            return Ok(());
        }
        self.run(&["add", "-A"]).await.ok_or("add")?;
        let (email, message) = (format!("user.email={}", self.email), self.message.clone());
        let args = ["-c", "user.name=rapp", "-c", &email, "-c", "commit.gpgsign=false", "commit", "-m", &message];
        self.run(&args).await.ok_or("commit")?;
        self.status.last_commit = Some(timestamp(SystemTime::now()));
        self.log.event(Lvl::Info, "data_commit", json!({"files": files}));
        Ok(())
    }

    /// Runs git in the root; its stdout when it exits 0, None otherwise (output is never logged).
    async fn run(&self, args: &[&str]) -> Option<String> {
        let mut cmd = tokio::process::Command::new(&self.git);
        cmd.current_dir(&self.root).args(args);
        for (k, _) in std::env::vars_os() {
            if k.to_string_lossy().starts_with("GIT_") {
                cmd.env_remove(k);
            }
        }
        cmd.env("GIT_TERMINAL_PROMPT", "0").envs(self.env.iter().map(|(k, v)| (k, v)));
        cmd.stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::null()).kill_on_drop(true);
        let out = tokio::time::timeout(GIT_TIMEOUT, cmd.output()).await.ok()?.ok()?;
        out.status.success().then(|| String::from_utf8_lossy(&out.stdout).into_owned())
    }
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
