//! Runners: run a program on this machine, or on another one through ssh.

use std::fmt;
use std::path::{Path, PathBuf};

/// Where a command runs.
#[derive(Clone, Debug)]
pub enum Runner {
    Local,
    Ssh { dest: String, ctl_dir: PathBuf },
}

impl Runner {
    /// An ssh runner. `dest` must be something ssh cannot mistake for an option or split in two.
    pub fn ssh(dest: &str, ctl_dir: &Path) -> anyhow::Result<Runner> {
        if dest.is_empty() || dest.starts_with('-') || dest.chars().any(|c| c.is_whitespace() || c.is_control()) {
            anyhow::bail!("invalid ssh destination");
        }
        Ok(Runner::Ssh { dest: dest.to_string(), ctl_dir: ctl_dir.to_path_buf() })
    }

    /// The full command line: program first, then its arguments.
    pub fn argv(&self, program: &str, args: &[String]) -> Vec<String> {
        match self {
            Runner::Local => std::iter::once(program.to_string()).chain(args.iter().cloned()).collect(),
            Runner::Ssh { dest, ctl_dir } => {
                let mut v: Vec<String> = ["ssh", "-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "-o"]
                    .into_iter()
                    .map(String::from)
                    .collect();
                v.extend(["ServerAliveInterval=15", "-o", "ServerAliveCountMax=3"].map(String::from));
                #[cfg(unix)]
                v.extend([
                    "-o".to_string(),
                    "ControlMaster=auto".to_string(),
                    "-o".to_string(),
                    format!("ControlPath={}/%C", ctl_dir.display()),
                    "-o".to_string(),
                    "ControlPersist=60".to_string(),
                ]);
                #[cfg(not(unix))]
                let _ = ctl_dir;
                let mut remote = format!("exec {}", sh_quote(program));
                for a in args {
                    remote.push(' ');
                    remote.push_str(&sh_quote(a));
                }
                v.extend(["--".to_string(), dest.clone(), remote]);
                v
            }
        }
    }

    /// A command ready to spawn; the caller sets stdio.
    pub fn command(&self, program: &str, args: &[String]) -> tokio::process::Command {
        let argv = self.argv(program, args);
        let mut c = tokio::process::Command::new(&argv[0]);
        c.args(&argv[1..]);
        c
    }
}

/// Wrap `s` in single quotes for a POSIX shell.
pub fn sh_quote(s: &str) -> String {
    format!("'{}'", s.replace('\'', r"'\''"))
}

/// Why a run failed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RunFail {
    HostKey,
    Auth,
    Unreachable,
    NoProgram,
    Other(String),
}

pub fn classify(code: Option<i32>, stderr: &str) -> RunFail {
    let s = stderr.to_lowercase();
    let has = |frags: &[&str]| frags.iter().any(|f| s.contains(f));
    if has(&["host key verification failed"]) {
        RunFail::HostKey
    } else if has(&["permission denied"]) {
        RunFail::Auth
    } else if has(&[
        "connection refused",
        "connection timed out",
        "could not resolve hostname",
        "no route to host",
        "network is unreachable",
    ]) {
        RunFail::Unreachable
    } else if code == Some(127) || has(&["command not found"]) {
        RunFail::NoProgram
    } else {
        RunFail::Other(stderr.trim().to_string())
    }
}

impl fmt::Display for RunFail {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            RunFail::HostKey => f.write_str("host key verification failed"),
            RunFail::Auth => f.write_str("authentication failed"),
            RunFail::Unreachable => f.write_str("host unreachable"),
            RunFail::NoProgram => f.write_str("program not found on the host"),
            RunFail::Other(s) => f.write_str(s),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::Path;

    #[test]
    fn local_argv_is_the_program_itself() {
        assert_eq!(Runner::Local.argv("tmux", &["-V".into()]), ["tmux", "-V"]);
    }
    #[test]
    fn ssh_argv_is_exact() {
        let r = Runner::ssh("me@gpu1.lab", Path::new("/tmp/c")).unwrap();
        let a = r.argv("/opt/homebrew/bin/tmux", &["list-panes".into(), "-F".into(), "#{pane_id} it's".into()]);
        let mut want = vec![
            "ssh",
            "-T",
            "-o",
            "BatchMode=yes",
            "-o",
            "ConnectTimeout=10",
            "-o",
            "ServerAliveInterval=15",
            "-o",
            "ServerAliveCountMax=3",
        ];
        #[cfg(unix)]
        want.extend(["-o", "ControlMaster=auto", "-o", "ControlPath=/tmp/c/%C", "-o", "ControlPersist=60"]);
        want.extend(["--", "me@gpu1.lab", r#"exec '/opt/homebrew/bin/tmux' 'list-panes' '-F' '#{pane_id} it'\''s'"#]);
        assert_eq!(a, want);
    }
    #[test]
    fn ssh_rejects_dests_that_ssh_would_misread() {
        for bad in ["-oProxyCommand=x", "", " host", "ho st", "host\n", "a\tb", "-"] {
            assert!(Runner::ssh(bad, Path::new("/tmp/c")).is_err(), "{bad:?}");
        }
        assert!(Runner::ssh("me@gpu1.lab", Path::new("/tmp/c")).is_ok());
        assert!(Runner::ssh("gpu1", Path::new("/tmp/c")).is_ok());
    }
    #[test]
    fn classifies_failures() {
        assert!(matches!(classify(Some(255), "Host key verification failed."), RunFail::HostKey));
        assert!(matches!(classify(Some(255), "me@h: Permission denied (publickey)."), RunFail::Auth));
        assert!(matches!(
            classify(Some(255), "ssh: connect to host h port 22: Connection refused"),
            RunFail::Unreachable
        ));
        assert!(matches!(classify(Some(255), "ssh: Could not resolve hostname h"), RunFail::Unreachable));
        assert!(matches!(classify(Some(127), "sh: tmux: command not found"), RunFail::NoProgram));
        assert!(matches!(classify(Some(1), "no server running on /tmp/tmux-501/default"), RunFail::Other(_)));
    }
}
