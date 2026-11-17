//! The hub in-process for iOS (spec 2026-11-17-rapp-ipad-duo-design §6.1): `rapp_hub::run` on an in-memory
//! pipe pair behind C functions (`include/rapp_hub.h`). The hub's own code is unchanged.

use std::ffi::{c_char, CStr};
use std::path::PathBuf;
use std::ptr;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use rapp_net::log::{Log, Lvl};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::sync::mpsc;

pub type OnLine = extern "C" fn(*const c_char);

/// A running hub: its runtime, the writer of its input and the task running it (and, last, signalling the end).
struct Running {
    rt: tokio::runtime::Runtime,
    input: mpsc::UnboundedSender<String>,
    hub: tokio::task::JoinHandle<()>,
    /// Set once the hub has ended (before the NULL line); `send` then answers -3.
    exited: Arc<AtomicBool>,
}

static HUB: Mutex<Option<Running>> = Mutex::new(None);

/// Test hook: the next hub run panics instead of starting.
#[cfg(test)]
static FORCE_PANIC: AtomicBool = AtomicBool::new(false);

fn text(p: *const c_char) -> Option<String> {
    if p.is_null() {
        return None;
    }
    unsafe { CStr::from_ptr(p) }.to_str().ok().map(str::to_owned)
}

#[no_mangle]
pub extern "C" fn rapp_hub_start(
    home: *const c_char,
    log_dir: *const c_char,
    name: *const c_char,
    on_line: OnLine,
) -> i32 {
    let mut slot = HUB.lock().unwrap_or_else(|e| e.into_inner());
    if slot.is_some() {
        return -1;
    }
    let (Some(home), Some(log_dir), Some(name)) = (text(home), text(log_dir), text(name)) else { return -2 };
    let Ok(rt) = tokio::runtime::Builder::new_multi_thread().enable_all().thread_name("rapp-hub").build() else {
        return -3;
    };
    let (input, mut commands) = mpsc::unbounded_channel::<String>();
    let (mut to_hub, hub_in) = tokio::io::duplex(1 << 16);
    let (hub_out, from_hub) = tokio::io::duplex(1 << 16);
    // Commands → the hub's input; the input ends (EOF) once every sender is gone.
    rt.spawn(async move {
        while let Some(line) = commands.recv().await {
            if to_hub.write_all(line.as_bytes()).await.is_err() {
                break;
            }
        }
    });
    // The hub's output → on_line, one line at a time; ends when the hub drops its output.
    let forwarder = rt.spawn(async move {
        let mut lines = BufReader::new(from_hub).lines();
        while let Ok(Some(line)) = lines.next_line().await {
            // Ownership goes to the callee: Dart's listener reads the line later, then frees it.
            if let Ok(c) = std::ffi::CString::new(line) {
                on_line(c.into_raw());
            }
        }
    });
    let log = Log::file(&PathBuf::from(&log_dir), "hub.log");
    let opts = rapp_hub::Opts {
        home: PathBuf::from(home),
        bin_dir: None,
        log: log.clone(),
        presence_every: Some(Duration::from_secs(30)),
        upgrade: rapp_hub::UpgradeTimes::default(),
        name: Some(name),
        owns_access: true,
        embed_only: true,
        dual_stack: true,
    };
    let exited = Arc::new(AtomicBool::new(false));
    let done = exited.clone();
    let hub = rt.spawn(async move {
        // Error first into hub.log, then all output lines, then the one NULL.
        // `run` is its own task so a panic in it is caught here and ends the hub like any other exit.
        let run = tokio::spawn(async move {
            #[cfg(test)]
            if FORCE_PANIC.swap(false, Ordering::SeqCst) {
                panic!("forced hub panic");
            }
            rapp_hub::run(opts, hub_in, hub_out).await
        });
        match run.await {
            Ok(Ok(())) => {}
            Ok(Err(e)) => log.msg(Lvl::Error, format_args!("{e:#}")),
            Err(e) => log.msg(Lvl::Error, format_args!("hub task failed: {e}")),
        }
        log.flush();
        done.store(true, Ordering::SeqCst);
        let _ = forwarder.await;
        on_line(ptr::null());
    });
    *slot = Some(Running { rt, input, hub, exited });
    0
}

/// Frees a line `on_line` handed over. Null is ignored.
#[no_mangle]
pub extern "C" fn rapp_hub_free_line(line: *mut c_char) {
    if !line.is_null() {
        drop(unsafe { std::ffi::CString::from_raw(line) });
    }
}

#[no_mangle]
pub extern "C" fn rapp_hub_send(line: *const c_char) -> i32 {
    let slot = HUB.lock().unwrap_or_else(|e| e.into_inner());
    let Some(running) = slot.as_ref() else { return -1 };
    if running.exited.load(Ordering::SeqCst) {
        return -3;
    }
    let Some(mut line) = text(line) else { return -2 };
    if !line.ends_with('\n') {
        line.push('\n');
    }
    if running.input.send(line).is_err() {
        return -3;
    }
    0
}

#[no_mangle]
pub extern "C" fn rapp_hub_stop() {
    let running = HUB.lock().unwrap_or_else(|e| e.into_inner()).take();
    let Some(Running { rt, input, hub, .. }) = running else { return };
    drop(input);
    // The hub task ends after the forwarder has delivered everything, so nothing is pending afterwards.
    let _ = rt.block_on(async { tokio::time::timeout(Duration::from_secs(2), hub).await });
    rt.shutdown_timeout(Duration::from_secs(1));
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::CString;
    use std::time::Instant;

    /// Serialises the tests: the hub is a process-wide singleton.
    static TEST_LOCK: Mutex<()> = Mutex::new(());
    /// Lines as the callback got them; None is the exit signal.
    static LINES: Mutex<Vec<Option<String>>> = Mutex::new(Vec::new());

    extern "C" fn collect(line: *const c_char) {
        if line.is_null() {
            LINES.lock().unwrap().push(None);
            return;
        }
        let s = unsafe { CStr::from_ptr(line) }.to_string_lossy().into_owned();
        rapp_hub_free_line(line as *mut c_char);
        LINES.lock().unwrap().push(Some(s));
    }

    fn count() -> usize {
        LINES.lock().unwrap().len()
    }

    fn start_named(home: &std::path::Path, log_dir: &std::path::Path, name: &str) -> i32 {
        LINES.lock().unwrap().clear();
        let h = CString::new(home.to_str().unwrap()).unwrap();
        let l = CString::new(log_dir.to_str().unwrap()).unwrap();
        let n = CString::new(name).unwrap();
        rapp_hub_start(h.as_ptr(), l.as_ptr(), n.as_ptr(), collect)
    }

    fn start(home: &std::path::Path) -> i32 {
        start_named(home, &home.join("logs"), "test")
    }

    fn send(line: &str) -> i32 {
        rapp_hub_send(CString::new(line).unwrap().as_ptr())
    }

    /// True once a line matching `f` is among those collected within `limit`.
    fn wait_for(f: impl Fn(&str) -> bool, limit: Duration) -> bool {
        let end = Instant::now() + limit;
        while Instant::now() < end {
            if LINES.lock().unwrap().iter().flatten().any(|l| f(l)) {
                return true;
            }
            std::thread::sleep(Duration::from_millis(20));
        }
        false
    }

    #[test]
    fn hosts_round_trip_then_restart() {
        let _g = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let home = tempfile::tempdir().unwrap();
        let hosts = |l: &str| l.contains(r#""event":"hosts""#);
        assert_eq!(start(home.path()), 0);
        assert_eq!(start(home.path()), -1, "already running");
        assert_eq!(send(r#"{"cmd":"hosts"}"#), 0);
        assert!(wait_for(hosts, Duration::from_secs(5)), "first hosts answer");
        rapp_hub_stop();
        assert_eq!(send(r#"{"cmd":"hosts"}"#), -1, "stopped");
        assert_eq!(start(home.path()), 0, "starts again after a stop");
        assert_eq!(send("{\"cmd\":\"hosts\"}\n"), 0);
        assert!(wait_for(hosts, Duration::from_secs(5)), "hosts answer after restart");
        rapp_hub_stop();
    }

    #[test]
    fn send_before_start_is_minus_one() {
        let _g = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        assert_eq!(send(r#"{"cmd":"hosts"}"#), -1);
    }

    #[test]
    fn exit_signals_null_and_send_is_minus_three() {
        let _g = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("not-a-dir");
        std::fs::write(&file, b"x").unwrap();
        assert_eq!(start_named(&file, &dir.path().join("logs"), "test"), 0);
        let end = Instant::now() + Duration::from_secs(5);
        while Instant::now() < end && !matches!(LINES.lock().unwrap().last(), Some(None)) {
            std::thread::sleep(Duration::from_millis(20));
        }
        assert_eq!(LINES.lock().unwrap().last(), Some(&None), "NULL after the hub exited");
        assert_eq!(send(r#"{"cmd":"hosts"}"#), -3);
        let log = std::fs::read_to_string(dir.path().join("logs").join("hub.log")).unwrap_or_default();
        assert!(log.contains("device key"), "error is in hub.log: {log}");
        rapp_hub_stop();
    }

    #[test]
    fn stop_waits_for_forwarder() {
        let _g = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let home = tempfile::tempdir().unwrap();
        assert_eq!(start(home.path()), 0);
        assert_eq!(send(r#"{"cmd":"hosts"}"#), 0);
        rapp_hub_stop();
        {
            let lines = LINES.lock().unwrap();
            assert!(
                lines.iter().flatten().any(|l| l.contains(r#""event":"hosts""#)),
                "the hosts answer was delivered before stop returned"
            );
            assert_eq!(lines.last(), Some(&None), "stop returns after the NULL");
        }
        let before = count();
        std::thread::sleep(Duration::from_millis(100));
        assert_eq!(count(), before, "nothing arrives after stop returned");
    }

    #[test]
    fn name_reaches_access() {
        let _g = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let home = tempfile::tempdir().unwrap();
        assert_eq!(start_named(home.path(), &home.path().join("logs"), "iPad"), 0);
        assert_eq!(send(r#"{"cmd":"access"}"#), 0);
        assert!(
            wait_for(|l| l.contains(r#""event":"access""#) && l.contains(r#""name":"iPad""#), Duration::from_secs(5)),
            "access event carries the name"
        );
        rapp_hub_stop();
    }

    #[test]
    fn hub_panic_signals_null_and_send_is_minus_three() {
        let _g = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let home = tempfile::tempdir().unwrap();
        FORCE_PANIC.store(true, Ordering::SeqCst);
        assert_eq!(start(home.path()), 0);
        let end = Instant::now() + Duration::from_secs(5);
        while Instant::now() < end && !matches!(LINES.lock().unwrap().last(), Some(None)) {
            std::thread::sleep(Duration::from_millis(20));
        }
        assert_eq!(LINES.lock().unwrap().last(), Some(&None), "NULL after the hub panicked");
        assert_eq!(send(r#"{"cmd":"hosts"}"#), -3);
        let log = std::fs::read_to_string(home.path().join("logs").join("hub.log")).unwrap_or_default();
        assert!(log.contains("panic"), "panic is in hub.log: {log}");
        rapp_hub_stop();
    }
}
