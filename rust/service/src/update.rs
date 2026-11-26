//! The updater (online-update spec §4.3, plan Task 4): a timer that checks and downloads, the
//! "nobody is using rApp" test, the install, the restart request, and what the next service
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
use rapp_update::runner::{IOREG, OPEN, PS};
use rapp_update::{self as up, InstallError, Manifest, Marker, Runner, Stage};
use serde_json::{json, Value};
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::watch;
use tokio::task::JoinHandle;
use tokio::time::Instant;

const LEFTOVER: &str =
    "上次升级没收拾干净：请手动删除 rapp.app 同目录的 .rapp-new.app，或 previous 里的 .rapp-old.backup / .rapp-old.app";
const STILL_OPEN: &str = "rApp 还开着";
const NOT_LAUNCHD: &str = "服务不是由系统启动的，请从 release 页面手动装 pkg";
const NEEDS_ADMIN: &str = "这次需要管理员密码";
const BAD_URL: &str = "更新地址不对";
const NOTHING_TO_INSTALL: &str = "没有可装的新版本";
const NO_PREVIOUS: &str = "没有上一版";
const BUSY: &str = "正在忙，请稍后再试";
/// The reply to a B that opens a session while the new version goes in.
pub const UPGRADING: &str = "远端正在升级，请稍后再连";
/// How often a manual install looks again for nobody using rApp (K20).
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
    /// An install is about to go in: the GUI quits itself (cli-update §5.2).
    pub quit_gui: bool,
    /// Why the auto install is waiting, as last found.
    pub auto_wait: Option<String>,
    /// No auto install before this: the last one found rApp still open.
    auto_after: Option<Instant>,
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
            quit_gui: false,
            auto_wait: None,
            auto_after: None,
        }
    }
}

#[derive(Clone, Copy, PartialEq)]
enum Mode {
    Auto,
    Manual,
    Rollback,
}

/// Who asked for an install (the marker's and `update_applied`'s `by`).
#[derive(Clone, Copy, PartialEq, Debug)]
pub enum By {
    Gui,
    Cli,
    Auto,
}

impl By {
    fn as_str(self) -> &'static str {
        match self {
            By::Gui => "gui",
            By::Cli => "cli",
            By::Auto => "auto",
        }
    }
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

/// A failed check. A verified download still on disk stays `ready` (log only): a transient
/// network error must not hide 立即升级.
fn check_failed(state: &State, reason: &str, was_ready: bool) {
    state.log.event(Lvl::Warn, "update_check", json!({"result": "failed", "reason": reason}));
    modify(state, |u| {
        if was_ready && u.ready_app.as_ref().is_some_and(|p| p.is_dir()) {
            u.state = "ready";
            u.error = None;
            return;
        }
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
    let can_rollback = state.update_opts.is_some() && up::previous_app(&previous_dir(state)).is_dir();
    // Read on every report, so a pkg run while the service is up clears it at once.
    let needs_reinstall = state
        .update_opts
        .as_ref()
        .and_then(|o| o.install_level.as_ref())
        .is_some_and(|f| up::needs_reinstall(std::fs::read_to_string(f).ok().as_deref()));
    let u = state.update.lock().unwrap();
    json!({
        "state": u.state, "current": u.current, "latest": u.latest, "progress": u.progress, "error": u.error,
        "notes": u.notes, "auto_update": auto_update, "check_updates": check_updates,
        "needs_confirm": u.needs_confirm, "needs_admin": u.needs_admin, "page": u.page,
        "can_rollback": can_rollback, "dismissed": dismissed,
        "needs_reinstall": needs_reinstall, "reinstall_page": up::RELEASES_PAGE,
        "quit_gui": u.quit_gui, "auto_wait": u.auto_wait,
        "launchd": state.update_opts.as_ref().is_some_and(|o| o.launchd),
        "error_code": u.error.as_deref().map(error_code),
    })
}

/// Reads the running version and signature, then handles a marker left by the service that
/// installed this version (K15).
pub async fn on_start(state: &Arc<State>) {
    let Some(o) = state.update_opts.clone() else { return };
    let bundle = o.bundle.clone();
    let prev = previous_dir(state);
    let (current, dr) = blocking(state, move |r| {
        up::adopt_legacy_previous(r, &prev);
        (up::bundle_version(r, &bundle), up::designated(r, &bundle))
    })
    .await;
    let latest = up::load_cache(&cache_file(state)).latest_version;
    note_signature(state, dr.as_deref());
    modify(state, |u| {
        u.state = if current.is_some() { "idle" } else { "off" };
        u.current = current.clone();
        u.dr_current = dr;
        u.latest = latest;
    });
    let Some(m) = up::read_marker(&state.home) else { return };
    let canon = |v: &str| up::canonical_version(v).unwrap_or_else(|| v.to_string());
    if current.as_deref().map(canon) == Some(canon(&m.to)) {
        let mut f = json!({"from": m.from, "to": m.to, "mode": m.mode});
        if !m.by.is_empty() {
            f["by"] = json!(m.by);
        }
        state.log.event(Lvl::Info, "update_applied", f);
        if m.gui_was_open {
            reopen_gui(state, &o).await;
        }
        state.update.lock().unwrap().applied = true;
        // K23: both were granted before the swap and the first check after it says otherwise.
        let granted = |v: &Value| v["screen_recording"] == true && v["accessibility"] == true;
        if granted(&m.perms_before) && !granted(&state.permissions.lock().unwrap()) {
            *state.perms_lost.lock().unwrap() = true;
            state.notify();
        }
    } else {
        up::clear_marker(&state.home);
        let now = current.as_deref().unwrap_or("未知");
        fail(state, Stage::Restart, &format!("重启后是 {now}，不是 {}", m.to));
    }
}

/// I-3: the designated requirement this service last ran under lives in `last-dr` (just the string).
/// When it is missing or differs and a permission reads ✗, the permissions were most likely lost to a
/// signing change (the ad-hoc to stable migration arrives by pkg, with no marker): say so (K23/K30).
fn note_signature(state: &State, dr: Option<&str>) {
    let Some(dr) = dr else { return };
    let file = state.home.join("last-dr");
    let known = std::fs::read_to_string(&file).ok();
    if known.as_deref().map(str::trim) == Some(dr) {
        return;
    }
    let perms = state.permissions.lock().unwrap().clone();
    if perms["screen_recording"] != true || perms["accessibility"] != true {
        *state.perms_lost.lock().unwrap() = true;
        state.notify();
    }
    if let Err(e) = std::fs::write(&file, dr) {
        state.log.event(Lvl::Warn, "update_note", json!({"reason": format!("last-dr: {e}")}));
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
    let was_ready = state.update.lock().unwrap().state == "ready";
    let now = up::now_secs();
    let cache = up::load_cache(&cache_file(state));
    let wanted = up::offer(&cache, &current);
    // A version waiting in the cache needs its manifest, which only lives in memory.
    let fetch = force || up::should_check(&cache, now) || (wanted.is_some() && have != wanted);
    if fetch {
        let url = state.cfg.lock().unwrap().update_url();
        if !url_ok(&url) {
            return check_failed(state, BAD_URL, was_ready);
        }
        modify(state, |u| {
            u.state = "checking";
            u.error = None;
        });
        let dir = o.cache_dir.clone();
        match blocking(state, move |r| up::fetch_manifest(r, &url, &dir)).await {
            Err(reason) => return check_failed(state, &reason, was_ready),
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

/// A session may open unless the new version is going in (then A restarts in a moment). It
/// counts as remote use for the auto-update.
pub fn begin_open(state: &Arc<State>) -> Result<(), &'static str> {
    if state.update.lock().unwrap().state == "installing" {
        return Err(UPGRADING);
    }
    state.activity.touch();
    Ok(())
}

/// One `pid ppid comm` line of ps; `comm` may contain spaces.
fn ps_fields(line: &str) -> Option<(u32, u32, &str)> {
    let (pid, rest) = line.trim_start().split_once(char::is_whitespace)?;
    let (ppid, comm) = rest.trim_start().split_once(char::is_whitespace)?;
    Some((pid.parse().ok()?, ppid.parse().ok()?, comm.trim()))
}

/// Bundle programs that never hold an install up (cli-update §5.1): a text terminal's `run`
/// keeps its shell across the swap, and `rapp update` itself runs as rapp-cli.
const NEVER_BLOCK: [&str; 2] = ["rapp-term", "rapp-cli"];

/// What ps says about the bundle's processes other than this service and its children.
#[derive(Debug, PartialEq)]
struct Procs {
    /// One that must be gone before the swap.
    blocking: bool,
    /// The GUI is among them.
    gui: bool,
}

/// None when the output does not show this service (`me`) under `<bundle>/Contents/`.
fn read_procs(ps: &str, me: u32, bundle: &str) -> Option<Procs> {
    let prefix = format!("{bundle}/Contents/");
    let gui = format!("{bundle}/Contents/MacOS/rapp");
    let procs: Vec<_> = ps.lines().filter_map(ps_fields).collect();
    if !procs.iter().any(|&(pid, _, comm)| pid == me && comm.starts_with(&prefix)) {
        return None;
    }
    let mut p = Procs { blocking: false, gui: false };
    for &(pid, ppid, comm) in &procs {
        let name = comm.rsplit('/').next().unwrap_or(comm);
        if pid == me || ppid == me || !comm.starts_with(&prefix) || NEVER_BLOCK.contains(&name) {
            continue;
        }
        p.blocking = true;
        p.gui |= comm == gui;
    }
    Some(p)
}

/// `read_procs` on this Mac's ps; None when ps fails or cannot be read.
async fn procs(state: &State) -> Option<Procs> {
    let o = state.update_opts.as_ref()?;
    let bundle = o.bundle.display().to_string();
    let args = vec!["-axo".to_string(), "pid=,ppid=,comm=".to_string()];
    match blocking(state, move |r| r.run(PS, &args)).await {
        Ok(out) if out.code == 0 => read_procs(&out.stdout, std::process::id(), &bundle),
        _ => None,
    }
}

/// Why the swap must wait: a bundle process that blocks it, or a ps that cannot be read.
async fn procs_in_use(state: &State) -> Option<String> {
    match procs(state).await {
        None => Some("查不了进程表".into()),
        Some(p) if p.blocking => Some(STILL_OPEN.into()),
        Some(_) => None,
    }
}

/// Why an auto install waits (cli-update §5.1), first reason only; None: nobody uses this Mac.
async fn auto_busy(state: &State, o: &UpdateOpts) -> Option<String> {
    if !state.activity.quiet_for(o.quiet) {
        return Some("最近有远程操作".into());
    }
    if state.activity.windows() > 0 {
        return Some("本机开着远程窗口".into());
    }
    let args: Vec<String> = up::IOREG_ARGS.iter().map(|a| a.to_string()).collect();
    let idle = match blocking(state, move |r| r.run(IOREG, &args)).await {
        Ok(out) if out.code == 0 => up::parse_hid_idle(&out.stdout),
        _ => None,
    };
    match idle {
        None => return Some("读不到本机空闲时间".into()),
        Some(d) if d < o.quiet => return Some("最近本机有人操作".into()),
        Some(_) => {}
    }
    if procs(state).await.is_none() {
        return Some("查不了进程表".into());
    }
    None
}

/// Every `idle_poll`: a ready version installs itself when allowed and nobody has used this Mac
/// for `quiet`. The GUI is asked to quit; when rApp is still open after that, it comes back and
/// the next try waits `auto_backoff`.
async fn try_auto(state: &Arc<State>, o: &UpdateOpts) {
    if !auto_allowed(state, o, "ready") {
        return set_auto_wait(state, None);
    }
    if state.update.lock().unwrap().auto_after.is_some_and(|t| Instant::now() < t) {
        return;
    }
    let why = auto_busy(state, o).await;
    set_auto_wait(state, why.clone());
    if why.is_some() {
        return;
    }
    let Some(busy) = Busy::begin(state) else { return };
    if !auto_allowed(state, o, "ready") {
        return;
    }
    match quit_gui_and_wait(state, o, None, By::Auto).await {
        Ok(gui_was_open) => put_in_place(state, busy, Mode::Auto, By::Auto, gui_was_open).await,
        Err(_) => {
            state.log.event(Lvl::Info, "update_auto_skipped", json!({"reason": STILL_OPEN}));
            state.update.lock().unwrap().auto_after = Some(Instant::now() + o.auto_backoff);
        }
    }
}

/// Remembers (and logs once) why the auto install is waiting.
fn set_auto_wait(state: &State, why: Option<String>) {
    let same = state.update.lock().unwrap().auto_wait == why;
    if same {
        return;
    }
    if let Some(w) = &why {
        state.log.event(Lvl::Info, "update_auto_wait", json!({"reason": w}));
    }
    modify(state, |u| u.auto_wait = why);
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

/// Everything an auto install needs except "nobody is using this Mac" (U-4c). Checked again
/// after every await. A ready version that was dismissed meanwhile goes back to idle.
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
    let dir = previous_dir(state);
    let aside = [dir.join(up::ASIDE), dir.join(up::LEGACY_ASIDE)];
    let found = staged.iter().chain(&aside).any(|p| std::fs::symlink_metadata(p).is_ok());
    if found {
        fail(state, Stage::Install, LEFTOVER);
    }
    found
}

async fn reopen_gui(state: &State, o: &UpdateOpts) {
    let b = o.bundle.display().to_string();
    let _ = blocking(state, move |r| r.run(OPEN, &[b])).await;
}

/// The install is off: the GUI may stay, and comes back if it quit for this.
async fn give_back_gui(state: &State, o: &UpdateOpts, gui_was_open: bool) {
    modify(state, |u| u.quit_gui = false);
    if gui_was_open {
        reopen_gui(state, o).await;
    }
}

/// An error reply with its fixed `code` (cli-update §5.4) beside the Chinese text.
fn code_err(code: &str, msg: &str) -> Value {
    json!({"ok": false, "error": msg, "code": code})
}

fn page_err(code: &str, msg: &str, page: Option<String>) -> Value {
    json!({"ok": false, "error": msg, "code": code, "page": page})
}

/// The `code` of a failure text the updater sets (`error_code` in the status).
fn error_code(error: &str) -> &'static str {
    match error {
        STILL_OPEN => "still_open",
        NEEDS_ADMIN => "needs_admin",
        NOT_LAUNCHD => "not_launchd",
        _ => "failed",
    }
}

/// Swaps in the ready version (or `previous/` for a rollback), writes the marker and asks for the
/// restart (K12, K13, K15, K25). When the GUI was open, a failure opens it again.
async fn put_in_place(state: &Arc<State>, busy: Busy, mode: Mode, by: By, gui_was_open: bool) {
    let Some(o) = state.update_opts.clone() else { return };
    let manual = mode != Mode::Auto;
    let failed = |stage, reason: &str| {
        fail(state, stage, reason);
        let o = o.clone();
        async move { give_back_gui(state, &o, gui_was_open).await }
    };
    if leftover(state) {
        return give_back_gui(state, &o, gui_was_open).await;
    }
    let prev_dir = previous_dir(state);
    let (src, to) = if mode == Mode::Rollback {
        let src = up::previous_app(&prev_dir);
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
    // once more after the last await, right before the swap. A manual install or rollback goes
    // in over open sessions: they drop with the restart.
    let before = std::mem::replace(&mut state.update.lock().unwrap().state, "installing");
    state.notify();
    let mut why = procs_in_use(state).await;
    if why.is_none() && !manual {
        why = auto_busy(state, &o).await;
    }
    if leftover(state) {
        return give_back_gui(state, &o, gui_was_open).await;
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
        return match (manual, why) {
            (true, Some(why)) => failed(Stage::Install, &why).await,
            // Dismissed or superseded while the GUI was going: `rapp update` must hear of it.
            (true, None) => failed(Stage::Install, NOTHING_TO_INSTALL).await,
            (false, _) => give_back_gui(state, &o, gui_was_open).await,
        };
    }
    let (bundle, pd) = (o.bundle.clone(), prev_dir.clone());
    match blocking(state, move |r| up::install(r, &src, &bundle, &pd)).await {
        Ok(()) => {
            let canon = |v: &str| up::canonical_version(v).unwrap_or_else(|| v.to_string());
            let m = Marker {
                from: canon(&from),
                to: canon(&to),
                at: up::now_secs(),
                gui_was_open,
                mode: mode.as_str().into(),
                perms_before: state.permissions.lock().unwrap().clone(),
                by: by.as_str().into(),
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
            give_back_gui(state, &o, gui_was_open).await;
        }
        Err(InstallError::NeedsAdmin) => {
            state.update.lock().unwrap().needs_admin = true;
            failed(Stage::Install, NEEDS_ADMIN).await;
        }
        Err(InstallError::Failed(reason)) => failed(Stage::Install, &reason).await,
    }
}

/// cli-update §5.2: raise `quit_gui`, then wait for the asking connection to close (at most
/// `gui_wait`) and for no bundle process that blocks the swap (at most `gui_wait` more).
/// Ok(whether the GUI was open, so it comes back after the restart). Still open: `quit_gui`
/// drops, the GUI comes back, Err. A GUI that asked itself was open, even if it is gone by the
/// time ps looks.
async fn quit_gui_and_wait(state: &Arc<State>, o: &UpdateOpts, closed: Option<watch::Receiver<()>>, by: By) -> Result<bool, bool> {
    // Read before the GUI hears `quit_gui`: it may be gone by the next ps.
    let gui_was_open = by == By::Gui || procs(state).await.is_some_and(|p| p.gui);
    modify(state, |u| u.quit_gui = true);
    if let Some(mut closed) = closed {
        // Nothing is ever sent: `changed` returns once the connection's sender is dropped.
        let _ = tokio::time::timeout(o.gui_wait, closed.changed()).await;
    }
    let deadline = Instant::now() + o.gui_wait;
    loop {
        if procs(state).await.is_some_and(|p| !p.blocking) {
            return Ok(gui_was_open);
        }
        let now = Instant::now();
        if now >= deadline {
            break;
        }
        tokio::time::sleep(MANUAL_POLL.min(deadline - now)).await;
    }
    give_back_gui(state, o, gui_was_open).await;
    Err(gui_was_open)
}

/// `update_apply` (K20). On ok the GUI quits; the install runs once rApp is closed.
pub async fn apply(state: &Arc<State>, confirm: bool, by: By, closed: watch::Receiver<()>) -> Value {
    let Some(o) = state.update_opts.clone() else { return code_err("nothing_to_install", NOTHING_TO_INSTALL) };
    {
        let u = state.update.lock().unwrap();
        if u.state != "ready" {
            return code_err("nothing_to_install", NOTHING_TO_INSTALL);
        }
        if u.needs_confirm && !confirm {
            return code_err("needs_confirm", "需要确认");
        }
        if u.needs_admin {
            return page_err("needs_admin", NEEDS_ADMIN, u.page.clone());
        }
        if !o.launchd {
            return page_err("not_launchd", NOT_LAUNCHD, u.page.clone());
        }
    }
    if leftover(state) {
        return code_err("failed", LEFTOVER);
    }
    // A pipeline or install already running would leave the GUI gone with nothing happening.
    let Some(busy) = Busy::begin(state) else { return code_err("busy", BUSY) };
    if state.update.lock().unwrap().state != "ready" {
        return code_err("nothing_to_install", NOTHING_TO_INSTALL);
    }
    let state = state.clone();
    tokio::spawn(async move {
        match quit_gui_and_wait(&state, &o, Some(closed), by).await {
            Ok(gui_was_open) => put_in_place(&state, busy, Mode::Manual, by, gui_was_open).await,
            Err(_) => fail(&state, Stage::Install, STILL_OPEN),
        }
    });
    ok(json!({}))
}

/// `update_rollback` (K13): swap with `previous/rapp.backup`, the same way as a manual install.
pub async fn rollback(state: &Arc<State>, by: By, closed: watch::Receiver<()>) -> Value {
    let Some(o) = state.update_opts.clone() else { return code_err("no_previous", NO_PREVIOUS) };
    if !o.launchd {
        return page_err("not_launchd", NOT_LAUNCHD, state.update.lock().unwrap().page.clone());
    }
    if state.update.lock().unwrap().state == "off" || !up::previous_app(&previous_dir(state)).is_dir() {
        return code_err("no_previous", NO_PREVIOUS);
    }
    if leftover(state) {
        return code_err("failed", LEFTOVER);
    }
    let Some(busy) = Busy::begin(state) else { return code_err("busy", BUSY) };
    let state = state.clone();
    tokio::spawn(async move {
        match quit_gui_and_wait(&state, &o, Some(closed), by).await {
            Ok(gui_was_open) => {
                // I-2: the older service must not fetch and install the version it is leaving.
                let from = state.update.lock().unwrap().current.clone();
                if let Some(v) = from {
                    dismiss(&state, &v);
                }
                put_in_place(&state, busy, Mode::Rollback, by, gui_was_open).await;
            }
            Err(_) => fail(&state, Stage::Install, STILL_OPEN),
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
    fn which_bundle_processes_block_and_which_is_the_gui() {
        let b = "/Applications/rApp.app";
        let ps = |extra: &str| format!("  10     1 {b}/Contents/MacOS/rapp-service\n  11    10 {b}/Contents/MacOS/rapp-host\n{extra}");
        let free = Some(Procs { blocking: false, gui: false });
        // Its own children, text terminals, the CLI (by either path) and other apps never block.
        let quiet = format!(
            "  20     1 {b}/Contents/MacOS/rapp-term\n  21     1 {b}/Contents/MacOS/rapp-cli\n  22     1 {}\n  23     1 /bin/zsh\n",
            up::CLI_LINK
        );
        assert_eq!(read_procs(&ps(&quiet), 10, b), free);
        assert_eq!(read_procs(&ps(&format!("  30     1 {b}/Contents/MacOS/rapp\n")), 10, b), Some(Procs { blocking: true, gui: true }));
        let helper = format!("  31     1 {b}/Contents/Helpers/x\n");
        assert_eq!(read_procs(&ps(&helper), 10, b), Some(Procs { blocking: true, gui: false }));
        // ps that does not show this service cannot be trusted.
        assert_eq!(read_procs(&ps(""), 99, b), None);
        assert_eq!(read_procs("", 10, b), None);
    }

    #[test]
    fn failure_texts_have_codes() {
        assert_eq!([STILL_OPEN, NEEDS_ADMIN, NOT_LAUNCHD, "x"].map(error_code), ["still_open", "needs_admin", "not_launchd", "failed"]);
        assert_eq!([By::Gui, By::Cli, By::Auto].map(By::as_str), ["gui", "cli", "auto"]);
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
