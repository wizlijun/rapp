//! One viewer of a `rapp-term run`: speaks the session protocol over a local connection, from the emulator.

use super::fit::Conn;
use super::Shared;
use crate::id::default_name;
use crate::keys;
use crate::proto::{self, In, Out, Pane};
use crate::sender::Sender;
use crate::wire::{history_msg, panes_msg, put, Got, Lines, PasteBuf, PasteStep, MAX_IN_LINE, TOO_LONG};
use std::sync::atomic::Ordering;
use std::sync::Arc;
use std::time::Duration;
use tokio::io::{AsyncBufRead, AsyncWrite};
use tokio::time::Instant;

/// The only pane a `run` has.
const PANE: &str = "%0";
/// The shortest time between two screens offered, so a busy program does not flood a viewer.
const MIN_GAP: Duration = Duration::from_millis(50);

/// Counts one viewer, and its say in the window's size, for as long as it lives, on every way out.
struct Counted {
    shared: Arc<Shared>,
    conn: Conn,
}

impl Counted {
    fn new(shared: &Arc<Shared>) -> Counted {
        shared.viewers.fetch_add(1, Ordering::Relaxed);
        let conn = shared.fit.lock().unwrap_or_else(|e| e.into_inner()).join();
        Counted { shared: shared.clone(), conn }
    }
}

impl Drop for Counted {
    fn drop(&mut self) {
        self.shared.viewers.fetch_sub(1, Ordering::Relaxed);
        self.shared.fit.lock().unwrap_or_else(|e| e.into_inner()).leave(self.conn);
    }
}

/// Serve one viewer: read `In` lines from `r`, write `Out` lines to `w`, until `r` ends or the program does.
pub async fn serve<R, W>(shared: Arc<Shared>, r: R, w: W) -> std::io::Result<()>
where
    R: AsyncBufRead + Unpin,
    W: AsyncWrite + Unpin,
{
    let count = Counted::new(&shared);
    let mut ended = shared.ended.subscribe();
    let mut rev = shared.rev.subscribe();
    let mut v = Viewer {
        shared: &shared,
        conn: count.conn,
        w,
        panes: Vec::new(),
        viewing: false,
        sender: Sender::new(PANE),
        pastes: PasteBuf::default(),
    };
    v.put(&Out::Hello { v: proto::PROTO, backend: "pty".into() }).await?;
    v.panes = vec![v.pane()];
    v.put(&panes_msg(&v.panes)).await?;
    let mut lines = Lines::new(r, MAX_IN_LINE);
    // Set when the screen changed and is waiting for `MIN_GAP` to pass since the last offer.
    let mut dirty = false;
    let mut last: Option<Instant> = None;
    loop {
        if *ended.borrow_and_update() {
            return v.ended().await;
        }
        let due = match (dirty, last) {
            (true, Some(at)) => Some(at + MIN_GAP),
            _ => None,
        };
        tokio::select! {
            got = lines.next() => match got? {
                Got::Eof => return Ok(()),
                Got::TooLong => {
                    // Which paste it was a chunk of, if any, cannot be told: none still coming is made.
                    v.pastes.fail_all("bad message");
                    v.error("bad message").await?;
                }
                Got::Line(l) => match serde_json::from_slice::<In>(&l) {
                    Ok(m) => {
                        if v.handle(m).await? {
                            // The first screen, or a whole one again, goes out now.
                            last = Some(Instant::now());
                            dirty = false;
                        }
                    }
                    Err(_) => v.bad_line(&l).await?,
                },
            },
            changed = rev.changed() => {
                if changed.is_err() {
                    return v.ended().await;
                }
                dirty = v.viewing;
            }
            changed = ended.changed() => {
                // The sender going away is the program being gone too.
                if changed.is_err() || *ended.borrow_and_update() {
                    return v.ended().await;
                }
            }
            _ = async { tokio::time::sleep_until(due.expect("only polled when due")).await }, if due.is_some() => {
                dirty = false;
                last = Some(Instant::now());
                v.refresh().await?;
            }
        }
        // A change with no gap to wait for goes out at once.
        if dirty && last.is_none_or(|at| at.elapsed() >= MIN_GAP) {
            dirty = false;
            last = Some(Instant::now());
            v.refresh().await?;
        }
    }
}

struct Viewer<'a, W> {
    shared: &'a Shared,
    /// Who this viewer is to `Shared::fit`.
    conn: Conn,
    w: W,
    /// The pane list last written.
    panes: Vec<Pane>,
    viewing: bool,
    sender: Sender,
    pastes: PasteBuf,
}

impl<W: AsyncWrite + Unpin> Viewer<'_, W> {
    /// The pane as the emulator is now.
    fn pane(&self) -> Pane {
        let s = self.shared.emu.lock().unwrap_or_else(|e| e.into_inner()).screen();
        Pane {
            id: PANE.into(),
            window: "0".into(),
            title: self.shared.meta.name(),
            command: default_name(&self.shared.meta.command).to_string(),
            cols: s.cols,
            rows: s.rows,
            dead: false,
            win: "@0".into(),
            active: true,
        }
    }

    /// The program is gone: its last screen first, past the ack gate and the gap, as no ack will release it later.
    async fn ended(&mut self) -> std::io::Result<()> {
        self.send_screen(true).await?;
        self.error("session ended").await
    }

    async fn error(&mut self, text: &str) -> std::io::Result<()> {
        self.put(&Out::Error { error: text.to_string() }).await
    }

    async fn put(&mut self, m: &Out) -> std::io::Result<()> {
        put(&mut self.w, m).await
    }

    /// The screen as it is, offered to the sender; a changed size is announced first.
    async fn refresh(&mut self) -> std::io::Result<()> {
        self.send_screen(false).await
    }

    /// The screen as it is; `last` sends it now whatever is in flight. A changed size is announced first.
    async fn send_screen(&mut self, last: bool) -> std::io::Result<()> {
        if !self.viewing {
            return Ok(());
        }
        let screen = self.shared.emu.lock().unwrap_or_else(|e| e.into_inner()).screen();
        let pane = self.pane();
        if (pane.cols, pane.rows) != (self.panes[0].cols, self.panes[0].rows) {
            self.panes = vec![pane];
            self.put(&panes_msg(&self.panes)).await?;
        }
        let out = if last { self.sender.last(screen) } else { self.sender.offer(screen) };
        for m in out {
            self.put(&m).await?;
        }
        Ok(())
    }

    /// A line that is not a message. A `Text` chunk is answered as part of its paste when its pane can be read;
    /// anything else gets an error, and then no paste still coming is made.
    async fn bad_line(&mut self, l: &[u8]) -> std::io::Result<()> {
        let v: Option<serde_json::Value> = serde_json::from_slice(l).ok();
        let text = v.as_ref().filter(|v| v["t"] == "text");
        if let Some(pane) = text.and_then(|v| v["pane"].as_str()) {
            let more = text.and_then(|v| v["more"].as_bool()).unwrap_or(false);
            return self.paste_failed(pane, more, "bad message").await;
        }
        self.pastes.fail_all("bad message");
        if text.is_some_and(|v| v["more"].as_bool() != Some(true)) {
            return self.put(&Out::Pasted { ok: false, error: Some("bad message".into()) }).await;
        }
        self.error("bad message").await
    }

    /// A chunk of `pane`'s paste could not be taken; the last chunk is answered.
    async fn paste_failed(&mut self, pane: &str, more: bool, why: &'static str) -> std::io::Result<()> {
        match self.pastes.fail(pane, more, why, pane == PANE) {
            Some(why) => self.put(&Out::Pasted { ok: false, error: Some(why.into()) }).await,
            None => Ok(()),
        }
    }

    /// Bytes for the pty; false when nobody reads them any more, which means the program is gone. Bytes that went
    /// in are an operation, which may make this viewer's size the window's.
    async fn input(&mut self, bytes: Vec<u8>) -> std::io::Result<bool> {
        if bytes.is_empty() {
            return Ok(true);
        }
        if self.shared.input.send(bytes).is_err() {
            self.ended().await?;
            return Ok(false);
        }
        let now = std::time::Instant::now();
        self.shared.fit.lock().unwrap_or_else(|e| e.into_inner()).input(self.conn, now);
        Ok(true)
    }

    /// Act on one message. `Ok(true)` when a whole screen is to go out at once (it was sent here).
    async fn handle(&mut self, m: In) -> std::io::Result<bool> {
        if let In::Text { pane, data, enter, more } = m {
            if pane != PANE {
                self.paste_failed(&pane, more, "no such pane").await?;
                return Ok(false);
            }
            if let Some(why) = self.pastes.failure(&pane) {
                self.paste_failed(&pane, more, why).await?;
                return Ok(false);
            }
            let reply = match self.pastes.push(&pane, data, more) {
                PasteStep::Pending | PasteStep::Dropped => return Ok(false),
                PasteStep::Ready(t) => {
                    let bracketed = self.shared.emu.lock().unwrap_or_else(|e| e.into_inner()).modes().bracketed_paste;
                    let mut b = Vec::new();
                    if bracketed {
                        b.extend_from_slice(b"\x1b[200~");
                    }
                    b.extend_from_slice(t.as_bytes());
                    if bracketed {
                        b.extend_from_slice(b"\x1b[201~");
                    }
                    if enter {
                        b.push(b'\r');
                    }
                    if !self.input(b).await? {
                        return Ok(false);
                    }
                    Out::Pasted { ok: true, error: None }
                }
                PasteStep::TooLong => Out::Pasted { ok: false, error: Some(TOO_LONG.into()) },
            };
            self.put(&reply).await?;
            return Ok(false);
        }
        let target = match &m {
            In::View { pane: Some(p), .. }
            | In::Keys { pane: p, .. }
            | In::Type { pane: p, .. }
            | In::History { pane: p, .. } => Some(p),
            _ => None,
        };
        if target.is_some_and(|p| p != PANE) {
            self.error("no such pane").await?;
            return Ok(false);
        }
        match m {
            In::View { fit, cols, rows, .. } => {
                // The pane (null too) is ignored: there is one pane. The size is only a wish: with `fit` the host
                // window may be asked to take it, and the pty and every viewer follow the window. A fresh sender
                // sends the screen whole.
                let now = std::time::Instant::now();
                self.shared.fit.lock().unwrap_or_else(|e| e.into_inner()).view(self.conn, fit, cols, rows, now);
                self.sender.switch(PANE);
                self.viewing = true;
                self.refresh().await?;
                return Ok(true);
            }
            In::Ack { rev } => {
                if self.viewing {
                    for m in self.sender.ack(rev) {
                        self.put(&m).await?;
                    }
                }
            }
            In::Keys { keys: wire, .. } => {
                let modes = self.shared.emu.lock().unwrap_or_else(|e| e.into_inner()).modes();
                let mut bytes = Vec::new();
                for k in &wire {
                    match keys::to_bytes(k, modes) {
                        Some(b) => bytes.extend(b),
                        None => {
                            self.error(&format!("unknown key: {k}")).await?;
                            return Ok(false);
                        }
                    }
                }
                self.input(bytes).await?;
            }
            In::Type { text, .. } => {
                self.input(text.into_bytes()).await?;
            }
            In::Text { .. } => {}
            In::History { before, lines, .. } => {
                let rows = self.shared.emu.lock().unwrap_or_else(|e| e.into_inner()).history(before, lines);
                self.put(&history_msg(PANE, before, rows)).await?;
            }
        }
        Ok(false)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::pty::grid::Emu;
    use crate::pty::Meta;
    use crate::wire::MAX_PASTE;
    use serde_json::{json, Value};
    use std::sync::atomic::{AtomicU32, AtomicU64};
    use std::sync::Mutex;
    use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader, DuplexStream};
    use tokio::sync::mpsc::{self, UnboundedReceiver};
    use tokio::sync::watch;

    fn shared(cols: u16, rows: u16) -> (Arc<Shared>, UnboundedReceiver<Vec<u8>>) {
        let (input, rx) = mpsc::unbounded_channel();
        let sh = Shared {
            emu: Mutex::new(Emu::new(cols, rows)),
            rev: watch::channel(0).0,
            input,
            meta: Meta { key: "0123456789abcdef".into(), name: Mutex::new("claude".into()), command: "/usr/bin/claude -c".into(), pid: 7, ticket: None },
            viewers: AtomicU32::new(0),
            ended: watch::channel(false).0,
            activity: AtomicU64::new(0),
            fit: Mutex::default(),
            ps: Mutex::new(None),
        };
        (Arc::new(sh), rx)
    }

    struct Client {
        r: BufReader<DuplexStream>,
        w: DuplexStream,
    }

    fn viewer(sh: &Arc<Shared>) -> Client {
        let (cw, sr) = tokio::io::duplex(1 << 20);
        let (sw, cr) = tokio::io::duplex(1 << 20);
        tokio::spawn(serve(sh.clone(), BufReader::new(sr), sw));
        Client { r: BufReader::new(cr), w: cw }
    }

    impl Client {
        /// The next line, or `Null` at end of stream; a hang fails the test.
        async fn next(&mut self) -> Value {
            let mut s = String::new();
            let n = tokio::time::timeout(Duration::from_secs(2), self.r.read_line(&mut s))
                .await
                .expect("timed out waiting for a line")
                .unwrap();
            if n == 0 {
                return Value::Null;
            }
            serde_json::from_str(&s).unwrap()
        }

        async fn send(&mut self, v: Value) {
            self.w.write_all(format!("{v}\n").as_bytes()).await.unwrap();
        }

        /// Hello, panes and the view, up to the first screen, which is returned.
        async fn open(&mut self) -> Value {
            self.next().await;
            self.next().await;
            self.send(json!({"t":"view","pane":"%0","cols":20,"rows":5})).await;
            self.next().await
        }
    }

    async fn settle() {
        tokio::time::sleep(Duration::from_millis(100)).await;
    }

    #[tokio::test]
    async fn a_viewer_gets_hello_panes_then_a_full_screen() {
        let (sh, _input) = shared(20, 5);
        sh.emu.lock().unwrap().feed(b"hello");
        let mut c = viewer(&sh);
        assert_eq!(c.next().await["backend"], "pty");
        let p = c.next().await;
        assert_eq!(p["panes"][0]["id"], "%0");
        assert_eq!(p["panes"][0]["command"], "claude");
        c.send(json!({"t":"view","pane":null,"cols":20,"rows":5})).await;
        let s = c.next().await;
        assert_eq!((s["t"].as_str(), s["full"].as_bool()), (Some("screen"), Some(true)));
        assert_eq!(s["lines"][0][1], "hello");
    }

    #[tokio::test]
    async fn keys_follow_app_cursor_mode() {
        let (sh, mut input) = shared(20, 5);
        let mut c = viewer(&sh);
        c.open().await;
        c.send(json!({"t":"keys","pane":"%0","keys":["Up"]})).await;
        assert_eq!(input.recv().await.unwrap(), b"\x1b[A");
        sh.emu.lock().unwrap().feed(b"\x1b[?1h");
        c.send(json!({"t":"keys","pane":"%0","keys":["Up"]})).await;
        assert_eq!(input.recv().await.unwrap(), b"\x1bOA");
        c.send(json!({"t":"keys","pane":"%0","keys":["Up","NoSuchKey"]})).await;
        assert_eq!(c.next().await["error"], "unknown key: NoSuchKey");
        c.send(json!({"t":"type","pane":"%0","text":"é"})).await;
        assert_eq!(input.recv().await.unwrap(), "é".as_bytes());
    }

    #[tokio::test]
    async fn a_paste_is_bracketed_only_when_the_program_asked() {
        let (sh, mut input) = shared(20, 5);
        let mut c = viewer(&sh);
        c.open().await;
        c.send(json!({"t":"text","pane":"%0","data":"a\nb","enter":true})).await;
        assert_eq!(c.next().await["ok"], true);
        assert_eq!(input.recv().await.unwrap(), b"a\nb\r");
        sh.emu.lock().unwrap().feed(b"\x1b[?2004h");
        c.send(json!({"t":"text","pane":"%0","data":"x","enter":false})).await;
        assert_eq!(c.next().await["ok"], true);
        assert_eq!(input.recv().await.unwrap(), b"\x1b[200~x\x1b[201~");
    }

    #[tokio::test]
    async fn a_paste_over_one_mib_is_refused_and_nothing_is_written() {
        let (sh, mut input) = shared(20, 5);
        let mut c = viewer(&sh);
        c.open().await;
        // A line holds 64 KiB at most, so the paste comes in 32 KiB chunks, one more than a MiB's worth.
        let chunk = "x".repeat(32 * 1024);
        for _ in 0..MAX_PASTE / chunk.len() + 1 {
            c.send(json!({"t":"text","pane":"%0","data":chunk,"enter":false,"more":true})).await;
        }
        c.send(json!({"t":"text","pane":"%0","data":"y","enter":false,"more":false})).await;
        let r = c.next().await;
        assert_eq!(
            (r["t"].as_str(), r["ok"].as_bool(), r["error"].as_str()),
            (Some("pasted"), Some(false), Some(TOO_LONG))
        );
        assert!(input.try_recv().is_err());
    }

    #[tokio::test]
    async fn new_output_sends_a_diff_after_the_ack() {
        let (sh, _input) = shared(20, 5);
        let mut c = viewer(&sh);
        let first = c.open().await;
        sh.emu.lock().unwrap().feed(b"!");
        sh.rev.send_modify(|r| *r += 1);
        c.send(json!({"t":"ack","rev":first["rev"]})).await;
        let s = c.next().await;
        assert_eq!((s["t"].as_str(), s["full"].as_bool()), (Some("screen"), Some(false)));
        assert_eq!(s["lines"][0][1], "!");
    }

    #[tokio::test]
    async fn a_new_size_is_announced_before_its_screen() {
        let (sh, _input) = shared(20, 5);
        let mut c = viewer(&sh);
        let first = c.open().await;
        {
            sh.emu.lock().unwrap().resize(30, 6);
            sh.rev.send_modify(|r| *r += 1);
        }
        c.send(json!({"t":"ack","rev":first["rev"]})).await;
        let p = c.next().await;
        assert_eq!((p["t"].as_str(), p["panes"][0]["cols"].as_u64()), (Some("panes"), Some(30)));
        let s = c.next().await;
        assert_eq!((s["cols"].as_u64(), s["full"].as_bool()), (Some(30), Some(true)));
    }

    #[tokio::test]
    async fn refit_and_new_window_are_bad_messages_and_the_size_stays() {
        let (sh, _input) = shared(20, 5);
        let mut c = viewer(&sh);
        c.open().await;
        c.send(json!({"t":"refit","pane":"%0","cols":100,"rows":40})).await;
        assert_eq!(c.next().await["error"], "bad message");
        c.send(json!({"t":"new_window","pane":"%0"})).await;
        assert_eq!(c.next().await["error"], "bad message");
    }

    #[tokio::test]
    async fn other_requests_the_host_cannot_serve_are_answered() {
        let (sh, mut input) = shared(20, 5);
        let mut c = viewer(&sh);
        c.open().await;
        c.send(json!({"t":"keys","pane":"%9","keys":["a"]})).await;
        assert_eq!(c.next().await["error"], "no such pane");
        c.send(json!({"t":"history","pane":"%0","before":0,"lines":10})).await;
        assert_eq!(c.next().await["t"], "history");
        c.send(json!("garbage")).await;
        assert_eq!(c.next().await["error"], "bad message");
        assert!(input.try_recv().is_err());
    }

    #[tokio::test]
    async fn ended_says_so_and_closes() {
        let (sh, _input) = shared(20, 5);
        let mut c = viewer(&sh);
        c.open().await;
        sh.ended.send(true).unwrap();
        assert_eq!(c.next().await["error"], "session ended");
        assert_eq!(c.next().await, Value::Null);
        // One that comes late is told the same, right after hello.
        let mut late = viewer(&sh);
        assert_eq!(late.next().await["t"], "hello");
        assert_eq!(late.next().await["t"], "panes");
        assert_eq!(late.next().await["error"], "session ended");
        assert_eq!(late.next().await, Value::Null);
    }

    #[tokio::test]
    async fn the_last_screen_reaches_a_viewer_that_never_acks_before_the_end() {
        let (sh, _input) = shared(20, 5);
        let mut c = viewer(&sh);
        let first = c.open().await;
        assert_eq!(first["lines"][0][1], "");
        // The first screen is never acknowledged, so nothing more is offered...
        sh.emu.lock().unwrap().feed(b"working");
        sh.rev.send_modify(|r| *r += 1);
        settle().await;
        // ...and the last output comes right before the end, inside MIN_GAP.
        sh.emu.lock().unwrap().feed(b"\r\nBYE");
        sh.rev.send_modify(|r| *r += 1);
        sh.ended.send(true).unwrap();
        let s = c.next().await;
        assert_eq!((s["t"].as_str(), s["full"].as_bool()), (Some("screen"), Some(false)), "{s}");
        let lines: Vec<(u64, &str)> =
            s["lines"].as_array().unwrap().iter().map(|l| (l[0].as_u64().unwrap(), l[1].as_str().unwrap())).collect();
        assert_eq!(lines, [(0, "working"), (1, "BYE")]);
        assert_eq!(c.next().await["error"], "session ended");
        assert_eq!(c.next().await, Value::Null);
    }

    #[tokio::test]
    async fn the_last_screen_announces_a_new_size_first() {
        let (sh, _input) = shared(20, 5);
        let mut c = viewer(&sh);
        c.open().await;
        sh.emu.lock().unwrap().resize(30, 6);
        sh.rev.send_modify(|r| *r += 1);
        sh.ended.send(true).unwrap();
        let p = c.next().await;
        assert_eq!((p["t"].as_str(), p["panes"][0]["cols"].as_u64()), (Some("panes"), Some(30)), "{p}");
        let s = c.next().await;
        assert_eq!((s["cols"].as_u64(), s["full"].as_bool()), (Some(30), Some(true)));
        assert_eq!(c.next().await["error"], "session ended");
    }

    #[tokio::test]
    async fn viewers_are_counted() {
        let (sh, _input) = shared(20, 5);
        let mut a = viewer(&sh);
        let mut b = viewer(&sh);
        a.next().await;
        b.next().await;
        assert_eq!(sh.status().viewers, 2);
        drop(a);
        settle().await;
        assert_eq!(sh.status().viewers, 1);
        drop(b);
        settle().await;
        assert_eq!(sh.status().viewers, 0);
    }
}
