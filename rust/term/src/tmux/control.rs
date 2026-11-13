//! The tmux control-mode client, attached only while someone is viewing the session.

use super::{cmd, Tmux};
use crate::runner::classify;
use std::collections::{HashSet, VecDeque};
use std::process::Stdio;
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::io::{AsyncBufRead, AsyncBufReadExt, AsyncReadExt, AsyncWrite, AsyncWriteExt};
use tokio::process::Child;
use tokio::sync::mpsc::{unbounded_channel, UnboundedReceiver, UnboundedSender};
use tokio::sync::{oneshot, Notify};

/// The stream ended without tmux saying `%exit` (for example, the ssh connection dropped).
const CLOSED: &str = "connection closed";
/// How long `detach` waits for the client process to leave before killing it.
const DETACH_WAIT: Duration = Duration::from_secs(1);
/// How much of the client's stderr is kept to explain a failed attach.
const STDERR_KEEP: usize = 4096;

/// Notifications that mean windows or panes came, went, or changed shape.
const LAYOUT: &[&str] = &[
    "%window-add",
    "%window-close",
    "%window-renamed",
    "%layout-change",
    "%unlinked-window-add",
    "%unlinked-window-close",
    "%session-window-changed",
    "%pane-mode-changed",
];

/// What the control client tells its owner besides command results and dirty panes.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Event {
    /// Windows or panes came, went, or changed shape.
    Layout,
    /// The client is gone: tmux's own `%exit` reason, or "connection closed" when the stream just ended.
    Exit(String),
}

/// One line from a control-mode stream, classified.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Line {
    Begin,
    End,
    Error,
    /// Output from this pane; the content is not kept.
    Output(String),
    Layout,
    Exit(String),
    Other,
}

pub fn parse_line(l: &str) -> Line {
    let (word, rest) = l.split_once(' ').unwrap_or((l, ""));
    match word {
        "%begin" => Line::Begin,
        "%end" => Line::End,
        "%error" => Line::Error,
        "%output" | "%extended-output" => match rest.split(' ').next() {
            Some(p) if p.starts_with('%') => Line::Output(p.to_string()),
            _ => Line::Other,
        },
        "%exit" => Line::Exit(rest.to_string()),
        w if LAYOUT.contains(&w) => Line::Layout,
        _ => Line::Other,
    }
}

/// The result of one command block: its lines, or tmux's error text.
type Reply = Result<Vec<String>, String>;

/// State the reader task shares with the client.
struct Shared {
    pending: Mutex<Pending>,
    dirty: Mutex<HashSet<String>>,
    notify: Notify,
}

/// Commands waiting for their block, oldest first; once the stream is over, why.
struct Pending {
    waiting: VecDeque<oneshot::Sender<Reply>>,
    closed: Option<&'static str>,
}

impl Shared {
    /// No more replies will come: fail everyone waiting, and everyone who asks later.
    fn close(&self, why: &'static str) {
        let mut p = self.pending.lock().unwrap();
        p.closed.get_or_insert(why);
        for w in p.waiting.drain(..) {
            let _ = w.send(Err(why.to_string()));
        }
    }

    fn reply(&self, r: Reply) {
        let w = self.pending.lock().unwrap().waiting.pop_front();
        if let Some(w) = w {
            let _ = w.send(r);
        }
    }
}

type Writer = Box<dyn AsyncWrite + Unpin + Send>;

struct Inner {
    shared: Arc<Shared>,
    /// Held for a whole command, so replies come back in the order commands went out.
    turn: tokio::sync::Mutex<()>,
    /// `None` once detached.
    writer: tokio::sync::Mutex<Option<Writer>>,
    /// The process `attach` started; `None` for `from_io`.
    child: Mutex<Option<Child>>,
}

/// A control-mode client. Clones share one connection.
#[derive(Clone)]
pub struct Control {
    inner: Arc<Inner>,
}

impl Control {
    /// Start `tmux -C attach-session` for `session_id` and wait until tmux has accepted it.
    pub async fn attach(tmux: &Tmux, session_id: &str) -> anyhow::Result<(Control, UnboundedReceiver<Event>)> {
        let mut c = tmux.runner.command(&tmux.bin, &tmux.args(&cmd::attach(session_id)));
        c.stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::piped()).kill_on_drop(true);
        let mut child = c.spawn().map_err(|_| anyhow::anyhow!("could not start {}", tmux.program_name()))?;
        let (Some(w), Some(r), Some(e)) = (child.stdin.take(), child.stdout.take(), child.stderr.take()) else {
            anyhow::bail!("could not start {}", tmux.program_name());
        };
        let stderr = tokio::spawn(keep_stderr(e));
        match Control::from_io(tokio::io::BufReader::new(r), w).await {
            Ok((ctl, ev)) => {
                *ctl.inner.child.lock().unwrap() = Some(child);
                Ok((ctl, ev))
            }
            Err(e) if e.to_string() == CLOSED => {
                // The process ended before tmux answered: ssh or the program itself says why on stderr.
                let code = match tokio::time::timeout(DETACH_WAIT, child.wait()).await {
                    Ok(Ok(s)) => s.code(),
                    _ => {
                        let _ = child.kill().await;
                        None
                    }
                };
                let text = tokio::time::timeout(DETACH_WAIT, stderr).await.ok().and_then(|r| r.ok()).unwrap_or_default();
                let why = classify(code, &String::from_utf8_lossy(&text)).to_string();
                Err(if why.is_empty() { e } else { anyhow::anyhow!(why) })
            }
            Err(e) => Err(e),
        }
    }

    /// A client over an already connected stream. tmux first answers the attach itself with one block; this
    /// waits for it, and an `%error` there is the returned error.
    pub async fn from_io<R, W>(r: R, w: W) -> anyhow::Result<(Control, UnboundedReceiver<Event>)>
    where
        R: AsyncBufRead + Unpin + Send + 'static,
        W: AsyncWrite + Unpin + Send + 'static,
    {
        let shared = Arc::new(Shared {
            pending: Mutex::new(Pending { waiting: VecDeque::new(), closed: None }),
            dirty: Mutex::new(HashSet::new()),
            notify: Notify::new(),
        });
        let (first, accepted) = oneshot::channel();
        shared.pending.lock().unwrap().waiting.push_back(first);
        let (tx, rx) = unbounded_channel();
        tokio::spawn(read(r, shared.clone(), tx));
        match accepted.await {
            Ok(Ok(_)) => {}
            Ok(Err(e)) if e.is_empty() => anyhow::bail!("tmux refused the control client"),
            Ok(Err(e)) => anyhow::bail!(e),
            Err(_) => anyhow::bail!(CLOSED),
        }
        let inner = Inner {
            shared,
            turn: tokio::sync::Mutex::new(()),
            writer: tokio::sync::Mutex::new(Some(Box::new(w))),
            child: Mutex::new(None),
        };
        Ok((Control { inner: Arc::new(inner) }, rx))
    }

    /// Run one tmux command on the channel: the lines between `%begin` and `%end`; `%error` is an `Err` with
    /// tmux's message.
    pub async fn command(&self, args: &[String]) -> anyhow::Result<Vec<String>> {
        let line = cmd::channel_line(args)?;
        let _turn = self.inner.turn.lock().await;
        let (tx, rx) = oneshot::channel();
        {
            let mut p = self.inner.shared.pending.lock().unwrap();
            if let Some(why) = p.closed {
                anyhow::bail!(why);
            }
            p.waiting.push_back(tx);
        }
        if let Err(e) = self.write(&line).await {
            // Ours is the newest entry: commands take turns.
            self.inner.shared.pending.lock().unwrap().waiting.pop_back();
            return Err(e);
        }
        match rx.await {
            Ok(Ok(v)) => Ok(v),
            Ok(Err(e)) if e.is_empty() => anyhow::bail!("tmux command failed"),
            Ok(Err(e)) => anyhow::bail!(e),
            Err(_) => anyhow::bail!(CLOSED),
        }
    }

    async fn write(&self, line: &str) -> anyhow::Result<()> {
        let mut w = self.inner.writer.lock().await;
        let w = w.as_mut().ok_or_else(|| anyhow::anyhow!("control client detached"))?;
        let sent = async {
            w.write_all(line.as_bytes()).await?;
            w.write_all(b"\n").await?;
            w.flush().await
        };
        sent.await.map_err(|_| anyhow::anyhow!(CLOSED))
    }

    /// Wait until some pane has new output; those panes, which are then no longer dirty.
    pub async fn dirty(&self) -> Vec<String> {
        let s = &self.inner.shared;
        loop {
            let woken = s.notify.notified();
            tokio::pin!(woken);
            woken.as_mut().enable();
            {
                let mut d = s.dirty.lock().unwrap();
                if !d.is_empty() {
                    return d.drain().collect();
                }
            }
            woken.await;
        }
    }

    /// Close the channel; if the process `attach` started has not left within a second, kill it.
    pub async fn detach(self) {
        self.inner.writer.lock().await.take();
        let child = self.inner.child.lock().unwrap().take();
        if let Some(mut c) = child {
            if tokio::time::timeout(DETACH_WAIT, c.wait()).await.is_err() {
                let _ = c.kill().await;
            }
        }
    }
}

/// The reader task: route blocks to waiting commands, mark dirty panes, pass on layout changes and the exit.
async fn read<R: AsyncBufRead + Unpin>(mut r: R, shared: Arc<Shared>, events: UnboundedSender<Event>) {
    let mut buf = Vec::new();
    // Inside a block: the `%begin` line's tail (time, number, flags), which its `%end` / `%error` repeats.
    let mut block: Option<(String, Vec<String>)> = None;
    let mut exited = false;
    loop {
        buf.clear();
        match r.read_until(b'\n', &mut buf).await {
            Ok(0) | Err(_) => break,
            Ok(_) => {}
        }
        if buf.last() == Some(&b'\n') {
            buf.pop();
        }
        let line = String::from_utf8_lossy(&buf);
        if let Some((tail, lines)) = &mut block {
            // Command output can hold any text, so only the matching end line closes the block.
            let ends = |word: &str| line.strip_prefix(word).and_then(|l| l.strip_prefix(' ')) == Some(tail.as_str());
            if ends("%end") {
                shared.reply(Ok(std::mem::take(lines)));
                block = None;
            } else if ends("%error") {
                shared.reply(Err(std::mem::take(lines).join("\n")));
                block = None;
            } else {
                lines.push(line.into_owned());
            }
            continue;
        }
        match parse_line(&line) {
            Line::Begin => block = Some((line["%begin".len()..].trim_start().to_string(), Vec::new())),
            Line::Output(pane) => {
                shared.dirty.lock().unwrap().insert(pane);
                shared.notify.notify_waiters();
            }
            Line::Layout => {
                let _ = events.send(Event::Layout);
            }
            Line::Exit(why) => {
                exited = true;
                shared.close("control client exited");
                let _ = events.send(Event::Exit(why));
            }
            Line::End | Line::Error | Line::Other => {}
        }
    }
    shared.close(CLOSED);
    if !exited {
        let _ = events.send(Event::Exit(CLOSED.to_string()));
    }
}

/// The first `STDERR_KEEP` bytes of the client's stderr; the rest is read and dropped so the pipe never fills.
async fn keep_stderr(mut e: tokio::process::ChildStderr) -> Vec<u8> {
    let mut kept = Vec::new();
    let mut chunk = [0u8; 1024];
    loop {
        match e.read(&mut chunk).await {
            Ok(0) | Err(_) => break,
            Ok(n) => {
                let room = STDERR_KEEP.saturating_sub(kept.len());
                kept.extend_from_slice(&chunk[..n.min(room)]);
            }
        }
    }
    kept
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::{AsyncWriteExt, BufReader, DuplexStream};

    #[test]
    fn classifies_control_lines() {
        assert!(matches!(parse_line("%begin 1794592454 12 0"), Line::Begin));
        assert!(matches!(parse_line("%end 1794592454 12 0"), Line::End));
        assert!(matches!(parse_line("%error 1794592454 12 0"), Line::Error));
        assert!(matches!(parse_line("%output %7 hello\\012"), Line::Output(p) if p == "%7"));
        assert!(matches!(parse_line("%extended-output %7 120 : x"), Line::Output(p) if p == "%7"));
        for l in [
            "%window-add @3",
            "%window-close @3",
            "%layout-change @1 abcd,80x24,0,0,1 abcd,80x24,0,0,1 *",
            "%window-renamed @1 x",
            "%unlinked-window-close @9",
        ] {
            assert!(matches!(parse_line(l), Line::Layout), "{l}");
        }
        assert!(matches!(parse_line("%exit server exited"), Line::Exit(r) if r == "server exited"));
        assert!(matches!(parse_line("%exit"), Line::Exit(r) if r.is_empty())); // when the session is killed it is a bare line (measured on tmux 3.4 and 3.8)
        assert!(matches!(parse_line("%session-changed $1 x"), Line::Other));
    }
    #[tokio::test]
    async fn a_stream_that_just_ends_is_reported_as_connection_closed() {
        // Review Focus 2: the ssh connection dropped
        let (mut tmux_side, ours) = tokio::io::duplex(4096);
        let (r, w) = tokio::io::split(ours);
        tokio::io::AsyncWriteExt::write_all(&mut tmux_side, b"%begin 1 1 0\n%end 1 1 0\n").await.unwrap();
        let (_ctl, mut ev) = Control::from_io(tokio::io::BufReader::new(r), w).await.unwrap();
        drop(tmux_side);
        assert!(matches!(ev.recv().await, Some(Event::Exit(r)) if r == "connection closed"));
    }

    /// A client whose attach tmux has already accepted, and tmux's end of the stream.
    async fn accepted() -> (Control, UnboundedReceiver<Event>, DuplexStream) {
        let (mut tmux_side, ours) = tokio::io::duplex(4096);
        let (r, w) = tokio::io::split(ours);
        tmux_side.write_all(b"%begin 1 1 0\n%end 1 1 0\n").await.unwrap();
        let (ctl, ev) = Control::from_io(BufReader::new(r), w).await.unwrap();
        (ctl, ev, tmux_side)
    }

    #[tokio::test]
    async fn a_refused_attach_is_the_error() {
        let (mut tmux_side, ours) = tokio::io::duplex(4096);
        let (r, w) = tokio::io::split(ours);
        tmux_side.write_all(b"%begin 1 1 0\ncan't find session: $99\n%error 1 1 0\n%exit\n").await.unwrap();
        let e = Control::from_io(BufReader::new(r), w).await.err().unwrap();
        assert_eq!(e.to_string(), "can't find session: $99");
    }

    #[tokio::test]
    async fn block_lines_that_look_like_markers_are_output() {
        let (ctl, _ev, mut tmux_side) = accepted().await;
        let ask = tokio::spawn(async move { ctl.command(&["capture-pane".into(), "-p".into()]).await });
        tmux_side.write_all(b"%begin 2 5 1\n%end 9 9 1\n%output %1 x\n%end 2 5 1\n").await.unwrap();
        assert_eq!(ask.await.unwrap().unwrap(), ["%end 9 9 1", "%output %1 x"]);
    }

    #[tokio::test]
    async fn a_waiting_command_fails_when_the_stream_ends() {
        let (ctl, _ev, tmux_side) = accepted().await;
        let ask = tokio::spawn(async move { ctl.command(&["display-message".into()]).await });
        tokio::task::yield_now().await;
        drop(tmux_side);
        let e = tokio::time::timeout(DETACH_WAIT, ask).await.unwrap().unwrap().unwrap_err();
        assert_eq!(e.to_string(), CLOSED);
    }
}
