//! The session pump: reads `In` lines, writes `Out` lines, and ties the tmux pieces together.

use crate::keys;
use crate::proto::{self, In, Out, Pane};
use crate::screen::Screen;
use crate::sender::Sender;
use crate::tmux::control::{Control, Event};
use crate::tmux::{cmd, PaneInfo, Tmux, MAX_PASTE};
use crate::unread::Unread;
use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tokio::io::{AsyncBufRead, AsyncBufReadExt, AsyncWrite, AsyncWriteExt};
use tokio::sync::mpsc::UnboundedReceiver;
use tokio::time::{Instant, Interval, MissedTickBehavior};

/// The longest `In` line accepted, newline excluded: input lines are held to `proto::MAX_LINE` like output.
/// A longer paste comes as several `Text` chunks.
const MAX_IN_LINE: usize = proto::MAX_LINE - 1;
/// Why a paste over `MAX_PASTE` in all was not made.
const TOO_LONG: &str = "text is too long (1 MiB at most)";
/// The most bytes of a pane's title, window name or command put in the pane list.
const MAX_NAME: usize = 256;
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
    let mut p = Pump {
        tmux,
        session,
        sid,
        attached: 0,
        w,
        unread,
        opts,
        panes: Vec::new(),
        view: None,
        sender: Sender::new(""),
        pastes: HashMap::new(),
    };
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
            window: cut(&p.window, MAX_NAME).to_string(),
            title: cut(&p.title, MAX_NAME).to_string(),
            command: cut(&p.command, MAX_NAME).to_string(),
            cols: p.cols,
            rows: p.rows,
            dead: p.dead,
        })
        .collect()
}

/// `s` cut to at most `max` bytes, at a char boundary.
fn cut(s: &str, max: usize) -> &str {
    let mut end = s.len().min(max);
    while !s.is_char_boundary(end) {
        end -= 1;
    }
    &s[..end]
}

/// A `Panes` message that fits in one line: when the panes do not all fit, the ones at the end are left out.
fn panes_msg(panes: &[Pane]) -> Out {
    let mut used = proto::encode(&Out::Panes { panes: Vec::new() }).len();
    let mut keep = 0;
    for p in panes {
        // The pane and the comma before it.
        used += serde_json::to_string(p).expect("a pane always serializes").len() + 1;
        if used > proto::MAX_LINE {
            break;
        }
        keep += 1;
    }
    Out::Panes { panes: panes[..keep].to_vec() }
}

/// One line written to `w`, flushed. A message too long for one line is never written: a fixed error goes instead.
async fn put<W: AsyncWrite + Unpin>(w: &mut W, m: &Out) -> std::io::Result<()> {
    let mut line = proto::encode(m);
    if line.len() > proto::MAX_LINE {
        line = proto::encode(&Out::Error { error: "message too large".into() });
    }
    w.write_all(line.as_bytes()).await?;
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
/// (the peer asks again from `before` plus what it got). A row too long for a line on its own is shrunk like a
/// screen row, so there is always at least one.
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
    if keep > 0 && keep == lines.len() {
        let last = lines.pop().expect("there are rows");
        return Out::History {
            pane: pane.to_string(),
            before,
            lines: vec![proto::shrink_text(&last, proto::MAX_LINE - used)],
        };
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
    /// When the last capture started.
    last: Option<Instant>,
    sized: Held,
}

/// Whether the control client has a size of its own.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Held {
    /// None: tmux leaves it out when sizing the window.
    No,
    /// Set because nobody else was attached; given up once someone is.
    Fit,
    /// Set because the peer asked to take the size over.
    Forced,
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
        View { ctl, events, poll, pane: pane.to_string(), last: None, sized: Held::No }
    }

    /// Swap in a freshly attached control client, which has no size yet, and let the old one go. On failure the
    /// old one stays.
    async fn reattach(&mut self, tmux: &Tmux, session_id: &str) -> anyhow::Result<()> {
        let (ctl, events) = Control::attach(tmux, session_id).await?;
        let old = std::mem::replace(&mut self.ctl, ctl);
        self.events = events;
        self.sized = Held::No;
        old.detach().await;
        Ok(())
    }

    /// Take the size over, as a refit asks: under `window-size latest` tmux sizes the window by the client that
    /// came last, so attach afresh, then set the size. Whether the window took it.
    async fn refit(&mut self, tmux: &Tmux, session_id: &str, cols: u16, rows: u16) -> anyhow::Result<bool> {
        self.reattach(tmux, session_id).await?;
        self.ctl.fit(tmux, session_id, cols, rows, true).await?;
        self.sized = Held::Forced;
        self.ctl.shows(&self.pane, cols, rows).await
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

/// A paste still coming in chunks.
enum Paste {
    /// The chunks so far, joined.
    Text(String),
    /// A chunk went wrong: the paste is not made, and its last chunk is answered with this.
    Failed(&'static str),
}

struct Pump<'a, W> {
    tmux: &'a Tmux,
    /// The session's name, which unread state is kept under.
    session: &'a str,
    sid: String,
    /// How many clients the session had at the last listing, rapp's own included.
    attached: u32,
    w: W,
    unread: Arc<Mutex<Unread>>,
    opts: Opts,
    /// The pane list last written.
    panes: Vec<Pane>,
    view: Option<View>,
    /// The screens sent to the peer. It outlives a view, so revisions never repeat while the pump runs.
    sender: Sender,
    /// Pastes waiting for their last chunk, by pane.
    pastes: HashMap<String, Paste>,
}

impl<W: AsyncWrite + Unpin> Pump<'_, W> {
    async fn pump<R: AsyncBufRead + Unpin>(&mut self, mut lines: Lines<R>, list: &[PaneInfo]) -> anyhow::Result<()> {
        self.put(&Out::Hello { v: proto::PROTO, backend: "tmux".into() }).await?;
        self.panes = panes_of(list, &self.sid);
        self.put(&panes_msg(&self.panes)).await?;
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
                Step::Input(Got::TooLong) => {
                    // Which paste it was a chunk of, if any, cannot be told: none still coming is made.
                    self.fail_pastes();
                    self.bad().await?
                }
                Step::Input(Got::Line(l)) => match serde_json::from_slice::<In>(&l) {
                    Ok(m) => self.handle(m).await?,
                    Err(_) => self.bad_line(&l).await?,
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

    /// A line that is not a message. A `Text` chunk is answered as part of its paste when its pane can be read;
    /// anything else gets an error, and then no paste still coming is made.
    async fn bad_line(&mut self, l: &[u8]) -> anyhow::Result<bool> {
        let v: Option<serde_json::Value> = serde_json::from_slice(l).ok();
        let text = v.as_ref().filter(|v| v["t"] == "text");
        if let Some(pane) = text.and_then(|v| v["pane"].as_str()) {
            let more = text.and_then(|v| v["more"].as_bool()).unwrap_or(false);
            self.paste_failed(pane, more, "bad message").await?;
            return Ok(true);
        }
        self.fail_pastes();
        if text.is_some_and(|v| v["more"].as_bool() != Some(true)) {
            self.put(&Out::Pasted { ok: false, error: Some("bad message".into()) }).await?;
            return Ok(true);
        }
        self.bad().await
    }

    /// Every paste still coming fails: a line that may have been one of its chunks was lost.
    fn fail_pastes(&mut self) {
        for p in self.pastes.values_mut() {
            if let Paste::Text(_) = p {
                *p = Paste::Failed("bad message");
            }
        }
    }

    /// A chunk of `pane`'s paste could not be taken. The last chunk is answered; before it, the paste is marked
    /// failed (kept only for one of this session's panes, so made-up names hold nothing).
    async fn paste_failed(&mut self, pane: &str, more: bool, why: &'static str) -> anyhow::Result<()> {
        if !more {
            let why = match self.pastes.remove(pane) {
                Some(Paste::Failed(first)) => first,
                _ => why,
            };
            return self.put(&Out::Pasted { ok: false, error: Some(why.into()) }).await;
        }
        match self.pastes.get_mut(pane) {
            Some(p @ Paste::Text(_)) => *p = Paste::Failed(why),
            Some(Paste::Failed(_)) => {}
            None if self.panes.iter().any(|p| p.id == pane) => {
                self.pastes.insert(pane.to_string(), Paste::Failed(why));
            }
            None => {}
        }
        Ok(())
    }

    /// One chunk of a paste into one of this session's panes: joined to the ones before; on the last, the whole
    /// text is pasted once and answered.
    async fn paste_chunk(&mut self, pane: &str, data: String, enter: bool, more: bool) -> anyhow::Result<()> {
        let joined = match self.pastes.remove(pane) {
            None if data.len() > MAX_PASTE => Paste::Failed(TOO_LONG),
            None => Paste::Text(data),
            Some(Paste::Text(t)) if t.len() + data.len() > MAX_PASTE => Paste::Failed(TOO_LONG),
            Some(Paste::Text(mut t)) => {
                t.push_str(&data);
                Paste::Text(t)
            }
            Some(failed) => failed,
        };
        if more {
            self.pastes.insert(pane.to_string(), joined);
            return Ok(());
        }
        let m = match joined {
            // The paste's errors say what went wrong, never what the text was.
            Paste::Text(t) => match self.tmux.paste(pane, &t, enter).await {
                Ok(()) => Out::Pasted { ok: true, error: None },
                Err(e) => Out::Pasted { ok: false, error: Some(e.to_string()) },
            },
            Paste::Failed(why) => Out::Pasted { ok: false, error: Some(why.into()) },
        };
        self.put(&m).await
    }

    /// Act on one input message; `false` when the pump should stop.
    async fn handle(&mut self, m: In) -> anyhow::Result<bool> {
        if let In::Text { pane, data, enter, more } = m {
            // Every paste is answered with `Pasted`, a refused one too, so the peer is never left waiting.
            return match self.is_own(&pane).await? {
                Some(true) => self.paste_chunk(&pane, data, enter, more).await.map(|_| true),
                Some(false) => self.paste_failed(&pane, more, "no such pane").await.map(|_| true),
                None => Ok(false),
            };
        }
        let target = match &m {
            In::View { pane: Some(p), .. }
            | In::Keys { pane: p, .. }
            | In::Type { pane: p, .. }
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
                if self.view.is_some() {
                    let out = self.sender.ack(rev);
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
            In::Text { .. } => {}
            In::History { pane, before, lines } => match self.tmux.history(&pane, before, lines).await {
                Ok(v) => self.put(&history_msg(&pane, before, v)).await?,
                Err(_) => self.error("could not read the history").await?,
            },
            In::Refit { cols, rows, .. } => {
                if let Some(v) = self.view.as_mut() {
                    if !v.refit(self.tmux, &self.sid, cols, rows).await.unwrap_or(false) {
                        self.error("could not resize").await?;
                    }
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
        match self.is_own(pane).await? {
            Some(true) => Ok(Own::Yes),
            Some(false) => {
                self.error("no such pane").await?;
                Ok(Own::No)
            }
            None => Ok(Own::Gone),
        }
    }

    /// `own_pane` without saying anything on a miss; `None` when the session is gone (already said).
    async fn is_own(&mut self, pane: &str) -> anyhow::Result<Option<bool>> {
        let listed = |panes: &[Pane]| panes.iter().any(|p| p.id == pane);
        if listed(&self.panes) {
            return Ok(Some(true));
        }
        if !self.relist().await? {
            return Ok(None);
        }
        Ok(Some(listed(&self.panes)))
    }

    /// Start or keep viewing `pane`: attach if not yet, size the session for the viewer, send its screen.
    async fn view_pane(&mut self, pane: &str, cols: u16, rows: u16) -> anyhow::Result<()> {
        if self.view.is_none() {
            match Control::attach(self.tmux, &self.sid).await {
                Ok((ctl, events)) => {
                    self.view = Some(View::new(ctl, events, pane, self.opts.poll));
                    self.sender.switch(pane);
                }
                Err(_) => return self.error("could not view the session").await,
            }
        }
        let Some(v) = self.view.as_mut() else { return Ok(()) };
        if v.pane != pane {
            v.pane = pane.to_string();
            self.sender.switch(pane);
        }
        // A size the session does not take is no reason to stop: the screen goes out at the size it has.
        if let Ok(true) = v.ctl.fit(self.tmux, &self.sid, cols, rows, false).await {
            if v.sized == Held::No {
                v.sized = Held::Fit;
            }
        }
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
                self.give_up_size().await;
                self.refresh(false).await?;
                Ok(true)
            }
        }
    }

    /// Someone else has attached since rapp sized the session for its viewer: let them have their own size
    /// (under `window-size smallest` rapp's would box them in). The client re-attaches without a size; if that
    /// fails, the next poll tries again.
    async fn give_up_size(&mut self) {
        let Some(v) = self.view.as_mut() else { return };
        if v.sized == Held::Fit && self.attached > 1 {
            let _ = v.reattach(self.tmux, &self.sid).await;
        }
    }

    /// List the session's panes again and send the list if it changed; `false` (after saying so) when the session
    /// is gone. A failed listing is skipped: a lost connection is reported by the control client.
    async fn relist(&mut self) -> anyhow::Result<bool> {
        let Ok(list) = self.tmux.list().await else { return Ok(true) };
        let Some(one) = list.iter().find(|p| p.session_id == self.sid) else {
            self.error("session ended").await?;
            return Ok(false);
        };
        self.attached = one.attached;
        let panes = panes_of(&list, &self.sid);
        if panes != self.panes {
            self.panes = panes;
            self.put(&panes_msg(&self.panes)).await?;
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
            Ok(s) => self.sender.offer(s),
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

    #[test]
    fn pane_names_are_cut_at_a_char_boundary() {
        let mut p = info("$1", 0, 0, "%1");
        (p.title, p.window, p.command) = ("é".repeat(35000), "w".repeat(300), "c".repeat(257));
        let v = panes_of(&[p], "$1");
        assert_eq!((v[0].title.len(), v[0].window.len(), v[0].command.len()), (256, 256, 256));
        assert!(v[0].title.chars().all(|c| c == 'é'));
        let mut p = info("$1", 0, 0, "%1");
        p.title = format!("a{}", "é".repeat(200)); // 401 bytes: the cut falls inside an 'é'
        assert_eq!(panes_of(&[p], "$1")[0].title.len(), 255);
    }

    #[test]
    fn the_pane_list_fits_one_line_dropping_panes_at_the_end() {
        // Control characters escape to six bytes each: 100 such panes cannot fit in 64 KiB.
        let list: Vec<PaneInfo> = (0..100)
            .map(|i| {
                let mut p = info("$1", 0, i, &format!("%{i}"));
                (p.title, p.window, p.command) = ("\u{1}".repeat(256), "\u{1}".repeat(256), "\u{1}".repeat(256));
                p
            })
            .collect();
        let panes = panes_of(&list, "$1");
        let m = panes_msg(&panes);
        assert!(proto::encode(&m).len() <= proto::MAX_LINE);
        let Out::Panes { panes: sent } = m else { panic!() };
        assert!(!sent.is_empty() && sent.len() < panes.len());
        assert_eq!(sent[..], panes[..sent.len()]);
        let small = panes_of(&list[..2], "$1");
        assert_eq!(panes_msg(&small), Out::Panes { panes: small.clone() });
    }

    #[tokio::test]
    async fn no_message_is_written_over_the_line_limit() {
        let mut w: Vec<u8> = Vec::new();
        put(&mut w, &Out::Error { error: "x".repeat(70000) }).await.unwrap();
        assert_eq!(String::from_utf8(w).unwrap(), proto::encode(&Out::Error { error: "message too large".into() }));
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

    #[test]
    fn a_single_row_over_the_line_limit_is_stripped_then_cut() {
        let row = format!("\x1b[31m{}", "é".repeat(40_000));
        let m = history_msg("%1", 0, vec!["before".into(), row]);
        assert!(proto::encode(&m).len() <= proto::MAX_LINE);
        let Out::History { lines, .. } = m else { panic!() };
        assert_eq!(lines.len(), 1);
        assert!(lines[0].len() > 60_000 && lines[0].chars().all(|c| c == 'é'), "{}", lines[0].len());
    }
}
