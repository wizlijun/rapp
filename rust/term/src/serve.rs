//! `rapp-term serve`: the resident worker of one device. Each connection carries one request line, then a token
//! line, then the reply: a session list, a watch (a list now and again on every change), a new terminal window, or
//! a whole view (the session protocol of `pty::view`).
//!
//! The sessions are the `pty` ones of `rapp-term run` on this machine, which are reached over unix sockets.
//!
//! Nothing a session shows or is sent, and no new session's command, goes to the events or to stderr.

use crate::config::{self, TermConfig};
use crate::id::TermId;
use crate::list::TermRow;
use crate::proto::{self, Out, MAX_LINE};
use crate::pty::launch;
use crate::pty::local::{self, Status};
use crate::unread::Unread;
use crate::wire::{Got, Lines, MAX_IN_LINE};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::future::Future;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tokio::io::{AsyncBufRead, AsyncBufReadExt, AsyncWrite, AsyncWriteExt, BufReader};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::mpsc::UnboundedSender;
use tokio::sync::Notify;
use tokio::task::JoinSet;
use tokio::time::MissedTickBehavior;

/// How long a connection has to send its request line and its token line, together.
const HEAD_WAIT: Duration = Duration::from_secs(30);
/// The backend of `rapp-term run` sessions.
const PTY: &str = "pty";

pub const BAD_TOKEN: &str = "bad token";
pub const BAD_REQUEST: &str = "bad request";
const BAD_ID: &str = "invalid term id";
const NO_TEXT_TERMINAL: &str = "no such text terminal";
const UNKNOWN_APP: &str = "unknown terminal app";
const NOT_STARTED: &str = "the terminal window did not start in 10 s";

pub struct ServeOpts {
    /// `term.json`, read afresh for every request.
    pub config: PathBuf,
    /// How often a watch scans for sessions and reads `term.json` again.
    pub poll: Duration,
    /// The directory `rapp-term run` keeps its sockets and token in (`pty/<pid>.sock`, `pty.token`).
    pub pty_dir: PathBuf,
    /// Run instead of `open -a`, for tests: `<program> <app> <file>`.
    pub launch_with: Option<PathBuf>,
}

impl ServeOpts {
    pub fn new(config: PathBuf) -> ServeOpts {
        let pty_dir = config.parent().unwrap_or(&config).join("term");
        ServeOpts { config, poll: Duration::from_secs(2), pty_dir, launch_with: None }
    }
}

#[derive(Deserialize, Debug)]
#[serde(tag = "op", rename_all = "snake_case")]
enum Req {
    List,
    Watch,
    View { term: String, sid: Option<u64> },
    Open { cwd: Option<String>, name: Option<String>, command: Option<String>, app: String },
}

/// The session list: this machine's sessions, and what it offers.
#[derive(Serialize, Clone, Debug, PartialEq)]
pub struct TermList {
    pub terms: Vec<TermRow>,
    pub hosts: Vec<HostRow>,
}

/// One host of a `TermList`: this machine (`host` null).
#[derive(Serialize, Clone, Debug, PartialEq)]
pub struct HostRow {
    pub host: Option<String>,
    /// The terminal programs this host offers to start a session with.
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub launchers: Vec<String>,
}

/// What every connection shares.
pub struct Worker {
    opts: ServeOpts,
    token: String,
    /// The unread state of this machine's sessions.
    unread: Arc<Mutex<Unread>>,
    events: UnboundedSender<Value>,
    /// The terminal programs this machine can open a window with, looked up once.
    launchers: Vec<String>,
    /// One `open` at a time.
    opening: tokio::sync::Mutex<()>,
}

/// Accept connections on `listener` until `stop` completes; then end every connection (a view's control client
/// goes with it) and return.
pub async fn serve(
    listener: TcpListener,
    token: String,
    opts: ServeOpts,
    events: UnboundedSender<Value>,
    stop: impl Future<Output = ()>,
) {
    let w = Arc::new(Worker::new(token, opts, events));
    let mut conns = JoinSet::new();
    tokio::pin!(stop);
    loop {
        tokio::select! {
            _ = &mut stop => break,
            a = listener.accept() => match a {
                Ok((s, _)) => {
                    let w = w.clone();
                    conns.spawn(async move { w.conn(s).await });
                }
                // Out of descriptors and the like: wait a little rather than spin.
                Err(_) => tokio::time::sleep(Duration::from_millis(100)).await,
            },
            Some(_) = conns.join_next(), if !conns.is_empty() => {}
        }
    }
    conns.shutdown().await;
}

impl Worker {
    pub fn new(token: String, opts: ServeOpts, events: UnboundedSender<Value>) -> Worker {
        Worker {
            opts,
            token,
            unread: Arc::new(Mutex::new(Unread::new(unix_now()))),
            events,
            launchers: launch::launchers(),
            opening: Default::default(),
        }
    }

    /// The live `run` sessions of this machine; none when the token cannot be had.
    async fn pty_statuses(&self) -> Vec<Status> {
        scan_pty(&self.opts.pty_dir).await
    }

    async fn conn(&self, s: TcpStream) {
        let _ = s.set_nodelay(true);
        let (r, mut w) = s.into_split();
        let mut r = BufReader::new(r);
        let head = tokio::time::timeout(HEAD_WAIT, async {
            let req = read_line(&mut r).await?;
            let token = read_line(&mut r).await?;
            Some((req, token))
        })
        .await;
        // Silence, a closed connection or a line that is not whole: nothing to answer.
        let Ok(Some((req, token))) = head else { return };
        if !token.as_deref().is_some_and(|t| same(t, self.token.as_bytes())) {
            let _ = reply(&mut w, &json!({ "error": BAD_TOKEN })).await;
            return;
        }
        let Some(req) = req.and_then(|l| serde_json::from_slice::<Req>(&l).ok()) else {
            let _ = reply(&mut w, &json!({ "error": BAD_REQUEST })).await;
            return;
        };
        let cfg = self.config();
        let _ = match req {
            Req::View { term, sid } => match cfg {
                Ok(_) => self.view(&term, sid, r, &mut w).await,
                Err(e) => put(&mut w, &Out::Error { error: e.into() }).await,
            },
            Req::Watch => match cfg {
                Ok(_) => self.watch(r, &mut w).await,
                Err(e) => reply(&mut w, &json!({ "error": e })).await,
            },
            Req::List => {
                let v = match cfg {
                    Ok(_) => serde_json::to_value(fit(self.list().await)).expect("a list always serializes"),
                    Err(e) => json!({ "error": e }),
                };
                reply(&mut w, &v).await
            }
            Req::Open { cwd, name, command, app } => {
                let v = match self.open(cwd.as_deref(), name.as_deref(), command.as_deref(), &app).await {
                    Ok(id) => json!({ "id": id }),
                    Err(e) => json!({ "error": e }),
                };
                reply(&mut w, &v).await
            }
        };
        let _ = w.shutdown().await;
    }

    /// `term.json` as it is now, or the fixed words for why it cannot be used.
    fn config(&self) -> Result<TermConfig, &'static str> {
        config::load(&self.opts.config).map_err(|_| config::INVALID).and_then(|c| match c.allow {
            true => Ok(c),
            false => Err(config::OFF),
        })
    }

    /// This machine's sessions and what it offers.
    pub async fn list(&self) -> TermList {
        let statuses = self.pty_statuses().await;
        TermList { terms: pty_rows(&self.unread, &statuses, unix_now()), hosts: host_list(&self.launchers) }
    }

    /// Send the session list now and again whenever it changes, until the other end closes; if terminal sessions
    /// are turned off meanwhile, one error line ends it. `term.json` is read again every `poll`; one that cannot
    /// be read is passed over.
    async fn watch<R, W>(&self, mut r: R, w: &mut W) -> std::io::Result<()>
    where
        R: AsyncBufRead + Unpin,
        W: AsyncWrite + Unpin,
    {
        let changed = Arc::new(Notify::new());
        // The watch's own task: it goes when the watch does.
        let mut tasks = JoinSet::new();
        let pty = Arc::new(Mutex::new(None));
        tasks.spawn(ask_pty(
            self.opts.pty_dir.clone(),
            self.unread.clone(),
            self.opts.poll,
            pty.clone(),
            changed.clone(),
        ));
        let hosts = host_list(&self.launchers);
        let mut sent: Option<TermList> = None;
        let mut tick = tokio::time::interval(self.opts.poll);
        tick.set_missed_tick_behavior(MissedTickBehavior::Delay);
        // The first tick is now: `term.json` was just read.
        tick.tick().await;
        loop {
            tokio::select! {
                _ = tick.tick() => {
                    // Halfway through being rewritten, perhaps: that is passed over.
                    if let Err(config::OFF) = self.config() {
                        return reply(w, &json!({ "error": config::OFF })).await;
                    }
                }
                _ = changed.notified() => {}
                _ = closed(&mut r) => return Ok(()),
            }
            let Some(terms) = lock(&pty).clone() else {
                continue;
            };
            let list = fit(TermList { terms, hosts: hosts.clone() });
            if sent.as_ref() != Some(&list) {
                reply(w, &serde_json::to_value(&list).expect("a list always serializes")).await?;
                sent = Some(list);
            }
        }
    }

    /// Open a window of `app` that runs `rapp-term run`, and wait for that `run` to show itself: the id of its
    /// session. One at a time, so each wait has only its own ticket to look for.
    async fn open(
        &self,
        cwd: Option<&str>,
        name: Option<&str>,
        command: Option<&str>,
        app: &str,
    ) -> Result<String, String> {
        let known = ["Terminal", "iTerm"].contains(&app);
        if !known || (self.opts.launch_with.is_none() && !self.launchers.iter().any(|l| l == app)) {
            return Err(UNKNOWN_APP.into());
        }
        let cwd = cwd.filter(|c| !c.is_empty()).map(expand_home);
        if let Some(c) = &cwd {
            if !c.is_dir() {
                return Err(format!("no such directory: {}", c.display()));
            }
        }
        const FAILED: &str = "could not open the terminal window";
        let _one = self.opening.lock().await;
        let dir = &self.opts.pty_dir;
        local::ensure_dirs(dir).map_err(|_| FAILED)?;
        sweep_launch(&dir.join("launch"));
        let token = local::token(dir).map_err(|_| FAILED)?;
        let bin = std::env::current_exe().map_err(|_| FAILED)?;
        let ticket = ticket();
        let body = launch::command_file(
            &bin,
            dir,
            &ticket,
            name.filter(|n| !n.is_empty()),
            cwd.as_deref(),
            command.filter(|c| !c.trim().is_empty()),
        );
        let file = dir.join("launch").join(format!("{ticket}.command"));
        write_private(&file, &body).map_err(|_| FAILED)?;
        let res = self.wait_for(&file, app, &ticket, dir, &token).await;
        // A window that is slow to start may still read it after the wait: that one is left for the sweep.
        if !matches!(&res, Err(e) if e == NOT_STARTED) {
            let _ = std::fs::remove_file(&file);
        }
        res
    }

    async fn wait_for(
        &self,
        file: &std::path::Path,
        app: &str,
        ticket: &str,
        dir: &std::path::Path,
        token: &str,
    ) -> Result<String, String> {
        let (app, file, with) = (app.to_string(), file.to_path_buf(), self.opts.launch_with.clone());
        let started = tokio::task::spawn_blocking(move || launch::open(&app, &file, with.as_deref())).await;
        if !matches!(started, Ok(Ok(()))) {
            return Err("could not open the terminal window".into());
        }
        let end = tokio::time::Instant::now() + OPEN_WAIT;
        loop {
            let found = local::scan(dir, token).await.into_iter().find(|s| s.ticket.as_deref() == Some(ticket));
            if let Some(s) = found {
                return Ok(TermId { backend: PTY.into(), host: None, name: s.name }.to_string());
            }
            if tokio::time::Instant::now() >= end {
                return Err(NOT_STARTED.into());
            }
            tokio::time::sleep(Duration::from_millis(100)).await;
        }
    }

    /// Pump the session `term` over the connection; one `Out::Error` when it cannot start. A view with a `sid`
    /// reports how many inputs it carried when it ends.
    async fn view<R, W>(&self, term: &str, sid: Option<u64>, r: R, w: &mut W) -> std::io::Result<()>
    where
        R: AsyncBufRead + Unpin,
        W: AsyncWrite + Unpin,
    {
        let id = match TermId::parse(term) {
            Ok(id) if id.backend == PTY && id.host.is_none() => id,
            _ => return put(w, &Out::Error { error: BAD_ID.into() }).await,
        };
        self.view_pty(id, sid, r, w).await
    }
}

impl Worker {
    /// Pump the `run` session `id` over the connection: lines go both ways as they are, the pump of `run` being
    /// the one that speaks the session protocol. A view with a `sid` reports its inputs when it ends.
    async fn view_pty<R, W>(&self, id: TermId, sid: Option<u64>, r: R, w: &mut W) -> std::io::Result<()>
    where
        R: AsyncBufRead + Unpin,
        W: AsyncWrite + Unpin,
    {
        let statuses = self.pty_statuses().await;
        let Some(st) = statuses.iter().find(|s| s.name == id.name) else {
            return put(w, &Out::Error { error: NO_TEXT_TERMINAL.into() }).await;
        };
        let (path, key) = match (local::socket_path(&self.opts.pty_dir, st.pid), format!("{PTY}:{}", st.pid)) {
            (Ok(p), k) => (p, k),
            _ => return put(w, &Out::Error { error: NO_TEXT_TERMINAL.into() }).await,
        };
        let token = local::token(&self.opts.pty_dir);
        let stream = match token {
            Ok(t) => local::connect(&path, "view", &t).await,
            Err(_) => Err(std::io::ErrorKind::NotFound.into()),
        };
        let Ok(stream) = stream else {
            return put(w, &Out::Error { error: NO_TEXT_TERMINAL.into() }).await;
        };
        let inputs = Arc::new(AtomicU64::new(0));
        let _ended = sid.map(|sid| Ended { events: &self.events, sid, term: id.to_string(), inputs: inputs.clone() });
        let (run_r, mut run_w) = stream.into_split();
        let unread = self.unread.clone();
        // Either direction ending ends the view.
        tokio::select! {
            res = to_run(r, &mut run_w, &inputs) => res,
            res = from_run(BufReader::new(run_r), w, &unread, &key) => res,
        }
    }
}

/// The lines the viewer sends, on to `run`; a line too long for a message goes on as one `run` calls a bad message,
/// which it answers as `session` does. The count of `inputs` is by the rule of `session`: a `Keys`, a `Type`, the
/// last chunk of a paste.
async fn to_run<R, S>(r: R, run: &mut S, inputs: &AtomicU64) -> std::io::Result<()>
where
    R: AsyncBufRead + Unpin,
    S: AsyncWrite + Unpin,
{
    let mut lines = Lines::new(r, MAX_IN_LINE);
    loop {
        match lines.next().await? {
            Got::Eof => return Ok(()),
            Got::TooLong => run.write_all(b"{}\n").await?,
            Got::Line(mut l) => {
                if let Ok(m) = serde_json::from_slice::<proto::In>(&l) {
                    if matches!(
                        m,
                        proto::In::Keys { .. } | proto::In::Type { .. } | proto::In::Text { more: false, .. }
                    ) {
                        inputs.fetch_add(1, Ordering::Relaxed);
                    }
                }
                l.push(b'\n');
                run.write_all(&l).await?;
            }
        }
    }
}

/// The lines `run` sends, on to the viewer; a screen means the session was looked at.
async fn from_run<R, W>(r: R, w: &mut W, unread: &Mutex<Unread>, key: &str) -> std::io::Result<()>
where
    R: AsyncBufRead + Unpin,
    W: AsyncWrite + Unpin,
{
    let mut lines = Lines::new(r, MAX_LINE);
    loop {
        match lines.next().await? {
            Got::Eof => return Ok(()),
            // `run` keeps to the limit itself.
            Got::TooLong => {}
            Got::Line(mut l) => {
                if l.starts_with(br#"{"t":"screen""#) {
                    lock(unread).seen(key, unix_now());
                }
                l.push(b'\n');
                w.write_all(&l).await?;
                w.flush().await?;
            }
        }
    }
}

/// The `ended` event of a view with a `sid`, sent when the view is over however it ends: the send is synchronous,
/// so it also goes out from a task being aborted.
struct Ended<'a> {
    events: &'a UnboundedSender<Value>,
    sid: u64,
    term: String,
    inputs: Arc<AtomicU64>,
}

impl Drop for Ended<'_> {
    fn drop(&mut self) {
        let n = self.inputs.load(Ordering::Relaxed);
        let _ = self.events.send(json!({ "event": "ended", "sid": self.sid, "term": self.term, "inputs": n }));
    }
}

/// The live `run` sessions in `dir`, none when its token cannot be had.
async fn scan_pty(dir: &std::path::Path) -> Vec<Status> {
    match local::token(dir) {
        Ok(t) => local::scan(dir, &t).await,
        Err(_) => Vec::new(),
    }
}

/// The `pty` rows of `statuses`: one pane each, and attached by as many viewers as `run` counts.
fn pty_rows(unread: &Mutex<Unread>, statuses: &[Status], now: u64) -> Vec<TermRow> {
    let u = lock(unread);
    statuses
        .iter()
        .map(|s| TermRow {
            id: TermId { backend: PTY.into(), host: None, name: s.name.clone() }.to_string(),
            host: None,
            name: s.name.clone(),
            command: s.command.clone(),
            panes: 1,
            attached: s.viewers,
            activity: s.activity,
            dead: false,
            unread: u.is_unread(&format!("{PTY}:{}", s.pid), s.activity, now),
        })
        .collect()
}

/// Scan for `run` sessions every `poll`; each answer goes in `rows`, and `changed` hears when it differs.
async fn ask_pty(
    dir: PathBuf,
    unread: Arc<Mutex<Unread>>,
    poll: Duration,
    rows: Arc<Mutex<Option<Vec<TermRow>>>>,
    changed: Arc<Notify>,
) {
    loop {
        let got = pty_rows(&unread, &scan_pty(&dir).await, unix_now());
        {
            let mut last = lock(&rows);
            if last.as_ref() != Some(&got) {
                *last = Some(got);
                changed.notify_one();
            }
        }
        tokio::time::sleep(poll).await;
    }
}

/// How long `open` waits for the window's `run` to appear.
const OPEN_WAIT: Duration = Duration::from_secs(10);

/// How long a `launch/*.command` file is kept when its window was not seen starting: a cold Terminal start with a
/// slow shell rc can take longer than `OPEN_WAIT`.
const LAUNCH_KEEP: Duration = Duration::from_secs(5 * 60);

/// Removes the `.command` files in `launch` last written more than `LAUNCH_KEEP` ago.
fn sweep_launch(launch: &std::path::Path) {
    let Ok(entries) = std::fs::read_dir(launch) else {
        return;
    };
    let now = SystemTime::now();
    for e in entries.flatten() {
        let p = e.path();
        if p.extension() != Some(std::ffi::OsStr::new("command")) {
            continue;
        }
        let age = e.metadata().and_then(|m| m.modified()).ok().and_then(|t| now.duration_since(t).ok());
        if age.is_some_and(|a| a > LAUNCH_KEEP) {
            let _ = std::fs::remove_file(&p);
        }
    }
}

/// `path` from the home directory: `~` is the home directory, `~/x` and a relative `x` are under it; an absolute
/// path stays as it is.
fn expand_home(path: &str) -> PathBuf {
    let Some(home) = std::env::var_os("HOME").map(PathBuf::from) else {
        return PathBuf::from(path);
    };
    match path {
        "~" => home,
        _ if path.starts_with('/') => PathBuf::from(path),
        _ => home.join(path.strip_prefix("~/").unwrap_or(path)),
    }
}

/// 16 hex characters nobody could have guessed: a random hash seed mixed with the clock.
fn ticket() -> String {
    use std::hash::{BuildHasher, Hasher};
    let mut h = std::collections::hash_map::RandomState::new().build_hasher();
    h.write_u128(SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |d| d.as_nanos()));
    format!("{:016x}", h.finish())
}

/// Write `body` to a new file only its owner can use.
fn write_private(path: &std::path::Path, body: &str) -> std::io::Result<()> {
    use std::io::Write;
    use std::os::unix::fs::OpenOptionsExt;
    let mut f = std::fs::OpenOptions::new().write(true).create_new(true).mode(0o700).open(path)?;
    f.write_all(body.as_bytes())
}

/// The hosts: this machine, offering `launchers`.
fn host_list(launchers: &[String]) -> Vec<HostRow> {
    vec![HostRow { host: None, launchers: launchers.to_vec() }]
}

/// Read and drop whatever the other end sends, until it closes.
async fn closed<R: AsyncBufRead + Unpin>(r: &mut R) {
    while let Ok(b) = r.fill_buf().await {
        if b.is_empty() {
            return;
        }
        let n = b.len();
        r.consume(n);
    }
}

fn lock<T>(m: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

/// A list that fits in one line: when the sessions do not all fit, the ones at the end are left out.
fn fit(mut list: TermList) -> TermList {
    let terms = std::mem::take(&mut list.terms);
    // The line's newline, and a comma before every row but the first.
    let mut used = serde_json::to_string(&list).expect("a list always serializes").len() + 1;
    for r in terms {
        let n = serde_json::to_string(&r).expect("a row always serializes").len() + usize::from(!list.terms.is_empty());
        if used + n > MAX_LINE {
            break;
        }
        used += n;
        list.terms.push(r);
    }
    list
}

/// One line of at most `MAX_LINE` bytes with its newline: `Some(None)` for a line too long (read past, never held
/// whole), `None` when the connection ends first.
async fn read_line<R: AsyncBufRead + Unpin>(r: &mut R) -> Option<Option<Vec<u8>>> {
    let mut buf = Vec::new();
    let mut over = false;
    loop {
        let chunk = r.fill_buf().await.ok()?;
        if chunk.is_empty() {
            return None;
        }
        let (part, used, ends) = match chunk.iter().position(|&b| b == b'\n') {
            Some(i) => (&chunk[..i], i + 1, true),
            None => (chunk, chunk.len(), false),
        };
        if !over {
            if buf.len() + part.len() + 1 > MAX_LINE {
                over = true;
                buf = Vec::new();
            } else {
                buf.extend_from_slice(part);
            }
        }
        r.consume(used);
        if ends {
            return Some((!over).then_some(buf));
        }
    }
}

/// Whether `a` and `b` are the same bytes, in a time that does not depend on where they differ.
fn same(a: &[u8], b: &[u8]) -> bool {
    let mut diff = a.len() ^ b.len();
    for i in 0..a.len().max(b.len()) {
        let x = a.get(i).copied().unwrap_or(0) ^ b.get(i).copied().unwrap_or(0);
        diff |= usize::from(x);
    }
    std::hint::black_box(diff) == 0
}

/// One JSON line, flushed.
async fn reply<W: AsyncWrite + Unpin>(w: &mut W, v: &Value) -> std::io::Result<()> {
    let mut line = serde_json::to_string(v).expect("a value always serializes");
    line.push('\n');
    w.write_all(line.as_bytes()).await?;
    w.flush().await
}

/// One wire message, flushed.
async fn put<W: AsyncWrite + Unpin>(w: &mut W, m: &Out) -> std::io::Result<()> {
    w.write_all(proto::encode(m).as_bytes()).await?;
    w.flush().await
}

fn unix_now() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |d| d.as_secs())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tokens_compare_whole() {
        assert!(same(b"abc", b"abc"));
        assert!(!same(b"abc", b"abd") && !same(b"abc", b"ab") && !same(b"ab", b"abc") && !same(b"", b"a"));
        assert!(!same(b"ab\0", b"ab"));
    }

    #[tokio::test]
    async fn lines_are_held_to_max_line() {
        let ok = vec![b'a'; MAX_LINE - 1];
        let long = vec![b'b'; MAX_LINE];
        let mut input = ok.clone();
        input.push(b'\n');
        input.extend_from_slice(&long);
        input.extend_from_slice(b"\nx\ny");
        let mut r = BufReader::with_capacity(16, &input[..]);
        assert_eq!(read_line(&mut r).await, Some(Some(ok)));
        assert_eq!(read_line(&mut r).await, Some(None));
        assert_eq!(read_line(&mut r).await, Some(Some(b"x".to_vec())));
        assert_eq!(read_line(&mut r).await, None);
    }

    #[test]
    fn requests_parse() {
        let r: Req = serde_json::from_str(r#"{"op":"view","term":"term:pty:w","sid":7}"#).unwrap();
        assert!(matches!(r, Req::View { sid: Some(7), .. }));
        // Removed requests are bad requests now.
        assert!(matches!(serde_json::from_str(r#"{"op":"watch"}"#).unwrap(), Req::Watch));
        for bad in [
            r#"{"op":"nope"}"#,
            r#"{"op":"new","host":null,"command":["sh"],"cols":1,"rows":2}"#,
            r#"{"op":"open"}"#,
            r#""list""#,
            "{",
        ] {
            assert!(serde_json::from_str::<Req>(bad).is_err(), "{bad}");
        }
    }

    #[test]
    fn a_long_list_is_cut_to_one_line() {
        let row = |i: usize| TermRow {
            id: format!("term:pty:{i}"),
            host: None,
            name: format!("{i}{}", "n".repeat(200)),
            command: "c".into(),
            panes: 1,
            attached: 0,
            activity: 0,
            dead: false,
            unread: false,
        };
        let hosts = host_list(&[]);
        let list = TermList { terms: (0..1000).map(row).collect(), hosts };
        let cut = fit(list.clone());
        assert!(!cut.terms.is_empty() && cut.terms.len() < 1000);
        assert!(serde_json::to_string(&cut).unwrap().len() < MAX_LINE);
        assert_eq!(cut.terms[..], list.terms[..cut.terms.len()]);
        let small = TermList { terms: list.terms[..3].to_vec(), hosts: list.hosts.clone() };
        assert_eq!(fit(small.clone()), small);
    }

    #[test]
    fn a_leading_tilde_is_the_home_directory_and_tickets_differ() {
        let home = std::env::var_os("HOME").map(PathBuf::from).unwrap();
        assert_eq!(expand_home("~/work"), home.join("work"));
        assert_eq!(expand_home("/tmp/~/x"), PathBuf::from("/tmp/~/x"));
        let (a, b) = (ticket(), ticket());
        assert!(a.len() == 16 && a.bytes().all(|c| c.is_ascii_hexdigit()));
        assert_ne!(a, b);
    }

    #[test]
    fn the_sweep_removes_old_command_files_and_keeps_fresh_ones() {
        let d = tempfile::tempdir().unwrap();
        let aged = |name: &str, age: Duration| {
            let f = std::fs::File::create(d.path().join(name)).unwrap();
            f.set_modified(SystemTime::now() - age).unwrap();
        };
        aged("old.command", Duration::from_secs(6 * 60));
        aged("fresh.command", Duration::from_secs(60));
        aged("old.txt", Duration::from_secs(6 * 60));
        sweep_launch(d.path());
        let mut left: Vec<String> =
            std::fs::read_dir(d.path()).unwrap().map(|e| e.unwrap().file_name().into_string().unwrap()).collect();
        left.sort();
        assert_eq!(left, ["fresh.command", "old.txt"]);
    }

    #[test]
    fn a_bare_tilde_is_home_a_relative_path_is_under_home_an_absolute_one_stays() {
        let home = std::env::var_os("HOME").map(PathBuf::from).unwrap();
        assert_eq!(expand_home("~"), home);
        assert_eq!(expand_home("proj"), home.join("proj"));
        assert_eq!(expand_home("proj/sub"), home.join("proj/sub"));
        assert_eq!(expand_home("/srv/proj"), PathBuf::from("/srv/proj"));
    }
}
