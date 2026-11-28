//! 不锁屏 (spec 2026-11-28): while the switch is on, a child holds this device awake, and auto-lock waits.
//! macOS: `rapp-host stay-awake --json`; Linux: `systemd-inhibit … cat`. Either lets go once its stdin closes.

use crate::state::State;
use rapp_net::log::Lvl;
use serde_json::{json, Value};
use std::future::Future;
use std::process::Stdio;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::process::{ChildStderr, Command};
use tokio::sync::watch;
use tokio::task::JoinHandle;
use tokio::time::Instant;

/// The longest wait between two tries of a failing child.
const MAX_BACKOFF: Duration = Duration::from_secs(60);
/// A child that ran this long counts as having worked: the next failure starts the backoff over.
const STEADY: Duration = Duration::from_secs(60);
/// How long a released child gets to exit after its stdin closes, before it is killed.
const RELEASE_WAIT: Duration = Duration::from_secs(2);
/// How long a child must stay up before it counts as holding: a failing hold exits within milliseconds.
const SETTLE: Duration = Duration::from_millis(500);
/// How much of a failing child's stderr line goes into the log.
const STDERR_MAX: usize = 200;

#[derive(Default)]
pub struct NoLock {
    /// A child is running and holding the device awake.
    held: AtomicBool,
    /// The service is stopping: let go of the hold, whatever the switch says.
    stopping: AtomicBool,
}

impl NoLock {
    pub fn held(&self) -> bool {
        self.held.load(Ordering::SeqCst)
    }

    /// The service is stopping: the supervisor closes the child's stdin, so it exits by itself,
    /// and then ends. The caller notifies `state.changed`.
    pub(crate) fn stop(&self) {
        self.stopping.store(true, Ordering::SeqCst);
    }
}

#[derive(Clone, Debug, PartialEq)]
enum Report {
    Held(bool),
    Failed { code: Option<i32>, stderr: String },
}

/// Whether this device can keep itself awake here: the Mac, or Linux under Hyprland.
/// Gates the snapshot keys, which come with the remote op.
#[allow(dead_code)] // until the snapshot uses it
pub fn supported() -> bool {
    let os = std::env::consts::OS;
    let hypr_dir = os == "linux"
        && std::env::var_os("XDG_RUNTIME_DIR").is_some_and(|d| std::path::Path::new(&d).join("hypr").is_dir());
    supported_in(os, |k| std::env::var(k).ok(), hypr_dir)
}

/// `hypr_dir`: `$XDG_RUNTIME_DIR/hypr` is a directory. A systemd user service may not carry the
/// Hyprland environment, but Hyprland's runtime directory is there.
#[allow(dead_code)] // until the snapshot uses `supported`
fn supported_in(os: &str, env: impl Fn(&str) -> Option<String>, hypr_dir: bool) -> bool {
    match os {
        "macos" => true,
        "linux" => {
            env("HYPRLAND_INSTANCE_SIGNATURE").is_some_and(|s| !s.is_empty())
                || env("XDG_CURRENT_DESKTOP").is_some_and(|s| s.to_lowercase().contains("hyprland"))
                || hypr_dir
        }
        _ => false,
    }
}

/// Turns the switch on or off: saves it, wakes everyone watching, and logs `no_lock_set` with `by` (an object).
pub fn set(state: &State, on: bool, by: Value) -> Result<(), String> {
    {
        let mut cfg = state.cfg.lock().unwrap();
        let mut next = cfg.clone();
        next.no_lock = Some(on);
        next.save(&state.home).map_err(|e| format!("save config: {e:#}"))?;
        *cfg = next;
    }
    state.notify();
    let mut fields = if by.is_object() { by } else { json!({}) };
    fields["on"] = json!(on);
    state.log.event(Lvl::Info, "no_lock_set", fields);
    Ok(())
}

/// Keeps a child running while the switch is on; ends after `NoLock::stop` once the child is let go.
pub fn spawn(state: Arc<State>) -> JoinHandle<()> {
    tokio::spawn(async move {
        let wanted = |s: &State| s.cfg.lock().unwrap().no_lock() && !s.no_lock.stopping.load(Ordering::SeqCst);
        let (tx, rx) = watch::channel(wanted(&state));
        let mut changed = state.changed.subscribe();
        let st = state.clone();
        // Dropping `tx` once stopping tells the supervisor to let go and end. The first pass also
        // catches a `stop` that came before `subscribe`.
        let feed = async move {
            loop {
                let w = wanted(&st);
                tx.send_if_modified(|v| std::mem::replace(v, w) != w);
                if st.no_lock.stopping.load(Ordering::SeqCst) || changed.changed().await.is_err() {
                    break;
                }
            }
        };
        let st = state.clone();
        let failing = AtomicBool::new(false);
        let report = move |r: Report| {
            let log = first_of_streak(&failing, &r);
            match r {
                Report::Held(h) => {
                    if st.no_lock.held.swap(h, Ordering::SeqCst) != h {
                        st.notify();
                    }
                }
                Report::Failed { code, stderr } if log => {
                    st.log.event(Lvl::Warn, "no_lock_hold_failed", json!({"code": code, "stderr": stderr}));
                }
                Report::Failed { .. } => {}
            }
        };
        let make = || {
            let st = state.clone();
            async move { command(&st).await }
        };
        tokio::join!(feed, supervise(rx, make, Duration::from_secs(1), SETTLE, report));
    })
}

/// The child that holds the device awake here; None where there is none.
async fn command(state: &State) -> Option<Command> {
    if cfg!(target_os = "macos") {
        let Ok(mut c) = crate::workers::host_command(state).await else {
            // Called once each time the switch goes on: one line, no retry until it goes off and on.
            let stderr = "could not start the keep-awake helper";
            state.log.event(Lvl::Warn, "no_lock_hold_failed", json!({"code": null, "stderr": stderr}));
            return None;
        };
        c.args(["stay-awake", "--json"]);
        Some(c)
    } else if cfg!(target_os = "linux") {
        let mut c = rapp_net::proc::tokio_command("systemd-inhibit");
        c.args(["--what=idle:sleep", "--mode=block", "--who=rapp", "--why=不锁屏", "cat"]);
        Some(c)
    } else {
        None
    }
}

/// Whether `r` is the first failure of a streak, the only one logged so the retries do not fill
/// 访问记录. A real hold (`Held(true)`, after the settle) ends the streak.
fn first_of_streak(failing: &AtomicBool, r: &Report) -> bool {
    match r {
        Report::Held(true) => {
            failing.store(false, Ordering::SeqCst);
            false
        }
        Report::Held(false) => false,
        Report::Failed { .. } => !failing.swap(true, Ordering::SeqCst),
    }
}

/// `base * 2^(failures-1)`, at most `MAX_BACKOFF`.
fn backoff(base: Duration, failures: u32) -> Duration {
    let factor = 1u32.checked_shl(failures.saturating_sub(1)).unwrap_or(u32::MAX);
    base.saturating_mul(factor).min(MAX_BACKOFF)
}

/// Runs `make()`'s child while `want` is true, restarting it with a backoff when it exits on its own.
/// `Held(true)` comes once the child has stayed up for `settle`, and `Held(false)` only after it.
/// Letting go closes the child's stdin, waits `RELEASE_WAIT`, then kills it. Returns once `want` closes,
/// after letting go. `make()` giving None holds nothing and reports nothing.
async fn supervise<F, Fut, R>(mut want: watch::Receiver<bool>, make: F, base: Duration, settle: Duration, report: R)
where
    F: Fn() -> Fut,
    Fut: Future<Output = Option<Command>>,
    R: Fn(Report),
{
    let mut failures = 0u32;
    loop {
        if !wait_for(&mut want, true).await {
            return;
        }
        let Some(mut cmd) = make().await else {
            if !wait_for(&mut want, false).await {
                return;
            }
            continue;
        };
        cmd.stdin(Stdio::piped()).stdout(Stdio::null()).stderr(Stdio::piped()).kill_on_drop(true);
        let started = Instant::now();
        match cmd.spawn() {
            Err(e) => report(Report::Failed { code: None, stderr: clip(&e.to_string()) }),
            Ok(mut child) => {
                let stdin = child.stdin.take();
                let mut last = tokio::spawn(last_line(child.stderr.take()));
                let mut held = false;
                let exited = loop {
                    tokio::select! {
                        st = child.wait() => break Some(st),
                        r = want.changed() => if r.is_err() || !*want.borrow_and_update() { break None },
                        _ = tokio::time::sleep_until(started + settle), if !held => {
                            held = true;
                            report(Report::Held(true));
                        }
                    }
                };
                drop(stdin);
                let Some(status) = exited else {
                    if tokio::time::timeout(RELEASE_WAIT, child.wait()).await.is_err() {
                        let _ = child.kill().await;
                    }
                    last.abort();
                    if held {
                        report(Report::Held(false));
                    }
                    failures = 0;
                    continue;
                };
                let code = status.ok().and_then(|s| s.code());
                let stderr = match tokio::time::timeout(Duration::from_secs(1), &mut last).await {
                    Ok(r) => r.unwrap_or_default(),
                    Err(_) => {
                        last.abort();
                        String::new()
                    }
                };
                report(Report::Failed { code, stderr });
                if held {
                    report(Report::Held(false));
                }
            }
        }
        failures = if started.elapsed() >= STEADY { 1 } else { failures + 1 };
        // Wait before the next try, unless the switch goes off meanwhile.
        let wake = Instant::now() + backoff(base, failures);
        loop {
            tokio::select! {
                _ = tokio::time::sleep_until(wake) => break,
                r = want.changed() => {
                    if r.is_err() {
                        return;
                    }
                    if !*want.borrow_and_update() {
                        failures = 0;
                        break;
                    }
                }
            }
        }
    }
}

/// Waits until `want` is `value`; false once it closes without being so.
async fn wait_for(want: &mut watch::Receiver<bool>, value: bool) -> bool {
    loop {
        if *want.borrow_and_update() == value {
            return true;
        }
        if want.changed().await.is_err() {
            return false;
        }
    }
}

/// The last non-empty line on `stderr`, clipped.
async fn last_line(stderr: Option<ChildStderr>) -> String {
    let Some(stderr) = stderr else { return String::new() };
    let mut lines = BufReader::new(stderr).split(b'\n');
    let mut last = String::new();
    while let Ok(Some(line)) = lines.next_segment().await {
        let line = String::from_utf8_lossy(&line);
        if !line.trim().is_empty() {
            last = clip(line.trim());
        }
    }
    last
}

fn clip(s: &str) -> String {
    s.chars().take(STDERR_MAX).collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Arc, Mutex};

    fn env_of(pairs: &'static [(&'static str, &'static str)]) -> impl Fn(&str) -> Option<String> {
        move |k| pairs.iter().find(|(n, _)| *n == k).map(|(_, v)| v.to_string())
    }

    #[test]
    fn supported_cases() {
        assert!(supported_in("macos", env_of(&[]), false));
        assert!(!supported_in("linux", env_of(&[]), false));
        assert!(supported_in("linux", env_of(&[("HYPRLAND_INSTANCE_SIGNATURE", "x")]), false));
        assert!(!supported_in("linux", env_of(&[("HYPRLAND_INSTANCE_SIGNATURE", "")]), false));
        assert!(supported_in("linux", env_of(&[("XDG_CURRENT_DESKTOP", "Hyprland")]), false));
        assert!(!supported_in("linux", env_of(&[("XDG_CURRENT_DESKTOP", "GNOME")]), false));
        assert!(supported_in("linux", env_of(&[]), true));
        assert!(!supported_in("windows", env_of(&[]), true));
    }

    #[test]
    fn backoff_doubles_to_60s() {
        let secs: Vec<u64> = (1..=9).map(|n| backoff(Duration::from_secs(1), n).as_secs()).collect();
        assert_eq!(secs, [1, 2, 4, 8, 16, 32, 60, 60, 60]);
        assert_eq!(backoff(Duration::from_secs(1), 100), Duration::from_secs(60));
    }

    fn sh(script: &'static str) -> impl Fn() -> std::future::Ready<Option<tokio::process::Command>> {
        move || {
            let mut c = tokio::process::Command::new("sh");
            c.args(["-c", script]);
            std::future::ready(Some(c))
        }
    }

    /// A settle short enough for tests.
    const SHORT: Duration = Duration::from_millis(50);

    type Seen = Arc<Mutex<Vec<Report>>>;

    fn recorder() -> (Seen, impl Fn(Report)) {
        let seen: Seen = Arc::default();
        let s = seen.clone();
        (seen, move |r| s.lock().unwrap().push(r))
    }

    async fn wait_for(seen: &Seen, within: Duration, f: impl Fn(&[Report]) -> bool) {
        let deadline = tokio::time::Instant::now() + within;
        while !f(&seen.lock().unwrap()) {
            assert!(tokio::time::Instant::now() < deadline, "{:?}", seen.lock().unwrap());
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    }

    #[tokio::test]
    async fn supervise_holds_and_releases() {
        let (tx, rx) = watch::channel(false);
        let (seen, report) = recorder();
        let task = tokio::spawn(supervise(rx, sh("cat >/dev/null"), Duration::from_secs(1), SHORT, report));
        tx.send(true).unwrap();
        wait_for(&seen, Duration::from_secs(1), |r| r == [Report::Held(true)]).await;
        tx.send(false).unwrap();
        wait_for(&seen, Duration::from_secs(3), |r| r == [Report::Held(true), Report::Held(false)]).await;
        drop(tx);
        tokio::time::timeout(Duration::from_secs(3), task).await.expect("ends once want closes").unwrap();
    }

    #[tokio::test]
    async fn supervise_restarts_a_failing_child() {
        let (_tx, rx) = watch::channel(true);
        let (seen, report) = recorder();
        tokio::spawn(supervise(rx, sh("echo boom >&2; exit 3"), Duration::from_millis(10), SHORT, report));
        let boom = Report::Failed { code: Some(3), stderr: "boom".into() };
        wait_for(&seen, Duration::from_secs(1), |r| r.iter().filter(|x| **x == boom).count() >= 2).await;
        let r = seen.lock().unwrap().clone();
        assert!(r.iter().all(|x| *x == boom), "never held: {r:?}");
    }

    #[tokio::test]
    async fn supervise_child_gone_before_the_settle_is_never_held() {
        let (_tx, rx) = watch::channel(true);
        let (seen, report) = recorder();
        let settle = Duration::from_millis(300);
        tokio::spawn(supervise(rx, sh("sleep 0.05; exit 1"), Duration::from_millis(10), settle, report));
        let gone = Report::Failed { code: Some(1), stderr: String::new() };
        wait_for(&seen, Duration::from_secs(2), |r| r.iter().filter(|x| **x == gone).count() >= 2).await;
        let r = seen.lock().unwrap().clone();
        assert!(!r.iter().any(|x| matches!(x, Report::Held(_))), "{r:?}");
    }

    #[test]
    fn only_the_first_failure_of_a_streak_is_logged() {
        let failing = AtomicBool::new(false);
        let fail = Report::Failed { code: Some(1), stderr: String::new() };
        let logged: Vec<bool> = [&fail, &fail, &Report::Held(false), &fail, &Report::Held(true), &fail, &fail]
            .into_iter()
            .map(|r| first_of_streak(&failing, r))
            .collect();
        assert_eq!(logged, [true, false, false, false, false, true, false]);
    }

    #[tokio::test]
    async fn supervise_none_reports_nothing() {
        let (_tx, rx) = watch::channel(true);
        let (seen, report) = recorder();
        tokio::spawn(supervise(rx, || std::future::ready(None), Duration::from_millis(10), SHORT, report));
        tokio::time::sleep(Duration::from_millis(200)).await;
        assert!(seen.lock().unwrap().is_empty(), "{:?}", seen.lock().unwrap());
    }
}
