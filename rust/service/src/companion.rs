//! Companion services: programs `rapp-service` runs next to itself when `services.json` turns
//! them on. For now there is one, the state service (`rapp-state`).
//!
//! On: the program is started (`kill_on_drop`), asked `GET /v1/health` every 200 ms for at most
//! 5 s, then its port is shared (kind `"state"`) and it becomes this device's own sink. A start
//! that fails, or a crash later, is tried again after `outbox::backoff`; a run of 60 s resets it.
//! While it is tried again it stays this device's sink, so the outboxes wait and resend.
//! Off: the program is stopped, it is no sink any more, and its share is taken back: removed when
//! the companion made it, only unmarked when the user had shared the port (`take_back`).
//! `rapp-service` never links `rapp-state`: it only starts the program.

use crate::outbox::send;
use crate::sharing::{self, Allow, By};
use crate::sink;
use crate::state::State;
use rapp_net::line::err;
use rapp_net::log::Lvl;
use serde::{Deserialize, Serialize};
use serde_json::{json, Map, Value};
use std::collections::HashMap;
use std::path::Path;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt};
use tokio::process::{Child, Command};
use tokio::sync::{watch, Notify};
use tokio::task::JoinHandle;

/// A program rApp can run beside itself.
pub struct Companion {
    /// Its key in `services.json` and the IPC `name`.
    pub name: &'static str,
    pub program: &'static str,
    /// The port it listens on unless `services.json` says another.
    pub port: u16,
    /// The `kind` its share carries.
    pub kind: &'static str,
    /// The note of its share, unless the port was shared already.
    pub note: &'static str,
}

pub const TABLE: &[Companion] = &[Companion { name: "state", program: "rapp-state", port: 8102, kind: "state", note: "状态服务" }];

/// In the device's `local/` (its home).
const FILE: &str = "services.json";
/// The health check is tried this often after a start ...
const PROBE_EVERY: Duration = Duration::from_millis(200);
/// ... for at most this long.
const READY_WAIT: Duration = Duration::from_secs(5);
/// One health check (connect and answer).
const PROBE_WAIT: Duration = Duration::from_millis(500);
/// A program that ends this soon after its start, saying its address is in use, found the port taken.
const QUICK_EXIT: Duration = Duration::from_secs(1);
/// A run this long is stable: the backoff starts over.
const STABLE: Duration = Duration::from_secs(60);
/// `stored` asks the running service this long at most.
const STORED_WAIT: Duration = Duration::from_secs(3);
/// The most of `/v1/state` read for `stored`.
const STORED_MAX: usize = 8 << 20;
/// `set` waits this long at most for a start to succeed or fail.
const SET_WAIT: Duration = Duration::from_secs(7);

/// One entry of `services.json`. Only `on` must be there.
#[derive(Serialize, Deserialize, Default, Clone, Debug, PartialEq)]
pub struct ServiceCfg {
    pub on: bool,
    pub port: Option<u16>,
    pub store: Option<String>,
    pub keep_days: Option<u64>,
    pub keep_events: Option<usize>,
}

/// The command line of `rapp-state` for `c`: the data under `<home>/state` unless the store is
/// `"memory"`.
pub fn args(c: &ServiceCfg, home: &Path) -> Vec<String> {
    let mut a = vec!["--port".to_string(), c.port.unwrap_or(TABLE[0].port).to_string()];
    if c.store.as_deref() != Some("memory") {
        a.extend(["--data".to_string(), home.join("state").to_string_lossy().into_owned()]);
    }
    a.extend(["--keep-days".to_string(), c.keep_days.unwrap_or(7).to_string()]);
    a.extend(["--keep-events".to_string(), c.keep_events.unwrap_or(1000).to_string()]);
    a
}

/// What a companion is doing.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
enum Phase {
    #[default]
    Off,
    /// Started, not answering yet.
    Starting,
    /// Answering its health check.
    Running,
    /// Failed or ended; tried again after the backoff.
    Waiting,
}

/// The supervisor of a companion that is on.
struct Run {
    task: JoinHandle<()>,
    stop: Arc<Notify>,
    retry: Arc<Notify>,
}

#[derive(Default)]
struct Slot {
    on: bool,
    /// The entry it was (or will be) started with.
    cfg: ServiceCfg,
    phase: Phase,
    /// Why the last start failed (Chinese, for the user).
    error: Option<String>,
    /// The running program's pid.
    pid: Option<u32>,
    run: Option<Run>,
}

/// The companions of this service.
pub struct Companions {
    slots: Mutex<HashMap<&'static str, Slot>>,
    /// Bumped on every phase change.
    changed: watch::Sender<u64>,
    /// One `set` at a time.
    setting: tokio::sync::Mutex<()>,
}

impl Default for Companions {
    fn default() -> Self {
        Self::new()
    }
}

impl Companions {
    pub fn new() -> Companions {
        Companions { slots: Mutex::new(HashMap::new()), changed: watch::channel(0).0, setting: tokio::sync::Mutex::new(()) }
    }

    fn with<R>(&self, name: &'static str, f: impl FnOnce(&mut Slot) -> R) -> R {
        f(self.slots.lock().unwrap().entry(name).or_default())
    }

    fn bump(&self) {
        self.changed.send_modify(|n| *n += 1);
    }

    /// Stops every companion now, without waiting: for `Service::stop`, after which the process
    /// may exit at once (a drop would come too late to end the programs).
    pub fn stop_all(&self) {
        for slot in self.slots.lock().unwrap().values_mut() {
            if let Some(run) = slot.run.take() {
                run.task.abort();
            }
            #[cfg(unix)]
            if let Some(pid) = slot.pid.take().and_then(|p| i32::try_from(p).ok()) {
                // SAFETY: kill(2) on a pid this service started; no memory is involved.
                unsafe {
                    libc::kill(pid, libc::SIGTERM);
                }
            }
            slot.phase = Phase::Off;
        }
    }
}

fn find(name: &str) -> Option<&'static Companion> {
    TABLE.iter().find(|c| c.name == name)
}

/// `services.json` as a map: an empty one when there is none. Err (why, for the log) when it is
/// not a JSON object or an entry of [`TABLE`] in it is not a [`ServiceCfg`].
fn read_file(home: &Path) -> Result<Map<String, Value>, Value> {
    let bytes = match std::fs::read(home.join(FILE)) {
        Ok(b) => b,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(Map::new()),
        Err(e) => return Err(json!({"why": "read", "error": e.kind().to_string()})),
    };
    let map = match serde_json::from_slice::<Value>(&bytes) {
        Ok(Value::Object(m)) => m,
        Ok(_) => return Err(json!({"why": "not an object"})),
        Err(e) => return Err(json!({"why": "json", "line": e.line(), "column": e.column()})),
    };
    for c in TABLE {
        if let Some(v) = map.get(c.name) {
            if let Err(e) = serde_json::from_value::<ServiceCfg>(v.clone()) {
                return Err(json!({"why": "entry", "name": c.name, "error": e.to_string()}));
            }
        }
    }
    Ok(map)
}

/// The entry of `c` in a valid map: off when there is none.
fn cfg_in(map: &Map<String, Value>, c: &Companion) -> ServiceCfg {
    map.get(c.name).and_then(|v| serde_json::from_value(v.clone()).ok()).unwrap_or_default()
}

/// `read_file`, a broken file logged and taken as everything off.
fn load(state: &State) -> Option<Map<String, Value>> {
    match read_file(&state.home) {
        Ok(m) => Some(m),
        Err(why) => {
            state.log.event(Lvl::Warn, "services_json_invalid", why);
            None
        }
    }
}

/// `map` with `name` turned `on`, every other field and entry kept; a new entry when there is none
/// (or it is not an object).
fn turned(mut map: Map<String, Value>, name: &str, on: bool) -> Map<String, Value> {
    match map.get_mut(name) {
        Some(Value::Object(e)) => {
            e.insert("on".into(), json!(on));
        }
        _ => {
            map.insert(name.into(), json!({"on": on}));
        }
    }
    map
}

/// At start: every companion `services.json` turns on is started.
pub fn spawn(state: Arc<State>) -> JoinHandle<()> {
    let map = load(&state).unwrap_or_default();
    for c in TABLE {
        let cfg = cfg_in(&map, c);
        let on = cfg.on;
        state.companions.with(c.name, |s| {
            s.cfg = cfg;
            s.on = on;
        });
        if on {
            start(&state, c);
        }
    }
    // The supervisors are their own tasks (`set` starts and stops them); nothing is left to do here.
    tokio::spawn(async {})
}

/// Starts the supervisor of `c` (its slot must be on).
fn start(state: &Arc<State>, c: &'static Companion) {
    let (stop, retry) = (Arc::new(Notify::new()), Arc::new(Notify::new()));
    let cfg = state.companions.with(c.name, |s| s.cfg.clone());
    let task = tokio::spawn(supervise(state.clone(), c, cfg, stop.clone(), retry.clone()));
    state.companions.with(c.name, |s| {
        s.phase = Phase::Starting;
        s.run = Some(Run { task, stop, retry });
    });
    state.companions.bump();
}

/// The supervisor of `c` says what it is doing. Once the slot is off (`set` turned it off while
/// the supervisor was still ending) it stays `Off`, without an error.
fn phase(state: &State, c: &'static Companion, phase: Phase, error: Option<String>) {
    state.companions.with(c.name, |s| {
        if !s.on {
            return;
        }
        s.phase = phase;
        s.error = error;
        if phase != Phase::Running && phase != Phase::Starting {
            s.pid = None;
        }
    });
    state.companions.bump();
    state.notify();
}

/// How one start ended.
enum Outcome {
    /// It never answered: (why for the log, reason for the user).
    Failed(&'static str, String),
    /// It answered, then ended after running this long.
    Ended(Duration),
}

/// Keeps `c` running until stopped: a failed start or a crash is tried again after the backoff
/// (at once on `retry`).
async fn supervise(state: Arc<State>, c: &'static Companion, cfg: ServiceCfg, stop: Arc<Notify>, retry: Arc<Notify>) {
    let mut fails = 0u32;
    let mut child: Option<Child> = None;
    loop {
        phase(&state, c, Phase::Starting, None);
        let outcome = tokio::select! {
            o = run_once(&state, c, &cfg, &mut child) => Some(o),
            _ = stop.notified() => None,
        };
        let Some(outcome) = outcome else { break };
        match outcome {
            Outcome::Failed(why, say) => {
                state.log.event(Lvl::Warn, "companion_failed", json!({"name": c.name, "why": why}));
                // Not answering: no share says it is here (one left by an earlier run neither).
                // `ready` shares it again once it answers. A crash after it ran keeps its share.
                take_back(&state, c, cfg.port.unwrap_or(c.port));
                fails += 1;
                phase(&state, c, Phase::Waiting, Some(say));
            }
            Outcome::Ended(ran) => {
                if ran >= STABLE {
                    fails = 0;
                }
                fails += 1;
                phase(&state, c, Phase::Waiting, None);
            }
        }
        tokio::select! {
            _ = tokio::time::sleep(crate::outbox::backoff(fails)) => {}
            _ = retry.notified() => {}
            _ = stop.notified() => break,
        }
    }
    // Stopped for good (`set` turned it off): the program (if one runs) ends now, not at some
    // drop later, and it is no sink any more.
    if let Some(mut ch) = child.take() {
        let _ = ch.kill().await;
        let code = ch.wait().await.ok().and_then(|s| s.code());
        state.log.event(Lvl::Info, "companion_exit", json!({"name": c.name, "code": code}));
    }
    sink::set_local(&state, None);
}

/// One start of `c`: the program, its health check, then (once it answers) its share and the
/// local sink, until it ends. `child` holds the program while it runs, so a stop can end it.
async fn run_once(state: &Arc<State>, c: &'static Companion, cfg: &ServiceCfg, child: &mut Option<Child>) -> Outcome {
    let port = cfg.port.unwrap_or(c.port);
    let not_found = || Outcome::Failed("not found", format!("找不到 {}", c.program));
    let Some(bin) = rapp_net::bins::find(c.program, state.bin_dir.as_deref()) else { return not_found() };
    let mut cmd = Command::new(bin);
    cmd.args(args(cfg, &state.home))
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::piped())
        .kill_on_drop(true);
    let ch = match cmd.spawn() {
        Ok(ch) => child.insert(ch),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return not_found(),
        Err(_) => return Outcome::Failed("spawn", "没有起来".into()),
    };
    let pid = ch.id();
    state.companions.with(c.name, |s| s.pid = pid);
    state.log.event(Lvl::Info, "companion_start", json!({"name": c.name, "port": port, "pid": pid}));
    let last = Arc::new(Mutex::new(String::new()));
    let reader = ch.stderr.take().map(|err| tokio::spawn(keep_stderr(state.log_dir.join(format!("{}.log", c.program)), err, last.clone())));

    // Ready: the health check answers AND this program still runs `QUICK_EXIT` after its start.
    // Another `rapp-state` already on the port (a foreign one, or an orphan of an earlier run)
    // answers too, while this one ends at once with "address in use": that is not ours.
    let started = tokio::time::Instant::now();
    let (grace, deadline) = (started + QUICK_EXIT, started + READY_WAIT);
    let mut answered = false;
    loop {
        if answered && tokio::time::Instant::now() >= grace {
            break;
        }
        if tokio::time::Instant::now() >= deadline {
            if let Some(mut ch) = child.take() {
                let _ = ch.kill().await;
                let code = ch.wait().await.ok().and_then(|s| s.code());
                state.log.event(Lvl::Info, "companion_exit", json!({"name": c.name, "code": code}));
            }
            return Outcome::Failed("not ready", "没有起来".into());
        }
        let exited = tokio::select! {
            status = ch.wait() => Some(status),
            a = probe(port, answered, grace) => {
                answered = a;
                None
            }
        };
        let Some(status) = exited else { continue };
        // Measured when it ended, not when that was noticed.
        let quick = started.elapsed() < QUICK_EXIT;
        if let Some(r) = reader {
            let _ = tokio::time::timeout(Duration::from_millis(500), r).await;
        }
        *child = None;
        state.log.event(Lvl::Info, "companion_exit", json!({"name": c.name, "code": status.ok().and_then(|s| s.code())}));
        let line = last.lock().unwrap().clone();
        if quick && (line.contains("Address already in use") || line.contains("AddrInUse")) {
            return Outcome::Failed("port taken", format!("端口 {port} 被占用"));
        }
        return Outcome::Failed("exited", "没有起来".into());
    }

    ready(state, c, port);
    let up = Instant::now();
    phase(state, c, Phase::Running, None);
    let status = match child.as_mut() {
        Some(ch) => ch.wait().await.ok(),
        None => None,
    };
    *child = None;
    state.log.event(Lvl::Info, "companion_exit", json!({"name": c.name, "code": status.and_then(|s| s.code())}));
    // Its share and the local sink stay: the supervisor starts it again on the same port. Every
    // outbox meanwhile finds it down, keeps its cache and sends it once it answers again. Telling
    // the devices it is gone would make each of them drop its cache.
    Outcome::Ended(up.elapsed())
}

/// `c` answers on `port`: it is shared (unless the port was shared already: that note stays),
/// marked as kind `c.kind`, and made this device's own sink.
fn ready(state: &Arc<State>, c: &'static Companion, port: u16) {
    if state.shares.get(port).is_none() {
        let req = json!({"ports": [port], "note": c.note, "proto": "http"});
        if let Err(e) = sharing::share(state, &req, Allow::Names, &By::Local) {
            state.log.event(Lvl::Warn, "companion_share_failed", json!({"name": c.name, "port": port, "error": e}));
        }
    }
    match state.shares.set_kind(port, Some(c.kind)) {
        Ok(true) => sharing::sync_own(state),
        Ok(false) => {}
        Err(e) => state.log.event(Lvl::Warn, "companion_share_failed", json!({"name": c.name, "port": port, "error": format!("{e:#}")})),
    }
    sink::set_local(state, Some(port));
    state.log.event(Lvl::Info, "companion_ready", json!({"name": c.name}));
}

/// Takes back what `ready` did to the share of `port` (one of kind `c.kind`): the share is removed
/// when the companion made it (its note is `c.note`); a share the user made of that port stays,
/// an ordinary one again. Any other share is not touched.
fn take_back(state: &State, c: &'static Companion, port: u16) {
    let Some(share) = state.shares.get(port).filter(|s| s.kind.as_deref() == Some(c.kind)) else { return };
    if share.note == c.note {
        if let Err(e) = sharing::unshare(state, &json!(port), &By::Local) {
            state.log.event(Lvl::Warn, "companion_unshare_failed", json!({"name": c.name, "port": port, "error": e}));
        }
        return;
    }
    match state.shares.set_kind(port, None) {
        Ok(true) => sharing::sync_own(state),
        Ok(false) => {}
        Err(e) => state.log.event(Lvl::Warn, "companion_unshare_failed", json!({"name": c.name, "port": port, "error": format!("{e:#}")})),
    }
}

/// Appends every stderr line of the program to `path`; `last` keeps the latest one.
async fn keep_stderr(path: std::path::PathBuf, err: tokio::process::ChildStderr, last: Arc<Mutex<String>>) {
    let mut file = tokio::fs::OpenOptions::new().create(true).append(true).open(&path).await.ok();
    let mut lines = tokio::io::BufReader::new(err).lines();
    while let Ok(Some(line)) = lines.next_line().await {
        if let Some(f) = file.as_mut() {
            let _ = f.write_all(format!("{line}\n").as_bytes()).await;
        }
        *last.lock().unwrap() = line;
    }
}

/// A connection to the state service on this device's `port`, past its health check.
async fn conn(port: u16) -> Option<send::Conn> {
    let go = async {
        let tcp = tokio::net::TcpStream::connect(("127.0.0.1", port)).await.ok()?;
        send::connect(Box::new(tcp)).await.ok()
    };
    tokio::time::timeout(PROBE_WAIT, go).await.ok().flatten()
}

async fn healthy(port: u16) -> bool {
    conn(port).await.is_some()
}

/// One step of the start: until the service has `answered`, one health check (then the pause
/// before the next when it did not answer); after, the rest of the grace period. Whether it has
/// answered now.
async fn probe(port: u16, answered: bool, grace: tokio::time::Instant) -> bool {
    if answered {
        tokio::time::sleep_until(grace).await;
        return true;
    }
    if healthy(port).await {
        return true;
    }
    tokio::time::sleep(PROBE_EVERY).await;
    false
}

/// What the running service holds: counts from `GET /v1/state`, None when it does not answer.
async fn stored(port: u16) -> Option<Value> {
    let ask = async {
        let mut c = conn(port).await?;
        let (status, body) = c.get("/v1/state", STORED_MAX).await.ok()?;
        (status == 200).then(|| serde_json::from_slice::<Value>(&body).ok()).flatten()
    };
    let v = tokio::time::timeout(STORED_WAIT, ask).await.ok().flatten()?;
    Some(counts(&v))
}

/// `{"devices","sessions","queued","last"}` of a `/v1/state` reply; `last` is the device heard from
/// last (its name, else its ID, else its fingerprint) and when.
fn counts(v: &Value) -> Value {
    let devices = v["devices"].as_array().map(Vec::as_slice).unwrap_or_default();
    let sessions: usize = devices.iter().map(|d| d["sessions"].as_array().map_or(0, Vec::len)).sum();
    let last = devices.iter().filter(|d| d["last"].as_u64().is_some()).max_by_key(|d| d["last"].as_u64()).map(|d| {
        let who = [&d["device"], &d["id"], &d["fp"]].into_iter().find(|x| x.is_string()).cloned().unwrap_or(Value::Null);
        json!({"device": who, "at": d["last"]})
    });
    json!({"devices": devices.len(), "sessions": sessions, "queued": v["queued"].as_u64().unwrap_or(0), "last": last})
}

/// Turns `name` on or off: `services.json` first, then the program. The reply is `status`.
pub async fn set(state: &Arc<State>, name: &str, on: bool) -> Value {
    let Some(c) = find(name) else { return err("unknown service") };
    let _one = state.companions.setting.lock().await;
    let map = turned(load(state).unwrap_or_default(), c.name, on);
    if let Err(e) = rapp_net::config::write_json(&state.home.join(FILE), &Value::Object(map.clone())) {
        return err(&format!("{e:#}"));
    }
    let cfg = cfg_in(&map, c);
    if on {
        let alive = state.companions.with(c.name, |s| {
            s.on = true;
            match &s.run {
                Some(r) if !r.task.is_finished() => {
                    // On but not running: try again now, not after the backoff.
                    if s.phase == Phase::Waiting {
                        s.phase = Phase::Starting;
                        r.retry.notify_one();
                    }
                    true
                }
                _ => {
                    s.cfg = cfg;
                    s.run = None;
                    false
                }
            }
        });
        if alive {
            state.companions.bump();
        } else {
            start(state, c);
        }
        let mut rx = state.companions.changed.subscribe();
        let _ = tokio::time::timeout(SET_WAIT, async {
            while state.companions.with(c.name, |s| s.phase == Phase::Starting) {
                if rx.changed().await.is_err() {
                    return;
                }
            }
        })
        .await;
    } else {
        let (run, port) = state.companions.with(c.name, |s| {
            let port = s.cfg.port.unwrap_or(c.port);
            s.on = false;
            s.phase = Phase::Off;
            s.error = None;
            s.cfg = cfg;
            (s.run.take(), port)
        });
        if let Some(run) = run {
            run.stop.notify_one();
            let mut task = run.task;
            if tokio::time::timeout(Duration::from_secs(3), &mut task).await.is_err() {
                task.abort();
            }
        }
        state.companions.with(c.name, |s| s.pid = None);
        sink::set_local(state, None);
        take_back(state, c, port);
        state.companions.bump();
        state.notify();
    }
    status(state, c.name).await
}

/// The address apps reach the chosen sink at: its own port here, or the localhost map of a
/// remote one (`local_of` finds it by device and port).
pub(crate) fn sink_url(chosen: Option<&sink::Dest>, local_of: impl Fn(&str, u16) -> Option<u16>) -> Option<String> {
    match chosen? {
        sink::Dest::Local(p) => Some(format!("http://127.0.0.1:{p}")),
        sink::Dest::Remote { id, port } => local_of(id, *port).map(|n| format!("http://localhost:{n}")),
    }
}

/// The IPC `state` reply of `name`: on, port, share number, running, why not, what it holds,
/// the sinks known and the outbox.
pub async fn status(state: &Arc<State>, name: &str) -> Value {
    let Some(c) = find(name) else { return err("unknown service") };
    let (on, port, running, error) = state.companions.with(c.name, |s| (s.on, s.cfg.port.unwrap_or(c.port), s.phase == Phase::Running, s.error.clone()));
    let share = state.shares.get(port).filter(|s| s.kind.as_deref() == Some(c.kind)).and_then(|s| s.local);
    let stored = if running { stored(port).await } else { None };
    let url = match sink::chosen(state) {
        Some(sink::Dest::Remote { id, port }) => {
            let got = crate::maps::ensure_all(state, &id, &[(port, None)]).await;
            sink_url(Some(&sink::Dest::Remote { id: id.clone(), port }), |_, _| got.first().copied().flatten())
        }
        other => sink_url(other.as_ref(), |_, _| None),
    };
    let mut r = sink::ipc(state);
    let extra = json!({"url": url, "on": on, "port": port, "share": share, "running": running, "error": error, "stored": stored, "outbox": crate::outbox::status(state)});
    if let (Some(m), Value::Object(e)) = (r.as_object_mut(), extra) {
        m.extend(e);
    }
    r
}

/// IPC `{"cmd":"state","name"?,"on"?}`: with `on`, `set`; without, `status`.
pub async fn ipc(state: &Arc<State>, cmd: &Value) -> Value {
    let name = cmd["name"].as_str().unwrap_or("state");
    match &cmd["on"] {
        Value::Null => status(state, name).await,
        Value::Bool(on) => set(state, name, *on).await,
        _ => err("bad request"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sink_url_points_at_the_local_port_or_the_map() {
        use sink::Dest;
        assert_eq!(sink_url(Some(&Dest::Local(8102)), |_, _| None).as_deref(), Some("http://127.0.0.1:8102"));
        let r = Dest::Remote { id: "222".into(), port: 8102 };
        assert_eq!(sink_url(Some(&r), |id, p| (id == "222" && p == 8102).then_some(28003)).as_deref(), Some("http://localhost:28003"));
        assert_eq!(sink_url(Some(&r), |_, _| None), None);
        assert_eq!(sink_url(None, |_, _| Some(1)), None);
    }

    #[test]
    fn args_follow_the_file() {
        let home = Path::new("/h");
        let data = home.join("state").to_string_lossy().into_owned();
        let on: ServiceCfg = serde_json::from_value(json!({"on": true})).unwrap();
        assert_eq!(args(&on, home), ["--port", "8102", "--data", data.as_str(), "--keep-days", "7", "--keep-events", "1000"]);
        let mem: ServiceCfg = serde_json::from_value(json!({"on": true, "port": 9000, "store": "memory", "keep_days": 2, "keep_events": 5})).unwrap();
        assert_eq!(args(&mem, home), ["--port", "9000", "--keep-days", "2", "--keep-events", "5"]);
        let disk: ServiceCfg = serde_json::from_value(json!({"on": false, "store": "disk"})).unwrap();
        assert!(args(&disk, home).contains(&"--data".to_string()));
    }

    #[test]
    fn turning_on_keeps_other_fields() {
        let dir = tempfile::tempdir().unwrap();
        let file = json!({"state": {"on": false, "x": 1}, "llm": {"on": true, "model": "m"}});
        std::fs::write(dir.path().join(FILE), file.to_string()).unwrap();
        let map = turned(read_file(dir.path()).unwrap(), "state", true);
        assert_eq!(Value::Object(map.clone()), json!({"state": {"on": true, "x": 1}, "llm": {"on": true, "model": "m"}}));
        assert!(cfg_in(&map, &TABLE[0]).on);
        // No file: everything off; turning on writes a fresh entry.
        let none = tempfile::tempdir().unwrap();
        let map = read_file(none.path()).unwrap();
        assert_eq!(cfg_in(&map, &TABLE[0]), ServiceCfg::default());
        assert_eq!(Value::Object(turned(map, "state", true)), json!({"state": {"on": true}}));
        // Broken: not JSON, not an object, or the entry is not a `ServiceCfg` (`on` missing, a bad port).
        for bad in ["{ nope", "[1]", r#"{"state":{"port":1}}"#, r#"{"state":{"on":true,"port":"x"}}"#] {
            std::fs::write(dir.path().join(FILE), bad).unwrap();
            assert!(read_file(dir.path()).is_err(), "{bad}");
        }
        // An entry of a service rApp does not know is not looked at.
        std::fs::write(dir.path().join(FILE), r#"{"llm":"anything"}"#).unwrap();
        assert!(read_file(dir.path()).is_ok());
    }

    #[test]
    fn stored_counts_the_state() {
        assert_eq!(counts(&json!({"devices": [], "needs": [], "queued": 0})), json!({"devices": 0, "sessions": 0, "queued": 0, "last": null}));
        let v = json!({"devices": [
            {"fp": "aa", "last": 5, "sessions": [{}, {}], "device": "mac"},
            {"fp": "bb", "last": 9, "sessions": [{}], "id": "123456789"},
        ], "queued": 3});
        assert_eq!(counts(&v), json!({"devices": 2, "sessions": 3, "queued": 3, "last": {"device": "123456789", "at": 9}}));
    }
}
