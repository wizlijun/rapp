//! `rapp-term serve`: the resident worker of one device. Each connection carries one request line, then a token
//! line, then the reply: a session list, a watch (a list now and again on every change), a new session, or a whole
//! view (the session protocol of `session::run`).
//!
//! The sessions are tmux's (on this machine and on the targets) and, on this machine, the `pty` ones of
//! `rapp-term run`, which are reached over unix sockets.
//!
//! Nothing a session shows or is sent, and no new session's command, goes to the events or to stderr.

use crate::config::{self, TermConfig};
use crate::id::{default_name, session_name, TermId};
use crate::list::{host_rows, Backoff, TermRow};
use crate::proto::{self, Out, MAX_LINE};
use crate::pty::launch;
use crate::pty::local::{self, Status};
use crate::runner::{RunFail, Runner};
use crate::session::{self, Opts};
use crate::tmux::Tmux;
use crate::unread::Unread;
use crate::wire::{Got, Lines, MAX_IN_LINE};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::future::Future;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tokio::io::{AsyncBufRead, AsyncBufReadExt, AsyncWrite, AsyncWriteExt, BufReader};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::mpsc::UnboundedSender;
use tokio::sync::Notify;
use tokio::task::{AbortHandle, JoinSet};
use tokio::time::MissedTickBehavior;

/// How long a connection has to send its request line and its token line, together.
const HEAD_WAIT: Duration = Duration::from_secs(30);
/// The backend of tmux sessions.
const TMUX: &str = "tmux";
/// The backend of `rapp-term run` sessions.
const PTY: &str = "pty";

pub const BAD_TOKEN: &str = "bad token";
pub const BAD_REQUEST: &str = "bad request";
const UNKNOWN_HOST: &str = "unknown host";
const BAD_ID: &str = "invalid term id";
const TAKEN: &str = "a session with that name already exists";
const NO_TEXT_TERMINAL: &str = "no such text terminal";
const UNKNOWN_APP: &str = "unknown terminal app";
const NOT_STARTED: &str = "the terminal window did not start in 10 s";
const LIST_FAILED: &str = "could not list the tmux sessions";

pub struct ServeOpts {
    /// `term.json`, read afresh for every request.
    pub config: PathBuf,
    /// A named tmux server (`tmux -L`) for this machine only; for tests.
    pub socket: Option<String>,
    /// Where ssh keeps its control connections.
    pub ctl_dir: PathBuf,
    /// How often a viewed session is listed and recaptured whether or not it changed; how often a watch asks
    /// each host for its sessions and reads `term.json` again.
    pub poll: Duration,
    /// The directory `rapp-term run` keeps its sockets and token in (`pty/<pid>.sock`, `pty.token`).
    pub pty_dir: PathBuf,
    /// Run instead of `open -a`, for tests: `<program> <app> <file>`.
    pub launch_with: Option<PathBuf>,
}

impl ServeOpts {
    pub fn new(config: PathBuf, ctl_dir: PathBuf) -> ServeOpts {
        let pty_dir = config.parent().unwrap_or(&config).join("term");
        ServeOpts { config, socket: None, ctl_dir, poll: Duration::from_secs(2), pty_dir, launch_with: None }
    }
}

#[derive(Deserialize, Debug)]
#[serde(tag = "op", rename_all = "snake_case")]
enum Req {
    List,
    Watch,
    New { host: Option<String>, name: Option<String>, command: Vec<String>, cols: u16, rows: u16 },
    View { term: String, sid: Option<u64> },
    Open { cwd: Option<String>, name: Option<String>, command: Option<String>, app: String },
}

/// The session list: every host's sessions, and how each host went.
#[derive(Serialize, Clone, Debug, PartialEq)]
pub struct TermList {
    pub terms: Vec<TermRow>,
    pub hosts: Vec<HostRow>,
}

/// One host of a `TermList`: this machine first (`host` null), then the targets in `term.json` order.
#[derive(Serialize, Clone, Debug, PartialEq)]
pub struct HostRow {
    pub host: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub target: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tmux: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
    /// The terminal programs this host offers to start a session with.
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub launchers: Vec<String>,
}

/// What every connection shares.
pub struct Worker {
    opts: ServeOpts,
    token: String,
    /// When the worker started: output before it is not unread.
    started: u64,
    /// The unread state of each host (`None`: this machine).
    unread: Mutex<HashMap<Option<String>, Arc<Mutex<Unread>>>>,
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
            started: unix_now(),
            unread: Mutex::new(HashMap::new()),
            events,
            launchers: launch::launchers(),
            opening: Default::default(),
        }
    }

    /// The unread state of `host`, made on first use.
    pub fn unread_for(&self, host: Option<&str>) -> Arc<Mutex<Unread>> {
        let mut m = self.unread.lock().unwrap_or_else(|e| e.into_inner());
        m.entry(host.map(str::to_string)).or_insert_with(|| Arc::new(Mutex::new(Unread::new(self.started)))).clone()
    }

    /// The live `run` sessions of this machine; none when the token cannot be had.
    async fn pty_statuses(&self) -> Vec<Status> {
        scan_pty(&self.opts.pty_dir).await
    }

    /// The rows of `statuses`, as `list` shows them.
    pub fn pty_rows(&self, statuses: &[Status], now: u64) -> Vec<TermRow> {
        pty_rows(&self.unread_for(None), statuses, now)
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
                Ok(cfg) => self.view(&cfg, &term, sid, r, &mut w).await,
                Err(e) => put(&mut w, &Out::Error { error: e.into() }).await,
            },
            Req::Watch => match cfg {
                Ok(cfg) => self.watch(cfg, r, &mut w).await,
                Err(e) => reply(&mut w, &json!({ "error": e })).await,
            },
            Req::List => {
                let v = match cfg {
                    Ok(cfg) => serde_json::to_value(fit(self.list(&cfg).await)).expect("a list always serializes"),
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
            Req::New { host, name, command, cols, rows } => {
                let v = match cfg {
                    Ok(cfg) => {
                        match self.new_session(&cfg, host.as_deref(), name.as_deref(), &command, cols, rows).await {
                            Ok(id) => json!({ "ok": true, "id": id }),
                            Err(e) => json!({ "error": e }),
                        }
                    }
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

    /// The tmux of `host` (`None`: this machine).
    fn tmux_for(&self, cfg: &TermConfig, host: Option<&str>) -> Result<Tmux, String> {
        let Some(h) = host else {
            return Ok(Tmux { runner: Runner::Local, bin: cfg.tmux_bin().into(), socket: self.opts.socket.clone() });
        };
        let t = cfg.target(h).ok_or(UNKNOWN_HOST)?;
        // `config::load` has checked the target by the same rules, so this does not fail.
        let runner = Runner::ssh(&t.target, &self.opts.ctl_dir).map_err(|_| config::INVALID)?;
        Ok(Tmux { runner, bin: t.tmux.clone().unwrap_or_else(|| TMUX.into()), socket: None })
    }

    /// Every host's sessions, the hosts asked at the same time. A host that fails is only marked in `hosts`.
    pub async fn list(&self, cfg: &TermConfig) -> TermList {
        let mut hosts = host_list(cfg, &self.launchers);
        // A `JoinSet` of this connection's own: when the connection is dropped, its asks are too.
        let mut asks = JoinSet::new();
        for (i, h) in hosts.iter().enumerate() {
            let host = h.host.clone();
            let tmux = self.tmux_for(cfg, host.as_deref());
            let unread = self.unread_for(host.as_deref());
            asks.spawn(async move {
                let rows = match tmux {
                    Ok(tmux) => host_rows(&tmux, host.as_deref(), &unread, unix_now())
                        .await
                        .map_err(|e| said(&e, &tmux, LIST_FAILED)),
                    Err(e) => Err(e),
                };
                (i, rows)
            });
        }
        let mut got: Vec<Option<Result<Vec<TermRow>, String>>> = vec![None; hosts.len()];
        let tmux_asks = async {
            while let Some(done) = asks.join_next().await {
                if let Ok((i, r)) = done {
                    got[i] = Some(r);
                }
            }
        };
        let (_, statuses) = tokio::join!(tmux_asks, self.pty_statuses());
        let pty = self.pty_rows(&statuses, unix_now());
        let mut terms = Vec::new();
        for (i, (h, r)) in hosts.iter_mut().zip(got).enumerate() {
            match r {
                Some(Ok(v)) => terms.extend(v),
                Some(Err(e)) => h.error = Some(e),
                // The ask itself failed (it panicked).
                None => h.error = Some(LIST_FAILED.into()),
            }
            // This machine's `pty` rows come right after its tmux ones.
            if i == 0 {
                terms.extend(pty.iter().cloned());
            }
        }
        TermList { terms, hosts }
    }

    /// Send the session list now (once this machine has answered, tmux and `pty` both) and again whenever it changes, until the other
    /// end closes; if terminal sessions are turned off meanwhile, one error line ends it. Each host is asked by a
    /// task of its own, so a slow one holds back only its own entry. `term.json` is read again every `poll`; one
    /// that cannot be read leaves the hosts as they were.
    async fn watch<R, W>(&self, cfg: TermConfig, mut r: R, w: &mut W) -> std::io::Result<()>
    where
        R: AsyncBufRead + Unpin,
        W: AsyncWrite + Unpin,
    {
        let changed = Arc::new(Notify::new());
        // The watch's own tasks: they go when it does.
        let mut tasks = JoinSet::new();
        let mut hosts = self.rewatch(&cfg, Vec::new(), &mut tasks, &changed);
        let pty = Arc::new(Mutex::new(None));
        tasks.spawn(ask_pty(
            self.opts.pty_dir.clone(),
            self.unread_for(None),
            self.opts.poll,
            pty.clone(),
            changed.clone(),
        ));
        let mut sent: Option<TermList> = None;
        let mut tick = tokio::time::interval(self.opts.poll);
        tick.set_missed_tick_behavior(MissedTickBehavior::Delay);
        // The first tick is now: `cfg` was just read.
        tick.tick().await;
        loop {
            tokio::select! {
                _ = tick.tick() => {
                    match self.config() {
                        Ok(cfg) => hosts = self.rewatch(&cfg, hosts, &mut tasks, &changed),
                        Err(config::OFF) => return reply(w, &json!({ "error": config::OFF })).await,
                        // Halfway through being rewritten, perhaps.
                        Err(_) => {}
                    }
                    while tasks.try_join_next().is_some() {}
                }
                _ = changed.notified() => {}
                _ = closed(&mut r) => return Ok(()),
            }
            if sent.is_none() && (lock(&hosts[0].rows).is_none() || lock(&pty).is_none()) {
                continue;
            }
            let list = fit(table(&hosts, lock(&pty).as_deref().unwrap_or_default()));
            if sent.as_ref() != Some(&list) {
                reply(w, &serde_json::to_value(&list).expect("a list always serializes")).await?;
                sent = Some(list);
            }
        }
    }

    /// The watched hosts of `cfg`, in its order: a host as it was keeps its task, a new or changed one gets a new
    /// task, and the tasks of the rest end (they are dropped).
    fn rewatch(
        &self,
        cfg: &TermConfig,
        mut old: Vec<Watched>,
        tasks: &mut JoinSet<()>,
        changed: &Arc<Notify>,
    ) -> Vec<Watched> {
        host_list(cfg, &self.launchers)
            .into_iter()
            .map(|row| {
                let tmux = self.tmux_for(cfg, row.host.as_deref());
                let key = (row, tmux.as_ref().ok().map(|t| t.bin.clone()));
                if let Some(i) = old.iter().position(|h| h.key == key) {
                    return old.swap_remove(i);
                }
                let rows = Arc::new(Mutex::new(None));
                let unread = self.unread_for(key.0.host.as_deref());
                let ask = ask_host(tmux, key.0.host.clone(), unread, self.opts.poll, rows.clone(), changed.clone());
                Watched { key, rows, task: tasks.spawn(ask) }
            })
            .collect()
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

    async fn new_session(
        &self,
        cfg: &TermConfig,
        host: Option<&str>,
        name: Option<&str>,
        command: &[String],
        cols: u16,
        rows: u16,
    ) -> Result<String, String> {
        let tmux = self.tmux_for(cfg, host)?;
        // No command: tmux's default shell, named `shell` unless asked otherwise.
        let default = command.first().map_or("shell", |program| default_name(program));
        let name = session_name(name.unwrap_or(default)).ok_or("invalid session name")?;
        let panes = tmux.list().await.map_err(|e| said(&e, &tmux, LIST_FAILED))?;
        if panes.iter().any(|p| p.session == name) {
            return Err(TAKEN.into());
        }
        // tmux's own words may quote the command, so they are not passed on.
        tmux.new_session(&name, command, cols, rows).await.map_err(|_| "could not create the session")?;
        Ok(TermId { backend: TMUX.into(), host: host.map(str::to_string), name }.to_string())
    }

    /// Pump the session `term` over the connection; one `Out::Error` when it cannot start. A view with a `sid`
    /// reports how many inputs it carried when it ends.
    async fn view<R, W>(&self, cfg: &TermConfig, term: &str, sid: Option<u64>, r: R, w: &mut W) -> std::io::Result<()>
    where
        R: AsyncBufRead + Unpin,
        W: AsyncWrite + Unpin,
    {
        let id = match TermId::parse(term) {
            Ok(id) if id.backend == TMUX || (id.backend == PTY && id.host.is_none()) => id,
            _ => return put(w, &Out::Error { error: BAD_ID.into() }).await,
        };
        if id.backend == PTY {
            return self.view_pty(id, sid, r, w).await;
        }
        let tmux = match self.tmux_for(cfg, id.host.as_deref()) {
            Ok(t) => t,
            Err(e) => return put(w, &Out::Error { error: e }).await,
        };
        let inputs = Arc::new(AtomicU64::new(0));
        // Reports when dropped, so a view cut off by the worker stopping (its task aborted) is reported too.
        let _ended = sid.map(|sid| Ended { events: &self.events, sid, term: id.to_string(), inputs: inputs.clone() });
        let opts = Opts { poll: self.opts.poll, inputs, ..Opts::default() };
        let res = session::run(&tmux, &id.name, r, &mut *w, self.unread_for(id.host.as_deref()), opts).await;
        match res {
            Ok(()) => Ok(()),
            Err(e) => put(w, &Out::Error { error: said(&e, &tmux, "the view stopped") }).await,
        }
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
        let Ok(stream) = stream else { return put(w, &Out::Error { error: NO_TEXT_TERMINAL.into() }).await };
        let inputs = Arc::new(AtomicU64::new(0));
        let _ended = sid.map(|sid| Ended { events: &self.events, sid, term: id.to_string(), inputs: inputs.clone() });
        let (run_r, mut run_w) = stream.into_split();
        let unread = self.unread_for(None);
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

/// What a host answered: its sessions, or why it could not say.
type Answer = Result<Vec<TermRow>, String>;

/// One host of a watch.
struct Watched {
    /// The host as `term.json` has it, and the tmux program asked: when either changes, it is a new host.
    key: (HostRow, Option<String>),
    /// Its last answer; `None` before the first.
    rows: Arc<Mutex<Option<Answer>>>,
    task: AbortHandle,
}

impl Drop for Watched {
    fn drop(&mut self) {
        self.task.abort();
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
    let Ok(entries) = std::fs::read_dir(launch) else { return };
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
    let Some(home) = std::env::var_os("HOME").map(PathBuf::from) else { return PathBuf::from(path) };
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

/// The hosts of `cfg`, none asked yet: this machine first (offering `launchers`), then the targets in order.
fn host_list(cfg: &TermConfig, launchers: &[String]) -> Vec<HostRow> {
    let mut hosts = vec![HostRow { host: None, target: None, tmux: None, error: None, launchers: launchers.to_vec() }];
    hosts.extend(cfg.targets.iter().map(|t| HostRow {
        host: Some(t.name.clone()),
        target: Some(t.target.clone()),
        tmux: t.tmux.clone(),
        error: None,
        launchers: Vec::new(),
    }));
    hosts
}

/// Ask one host for its sessions every `poll`, or, after a failure, when its own `Backoff` says. Each answer goes
/// in `rows`; `changed` hears when it differs from the one before.
async fn ask_host(
    tmux: Result<Tmux, String>,
    host: Option<String>,
    unread: Arc<Mutex<Unread>>,
    poll: Duration,
    rows: Arc<Mutex<Option<Answer>>>,
    changed: Arc<Notify>,
) {
    let tmux = match tmux {
        Ok(t) => t,
        Err(e) => {
            *lock(&rows) = Some(Err(e));
            changed.notify_one();
            return;
        }
    };
    let mut backoff = Backoff::new();
    loop {
        let got =
            host_rows(&tmux, host.as_deref(), &unread, unix_now()).await.map_err(|e| said(&e, &tmux, LIST_FAILED));
        let wait = match got {
            Ok(_) => {
                backoff.reset();
                poll
            }
            Err(_) => backoff.failed(),
        };
        {
            let mut last = lock(&rows);
            if last.as_ref() != Some(&got) {
                *last = Some(got);
                changed.notify_one();
            }
        }
        tokio::time::sleep(wait).await;
    }
}

/// The list as the watched hosts and the `pty` scan last answered; a host that has not answered yet is listed with no sessions.
fn table(hosts: &[Watched], pty: &[TermRow]) -> TermList {
    let mut list = TermList { terms: Vec::new(), hosts: Vec::new() };
    for (i, h) in hosts.iter().enumerate() {
        let mut row = h.key.0.clone();
        match &*lock(&h.rows) {
            Some(Ok(v)) => list.terms.extend(v.iter().cloned()),
            Some(Err(e)) => row.error = Some(e.clone()),
            None => {}
        }
        // This machine's `pty` rows come right after its tmux ones.
        if i == 0 {
            list.terms.extend(pty.iter().cloned());
        }
        list.hosts.push(row);
    }
    list
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

/// The words of a tmux failure fit to pass on: the kind of failure or a starting problem, never tmux's or ssh's
/// own output (which can quote a command); `other` for anything else.
fn said(e: &anyhow::Error, tmux: &Tmux, other: &str) -> String {
    let s = e.to_string();
    let kinds = [RunFail::HostKey, RunFail::Auth, RunFail::Unreachable, RunFail::NoProgram].map(|k| k.to_string());
    let fixed = ["could not read the tmux pane list".to_string(), format!("could not start {}", tmux.program_name())];
    match kinds.contains(&s) || fixed.contains(&s) {
        true => s,
        false => other.to_string(),
    }
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
        let r: Req = serde_json::from_str(r#"{"op":"view","term":"term:tmux:w","sid":7}"#).unwrap();
        assert!(matches!(r, Req::View { sid: Some(7), .. }));
        let r: Req = serde_json::from_str(r#"{"op":"new","host":null,"command":["sh"],"cols":1,"rows":2}"#).unwrap();
        assert!(matches!(r, Req::New { name: None, host: None, .. }));
        assert!(matches!(serde_json::from_str(r#"{"op":"watch"}"#).unwrap(), Req::Watch));
        for bad in [r#"{"op":"nope"}"#, r#"{"op":"new"}"#, r#""list""#, "{"] {
            assert!(serde_json::from_str::<Req>(bad).is_err(), "{bad}");
        }
    }

    #[test]
    fn unread_is_kept_per_host() {
        let opts = ServeOpts::new("term.json".into(), "ctl".into());
        let w = Worker::new("t".into(), opts, tokio::sync::mpsc::unbounded_channel().0);
        let (here, gpu1) = (w.unread_for(None), w.unread_for(Some("gpu1")));
        assert!(!Arc::ptr_eq(&here, &gpu1));
        assert!(Arc::ptr_eq(&gpu1, &w.unread_for(Some("gpu1"))));
        // Output after the start, then quiet: unread on both until gpu1's "$0" is seen.
        let (activity, now) = (w.started + 10, w.started + 20);
        assert!(here.lock().unwrap().is_unread("$0", activity, now));
        gpu1.lock().unwrap().seen("$0", now);
        assert!(!gpu1.lock().unwrap().is_unread("$0", activity, now));
        assert!(here.lock().unwrap().is_unread("$0", activity, now));
    }

    #[test]
    fn a_long_list_is_cut_to_one_line() {
        let row = |i: usize| TermRow {
            id: format!("term:tmux:{i}"),
            host: None,
            name: format!("{i}{}", "n".repeat(200)),
            command: "c".into(),
            panes: 1,
            attached: 0,
            activity: 0,
            dead: false,
            unread: false,
        };
        let hosts = vec![HostRow { host: None, target: None, tmux: None, error: None, launchers: Vec::new() }];
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
