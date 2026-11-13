//! The session pump: reads `In` lines, writes `Out` lines, and ties the tmux pieces together.

use crate::keys;
use crate::proto::{self, In, Out, Pane};
use crate::screen::Screen;
use crate::sender::Sender;
use crate::tmux::control::{Control, Event};
use crate::tmux::{cmd, PaneInfo, Tmux};
use crate::unread::Unread;
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tokio::io::{AsyncBufRead, AsyncBufReadExt, AsyncWrite, AsyncWriteExt};
use tokio::sync::mpsc::UnboundedReceiver;
use tokio::time::{Instant, Interval, MissedTickBehavior};

/// The longest `In` line accepted, newline excluded: room for a 1 MiB paste even when JSON escaping grows it.
/// Output lines stay within `proto::MAX_LINE`.
const MAX_IN_LINE: usize = 8 * 1024 * 1024;
/// The exit reason the control client gives when its stream just ended rather than tmux saying `%exit`.
const CLOSED: &str = "connection closed";

pub struct Opts {
    /// How often a viewed session is listed and its pane recaptured whether or not it changed.
    pub poll: Duration,
    /// The shortest time between two captures.
    pub min_gap: Duration,
}

impl Default for Opts {
    fn default() -> Opts {
        Opts { poll: Duration::from_secs(2), min_gap: Duration::from_millis(50) }
    }
}

/// Serve the tmux session named `session`: read `In` lines from `r`, write `Out` lines to `w`, until `r` ends or
/// the session does. A missing session is reported on `w`, not as an error.
pub async fn run<R, W>(
    tmux: &Tmux,
    session: &str,
    r: R,
    w: W,
    unread: Arc<Mutex<Unread>>,
    opts: Opts,
) -> anyhow::Result<()>
where
    R: AsyncBufRead + Unpin,
    W: AsyncWrite + Unpin,
{
    let mut w = w;
    let list = tmux.list().await?;
    let Some(sid) = list.iter().find(|p| p.session == session).map(|p| p.session_id.clone()) else {
        put(&mut w, &Out::Error { error: "no such session".into() }).await?;
        return Ok(());
    };
    let mut p = Pump { tmux, session, sid, w, unread, opts, panes: Vec::new(), view: None };
    let res = p.pump(Lines::new(r, MAX_IN_LINE), &list).await;
    if let Some(v) = p.view.take() {
        v.ctl.detach().await;
    }
    res
}

/// The wire's pane list for one session, in window order, then pane order.
pub fn panes_of(list: &[PaneInfo], session_id: &str) -> Vec<Pane> {
    let mut v: Vec<&PaneInfo> = list.iter().filter(|p| p.session_id == session_id).collect();
    v.sort_by_key(|p| (p.window_index, p.pane_index));
    v.into_iter()
        .map(|p| Pane {
            id: p.pane.clone(),
            window: p.window.clone(),
            title: p.title.clone(),
            command: p.command.clone(),
            cols: p.cols,
            rows: p.rows,
            dead: p.dead,
        })
        .collect()
}

/// One line written to `w`, flushed.
async fn put<W: AsyncWrite + Unpin>(w: &mut W, m: &Out) -> std::io::Result<()> {
    w.write_all(proto::encode(m).as_bytes()).await?;
    w.flush().await
}

fn unix_now() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)
}

/// One screen of `pane`, read over the control channel (no process per frame).
async fn capture(ctl: &Control, pane: &str) -> anyhow::Result<Screen> {
    let rows = ctl.command(&cmd::capture(pane)).await?;
    let meta = ctl.command(&cmd::meta(pane)).await?;
    // The same text `Tmux::capture` reads from stdout, where every row ends in a newline.
    let mut text = rows.join("\n");
    text.push('\n');
    Screen::from_capture(&text, meta.first().map(String::as_str).unwrap_or(""))
}

/// A `History` message that fits in one line: when the rows do not all fit, the ones nearest the screen are kept
/// (the peer asks again from `before` plus what it got).
fn history_msg(pane: &str, before: u32, mut lines: Vec<String>) -> Out {
    let mut used = proto::encode(&Out::History { pane: pane.to_string(), before, lines: Vec::new() }).len();
    let mut keep = lines.len();
    while keep > 0 {
        let n = serde_json::to_string(&lines[keep - 1]).expect("a string always serializes").len() + 1;
        if used + n > proto::MAX_LINE {
            break;
        }
        used += n;
        keep -= 1;
    }
    lines.drain(..keep);
    Out::History { pane: pane.to_string(), before, lines }
}

/// What reading one input line gave.
enum Got {
    /// A line, newline removed.
    Line(Vec<u8>),
    /// A line longer than the limit; it was read and dropped.
    TooLong,
    Eof,
}

/// Lines of `r` up to `limit` bytes each. Cancel-safe: a read cancelled half way keeps what it had, and the next
/// call goes on from there. A line over the limit is dropped as it streams past, never held whole.
struct Lines<R> {
    r: R,
    buf: Vec<u8>,
    limit: usize,
    /// The current line went over the limit.
    over: bool,
}

impl<R: AsyncBufRead + Unpin> Lines<R> {
    fn new(r: R, limit: usize) -> Lines<R> {
        Lines { r, buf: Vec::new(), limit, over: false }
    }

    async fn next(&mut self) -> std::io::Result<Got> {
        loop {
            // The only await; nothing is consumed or kept until it has returned.
            let chunk = self.r.fill_buf().await?;
            if chunk.is_empty() {
                if std::mem::take(&mut self.over) {
                    return Ok(Got::TooLong);
                }
                if self.buf.is_empty() {
                    return Ok(Got::Eof);
                }
                return Ok(Got::Line(std::mem::take(&mut self.buf)));
            }
            let (part, used, ends) = match chunk.iter().position(|&b| b == b'\n') {
                Some(i) => (&chunk[..i], i + 1, true),
                None => (chunk, chunk.len(), false),
            };
            if !self.over {
                if self.buf.len() + part.len() > self.limit {
                    self.over = true;
                    self.buf = Vec::new();
                } else {
                    self.buf.extend_from_slice(part);
                }
            }
            self.r.consume(used);
            if ends {
                if std::mem::take(&mut self.over) {
                    return Ok(Got::TooLong);
                }
                return Ok(Got::Line(std::mem::take(&mut self.buf)));
            }
        }
    }
}

/// The control client and what goes with it, while someone views the session.
struct View {
    ctl: Control,
    events: UnboundedReceiver<Event>,
    poll: Interval,
    pane: String,
    sender: Sender,
    /// When the last capture started.
    last: Option<Instant>,
}

/// Why a viewed session woke the pump.
enum Wake {
    Dirty(Vec<String>),
    Event(Option<Event>),
    Poll,
}

impl View {
    fn new(ctl: Control, events: UnboundedReceiver<Event>, pane: &str, poll: Duration) -> View {
        let mut poll = tokio::time::interval_at(Instant::now() + poll, poll);
        poll.set_missed_tick_behavior(MissedTickBehavior::Delay);
        View { ctl, events, poll, pane: pane.to_string(), sender: Sender::new(pane), last: None }
    }

    /// The next thing that needs the pump. Every branch is cancel-safe and none sends a command: a command future
    /// dropped half way would leave its reply to the next command. `dirty` never returns once the stream has
    /// closed, so the events are always watched too.
    async fn wake(&mut self) -> Wake {
        tokio::select! {
            d = self.ctl.dirty() => Wake::Dirty(d),
            e = self.events.recv() => Wake::Event(e),
            _ = self.poll.tick() => Wake::Poll,
        }
    }
}

/// Whether a pane named by the peer belongs to the pumped session.
enum Own {
    Yes,
    /// Not one of its panes (already said).
    No,
    /// The session itself is gone (already said).
    Gone,
}

enum Step {
    Input(Got),
    Wake(Wake),
}

struct Pump<'a, W> {
    tmux: &'a Tmux,
    /// The session's name, which unread state is kept under.
    session: &'a str,
    sid: String,
    w: W,
    unread: Arc<Mutex<Unread>>,
    opts: Opts,
    /// The pane list last written.
    panes: Vec<Pane>,
    view: Option<View>,
}

impl<W: AsyncWrite + Unpin> Pump<'_, W> {
    async fn pump<R: AsyncBufRead + Unpin>(&mut self, mut lines: Lines<R>, list: &[PaneInfo]) -> anyhow::Result<()> {
        self.put(&Out::Hello { v: proto::PROTO, backend: "tmux".into() }).await?;
        self.panes = panes_of(list, &self.sid);
        self.put(&Out::Panes { panes: self.panes.clone() }).await?;
        loop {
            let view = &mut self.view;
            // Both branches are cancel-safe; commands run only in the handling below.
            let step = tokio::select! {
                got = lines.next() => Step::Input(got?),
                wake = async {
                    match view {
                        Some(v) => v.wake().await,
                        None => std::future::pending().await,
                    }
                } => Step::Wake(wake),
            };
            let go_on = match step {
                Step::Input(Got::Eof) => return Ok(()),
                Step::Input(Got::TooLong) => self.bad().await?,
                Step::Input(Got::Line(l)) => match serde_json::from_slice::<In>(&l) {
                    Ok(m) => self.handle(m).await?,
                    Err(_) => self.bad().await?,
                },
                Step::Wake(w) => self.wake(w).await?,
            };
            if !go_on {
                return Ok(());
            }
        }
    }

    async fn bad(&mut self) -> anyhow::Result<bool> {
        self.error("bad message").await?;
        Ok(true)
    }

    /// Act on one input message; `false` when the pump should stop.
    async fn handle(&mut self, m: In) -> anyhow::Result<bool> {
        let target = match &m {
            In::View { pane: Some(p), .. }
            | In::Keys { pane: p, .. }
            | In::Type { pane: p, .. }
            | In::Text { pane: p, .. }
            | In::History { pane: p, .. } => Some(p.clone()),
            _ => None,
        };
        if let Some(p) = target {
            match self.own_pane(&p).await? {
                Own::Yes => {}
                Own::No => return Ok(true),
                Own::Gone => return Ok(false),
            }
        }
        match m {
            In::View { pane: Some(pane), cols, rows } => self.view_pane(&pane, cols, rows).await?,
            In::View { pane: None, .. } => {
                if let Some(v) = self.view.take() {
                    v.ctl.detach().await;
                }
            }
            In::Ack { rev } => {
                if let Some(v) = self.view.as_mut() {
                    let out = v.sender.ack(rev);
                    self.put_all(out).await?;
                }
            }
            In::Keys { pane, keys: wire } => {
                let names: Option<Vec<String>> = wire.iter().map(|k| keys::tmux_name(k)).collect();
                match names {
                    None => self.error("unknown key").await?,
                    Some(n) if n.is_empty() => {}
                    Some(n) => self.input(cmd::send_named(&pane, &n)).await?,
                }
            }
            In::Type { pane, text } => {
                if !text.is_empty() {
                    self.input(cmd::send_hex(&pane, &keys::utf8_hex(&text))).await?;
                }
            }
            In::Text { pane, data, enter } => {
                // The paste's errors say what went wrong, never what the text was.
                let m = match self.tmux.paste(&pane, &data, enter).await {
                    Ok(()) => Out::Pasted { ok: true, error: None },
                    Err(e) => Out::Pasted { ok: false, error: Some(e.to_string()) },
                };
                self.put(&m).await?;
            }
            In::History { pane, before, lines } => match self.tmux.history(&pane, before, lines).await {
                Ok(v) => self.put(&history_msg(&pane, before, v)).await?,
                Err(_) => self.error("could not read the history").await?,
            },
            In::Refit { cols, rows, .. } => {
                if let Some(v) = &self.view {
                    let _ = v.ctl.fit(self.tmux, &self.sid, cols, rows, true).await;
                    self.refresh(true).await?;
                }
            }
        }
        Ok(true)
    }

    /// Is `pane` an id of one of this session's panes? Only those are passed to tmux: anything else (another
    /// session's pane, or a name tmux would resolve as a target) is refused with an error. On a miss the list is
    /// read again once, since the pane may have been made after the last listing.
    async fn own_pane(&mut self, pane: &str) -> anyhow::Result<Own> {
        let listed = |panes: &[Pane]| panes.iter().any(|p| p.id == pane);
        if listed(&self.panes) {
            return Ok(Own::Yes);
        }
        if !self.relist().await? {
            return Ok(Own::Gone);
        }
        if listed(&self.panes) {
            return Ok(Own::Yes);
        }
        self.error("no such pane").await?;
        Ok(Own::No)
    }

    /// Start or keep viewing `pane`: attach if not yet, size the session for the viewer, send its screen.
    async fn view_pane(&mut self, pane: &str, cols: u16, rows: u16) -> anyhow::Result<()> {
        if self.view.is_none() {
            match Control::attach(self.tmux, &self.sid).await {
                Ok((ctl, events)) => self.view = Some(View::new(ctl, events, pane, self.opts.poll)),
                Err(_) => return self.error("could not view the session").await,
            }
        }
        let Some(v) = self.view.as_mut() else { return Ok(()) };
        if v.pane != pane {
            v.pane = pane.to_string();
            v.sender = Sender::new(pane);
        }
        // A size the session does not take is no reason to stop: the screen goes out at the size it has.
        let _ = v.ctl.fit(self.tmux, &self.sid, cols, rows, false).await;
        self.refresh(true).await
    }

    /// Send keys or typed text: over the control channel while viewing, else as one command.
    async fn input(&mut self, args: Vec<String>) -> anyhow::Result<()> {
        let sent = match &self.view {
            Some(v) => v.ctl.command(&args).await.map(|_| ()),
            None => self.tmux.send(args).await,
        };
        // tmux's own message may quote the input, so it is never passed on.
        if sent.is_err() {
            self.error("could not send input").await?;
        }
        Ok(())
    }

    /// Handle a wake-up of the viewed session; `false` when the session is over.
    async fn wake(&mut self, w: Wake) -> anyhow::Result<bool> {
        match w {
            Wake::Dirty(d) => {
                if self.view.as_ref().is_some_and(|v| d.contains(&v.pane)) {
                    self.refresh(false).await?;
                }
                Ok(true)
            }
            Wake::Event(Some(Event::Layout)) => self.relist().await,
            Wake::Event(Some(Event::Exit(why))) => {
                self.error(if why == CLOSED { "connection lost" } else { "session ended" }).await?;
                Ok(false)
            }
            Wake::Event(None) => {
                self.error("connection lost").await?;
                Ok(false)
            }
            Wake::Poll => {
                if !self.relist().await? {
                    return Ok(false);
                }
                self.refresh(false).await?;
                Ok(true)
            }
        }
    }

    /// List the session's panes again and send the list if it changed; `false` (after saying so) when the session
    /// is gone. A failed listing is skipped: a lost connection is reported by the control client.
    async fn relist(&mut self) -> anyhow::Result<bool> {
        let Ok(list) = self.tmux.list().await else { return Ok(true) };
        if !list.iter().any(|p| p.session_id == self.sid) {
            self.error("session ended").await?;
            return Ok(false);
        }
        let panes = panes_of(&list, &self.sid);
        if panes != self.panes {
            self.panes = panes;
            self.put(&Out::Panes { panes: self.panes.clone() }).await?;
        }
        Ok(true)
    }

    /// Capture the viewed pane, no sooner than `min_gap` after the last capture, and offer it to the sender.
    /// `report`: the capture answers the peer, so a failure is said; otherwise the next capture tries again.
    async fn refresh(&mut self, report: bool) -> anyhow::Result<()> {
        let Some(v) = self.view.as_mut() else { return Ok(()) };
        if let Some(at) = v.last {
            tokio::time::sleep_until(at + self.opts.min_gap).await;
        }
        v.last = Some(Instant::now());
        let out = match capture(&v.ctl, &v.pane).await {
            Ok(s) => v.sender.offer(s),
            Err(_) if report => vec![Out::Error { error: "could not capture the screen".into() }],
            Err(_) => Vec::new(),
        };
        self.put_all(out).await
    }

    async fn error(&mut self, text: &str) -> anyhow::Result<()> {
        self.put(&Out::Error { error: text.to_string() }).await
    }

    async fn put_all(&mut self, out: Vec<Out>) -> anyhow::Result<()> {
        for m in &out {
            self.put(m).await?;
        }
        Ok(())
    }

    /// Write one message; a screen written means the session has been seen.
    async fn put(&mut self, m: &Out) -> anyhow::Result<()> {
        put(&mut self.w, m).await?;
        if matches!(m, Out::Screen { .. }) {
            self.unread.lock().unwrap_or_else(|e| e.into_inner()).seen(self.session, unix_now());
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::AsyncWriteExt;

    fn info(sid: &str, window_index: u32, pane_index: u32, pane: &str) -> PaneInfo {
        PaneInfo {
            session_id: sid.into(),
            session: "s".into(),
            window_id: format!("@{window_index}"),
            window: format!("w{window_index}"),
            pane: pane.into(),
            command: "cat".into(),
            title: "t".into(),
            window_index,
            pane_index,
            attached: 0,
            activity: 1,
            cols: 80,
            rows: 24,
            dead: false,
        }
    }

    #[test]
    fn panes_of_keeps_one_session_in_window_then_pane_order() {
        let list = [info("$1", 1, 0, "%3"), info("$2", 0, 0, "%9"), info("$1", 0, 1, "%2"), info("$1", 0, 0, "%1")];
        let v = panes_of(&list, "$1");
        assert_eq!(v.iter().map(|p| p.id.as_str()).collect::<Vec<_>>(), ["%1", "%2", "%3"]);
        assert_eq!(
            v[0],
            proto::Pane {
                id: "%1".into(),
                window: "w0".into(),
                title: "t".into(),
                command: "cat".into(),
                cols: 80,
                rows: 24,
                dead: false
            }
        );
        assert!(panes_of(&list, "$7").is_empty());
    }

    fn line(got: Got) -> Vec<u8> {
        match got {
            Got::Line(l) => l,
            Got::TooLong => panic!("too long"),
            Got::Eof => panic!("eof"),
        }
    }

    #[tokio::test]
    async fn a_line_over_the_limit_is_dropped_and_reading_goes_on() {
        let (mut w, r) = tokio::io::duplex(8);
        let mut lines = Lines::new(tokio::io::BufReader::with_capacity(4, r), 16);
        let feed = tokio::spawn(async move {
            w.write_all(b"0123456789abcdef\n0123456789abcdefg\nok\nlast").await.unwrap();
        });
        assert_eq!(line(lines.next().await.unwrap()), b"0123456789abcdef"); // exactly the limit is fine
        assert!(matches!(lines.next().await.unwrap(), Got::TooLong));
        assert_eq!(line(lines.next().await.unwrap()), b"ok");
        feed.await.unwrap();
        assert_eq!(line(lines.next().await.unwrap()), b"last"); // a last line without a newline still counts
        assert!(matches!(lines.next().await.unwrap(), Got::Eof));
    }

    #[tokio::test]
    async fn a_cancelled_read_keeps_what_it_had_read() {
        let (mut w, r) = tokio::io::duplex(64);
        let mut lines = Lines::new(tokio::io::BufReader::new(r), 1024);
        w.write_all(b"{\"t\":\"ack\",").await.unwrap();
        assert!(tokio::time::timeout(Duration::from_millis(20), lines.next()).await.is_err());
        w.write_all(b"\"rev\":3}\n").await.unwrap();
        assert_eq!(line(lines.next().await.unwrap()), b"{\"t\":\"ack\",\"rev\":3}");
        drop(w);
        assert!(matches!(lines.next().await.unwrap(), Got::Eof));
    }

    #[test]
    fn history_is_cut_to_the_line_limit_keeping_the_rows_nearest_the_screen() {
        let rows: Vec<String> = (0..1000).map(|i| format!("{i:0>200}")).collect();
        let m = history_msg("%1", 5, rows.clone());
        assert!(proto::encode(&m).len() <= proto::MAX_LINE);
        let Out::History { pane, before, lines } = m else { panic!() };
        assert_eq!((pane.as_str(), before), ("%1", 5));
        assert!(!lines.is_empty() && lines.len() < rows.len());
        assert_eq!(lines[..], rows[rows.len() - lines.len()..]);
        let small = history_msg("%1", 0, vec!["a".into(), "b".into()]);
        assert!(matches!(small, Out::History { lines, .. } if lines == ["a", "b"]));
    }
}
