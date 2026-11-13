//! One-shot tmux commands, run locally or over ssh.

pub mod cmd;
pub mod control;
pub mod parse;

use crate::runner::{classify, RunFail, Runner};
use crate::screen::Screen;
use std::process::Stdio;
use std::sync::atomic::{AtomicU64, Ordering};
use tokio::io::AsyncWriteExt;

/// The most text one paste may carry, in bytes.
pub const MAX_PASTE: usize = 1_048_576;

static PASTE_SEQ: AtomicU64 = AtomicU64::new(0);

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

    /// Like `run_stdin` for input commands: a failure keeps only its kind, never tmux's own words.
    async fn run_input(&self, args: &[String], stdin: &[u8]) -> anyhow::Result<()> {
        let d = self.exec(args, stdin).await?;
        if d.code == Some(0) {
            return Ok(());
        }
        match classify(d.code, &d.stderr) {
            RunFail::Other(_) => match d.code {
                Some(c) => anyhow::bail!("tmux refused the input (exit code {c})"),
                None => anyhow::bail!("tmux refused the input (terminated by a signal)"),
            },
            kind => anyhow::bail!("could not send input: {kind}"),
        }
    }

    /// Send keys or typed text, built by `cmd::send_named` / `cmd::send_hex`, once.
    pub async fn send(&self, args: Vec<String>) -> anyhow::Result<()> {
        self.run_input(&args, &[]).await
    }

    /// Paste `text` into `pane` as one bracketed paste through a throwaway buffer; `enter` adds an Enter after it.
    pub async fn paste(&self, pane: &str, text: &str, enter: bool) -> anyhow::Result<()> {
        if text.len() > MAX_PASTE {
            anyhow::bail!("text is too long (1 MiB at most)");
        }
        let name = format!("rapp-{}-{}", std::process::id(), PASTE_SEQ.fetch_add(1, Ordering::Relaxed));
        self.run_input(&cmd::load_buffer(&name), text.as_bytes()).await?;
        self.run_input(&cmd::paste_buffer(&name, pane), &[]).await?;
        if enter {
            self.send(cmd::send_named(pane, &["Enter".to_string()])).await?;
        }
        Ok(())
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
        let mut c = self.runner.command(&self.bin, &self.args(args));
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

    /// The full tmux argument list for `rest`: `-u` first (tmux must not fall back to `_` for non-ASCII bytes and
    /// tabs under a C locale), then the socket, then the command. Every tmux process rapp starts uses this.
    pub fn args(&self, rest: &[String]) -> Vec<String> {
        let mut full = vec!["-u".to_string()];
        if let Some(s) = &self.socket {
            full.extend(["-L".to_string(), s.clone()]);
        }
        full.extend(rest.iter().cloned());
        full
    }

    pub(crate) fn program_name(&self) -> &str {
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
            let v = parse::panes(&d.stdout);
            if v.is_empty() && !d.stdout.trim().is_empty() {
                anyhow::bail!("could not read the tmux pane list");
            }
            return Ok(v);
        }
        if is_empty_server(d.code, &d.stderr) {
            return Ok(Vec::new());
        }
        Err(Self::failure(&d))
    }

    /// The visible screen of `pane`: the capture, then its geometry.
    pub async fn capture(&self, pane: &str) -> anyhow::Result<Screen> {
        let text = self.run(&cmd::capture(pane)).await?;
        let meta = self.run(&cmd::meta(pane)).await?;
        Screen::from_capture(&text, &meta)
    }

    /// `lines` rows of scrollback ending `before` rows above the visible screen.
    pub async fn history(&self, pane: &str, before: u32, lines: u32) -> anyhow::Result<Vec<String>> {
        if lines == 0 {
            return Ok(Vec::new());
        }
        let size = self.run(&cmd::history_size(pane)).await?;
        let size: u32 = size.trim().parse().map_err(|_| anyhow::anyhow!("could not read the pane history size"))?;
        if before >= size {
            return Ok(Vec::new());
        }
        let lines = lines.min(size - before);
        let out = self.run(&cmd::history(pane, before, lines)).await?;
        let mut v: Vec<String> = out.split('\n').map(String::from).collect();
        if v.last().is_some_and(|l| l.is_empty()) {
            v.pop();
        }
        Ok(v)
    }
}

/// Does this failed `list-panes` only mean "no server, or no sessions"? tmux exits 1 for it; other exit codes
/// (ssh 255, a missing program 127) and classified failures are real errors.
fn is_empty_server(code: Option<i32>, stderr: &str) -> bool {
    const EMPTY: [&str; 5] =
        ["no server running", "error connecting to", "No such file or directory", "no current target", "no sessions"];
    code == Some(1) && matches!(classify(code, stderr), RunFail::Other(_)) && EMPTY.iter().any(|m| stderr.contains(m))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_server_decision() {
        assert!(is_empty_server(Some(1), "no current target"));
        assert!(is_empty_server(Some(1), "no server running on /tmp/tmux-501/default"));
        assert!(is_empty_server(Some(1), "error connecting to /tmp/tmux-501/x (No such file or directory)"));
        assert!(!is_empty_server(Some(127), "sh: tmux: No such file or directory"));
        assert!(!is_empty_server(Some(255), "ssh: Could not resolve hostname h: No such file or directory"));
        assert!(!is_empty_server(Some(255), "Warning: no such file; no current target"));
        assert!(!is_empty_server(Some(1), "Permission denied (publickey). No such file or directory"));
        assert!(!is_empty_server(Some(1), "something else"));
    }

    #[test]
    fn args_put_u_first() {
        let t = Tmux { runner: Runner::Local, bin: "tmux".into(), socket: Some("s".into()) };
        assert_eq!(t.args(&["list-panes".into()]), ["-u", "-L", "s", "list-panes"]);
        assert_eq!(Tmux::local().args(&["-V".into()]), ["-u", "-V"]);
    }
}
