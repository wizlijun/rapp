//! Terminal sessions as device requests (spec §6, §8, §9): `list_terms`, `watch_terms`, `open_term` and `rename_term`
//! are asked of the device's one `rapp-term serve` (`workers::TERM`).
//! `open term:…` splices B to a view on that worker (§7, §15: several may watch one, nothing is taken over). The
//! switch in `term.json` is changed only over local IPC (`term` / `set_term`).
//! While terminal sessions are off, or `term.json` cannot be used, every request is refused and no worker starts.

use crate::peer::log_request;
use crate::state::{Peer, State};
use crate::workers::{self, TERM};
use anyhow::{anyhow, Context, Result};
use rapp_net::line::{err, ok, write_json};
use rapp_net::log::Lvl;
use rapp_net::msg::Op;
use rapp_net::quic::{splice_metered, Meter};
use rapp_term::config::{TermConfig, INVALID, OFF};
use serde_json::{json, Value};
use std::path::PathBuf;
use std::pin::Pin;
use std::sync::{Arc, Mutex, MutexGuard};
use std::task::{self, Poll};
use std::time::{Duration, Instant};
use tokio::io::{AsyncBufReadExt, AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt, BufReader, Lines, ReadBuf};
use tokio::net::TcpStream;
use tokio::sync::Notify;

/// How long the worker has to give its (first) answer.
const ASK_WAIT: Duration = Duration::from_secs(30);

/// Held around every read-modify-write of `term.json`.
static EDIT: Mutex<()> = Mutex::new(());

/// A connection to the worker, read line by line.
type WorkerConn = Lines<BufReader<TcpStream>>;

pub fn path(state: &State) -> PathBuf {
    state.home.join("term.json")
}

/// `term.json` as it is now; `Err(INVALID)` when it cannot be used (why goes to the log, never what it holds).
pub fn config(state: &State) -> Result<TermConfig, String> {
    rapp_term::config::load(&path(state)).map_err(|e| {
        state.log.msg(Lvl::Warn, e);
        INVALID.to_string()
    })
}

/// `term.json`, when terminal sessions are on.
fn allowed(state: &State) -> Result<TermConfig, String> {
    let c = config(state)?;
    if !c.allow {
        return Err(OFF.into());
    }
    Ok(c)
}

/// One terminal-session request from B, logged as one `request` line.
pub async fn request<S: AsyncRead + AsyncWrite + Unpin + Send>(
    state: &Arc<State>,
    s: &mut S,
    peer: &Peer,
    op: Op,
) -> Result<()> {
    let what = log_fields(&op);
    let r = match allowed(state) {
        Err(e) => err(&e),
        Ok(_) => match op {
            Op::WatchTerms => return watch(state, s, peer, what).await,
            Op::ListTerms => answer(ask(state, &json!({"op": "list"})).await),
            Op::OpenTerm { shell, from, app } => {
                answer(ask(state, &json!({"op": "open", "shell": shell, "from": from, "app": app})).await)
            }
            Op::RestoreTerms { keys, app } => {
                answer(ask(state, &json!({"op": "restore", "keys": keys, "app": app})).await)
            }
            Op::ForgetTerms { keys } => answer(ask(state, &json!({"op": "forget", "keys": keys})).await),
            Op::EndTerm { term } => answer(ask(state, &json!({"op": "end", "term": term})).await),
            Op::RenameTerm { term, name } => answer(ask(state, &json!({"op": "rename", "term": term, "name": name})).await),
            _ => err("unknown op"),
        },
    };
    log_request(state, peer, what, &r);
    finish(s, &r).await
}

/// The `request` line's fields: never a name, a term id or anything from `term.json`.
fn log_fields(op: &Op) -> Value {
    match op {
        Op::ListTerms => json!({"op": "list_terms"}),
        Op::WatchTerms => json!({"op": "watch_terms"}),
        // `from` is a term id unless it is serve's "last": only its kind is logged.
        Op::OpenTerm { app, from, .. } => match from.as_deref() {
            None => json!({"op": "open_term", "app": app}),
            Some("last") => json!({"op": "open_term", "app": app, "from": "last"}),
            Some(_) => json!({"op": "open_term", "app": app, "from": "term"}),
        },
        // Only how many: a key names a saved terminal.
        Op::RestoreTerms { keys, .. } => json!({"op": "restore_terms", "keys": keys.len()}),
        Op::ForgetTerms { keys } => json!({"op": "forget_terms", "keys": keys.len()}),
        Op::EndTerm { .. } => json!({"op": "end_term"}),
        Op::RenameTerm { .. } => json!({"op": "rename_term"}),
        _ => json!({}),
    }
}

async fn finish<S: AsyncWrite + Unpin>(s: &mut S, v: &Value) -> Result<()> {
    write_json(s, v).await?;
    s.shutdown().await?;
    Ok(())
}

/// A worker line as a reply to B: one carrying `error` is that error, anything else is passed on with `ok` added.
fn answer(r: Result<Value>) -> Value {
    match r {
        Ok(v) => match v["error"].as_str() {
            Some(e) => err(e),
            None => ok(v),
        },
        Err(e) => err(&format!("{e:#}")),
    }
}

/// Connects to the worker and sends the request line and the token line.
async fn connect(port: u16, token: &str, req: &Value) -> Result<WorkerConn> {
    let mut tcp = TcpStream::connect(("127.0.0.1", port)).await.context("terminal worker unreachable")?;
    tcp.set_nodelay(true)?;
    tcp.write_all(format!("{req}\n{token}\n").as_bytes()).await?;
    Ok(BufReader::new(tcp).lines())
}

/// The worker's next line; None when it closed.
async fn next(w: &mut WorkerConn) -> Result<Option<Value>> {
    match w.next_line().await? {
        Some(l) => Ok(Some(serde_json::from_str(&l)?)),
        None => Ok(None),
    }
}

/// Connects with `req` and waits for the worker's first line.
async fn first(port: u16, token: &str, req: &Value) -> Result<(WorkerConn, Value)> {
    let asked = async {
        let mut w = connect(port, token, req).await?;
        let v = next(&mut w).await?.ok_or_else(|| anyhow!("the terminal worker closed"))?;
        Ok((w, v))
    };
    tokio::time::timeout(ASK_WAIT, asked).await.map_err(|_| anyhow!("the terminal worker did not answer"))?
}

/// One session counted on the worker (`workers::start_session` succeeded), ended when this is dropped: however
/// the request ends, even when its future is dropped, the worker is not kept from stopping as idle.
/// Only that worker's count goes down: one started after it (the switch turned off and on) keeps its own.
struct Counted<'a>(&'a Arc<State>, u64);

impl Drop for Counted<'_> {
    fn drop(&mut self) {
        workers::end_counted(self.0, TERM, self.1);
    }
}

/// Port and token of the worker, with its session counted until the `Counted` is dropped.
async fn start(state: &Arc<State>) -> Result<(u16, String, Counted<'_>)> {
    let (port, token, gen) = workers::start_counted(state, TERM).await?;
    Ok((port, token, Counted(state, gen)))
}

/// A one-line request (`list`, `new`) to the worker.
pub(crate) async fn ask(state: &Arc<State>, req: &Value) -> Result<Value> {
    let (port, token, _counted) = start(state).await?;
    first(port, &token, req).await.map(|(_, v)| v)
}

/// The worker's watch, passed on to B. The worker's session count stays up until the watch ends, so it is not
/// stopped as idle meanwhile.
async fn watch<S: AsyncRead + AsyncWrite + Unpin + Send>(
    state: &Arc<State>,
    s: &mut S,
    peer: &Peer,
    what: Value,
) -> Result<()> {
    let (port, token, _counted) = match start(state).await {
        Ok(w) => w,
        Err(e) => {
            let r = err(&format!("{e:#}"));
            log_request(state, peer, what, &r);
            return finish(s, &r).await;
        }
    };
    follow(state, s, peer, what, port, &token).await
}

/// The first line answers the request; each one after it follows, until B or the worker closes, or the worker
/// sends an error (passed on as an error).
async fn follow<S: AsyncRead + AsyncWrite + Unpin + Send>(
    state: &State,
    s: &mut S,
    peer: &Peer,
    what: Value,
    port: u16,
    token: &str,
) -> Result<()> {
    let (mut w, line) = match first(port, token, &json!({"op": "watch"})).await {
        Ok((w, v)) => (Some(w), answer(Ok(v))),
        Err(e) => (None, answer(Err(e))),
    };
    log_request(state, peer, what, &line);
    let Some(w) = w.as_mut().filter(|_| line["ok"] == true) else { return finish(s, &line).await };
    write_json(s, &line).await?;
    let mut buf = [0u8; 256];
    loop {
        tokio::select! {
            // What B writes is ignored; its close ends the watch.
            n = s.read(&mut buf) => if !matches!(n, Ok(1..)) {
                break;
            },
            v = next(w) => {
                let Ok(Some(v)) = v else { break };
                let line = answer(Ok(v));
                if write_json(s, &line).await.is_err() || line["ok"] != true {
                    break;
                }
            }
        }
    }
    // B may be gone already.
    let _ = s.shutdown().await;
    Ok(())
}

/// `open term:…`: B is spliced to a view on the worker. The service writes the view's request line, with the
/// session's sid; the token line is B's first line, passed through. Logged as an app session is (`request`,
/// `session_start`, `session_end`), and a kick ends it; the worker reports its inputs (`ended`) on its own.
pub async fn open<S: AsyncRead + AsyncWrite + Unpin + Send>(
    state: &Arc<State>,
    s: &mut S,
    app: &str,
    peer: Peer,
) -> Result<()> {
    let what = json!({"op": "open", "app": app});
    let ready = async {
        allowed(state)?;
        // Counts as "in use" for the updater from now until the session ends.
        let opening = crate::update::begin_open(state).map_err(str::to_string)?;
        let (port, token, counted) = start(state).await.map_err(|e| format!("{e:#}"))?;
        Ok::<_, String>((opening, port, token, counted))
    };
    let (_opening, port, token, _counted) = match ready.await {
        Ok(r) => r,
        Err(e) => return refuse(state, s, &peer, what, &e).await,
    };
    let mut tcp = match TcpStream::connect(("127.0.0.1", port)).await {
        Ok(t) => t,
        Err(e) => return refuse(state, s, &peer, what, &format!("terminal worker unreachable: {e}")).await,
    };
    tcp.set_nodelay(true)?;
    // Registered before B hears `ok`, so the worker's `ended` for this view carries a known sid.
    let (sid, kick, _) = state.add_session(&peer, app, false);
    let view = json!({"op": "view", "term": app, "sid": sid});
    if let Err(e) = tcp.write_all(format!("{view}\n").as_bytes()).await {
        state.end_session(sid);
        return refuse(state, s, &peer, what, &format!("terminal worker unreachable: {e}")).await;
    }
    let reply = ok(json!({"token": token}));
    log_request(state, &peer, what, &reply);
    let mut fields = peer.session_fields(app, false, sid);
    state.log.event(Lvl::Info, "session_start", fields.clone());
    let (meter, began, closed) = (Meter::default(), Instant::now(), Notify::new());
    let reason = match write_json(s, &reply).await {
        Err(e) => format!("{e:#}"),
        Ok(()) => {
            crate::cm::ensure_running(state);
            let mut worker = WorkerSide { tcp: &mut tcp, closed: &closed };
            tokio::select! {
                r = splice_metered(s, &mut worker, &meter) => match r {
                    Ok(()) => "closed".to_string(),
                    Err(e) => format!("{e:#}"),
                },
                _ = kick.notified() => "kicked".to_string(),
                // The worker closing the view ends the session: B's side is not waited for.
                _ = closed.notified() => {
                    let _ = s.shutdown().await; // B may be gone already
                    "closed".to_string()
                }
            }
        }
    };
    if !state.end_session(sid) {
        return Ok(()); // the stopping service already wrote its end line
    }
    // The meter counts on B's stream: read from B = up (B→A), written to B = down.
    let (up, down) = meter.get();
    fields["secs"] = json!(began.elapsed().as_secs());
    (fields["up"], fields["down"], fields["reason"]) = (json!(up), json!(down), json!(reason));
    state.log.event(Lvl::Info, "session_end", fields);
    Ok(())
}

async fn refuse<S: AsyncWrite + Unpin>(state: &State, s: &mut S, peer: &Peer, what: Value, e: &str) -> Result<()> {
    let r = err(e);
    log_request(state, peer, what, &r);
    finish(s, &r).await
}

/// The worker's end of a view; `closed` is woken when a read finds it closed. All the view sent before that has
/// been handed on to B by then (the splice writes out what it read before it reads again).
struct WorkerSide<'a> {
    tcp: &'a mut TcpStream,
    closed: &'a Notify,
}

impl AsyncRead for WorkerSide<'_> {
    fn poll_read(self: Pin<&mut Self>, cx: &mut task::Context<'_>, buf: &mut ReadBuf<'_>) -> Poll<std::io::Result<()>> {
        let this = self.get_mut();
        let (room, before) = (buf.remaining() > 0, buf.filled().len());
        let r = Pin::new(&mut *this.tcp).poll_read(cx, buf);
        if room && matches!(r, Poll::Ready(Ok(()))) && buf.filled().len() == before {
            this.closed.notify_one();
        }
        r
    }
}

impl AsyncWrite for WorkerSide<'_> {
    fn poll_write(self: Pin<&mut Self>, cx: &mut task::Context<'_>, b: &[u8]) -> Poll<std::io::Result<usize>> {
        Pin::new(&mut *self.get_mut().tcp).poll_write(cx, b)
    }
    fn poll_flush(self: Pin<&mut Self>, cx: &mut task::Context<'_>) -> Poll<std::io::Result<()>> {
        Pin::new(&mut *self.get_mut().tcp).poll_flush(cx)
    }
    fn poll_shutdown(self: Pin<&mut Self>, cx: &mut task::Context<'_>) -> Poll<std::io::Result<()>> {
        Pin::new(&mut *self.get_mut().tcp).poll_shutdown(cx)
    }
}

/// The worker's `ended` for a view: `term_inputs {sid, term, inputs}`, those fields only (never what was typed).
pub fn ended(state: &State, v: &Value) {
    let Some(sid) = v["sid"].as_u64() else { return };
    let fields = json!({"sid": sid, "term": v["term"].as_str(), "inputs": v["inputs"].as_u64()});
    state.log.event(Lvl::Info, "term_inputs", fields);
}

/// IPC `term`: `{"ok":true,"allow"}`.
pub fn settings(state: &State) -> Value {
    match config(state) {
        Ok(c) => ok(json!({"allow": c.allow})),
        Err(e) => err(&e),
    }
}

/// IPC `set_term {"allow"?}`. Turned off, the worker is stopped,
/// which ends every terminal session and watch on it (app sessions are another worker's).
pub fn set(state: &State, cmd: &Value) -> Value {
    let saved = {
        let _held = lock();
        config(state).and_then(|mut c| {
            match cmd.get("allow") {
                None => {}
                Some(Value::Bool(a)) => c.allow = *a,
                Some(_) => return Err("allow must be true or false".into()),
            }
            save(state, c.allow)?;
            Ok(c.allow)
        })
    };
    match saved {
        Ok(allow) => {
            if !allow {
                workers::stop(state, TERM);
            }
            state.notify();
            ok(json!({}))
        }
        Err(e) => err(&e),
    }
}

fn lock() -> MutexGuard<'static, ()> {
    EDIT.lock().unwrap_or_else(|e| e.into_inner())
}

/// Writes `allow` into `term.json` (0600); held under `lock`.
fn save(state: &State, allow: bool) -> Result<(), String> {
    write_allow(&path(state), allow).map_err(|e| {
        state.log.msg(Lvl::Warn, format!("term.json: {e:#}"));
        "could not save term.json".to_string()
    })
}

/// `allow` set in the file at `path`; every other field in it stays as it is (an older version still reads its own).
/// A file that is missing or is not a JSON object is replaced by `{"allow":…}`.
fn write_allow(path: &std::path::Path, allow: bool) -> Result<()> {
    let mut v = std::fs::read_to_string(path).ok().and_then(|t| serde_json::from_str::<Value>(&t).ok());
    let obj = match v.as_mut().and_then(Value::as_object_mut) {
        Some(o) => o,
        None => {
            v = Some(json!({}));
            v.as_mut().and_then(Value::as_object_mut).expect("an object")
        }
    };
    obj.insert("allow".into(), Value::Bool(allow));
    rapp_net::config::write_json(path, &v)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn set_allow_keeps_the_other_fields_of_term_json() {
        let d = tempfile::tempdir().unwrap();
        let p = d.path().join("term.json");
        std::fs::write(&p, r#"{"allow":true,"targets":[{"host":"h"}],"tmux":"x"}"#).unwrap();
        write_allow(&p, false).unwrap();
        let v: Value = serde_json::from_str(&std::fs::read_to_string(&p).unwrap()).unwrap();
        assert_eq!(v, json!({"allow":false,"targets":[{"host":"h"}],"tmux":"x"}));
        // Missing, or not an object: just `allow`.
        let q = d.path().join("new.json");
        write_allow(&q, true).unwrap();
        assert_eq!(serde_json::from_str::<Value>(&std::fs::read_to_string(&q).unwrap()).unwrap(), json!({"allow":true}));
        std::fs::write(&q, "[1]").unwrap();
        write_allow(&q, false).unwrap();
        assert_eq!(serde_json::from_str::<Value>(&std::fs::read_to_string(&q).unwrap()).unwrap(), json!({"allow":false}));
    }

    #[test]
    fn open_term_logs_only_the_app() {
        let op = Op::OpenTerm { shell: Some("zsh".into()), from: None, app: "iTerm".into() };
        assert_eq!(log_fields(&op), json!({"op":"open_term","app":"iTerm"}));
    }

    #[test]
    fn open_term_logs_from_kind() {
        let op = Op::OpenTerm { shell: None, from: Some("last".into()), app: "iTerm".into() };
        assert_eq!(log_fields(&op), json!({"op":"open_term","app":"iTerm","from":"last"}));
        let op = Op::OpenTerm { shell: None, from: Some("term:pty:secret".into()), app: "iTerm".into() };
        let f = log_fields(&op);
        assert_eq!(f, json!({"op":"open_term","app":"iTerm","from":"term"}));
        assert!(!f.to_string().contains("secret"));
    }

    #[test]
    fn restore_terms_forwarded_and_logged_without_keys_values() {
        let op = Op::RestoreTerms { keys: vec!["key-secret".into()], app: Some("Terminal".into()) };
        let f = log_fields(&op);
        assert_eq!(f, json!({"op":"restore_terms","keys":1}));
        assert!(!f.to_string().contains("secret"));
        let op = Op::ForgetTerms { keys: vec!["a-secret".into(), "b".into()] };
        let f = log_fields(&op);
        assert_eq!(f, json!({"op":"forget_terms","keys":2}));
        assert!(!f.to_string().contains("secret"));
    }

    #[test]
    fn end_term_log_has_no_term() {
        let op = Op::EndTerm { term: "term:pty:secret".into() };
        let f = log_fields(&op);
        assert_eq!(f, json!({"op":"end_term"}));
        assert!(!f.to_string().contains("secret"));
    }

    #[test]
    fn rename_term_logs_neither_the_term_nor_the_name() {
        let op = Op::RenameTerm { term: "term:pty:secret".into(), name: "secret-name".into() };
        assert_eq!(log_fields(&op), json!({"op":"rename_term"}));
    }
}
