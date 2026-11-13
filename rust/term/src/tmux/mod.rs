//! One-shot tmux commands, run locally or over ssh.

pub mod cmd;
pub mod parse;

use crate::runner::{classify, Runner};
use std::process::Stdio;
use tokio::io::AsyncWriteExt;

/// A tmux on some host, optionally on a named socket.
#[derive(Clone, Debug)]
pub struct Tmux {
    pub runner: Runner,
    pub bin: String,
    pub socket: Option<String>,
}

/// One pane and what it sits in.
#[derive(Clone, Debug, PartialEq)]
pub struct PaneInfo {
    pub session_id: String,
    pub session: String,
    pub window_id: String,
    pub window: String,
    pub pane: String,
    pub command: String,
    pub title: String,
    pub window_index: u32,
    pub pane_index: u32,
    pub attached: u32,
    pub activity: u64,
    pub cols: u16,
    pub rows: u16,
    pub dead: bool,
}

/// What a finished one-shot process left behind.
struct Done {
    code: Option<i32>,
    stdout: String,
    stderr: String,
}

impl Tmux {
    pub fn local() -> Tmux {
        Tmux { runner: Runner::Local, bin: "tmux".into(), socket: None }
    }

    /// Run one tmux command; stdout on success. Errors never carry the args.
    pub async fn run(&self, args: &[String]) -> anyhow::Result<String> {
        self.run_stdin(args, &[]).await
    }

    /// Like `run`, feeding `stdin` to the process.
    pub async fn run_stdin(&self, args: &[String], stdin: &[u8]) -> anyhow::Result<String> {
        let d = self.exec(args, stdin).await?;
        if d.code == Some(0) {
            return Ok(d.stdout);
        }
        Err(Self::failure(&d))
    }

    fn failure(d: &Done) -> anyhow::Error {
        let text = classify(d.code, &d.stderr).to_string();
        if !text.is_empty() {
            anyhow::anyhow!(text)
        } else {
            match d.code {
                Some(c) => anyhow::anyhow!("exit code {c}"),
                None => anyhow::anyhow!("terminated by a signal"),
            }
        }
    }

    async fn exec(&self, args: &[String], stdin: &[u8]) -> anyhow::Result<Done> {
        let mut full: Vec<String> = Vec::new();
        if let Some(s) = &self.socket {
            full.extend(["-L".to_string(), s.clone()]);
        }
        full.extend(args.iter().cloned());
        let mut c = self.runner.command(&self.bin, &full);
        c.stdin(if stdin.is_empty() { Stdio::null() } else { Stdio::piped() })
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .kill_on_drop(true);
        let mut child = c.spawn().map_err(|_| anyhow::anyhow!("could not start {}", self.program_name()))?;
        let writer = child.stdin.take().map(|mut w| {
            let data = stdin.to_vec();
            tokio::spawn(async move {
                // A process that exits without reading is reported through its exit code.
                let _ = w.write_all(&data).await;
            })
        });
        let out = child.wait_with_output().await?;
        if let Some(w) = writer {
            let _ = w.await;
        }
        Ok(Done {
            code: out.status.code(),
            stdout: String::from_utf8_lossy(&out.stdout).into_owned(),
            stderr: String::from_utf8_lossy(&out.stderr).into_owned(),
        })
    }

    fn program_name(&self) -> &str {
        match self.runner {
            Runner::Local => &self.bin,
            Runner::Ssh { .. } => "ssh",
        }
    }

    pub async fn version(&self) -> anyhow::Result<(u32, u32)> {
        let out = self.run(&["-V".to_string()]).await?;
        parse::version(&out).ok_or_else(|| anyhow::anyhow!("could not read the tmux version"))
    }

    pub async fn check(&self) -> anyhow::Result<()> {
        let (major, minor) = self.version().await?;
        if (major, minor) < (3, 2) {
            anyhow::bail!("tmux 3.2 or newer is required (found {major}.{minor})");
        }
        Ok(())
    }

    /// Every pane; no server (or no sessions) is an empty list.
    pub async fn list(&self) -> anyhow::Result<Vec<PaneInfo>> {
        let d = self.exec(&cmd::list_panes(), &[]).await?;
        if d.code == Some(0) {
            return Ok(parse::panes(&d.stdout));
        }
        const EMPTY: [&str; 4] = ["no server running", "No such file or directory", "no current target", "no sessions"];
        if EMPTY.iter().any(|m| d.stderr.contains(m)) {
            return Ok(Vec::new());
        }
        Err(Self::failure(&d))
    }
}
