//! `rapp-host` workers (spec §3): one per app, started on demand, stdin closed after
//! `idle` without sessions, forgotten when they exit (never restarted).

use crate::state::State;
use anyhow::{anyhow, bail, Context, Result};
use rapp_net::crypto::random_hex;
use serde_json::{json, Value};
use std::collections::HashMap;
use std::path::PathBuf;
use std::process::Stdio;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::process::{ChildStdin, Command};

const START_WAIT: Duration = Duration::from_secs(15);
const RUN_WAIT: Duration = Duration::from_secs(15);

struct Worker {
    gen: u64,
    port: u16,
    token: String,
    /// Dropping it closes the worker's stdin, which makes it exit.
    stdin: Option<ChildStdin>,
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
            eprintln!("rapp-service: {e:#}");
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

async fn spawn(state: &Arc<State>, app: &str, gen: u64) -> Result<(u16, String, ChildStdin)> {
    let token = random_hex(16);
    let mut child = Command::new(host_bin(state)?)
        .args(["serve", "--app", app, "--bind", "127.0.0.1", "--port", "0", "--token-env", "RAPP_TOKEN", "--json"])
        .env("RAPP_TOKEN", &token)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .kill_on_drop(true)
        .spawn()
        .context("start rapp-host")?;
    let stdin = child.stdin.take().expect("piped stdin");
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

    let (state, app) = (state.clone(), app.to_string());
    tokio::spawn(async move {
        while let Ok(Some(_)) = lines.next_line().await {}
        let _ = child.wait().await;
        let mut map = state.workers.map.lock().unwrap();
        if map.get(&app).is_some_and(|w| w.gen == gen) {
            map.remove(&app);
        }
    });
    Ok((port, token, stdin))
}
