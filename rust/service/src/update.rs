//! The updater (online-update spec §4.3, plan Task 4): a timer that checks and downloads, the
//! "nobody is using rapp" test, the install, the restart request, and what the next service
//! does with the marker. External programs go through `state.runner`, always in `spawn_blocking`.
//!
//! "Nobody is using it" (K17) reads `ps -axo pid=,ppid=,comm=`. Checked read-only on this Mac
//! (Task 4 Step 0, 2026-11-12): `comm` is the executable's full, untruncated path, e.g.
//! `/System/Library/CoreServices/loginwindow.app/Contents/MacOS/loginwindow`, so K17's match on
//! the `<bundle>/Contents/` prefix of `comm` is used as written. As a guard against a format
//! change, the output only counts when it shows this service itself under that prefix.

use crate::state::State;
use crate::UpdateOpts;
use rapp_net::line::{err, ok};
use rapp_net::log::Lvl;
use rapp_update::runner::{OPEN, PS};
use rapp_update::{self as up, InstallError, Manifest, Marker, Runner, Stage};
use serde_json::{json, Value};
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::watch;
use tokio::task::JoinHandle;
use tokio::time::Instant;

const LEFTOVER: &str = "上次升级没收拾干净，需要手动处理";
const STILL_OPEN: &str = "rapp 还开着";
const NOT_LAUNCHD: &str = "服务不是由系统启动的，请从 release 页面手动装 pkg";
const NEEDS_ADMIN: &str = "这次需要管理员密码";
const BAD_URL: &str = "更新地址不对";
const NOTHING_TO_INSTALL: &str = "没有可装的新版本";
const NO_PREVIOUS: &str = "没有上一版";
const BUSY: &str = "正在忙，请稍后再试";
/// The reply to a B that opens a session while the new version goes in.
pub const UPGRADING: &str = "A 正在升级，请稍后再连";
/// How often a manual install looks again for nobody using rapp (K20).
const MANUAL_POLL: Duration = Duration::from_millis(500);

/// The updater's state machine (K18). `busy`: a pipeline or an install is running.
#[derive(Clone, PartialEq)]
pub struct UpdState {
    /// off | idle | checking | downloading | ready | installing | failed | up_to_date
    pub state: &'static str,
    pub current: Option<String>,
    pub latest: Option<String>,
    pub progress: Option<u8>,
    pub error: Option<String>,
    /// The stage of the last failure; None for a failed check.
    failed_stage: Option<Stage>,
    pub notes: Option<String>,
    /// The new app's signature differs from the running one: install only on confirmation.
    pub needs_confirm: bool,
    pub needs_admin: bool,
    /// The release page, for 打开安装包.
    pub page: Option<String>,
    pub busy: bool,
    pub ready_app: Option<PathBuf>,
    pub dr_current: Option<String>,
    /// The last manifest fetched by this service; the cache only keeps its version.
    manifest: Option<Manifest>,
    /// A marker for this very version was found at start: remove it once healthy.
    applied: bool,
    /// Remote sessions between B's `open` and their end (K17, fix round 1): a session that is
    /// still starting rapp-host is not in the session table yet but is about to be.
    opening: usize,
}

impl Default for UpdState {
    fn default() -> Self {
        UpdState {
            state: "off",
            current: None,
            latest: None,
            progress: None,
            error: None,
            failed_stage: None,
            notes: None,
            needs_confirm: false,
            needs_admin: false,
            page: None,
            busy: false,
            ready_app: None,
            dr_current: None,
            manifest: None,
            applied: false,
            opening: 0,
        }
    }
}

#[derive(Clone, Copy, PartialEq)]
enum Mode {
    Auto,
    Manual,
    Rollback,
}

impl Mode {
    fn as_str(self) -> &'static str {
        match self {
            Mode::Auto => "auto",
            Mode::Manual => "manual",
            Mode::Rollback => "rollback",
        }
    }
}

/// Holds `UpdState::busy`; dropping it lets the next pipeline or install run.
struct Busy(Arc<State>);

impl Busy {
    fn begin(state: &Arc<State>) -> Option<Busy> {
        let mut u = state.update.lock().unwrap();
        if u.busy || u.state == "off" {
            return None;
        }
        u.busy = true;
        Some(Busy(state.clone()))
    }

    /// The new version is in place: nothing else runs until the restart.
    fn keep(self) {
        std::mem::forget(self);
    }
}

impl Drop for Busy {
    fn drop(&mut self) {
        self.0.update.lock().unwrap().busy = false;
    }
}

fn cache_file(state: &State) -> PathBuf {
    state.home.join("update.json")
}

fn previous_dir(state: &State) -> PathBuf {
    state.home.join("previous")
}

/// Changes the state; subscribers hear about it only if something changed.
fn modify(state: &State, f: impl FnOnce(&mut UpdState)) {
    let mut u = state.update.lock().unwrap();
    let before = u.clone();
    f(&mut u);
    let changed = *u != before;
    drop(u);
    if changed {
        state.notify();
    }
}

async fn blocking<T: Send + 'static>(state: &State, f: impl FnOnce(&dyn Runner) -> T + Send + 'static) -> T {
    let r = state.runner.clone();
    tokio::task::spawn_blocking(move || f(&*r)).await.expect("update task panicked")
}

/// `update_failed {stage, reason}` and state `failed`. `reason` is never a URL (spec §7).
fn fail(state: &State, stage: Stage, reason: &str) {
    state.log.event(Lvl::Warn, "update_failed", json!({"stage": stage.as_str(), "reason": reason}));
    modify(state, |u| {
        u.state = "failed";
        u.error = Some(reason.to_string());
        u.failed_stage = Some(stage);
        u.progress = None;
    });
}

fn check_failed(state: &State, reason: &str) {
    state.log.event(Lvl::Warn, "update_check", json!({"result": "failed", "reason": reason}));
    modify(state, |u| {
        u.state = "failed";
        u.error = Some(reason.to_string());
        u.failed_stage = None;
    });
}

/// `update_status` (spec §4.4 plus K19's fields).
pub fn status_json(state: &State) -> Value {
    let (auto_update, check_updates) = {
        let c = state.cfg.lock().unwrap();
        (c.auto_update(), c.check_updates())
    };
    let cache = up::load_cache(&cache_file(state));
    let dismissed = cache.latest_version.is_some() && cache.latest_version == cache.dismissed_version;
    let can_rollback = state.update_opts.is_some() && previous_dir(state).join("rapp.app").is_dir();
    let u = state.update.lock().unwrap();
    json!({
        "state": u.state, "current": u.current, "latest": u.latest, "progress": u.progress, "error": u.error,
        "notes": u.notes, "auto_update": auto_update, "check_updates": check_updates,
        "needs_confirm": u.needs_confirm, "needs_admin": u.needs_admin, "page": u.page,
        "can_rollback": can_rollback, "dismissed": dismissed,
    })
}

/// Reads the running version and signature, then handles a marker left by the service that
/// installed this version (K15).
pub async fn on_start(state: &Arc<State>) {
    let Some(o) = state.update_opts.clone() else { return };
    let bundle = o.bundle.clone();
    let (current, dr) = blocking(state, move |r| (up::bundle_version(r, &bundle), up::designated(r, &bundle))).await;
    let latest = up::load_cache(&cache_file(state)).latest_version;
    modify(state, |u| {
        u.state = if current.is_some() { "idle" } else { "off" };
        u.current = current.clone();
        u.dr_current = dr;
        u.latest = latest;
    });
    let Some(m) = up::read_marker(&state.home) else { return };
    let canon = |v: &str| up::canonical_version(v).unwrap_or_else(|| v.to_string());
    if current.as_deref().map(canon) == Some(canon(&m.to)) {
        state.log.event(Lvl::Info, "update_applied", json!({"from": m.from, "to": m.to, "mode": m.mode}));
        if m.gui_was_open {
            reopen_gui(state, &o).await;
        }
        state.update.lock().unwrap().applied = true;
    } else {
        up::clear_marker(&state.home);
        let now = current.as_deref().unwrap_or("未知");
        fail(state, Stage::Restart, &format!("重启后是 {now}，不是 {}", m.to));
    }
}

/// The updater's timer: the first check after `first_check`, then every `tick`; every
/// `idle_poll` a downloaded version tries to install itself. Does nothing when off.
pub fn spawn(state: Arc<State>) -> JoinHandle<()> {
    tokio::spawn(async move {
        let Some(o) = state.update_opts.clone() else { return };
        if state.update.lock().unwrap().state == "off" {
            return;
        }
        tokio::join!(remove_when_healthy(&state, &o), run(&state, &o));
    })
}

async fn run(state: &Arc<State>, o: &UpdateOpts) {
    let start = Instant::now();
    let mut next_check = start + o.first_check;
    let mut idle = tokio::time::interval_at(start + o.idle_poll, o.idle_poll);
    idle.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    loop {
        tokio::select! {
            _ = tokio::time::sleep_until(next_check) => {
                next_check = Instant::now() + o.tick;
                let scheduled = state.cfg.lock().unwrap().check_updates();
                if scheduled {
                    pipeline(state, false).await;
                }
            }
            _ = idle.tick() => try_auto(state, o).await,
        }
    }
}

/// After `healthy_after`, the marker and the downloaded zips and unpacked apps go (K15).
async fn remove_when_healthy(state: &State, o: &UpdateOpts) {
    if !state.update.lock().unwrap().applied {
        return;
    }
    tokio::time::sleep(o.healthy_after).await;
    up::clear_marker(&state.home);
    let Ok(dir) = std::fs::read_dir(&o.cache_dir) else { return };
    for e in dir.flatten() {
        let (name, p) = (e.file_name().to_string_lossy().into_owned(), e.path());
        if name.starts_with("rapp-") && name.ends_with(".zip") {
            let _ = std::fs::remove_file(&p);
        } else if up::parse_version(&name).is_some() && p.is_dir() {
            let _ = std::fs::remove_dir_all(&p);
        }
    }
}

/// U-3c: anything else could be read by curl as an option.
fn url_ok(url: &str) -> bool {
    url.starts_with("https://") || url.starts_with("http://127.0.0.1:") || url.starts_with("http://127.0.0.1/")
}

/// The 检查更新 button: forget the dismissed version and check now (K8).
pub async fn check_now(state: &Arc<State>) {
    {
        let u = state.update.lock().unwrap();
        if state.update_opts.is_none() || u.busy || u.state == "off" {
            return;
        }
    }
    let p = cache_file(state);
    let mut c = up::load_cache(&p);
    if c.dismissed_version.take().is_some() {
        if let Err(e) = up::save_cache(&p, &c) {
            state.log.msg(Lvl::Warn, format!("update: save cache: {e}"));
        }
    }
    pipeline(state, true).await;
}

/// Check (when due or `force`), download, verify, and leave the result in `ready` (K8, K11).
async fn pipeline(state: &Arc<State>, force: bool) {
    let Some(o) = state.update_opts.clone() else { return };
    let Some(_busy) = Busy::begin(state) else { return };
    let (current, have) = {
        let u = state.update.lock().unwrap();
        (u.current.clone(), u.manifest.as_ref().and_then(|m| up::canonical_version(&m.version)))
    };
    let Some(current) = current else { return };
    let now = up::now_secs();
    let cache = up::load_cache(&cache_file(state));
    let wanted = up::offer(&cache, &current);
    // A version waiting in the cache needs its manifest, which only lives in memory.
    let fetch = force || up::should_check(&cache, now) || (wanted.is_some() && have != wanted);
    if fetch {
        let url = state.cfg.lock().unwrap().update_url();
        if !url_ok(&url) {
            return check_failed(state, BAD_URL);
        }
        modify(state, |u| {
            u.state = "checking";
            u.error = None;
        });
        let dir = o.cache_dir.clone();
        match blocking(state, move |r| up::fetch_manifest(r, &url, &dir)).await {
            Err(reason) => return check_failed(state, &reason),
            Ok(m) => {
                let latest = m.as_ref().and_then(|m| up::canonical_version(&m.version));
                let p = cache_file(state);
                let mut c = up::load_cache(&p);
                (c.latest_version, c.last_checked_at) = (latest.clone(), Some(now));
                if let Err(e) = up::save_cache(&p, &c) {
                    state.log.msg(Lvl::Warn, format!("update: save cache: {e}"));
                }
                let newer = latest.as_deref().is_some_and(|l| up::is_newer(l, &current));
                let mut f = json!({"result": if newer { "available" } else { "up_to_date" }});
                if let Some(l) = &latest {
                    f["latest"] = json!(l);
                }
                state.log.event(Lvl::Info, "update_check", f);
                state.update.lock().unwrap().manifest = m;
            }
        }
    }

    let cache = up::load_cache(&cache_file(state));
    let manifest = state.update.lock().unwrap().manifest.clone();
    let offered = up::offer(&cache, &current);
    let found = offered.zip(manifest).filter(|(v, m)| up::canonical_version(&m.version).as_ref() == Some(v));
    let Some((v, m)) = found else {
        let newer = cache.latest_version.as_deref().is_some_and(|l| up::is_newer(l, &current));
        return modify(state, |u| {
            u.state = if newer || cache.latest_version.is_none() { "idle" } else { "up_to_date" };
            u.latest = cache.latest_version.clone();
            (u.error, u.failed_stage, u.progress, u.ready_app) = (None, None, None, None);
            (u.needs_confirm, u.needs_admin, u.notes, u.page) = (false, false, None, None);
        });
    };
    {
        // Already downloaded and verified, or its install failed: wait for the button or the next real check.
        let u = state.update.lock().unwrap();
        let settled = u.state == "ready" || (u.state == "failed" && u.failed_stage == Some(Stage::Install));
        if !force && !fetch && settled && u.latest.as_deref() == Some(v.as_str()) {
            return;
        }
    }

    modify(state, |u| {
        u.state = "downloading";
        u.latest = Some(v.clone());
        u.notes = m.notes.clone();
        u.page = Some(up::release_page(&m.asset.url));
        (u.progress, u.error, u.failed_stage, u.ready_app) = (Some(0), None, None, None);
        (u.needs_confirm, u.needs_admin) = (false, false);
    });
    let progress = tokio::spawn(report_progress(state.clone(), up::part_path(&o.cache_dir, &v), m.asset.size));
    let (dir, mm) = (o.cache_dir.clone(), m.clone());
    let res = blocking(state, move |r| up::download(r, &dir, &mm)).await;
    progress.abort();
    let zip = match res {
        Ok((zip, bytes)) => {
            state.log.event(Lvl::Info, "update_download", json!({"version": v, "result": "ok", "bytes": bytes}));
            zip
        }
        Err(f) => return fail(state, f.stage, &f.reason),
    };

    let dr = state.update.lock().unwrap().dr_current.clone().unwrap_or_default();
    let (dir, vv) = (o.cache_dir.clone(), v.clone());
    match blocking(state, move |r| up::verify(r, &zip, &dir, &vv, &dr)).await {
        Err(f) => fail(state, f.stage, &f.reason),
        Ok(ok) => {
            let dismissed = up::load_cache(&cache_file(state)).dismissed_version.as_deref() == Some(v.as_str());
            modify(state, |u| {
                u.progress = None;
                if dismissed {
                    u.state = "idle";
                } else {
                    u.state = "ready";
                    u.ready_app = Some(ok.app);
                    u.needs_confirm = ok.signature_changed;
                }
            });
        }
    }
}

/// The `.part` size as a percentage, once a second (K11).
async fn report_progress(state: Arc<State>, part: PathBuf, size: u64) {
    let mut every = tokio::time::interval(Duration::from_secs(1));
    loop {
        every.tick().await;
        let have = std::fs::metadata(&part).map(|m| m.len()).unwrap_or(0);
        let pct = (have.saturating_mul(100) / size.max(1)).min(99) as u8;
        modify(&state, |u| {
            if u.state == "downloading" {
                u.progress = Some(pct);
            }
        });
    }
}

fn sessions_in_use(state: &State) -> Option<String> {
    let n = state.sessions.lock().unwrap().1.len();
    if n > 0 {
        return Some(format!("有 {n} 个远程会话在用这台电脑"));
    }
    (state.update.lock().unwrap().opening > 0).then(|| "有远程会话正在连进来".to_string())
}

/// Held by `peer::open` for the whole session, from before rapp-host starts.
pub struct Opening(Arc<State>);

impl Drop for Opening {
    fn drop(&mut self) {
        let mut u = self.0.update.lock().unwrap();
        u.opening = u.opening.saturating_sub(1);
    }
}

/// A session may open unless the new version is going in (then A restarts in a moment).
pub fn begin_open(state: &Arc<State>) -> Result<Opening, &'static str> {
    let mut u = state.update.lock().unwrap();
    if u.state == "installing" {
        return Err(UPGRADING);
    }
    u.opening += 1;
    Ok(Opening(state.clone()))
}

/// One `pid ppid comm` line of ps; `comm` may contain spaces.
fn ps_fields(line: &str) -> Option<(u32, u32, &str)> {
    let (pid, rest) = line.trim_start().split_once(char::is_whitespace)?;
    let (ppid, comm) = rest.trim_start().split_once(char::is_whitespace)?;
    Some((pid.parse().ok()?, ppid.parse().ok()?, comm.trim()))
}

/// Why rapp counts as in use, or None when nobody is using it (K17): a remote session, or a
/// process from the bundle other than this service and its own children. A ps that fails, or
/// whose output doesn't show this service, counts as in use.
pub async fn in_use(state: &State) -> Option<String> {
    if let Some(why) = sessions_in_use(state) {
        return Some(why);
    }
    let o = state.update_opts.as_ref()?;
    let prefix = format!("{}/Contents/", o.bundle.display());
    let args = vec!["-axo".to_string(), "pid=,ppid=,comm=".to_string()];
    let out = match blocking(state, move |r| r.run(PS, &args)).await {
        Ok(out) if out.code == 0 => out.stdout,
        _ => return Some("查不了进程表".into()),
    };
    let me = std::process::id();
    let procs: Vec<_> = out.lines().filter_map(ps_fields).collect();
    if !procs.iter().any(|&(pid, _, comm)| pid == me && comm.starts_with(&prefix)) {
        return Some("看不懂进程表".into());
    }
    let other = procs.iter().any(|&(pid, ppid, comm)| comm.starts_with(&prefix) && pid != me && ppid != me);
    other.then(|| STILL_OPEN.to_string())
}

/// Every `idle_poll`: a ready version installs itself when allowed and nobody is using rapp.
async fn try_auto(state: &Arc<State>, o: &UpdateOpts) {
    if !auto_allowed(state, o, "ready") || in_use(state).await.is_some() {
        return;
    }
    let Some(busy) = Busy::begin(state) else { return };
    if auto_allowed(state, o, "ready") {
        put_in_place(state, busy, Mode::Auto).await;
    }
}

/// The version in `latest` is still the one on offer (not dismissed, not superseded).
fn still_offered(state: &State) -> bool {
    let (current, latest) = {
        let u = state.update.lock().unwrap();
        (u.current.clone(), u.latest.clone())
    };
    let Some(current) = current else { return false };
    latest.is_some() && up::offer(&up::load_cache(&cache_file(state)), &current) == latest
}

/// Everything an auto install needs except "nobody is using rapp" (U-4c). Checked again after
/// every await. A ready version that was dismissed meanwhile goes back to idle.
fn auto_allowed(state: &State, o: &UpdateOpts, want: &str) -> bool {
    if !still_offered(state) {
        modify(state, |u| {
            if u.state == "ready" {
                u.state = "idle";
                (u.ready_app, u.needs_confirm) = (None, false);
            }
        });
        return false;
    }
    if !o.launchd || !state.cfg.lock().unwrap().auto_update() {
        return false;
    }
    let u = state.update.lock().unwrap();
    u.state == want && !u.needs_confirm && !u.needs_admin
}

/// U-3e: a leftover from a twice-failed install may be the only copy of a version, and
/// install's first step would delete it, so nothing installs until someone clears it.
fn leftover(state: &State) -> bool {
    let Some(o) = &state.update_opts else { return false };
    let staged = o.bundle.parent().map(|d| d.join(".rapp-new.app"));
    let aside = previous_dir(state).join(".rapp-old.app");
    let found = staged.iter().chain([&aside]).any(|p| std::fs::symlink_metadata(p).is_ok());
    if found {
        fail(state, Stage::Install, LEFTOVER);
    }
    found
}

async fn reopen_gui(state: &State, o: &UpdateOpts) {
    let b = o.bundle.display().to_string();
    let _ = blocking(state, move |r| r.run(OPEN, &[b])).await;
}

fn page_err(msg: &str, page: Option<String>) -> Value {
    json!({"ok": false, "error": msg, "page": page})
}

/// Swaps in the ready version (or `previous/` for a rollback), writes the marker and asks for the
/// restart (K12, K13, K15, K25). When the GUI quit for this, a failure opens it again.
async fn put_in_place(state: &Arc<State>, busy: Busy, mode: Mode) {
    let Some(o) = state.update_opts.clone() else { return };
    let gui = mode != Mode::Auto;
    let failed = |stage, reason: &str| {
        fail(state, stage, reason);
        let o = o.clone();
        async move {
            if gui {
                reopen_gui(state, &o).await;
            }
        }
    };
    if leftover(state) {
        if gui {
            reopen_gui(state, &o).await;
        }
        return;
    }
    let prev_dir = previous_dir(state);
    let (src, to) = if mode == Mode::Rollback {
        let src = prev_dir.join("rapp.app");
        let s = src.clone();
        match blocking(state, move |r| up::verify_local(r, &s).map(|_| up::bundle_version(r, &s))).await {
            Err(f) => return failed(f.stage, &f.reason).await,
            Ok(None) => return failed(Stage::Verify, "读不到上一版的版本号").await,
            Ok(Some(v)) => (src, v),
        }
    } else {
        let ready = {
            let u = state.update.lock().unwrap();
            u.ready_app.clone().zip(u.latest.clone())
        };
        match ready {
            Some(r) => r,
            None => return failed(Stage::Install, NOTHING_TO_INSTALL).await,
        }
    };
    let from = state.update.lock().unwrap().current.clone().unwrap_or_default();
    // The last gate (fix round 1): from here on B's opens are refused, then everything is checked
    // once more after the last await, right before the swap.
    let before = {
        let mut u = state.update.lock().unwrap();
        let before = u.state;
        if u.opening == 0 {
            u.state = "installing";
        }
        before
    };
    state.notify();
    let why = if state.update.lock().unwrap().state == "installing" {
        in_use(state).await
    } else {
        Some("有远程会话正在连进来".to_string())
    };
    if leftover(state) {
        if gui {
            reopen_gui(state, &o).await;
        }
        return;
    }
    let wanted = match mode {
        Mode::Auto => auto_allowed(state, &o, "installing"),
        Mode::Manual => still_offered(state),
        Mode::Rollback => true,
    };
    if why.is_some() || !wanted {
        let gone = !still_offered(state);
        modify(state, |u| {
            u.state = before;
            if before == "ready" && gone {
                (u.state, u.ready_app, u.needs_confirm) = ("idle", None, false);
            }
        });
        match (gui, why) {
            (true, Some(why)) => failed(Stage::Install, &why).await,
            (true, None) => reopen_gui(state, &o).await,
            _ => {}
        }
        return;
    }
    let (bundle, pd) = (o.bundle.clone(), prev_dir.clone());
    match blocking(state, move |r| up::install(r, &src, &bundle, &pd)).await {
        Ok(()) => {
            let canon = |v: &str| up::canonical_version(v).unwrap_or_else(|| v.to_string());
            let m = Marker {
                from: canon(&from),
                to: canon(&to),
                at: up::now_secs(),
                gui_was_open: gui,
                mode: mode.as_str().into(),
                perms_before: Value::Null,
            };
            if let Err(e) = up::write_marker(&state.home, &m) {
                state.log.msg(Lvl::Warn, format!("update: write marker: {e}"));
            }
            busy.keep();
            state.restart.send_replace(true);
        }
        Err(InstallError::NeedsAdmin) if mode != Mode::Rollback => {
            state.log.event(Lvl::Warn, "update_failed", json!({"stage": "install", "reason": NEEDS_ADMIN}));
            modify(state, |u| {
                u.state = "ready";
                u.needs_admin = true;
            });
            if gui {
                reopen_gui(state, &o).await;
            }
        }
        Err(InstallError::NeedsAdmin) => {
            state.update.lock().unwrap().needs_admin = true;
            failed(Stage::Install, NEEDS_ADMIN).await;
        }
        Err(InstallError::Failed(reason)) => failed(Stage::Install, &reason).await,
    }
}

/// K20: after the GUI's connection closes (at most `gui_wait`), look for nobody using rapp for
/// at most `gui_wait` more. Still in use: open the GUI again and fail.
async fn wait_for_nobody(state: &Arc<State>, o: &UpdateOpts, mut closed: watch::Receiver<()>) -> bool {
    // Nothing is ever sent: `changed` returns once the connection's sender is dropped.
    let _ = tokio::time::timeout(o.gui_wait, closed.changed()).await;
    let deadline = Instant::now() + o.gui_wait;
    loop {
        if in_use(state).await.is_none() {
            return true;
        }
        let now = Instant::now();
        if now >= deadline {
            break;
        }
        tokio::time::sleep(MANUAL_POLL.min(deadline - now)).await;
    }
    reopen_gui(state, o).await;
    fail(state, Stage::Install, STILL_OPEN);
    false
}

/// `update_apply` (K20). On ok the GUI quits; the install runs once its connection closes.
pub async fn apply(state: &Arc<State>, confirm: bool, closed: watch::Receiver<()>) -> Value {
    let Some(o) = state.update_opts.clone() else { return err(NOTHING_TO_INSTALL) };
    {
        let u = state.update.lock().unwrap();
        if u.state != "ready" {
            return err(NOTHING_TO_INSTALL);
        }
        if u.needs_confirm && !confirm {
            return err("需要确认");
        }
        if u.needs_admin || !o.launchd {
            return page_err(if u.needs_admin { NEEDS_ADMIN } else { NOT_LAUNCHD }, u.page.clone());
        }
    }
    if let Some(why) = sessions_in_use(state) {
        return err(&why);
    }
    if leftover(state) {
        return err(LEFTOVER);
    }
    // A pipeline or install already running would leave the GUI gone with nothing happening.
    let Some(busy) = Busy::begin(state) else { return err(BUSY) };
    if state.update.lock().unwrap().state != "ready" {
        return err(NOTHING_TO_INSTALL);
    }
    let state = state.clone();
    tokio::spawn(async move {
        if wait_for_nobody(&state, &o, closed).await {
            put_in_place(&state, busy, Mode::Manual).await;
        }
    });
    ok(json!({}))
}

/// `update_rollback` (K13): swap with `previous/rapp.app`, the same way as a manual install.
pub async fn rollback(state: &Arc<State>, closed: watch::Receiver<()>) -> Value {
    let Some(o) = state.update_opts.clone() else { return err(NO_PREVIOUS) };
    if !o.launchd {
        return page_err(NOT_LAUNCHD, state.update.lock().unwrap().page.clone());
    }
    if state.update.lock().unwrap().state == "off" || !previous_dir(state).join("rapp.app").is_dir() {
        return err(NO_PREVIOUS);
    }
    if leftover(state) {
        return err(LEFTOVER);
    }
    if let Some(why) = sessions_in_use(state) {
        return err(&why);
    }
    let Some(busy) = Busy::begin(state) else { return err(BUSY) };
    let state = state.clone();
    tokio::spawn(async move {
        if wait_for_nobody(&state, &o, closed).await {
            put_in_place(&state, busy, Mode::Rollback).await;
        }
    });
    ok(json!({}))
}

/// `update_dismiss {version}`: that version is not offered again until 检查更新.
pub fn dismiss(state: &State, version: &str) -> Value {
    let Some(v) = up::canonical_version(version) else { return err("版本号不对") };
    let p = cache_file(state);
    let mut c = up::load_cache(&p);
    c.dismissed_version = Some(v.clone());
    if let Err(e) = up::save_cache(&p, &c) {
        return err(&format!("save cache: {e}"));
    }
    modify(state, |u| {
        if !u.busy && u.latest.as_deref() == Some(v.as_str()) && matches!(u.state, "ready" | "failed") {
            u.state = "idle";
            (u.error, u.failed_stage, u.ready_app) = (None, None, None);
            (u.needs_confirm, u.needs_admin) = (false, false);
        }
    });
    state.notify();
    ok(json!({}))
}

/// `set_update {auto_update?, check_updates?}`.
pub fn set(state: &State, auto_update: Option<bool>, check_updates: Option<bool>) -> Value {
    let mut cfg = state.cfg.lock().unwrap();
    if let Some(a) = auto_update {
        cfg.auto_update = Some(a);
    }
    if let Some(c) = check_updates {
        cfg.check_updates = Some(c);
    }
    if let Err(e) = cfg.save(&state.home) {
        return err(&format!("save config: {e:#}"));
    }
    drop(cfg);
    state.notify();
    ok(json!({}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ps_lines_with_spaces_in_the_path() {
        assert_eq!(
            ps_fields("  417     1 /Applications/My App.app/Contents/MacOS/My App"),
            Some((417, 1, "/Applications/My App.app/Contents/MacOS/My App"))
        );
        assert_eq!(ps_fields("x 1 /bin/sh"), None);
        assert_eq!(ps_fields("12"), None);
    }

    #[test]
    fn only_https_or_local_test_urls() {
        assert!(url_ok("https://github.com/x/latest.json"));
        assert!(url_ok("http://127.0.0.1:8080/latest.json"));
        for u in ["-K/etc/x", "http://example.com/x", "file:///etc/passwd", "http://127.0.0.1.evil/x", ""] {
            assert!(!url_ok(u), "{u}");
        }
    }

    #[test]
    fn rollback_mode_names() {
        assert_eq!([Mode::Auto, Mode::Manual, Mode::Rollback].map(Mode::as_str), ["auto", "manual", "rollback"]);
    }
}
