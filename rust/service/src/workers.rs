//! `rapp-host` workers (spec §3): one per app, started on demand, stdin closed after
//! `idle` without sessions, forgotten when they exit (never restarted).

use crate::state::{Peer, State};
use anyhow::{anyhow, bail, Context, Result};
use rapp_net::crypto::random_hex;
use rapp_net::log::{pipe_lines, Lvl};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::path::PathBuf;
use std::process::Stdio;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::Command;
use tokio::sync::mpsc::UnboundedSender;

const START_WAIT: Duration = Duration::from_secs(15);
const RUN_WAIT: Duration = Duration::from_secs(15);
/// At most one `input_blocked` access-log line per session in this time (R11).
const BLOCKED_EVERY: Duration = Duration::from_secs(60);

struct Worker {
    gen: u64,
    port: u16,
    token: String,
    /// Lines for the worker's stdin (one task owns it). Dropping it closes stdin once what is
    /// queued is written, which makes the worker exit.
    stdin: Option<UnboundedSender<String>>,
    sessions: usize,
    idle_since: Option<Instant>,
}

pub struct Workers {
    idle: Duration,
    map: Mutex<HashMap<String, Worker>>,
    next_gen: Mutex<u64>,
    spawn_lock: tokio::sync::Mutex<()>,
}

impl Workers {
    pub fn new(idle: Duration) -> Workers {
        Workers { idle, map: Mutex::default(), next_gen: Mutex::new(0), spawn_lock: Default::default() }
    }

    /// Closes every worker's stdin.
    pub fn close_all(&self) {
        for w in self.map.lock().unwrap().values_mut() {
            w.stdin = None;
        }
    }
}

/// Writes one line to `app`'s worker stdin. False when there is no worker or its stdin is closed.
pub fn tell(state: &State, app: &str, line: String) -> bool {
    let map = state.workers.map.lock().unwrap();
    map.get(app).and_then(|w| w.stdin.as_ref()).is_some_and(|tx| tx.send(line + "\n").is_ok())
}

/// `app`'s session had input: every other app with a live session yields to its device (R1),
/// unless both sessions are the same device (R9: both named, same name).
fn tell_others(state: &State, app: &str) {
    let from = state.live_session(app).and_then(|(_, p)| p.name);
    let line = json!({"cmd": "yield", "by": from.as_deref().unwrap_or("")}).to_string();
    let same = |p: &Peer| from.is_some() && p.name == from;
    for (other, peer) in state.live_sessions() {
        if other != app && !same(&peer) {
            tell(state, &other, line.clone());
        }
    }
}

fn host_bin(state: &State) -> Result<PathBuf> {
    rapp_net::bins::find("rapp-host", state.bin_dir.as_deref()).ok_or_else(|| anyhow!("rapp-host not found"))
}

/// Runs `rapp-host <args> --json` and returns its first non-event JSON line.
async fn run_json(state: &State, args: &[&str]) -> Result<Value> {
    let out = Command::new(host_bin(state)?).args(args).arg("--json").stdin(Stdio::null()).kill_on_drop(true).output();
    let out = tokio::time::timeout(RUN_WAIT, out).await.map_err(|_| anyhow!("rapp-host {} timed out", args[0]))??;
    String::from_utf8_lossy(&out.stdout)
        .lines()
        .filter_map(|l| serde_json::from_str::<Value>(l).ok())
        .find(|v| v.is_object() && v.get("event").is_none())
        .ok_or_else(|| anyhow!("rapp-host {} gave no result", args[0]))
}

fn permissions(v: &Value) -> Value {
    json!({"screen_recording": v["screen_recording"] == true, "accessibility": v["accessibility"] == true})
}

/// `rapp-host check`; with `prompt`, macOS is asked for what is missing, so rapp shows up in System Settings.
/// None when the check itself failed (that says nothing about the permissions).
pub async fn check(state: &State, prompt: bool) -> Option<Value> {
    let args: &[&str] = if prompt { &["check", "--prompt"] } else { &["check"] };
    match run_json(state, args).await {
        Ok(v) => Some(permissions(&v)),
        Err(e) => {
            state.log.msg(Lvl::Warn, format!("{e:#}"));
            None
        }
    }
}

/// Checks again and stores the result; a failed check keeps the last known one.
pub async fn refresh_permissions(state: &State, prompt: bool) -> Value {
    if let Some(v) = check(state, prompt).await {
        state.set_permissions(v);
    }
    state.permissions.lock().unwrap().clone()
}

/// Resets rapp's own TCC records (never another app's: only `BUNDLE_ID`), then checks again with a
/// prompt so rapp shows up in System Settings. A `_reset` is true only if tccutil exited 0 and the
/// permission really reads as missing afterwards.
pub async fn reset_permissions(state: &State) -> Value {
    let mut ran = [false; 2];
    for (i, service) in ["ScreenCapture", "Accessibility"].into_iter().enumerate() {
        let args = ["reset", service, rapp_update::BUNDLE_ID].map(String::from);
        let runner = state.runner.clone();
        let out = tokio::task::spawn_blocking(move || runner.run(rapp_update::runner::TCCUTIL, &args)).await;
        ran[i] = matches!(out, Ok(Ok(o)) if o.code == 0);
    }
    state.log.event(Lvl::Info, "permissions_reset", json!({}));
    let perms = refresh_permissions(state, true).await;
    json!({
        "screen_recording_reset": ran[0] && perms["screen_recording"] != true,
        "accessibility_reset": ran[1] && perms["accessibility"] != true,
        "permissions": perms,
    })
}

/// The shareable apps, plus A's permissions when the host reports them (it stores those too).
pub async fn list_apps(state: &State) -> Result<(Value, Option<Value>)> {
    let v = run_json(state, &["list-apps"]).await?;
    let perms = v.get("permissions").filter(|p| p.is_object()).map(permissions);
    if let Some(p) = &perms {
        state.set_permissions(p.clone());
    }
    Ok((v["apps"].clone(), perms))
}

/// Port and token of the worker for `app`, starting one if needed; counts a session.
pub async fn start_session(state: &Arc<State>, app: &str) -> Result<(u16, String)> {
    let w = &state.workers;
    let _guard = w.spawn_lock.lock().await;
    if let Some(wk) = w.map.lock().unwrap().get_mut(app).filter(|wk| wk.stdin.is_some()) {
        wk.sessions += 1;
        wk.idle_since = None;
        return Ok((wk.port, wk.token.clone()));
    }
    let gen = {
        let mut g = w.next_gen.lock().unwrap();
        *g += 1;
        *g
    };
    let (port, token, stdin) = spawn(state, app, gen).await?;
    let worker = Worker { gen, port, token: token.clone(), stdin: Some(stdin), sessions: 1, idle_since: None };
    w.map.lock().unwrap().insert(app.to_string(), worker);
    Ok((port, token))
}

pub fn end_session(state: &Arc<State>, app: &str) {
    let mut map = state.workers.map.lock().unwrap();
    let Some(wk) = map.get_mut(app) else { return };
    wk.sessions = wk.sessions.saturating_sub(1);
    if wk.sessions == 0 {
        wk.idle_since = Some(Instant::now());
        let (state, app, gen) = (state.clone(), app.to_string(), wk.gen);
        tokio::spawn(async move {
            tokio::time::sleep(state.workers.idle).await;
            let mut map = state.workers.map.lock().unwrap();
            if let Some(wk) = map.get_mut(&app).filter(|wk| wk.gen == gen) {
                if wk.idle_since.is_some_and(|t| t.elapsed() >= state.workers.idle) {
                    wk.stdin = None;
                }
            }
        });
    }
}

async fn spawn(state: &Arc<State>, app: &str, gen: u64) -> Result<(u16, String, UnboundedSender<String>)> {
    let token = random_hex(16);
    let mut child = Command::new(host_bin(state)?)
        .args(["serve", "--app", app, "--bind", "127.0.0.1", "--port", "0", "--token-env", "RAPP_TOKEN", "--json"])
        .env("RAPP_TOKEN", &token)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true)
        .spawn()
        .context("start rapp-host")?;
    let mut stdin = child.stdin.take().expect("piped stdin");
    let stderr = child.stderr.take().expect("piped stderr");
    pipe_lines(state.log.clone(), stderr, json!({"src": "host", "app": app}));
    let mut lines = BufReader::new(child.stdout.take().expect("piped stdout")).lines();
    let port = tokio::time::timeout(START_WAIT, async {
        while let Some(l) = lines.next_line().await? {
            let v: Value = serde_json::from_str(&l).unwrap_or_default();
            match v["event"].as_str() {
                Some("listening") => return v["port"].as_u64().map(|p| p as u16).context("listening without port"),
                Some("exit") => bail!("rapp-host exited: {}", v["reason"].as_str().unwrap_or("?")),
                _ => {}
            }
        }
        bail!("rapp-host exited before listening")
    })
    .await
    .map_err(|_| anyhow!("rapp-host did not start"))??;

    // One task owns the worker's stdin (R16): when every sender is gone it drains what is
    // queued, then drops stdin, so the worker sees EOF.
    let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel::<String>();
    tokio::spawn(async move {
        while let Some(l) = rx.recv().await {
            if stdin.write_all(l.as_bytes()).await.is_err() {
                break;
            }
        }
    });

    let (state, app) = (state.clone(), app.to_string());
    tokio::spawn(async move {
        let mut said = None;
        let mut blocked_logged: HashMap<u64, Instant> = HashMap::new();
        while let Ok(Some(l)) = lines.next_line().await {
            let v: Value = serde_json::from_str(&l).unwrap_or_default();
            match v["event"].as_str() {
                Some("exit") => said = Some(v),
                Some(ev @ ("transfer" | "rejected")) => transcribe(&state, &app, ev, &v),
                Some("input") => tell_others(&state, &app),
                Some("input_blocked") => log_blocked(&state, &app, &v, &mut blocked_logged),
                _ => {}
            }
        }
        let status = child.wait().await.ok().and_then(|s| s.code());
        let code = said.as_ref().and_then(|v| v["code"].as_i64()).or(status.map(i64::from));
        let reason = said.as_ref().and_then(|v| v["reason"].as_str()).unwrap_or("exited").to_string();
        let lvl = if code == Some(0) { Lvl::Info } else { Lvl::Warn };
        state.log.event(lvl, "worker_exit", json!({"app": app, "code": code, "reason": reason}));
        let mut map = state.workers.map.lock().unwrap();
        if map.get(&app).is_some_and(|w| w.gen == gen) {
            map.remove(&app);
        }
    });
    Ok((port, token, tx))
}

/// `input_blocked {app, sid, by}` for the app's live session, at most once a minute per session
/// (R11). Nothing else from the event is copied.
fn log_blocked(state: &State, app: &str, v: &Value, logged: &mut HashMap<u64, Instant>) {
    let Some((sid, _)) = state.live_session(app) else { return };
    let now = Instant::now();
    logged.retain(|_, t| now.duration_since(*t) < BLOCKED_EVERY);
    if logged.contains_key(&sid) {
        return;
    }
    logged.insert(sid, now);
    let by = v["by"].as_str().map(rapp_net::log::clean_name).unwrap_or_default();
    state.log.event(Lvl::Info, "input_blocked", json!({"app": app, "sid": sid, "by": by}));
}

/// A worker's `transfer` / `rejected` stdout event as a log line, tagged with the app's current session.
/// Only the named fields are copied, so nothing the host adds later can carry content into the log.
fn transcribe(state: &State, app: &str, ev: &str, v: &Value) {
    let mut fields = json!({"app": app});
    for k in ["dir", "kind", "bytes", "name", "reason"] {
        if let Some(x) = v.get(k) {
            fields[k] = x.clone();
        }
    }
    if let Some(sid) = state.session_for(app) {
        fields["sid"] = json!(sid);
    }
    let lvl = if ev == "rejected" { Lvl::Warn } else { Lvl::Info };
    state.log.event(lvl, ev, fields);
}
