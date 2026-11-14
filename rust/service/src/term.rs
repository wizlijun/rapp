//! Terminal sessions as device requests (spec §6, §8, §9): `list_terms`, `watch_terms` and `new_term` are asked of
//! the device's one `rapp-term serve` (`workers::TERM`); `add_term_target` / `remove_term_target` edit `term.json`.
//! While terminal sessions are off, or `term.json` cannot be used, every request is refused and no worker starts.

use crate::peer::log_request;
use crate::state::{Peer, State};
use crate::workers::{self, TERM};
use anyhow::{anyhow, Context, Result};
use rapp_net::line::{err, ok, write_json};
use rapp_net::log::{clean_name, Lvl};
use rapp_net::msg::Op;
use rapp_term::config::{check_target, Target, TermConfig, INVALID, MAX_TARGETS, OFF};
use serde_json::{json, Value};
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt, BufReader, Lines};
use tokio::net::TcpStream;

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
            Op::NewTerm { host, name, command, cols, rows } => {
                let mut req = json!({"op": "new", "host": host, "command": command, "cols": cols, "rows": rows});
                if let Some(name) = name {
                    req["name"] = json!(name);
                }
                answer(ask(state, &req).await)
            }
            Op::AddTermTarget { name, target, tmux } => targets(edit(state, |c| add(c, Target { name, target, tmux }))),
            Op::RemoveTermTarget { name } => targets(edit(state, |c| remove(c, &name))),
            _ => err("unknown op"),
        },
    };
    log_request(state, peer, what, &r);
    finish(s, &r).await
}

/// The `request` line's fields: never a command, a target string or anything from `term.json`.
fn log_fields(op: &Op) -> Value {
    match op {
        Op::ListTerms => json!({"op": "list_terms"}),
        Op::WatchTerms => json!({"op": "watch_terms"}),
        Op::NewTerm { host, .. } => json!({"op": "new_term", "host": host.as_deref().map(clean_name)}),
        Op::AddTermTarget { name, .. } => json!({"op": "add_term_target", "name": clean_name(name)}),
        Op::RemoveTermTarget { name } => json!({"op": "remove_term_target", "name": clean_name(name)}),
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

/// A one-line request (`list`, `new`) to the worker.
async fn ask(state: &Arc<State>, req: &Value) -> Result<Value> {
    let (port, token) = workers::start_session(state, TERM).await?;
    let r = first(port, &token, req).await.map(|(_, v)| v);
    workers::end_session(state, TERM);
    r
}

/// The worker's watch, passed on to B. The worker's session count stays up until the watch ends, so it is not
/// stopped as idle meanwhile.
async fn watch<S: AsyncRead + AsyncWrite + Unpin + Send>(
    state: &Arc<State>,
    s: &mut S,
    peer: &Peer,
    what: Value,
) -> Result<()> {
    let (port, token) = match workers::start_session(state, TERM).await {
        Ok(w) => w,
        Err(e) => {
            let r = err(&format!("{e:#}"));
            log_request(state, peer, what, &r);
            return finish(s, &r).await;
        }
    };
    let r = follow(state, s, peer, what, port, &token).await;
    workers::end_session(state, TERM);
    r
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

fn targets(r: Result<Vec<Target>, String>) -> Value {
    match r {
        Ok(t) => ok(json!({"targets": t})),
        Err(e) => err(&e),
    }
}

/// Applies `change` to `term.json` under `EDIT` and returns the targets; a file that cannot be used, or a change
/// that is refused, leaves it as it was.
fn edit(state: &State, change: impl FnOnce(&mut TermConfig) -> Result<(), String>) -> Result<Vec<Target>, String> {
    let _held = EDIT.lock().unwrap_or_else(|e| e.into_inner());
    let mut c = allowed(state)?;
    change(&mut c)?;
    rapp_net::config::write_json(&path(state), &c).map_err(|e| {
        state.log.msg(Lvl::Warn, format!("term.json: {e:#}"));
        "could not save term.json".to_string()
    })?;
    Ok(c.targets)
}

fn add(c: &mut TermConfig, t: Target) -> Result<(), String> {
    check_target(&t)?;
    if c.target(&t.name).is_some() {
        return Err("name is taken".into());
    }
    if c.targets.len() >= MAX_TARGETS {
        return Err("too many targets".into());
    }
    c.targets.push(t);
    Ok(())
}

fn remove(c: &mut TermConfig, name: &str) -> Result<(), String> {
    let before = c.targets.len();
    c.targets.retain(|t| t.name != name);
    if c.targets.len() == before {
        return Err("unknown target".into());
    }
    Ok(())
}
