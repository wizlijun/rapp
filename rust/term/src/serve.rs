//! `rapp-term serve`: the resident worker of one device. Each connection carries one request line, then a token
//! line, then the reply: a session list, a new session, or a whole view (the session protocol of `session::run`).
//!
//! Nothing a session shows or is sent, and no new session's command, goes to the events or to stderr.

use crate::config::{self, TermConfig};
use crate::id::{default_name, session_name, TermId};
use crate::list::{host_rows, TermRow};
use crate::proto::{self, Out, MAX_LINE};
use crate::runner::{RunFail, Runner};
use crate::session::{self, Opts};
use crate::tmux::Tmux;
use crate::unread::Unread;
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
use tokio::task::JoinSet;

/// How long a connection has to send its request line and its token line, together.
const HEAD_WAIT: Duration = Duration::from_secs(30);
/// The only backend served.
const BACKEND: &str = "tmux";

pub const BAD_TOKEN: &str = "bad token";
pub const BAD_REQUEST: &str = "bad request";
const UNKNOWN_HOST: &str = "unknown host";
const BAD_ID: &str = "invalid term id";
const NO_COMMAND: &str = "command required";
const TAKEN: &str = "a session with that name already exists";
const LIST_FAILED: &str = "could not list the tmux sessions";

pub struct ServeOpts {
    /// `term.json`, read afresh for every request.
    pub config: PathBuf,
    /// A named tmux server (`tmux -L`) for this machine only; for tests.
    pub socket: Option<String>,
    /// Where ssh keeps its control connections.
    pub ctl_dir: PathBuf,
    /// How often a viewed session is listed and recaptured whether or not it changed.
    pub poll: Duration,
}

impl ServeOpts {
    pub fn new(config: PathBuf, ctl_dir: PathBuf) -> ServeOpts {
        ServeOpts { config, socket: None, ctl_dir, poll: Duration::from_secs(2) }
    }
}

#[derive(Deserialize, Debug)]
#[serde(tag = "op", rename_all = "snake_case")]
enum Req {
    List,
    New { host: Option<String>, name: Option<String>, command: Vec<String>, cols: u16, rows: u16 },
    View { term: String, sid: Option<u64> },
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
        Worker { opts, token, started: unix_now(), unread: Mutex::new(HashMap::new()), events }
    }

    /// The unread state of `host`, made on first use.
    pub fn unread_for(&self, host: Option<&str>) -> Arc<Mutex<Unread>> {
        let mut m = self.unread.lock().unwrap_or_else(|e| e.into_inner());
        m.entry(host.map(str::to_string)).or_insert_with(|| Arc::new(Mutex::new(Unread::new(self.started)))).clone()
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
        let cfg = config::load(&self.opts.config).map_err(|_| config::INVALID).and_then(|c| match c.allow {
            true => Ok(c),
            false => Err(config::OFF),
        });
        let _ = match req {
            Req::View { term, sid } => match cfg {
                Ok(cfg) => self.view(&cfg, &term, sid, r, &mut w).await,
                Err(e) => put(&mut w, &Out::Error { error: e.into() }).await,
            },
            Req::List => {
                let v = match cfg {
                    Ok(cfg) => serde_json::to_value(fit(self.list(&cfg).await)).expect("a list always serializes"),
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

    /// The tmux of `host` (`None`: this machine).
    fn tmux_for(&self, cfg: &TermConfig, host: Option<&str>) -> Result<Tmux, String> {
        let Some(h) = host else {
            return Ok(Tmux { runner: Runner::Local, bin: cfg.tmux_bin().into(), socket: self.opts.socket.clone() });
        };
        let t = cfg.target(h).ok_or(UNKNOWN_HOST)?;
        // `config::load` has checked the target by the same rules, so this does not fail.
        let runner = Runner::ssh(&t.target, &self.opts.ctl_dir).map_err(|_| config::INVALID)?;
        Ok(Tmux { runner, bin: t.tmux.clone().unwrap_or_else(|| BACKEND.into()), socket: None })
    }

    /// Every host's sessions, the hosts asked at the same time. A host that fails is only marked in `hosts`.
    pub async fn list(&self, cfg: &TermConfig) -> TermList {
        let mut hosts = vec![HostRow { host: None, target: None, tmux: None, error: None }];
        hosts.extend(cfg.targets.iter().map(|t| HostRow {
            host: Some(t.name.clone()),
            target: Some(t.target.clone()),
            tmux: t.tmux.clone(),
            error: None,
        }));
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
        while let Some(done) = asks.join_next().await {
            if let Ok((i, r)) = done {
                got[i] = Some(r);
            }
        }
        let mut terms = Vec::new();
        for (h, r) in hosts.iter_mut().zip(got) {
            match r {
                Some(Ok(v)) => terms.extend(v),
                Some(Err(e)) => h.error = Some(e),
                // The ask itself failed (it panicked).
                None => h.error = Some(LIST_FAILED.into()),
            }
        }
        TermList { terms, hosts }
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
        let Some(program) = command.first() else { return Err(NO_COMMAND.into()) };
        let name = session_name(name.unwrap_or_else(|| default_name(program))).ok_or("invalid session name")?;
        let panes = tmux.list().await.map_err(|e| said(&e, &tmux, LIST_FAILED))?;
        if panes.iter().any(|p| p.session == name) {
            return Err(TAKEN.into());
        }
        // tmux's own words may quote the command, so they are not passed on.
        tmux.new_session(&name, command, cols, rows).await.map_err(|_| "could not create the session")?;
        Ok(TermId { backend: BACKEND.into(), host: host.map(str::to_string), name }.to_string())
    }

    /// Pump the session `term` over the connection; one `Out::Error` when it cannot start. A view with a `sid`
    /// reports how many inputs it carried when it ends.
    async fn view<R, W>(&self, cfg: &TermConfig, term: &str, sid: Option<u64>, r: R, w: &mut W) -> std::io::Result<()>
    where
        R: AsyncBufRead + Unpin,
        W: AsyncWrite + Unpin,
    {
        let id = match TermId::parse(term) {
            Ok(id) if id.backend == BACKEND => id,
            _ => return put(w, &Out::Error { error: BAD_ID.into() }).await,
        };
        let tmux = match self.tmux_for(cfg, id.host.as_deref()) {
            Ok(t) => t,
            Err(e) => return put(w, &Out::Error { error: e }).await,
        };
        let inputs = Arc::new(AtomicU64::new(0));
        let opts = Opts { poll: self.opts.poll, inputs: inputs.clone(), ..Opts::default() };
        let res = session::run(&tmux, &id.name, r, &mut *w, self.unread_for(id.host.as_deref()), opts).await;
        if let Some(sid) = sid {
            let n = inputs.load(Ordering::Relaxed);
            let _ = self.events.send(json!({ "event": "ended", "sid": sid, "term": id.to_string(), "inputs": n }));
        }
        match res {
            Ok(()) => Ok(()),
            Err(e) => put(w, &Out::Error { error: said(&e, &tmux, "the view stopped") }).await,
        }
    }
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
        for bad in [r#"{"op":"watch"}"#, r#"{"op":"new"}"#, r#""list""#, "{"] {
            assert!(serde_json::from_str::<Req>(bad).is_err(), "{bad}");
        }
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
        let hosts = vec![HostRow { host: None, target: None, tmux: None, error: None }];
        let list = TermList { terms: (0..1000).map(row).collect(), hosts };
        let cut = fit(list.clone());
        assert!(!cut.terms.is_empty() && cut.terms.len() < 1000);
        assert!(serde_json::to_string(&cut).unwrap().len() < MAX_LINE);
        assert_eq!(cut.terms[..], list.terms[..cut.terms.len()]);
        let small = TermList { terms: list.terms[..3].to_vec(), hosts: list.hosts.clone() };
        assert_eq!(fit(small.clone()), small);
    }
}
