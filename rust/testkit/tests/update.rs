//! The updater inside rapp-service (online-update plan Task 4): checks, downloads, waits until
//! nobody uses rapp, installs and asks for a restart. Every external program is a FakeRunner
//! script; the "bundle" and every other path live in a temp dir.

mod common;

use common::*;
use rapp_net::line::{read_json, write_json};
use rapp_net::quic::bi;
use rapp_service::{Runner, Service, UpdateOpts};
use rapp_update::fake::{arg_after, FakeRunner};
use rapp_update::runner::{Out, CODESIGN, CURL, DF, DITTO, OPEN, PLUTIL, PS};
use serde_json::{json, Value};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicI32, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tempfile::TempDir;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};

const DR: &str = r#"identifier "com.rapp.rapp" and anchor apple generic and certificate leaf[subject.CN] = "A""#;
const OTHER_DR: &str = r#"identifier "com.rapp.rapp" and anchor apple generic and certificate leaf[subject.CN] = "B""#;
const URL: &str = "https://example.invalid/latest.json";
const POLL: Duration = Duration::from_millis(50);
const DF_PLENTY: &str =
    "Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/disk3s5 1000000000 50 900000000 1% /\n";

fn zip_bytes() -> Vec<u8> {
    (0..4096u32).map(|i| (i * 13 % 251) as u8).collect()
}

fn make_app(app: &Path, marker: &str) {
    std::fs::create_dir_all(app.join("Contents")).unwrap();
    std::fs::write(app.join("Contents/marker"), marker).unwrap();
}

fn marker_of(app: &Path) -> String {
    std::fs::read_to_string(app.join("Contents/marker")).unwrap_or_default()
}

fn s(p: &Path) -> String {
    p.display().to_string()
}

struct Knobs {
    /// The version in the manifest.
    version: &'static str,
    /// The downloaded app's designated requirement.
    new_dr: &'static str,
    curl_code: i32,
    /// The zip arrives in two halves with this pause between them.
    split: Option<Duration>,
    launchd: bool,
    /// How long a manual install waits for the GUI's connection to close.
    gui_wait: Duration,
    /// Extra `service.json` fields.
    cfg: Value,
}

impl Default for Knobs {
    fn default() -> Self {
        Knobs {
            version: "0.5.0",
            new_dr: DR,
            curl_code: 0,
            split: None,
            launchd: true,
            gui_wait: Duration::from_millis(300),
            cfg: json!({}),
        }
    }
}

struct Env {
    _tmp: TempDir,
    home: PathBuf,
    bins: TempDir,
    bundle: PathBuf,
    cache: PathBuf,
    runner: Arc<FakeRunner>,
    /// Extra lines the fake ps prints.
    ps_extra: Arc<Mutex<Vec<String>>>,
    /// Non-zero: the fake ps fails with this exit code.
    ps_code: Arc<AtomicI32>,
    launchd: bool,
    gui_wait: Duration,
    svc: Option<Service>,
}

impl Env {
    fn new(k: Knobs) -> Env {
        let tmp = tempfile::tempdir().unwrap();
        let home = tmp.path().join("home");
        std::fs::create_dir_all(&home).unwrap();
        let bundle = tmp.path().join("Applications/rapp.app");
        make_app(&bundle, "current");
        let cache = tmp.path().join("cache");
        service_json(&home, None);
        let path = home.join("service.json");
        let mut cfg: Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
        cfg["update_url"] = json!(URL);
        for (key, v) in k.cfg.as_object().unwrap() {
            cfg[key] = v.clone();
        }
        rapp_net::config::write_json(&path, &cfg).unwrap();

        let ps_extra: Arc<Mutex<Vec<String>>> = Arc::default();
        let ps_code = Arc::new(AtomicI32::new(0));
        let runner = Arc::new(fake(&k, &bundle, &cache, &home, tmp.path(), ps_extra.clone(), ps_code.clone()));
        Env {
            _tmp: tmp,
            home,
            bins: bins(),
            bundle,
            cache,
            runner,
            ps_extra,
            ps_code,
            launchd: k.launchd,
            gui_wait: k.gui_wait,
            svc: None,
        }
    }

    async fn start(&mut self) {
        let opts = UpdateOpts {
            bundle: self.bundle.clone(),
            launchd: self.launchd,
            cache_dir: self.cache.clone(),
            first_check: Duration::from_millis(50),
            tick: Duration::from_millis(50),
            idle_poll: POLL,
            healthy_after: Duration::from_millis(200),
            gui_wait: self.gui_wait,
        };
        let runner: Arc<dyn Runner> = self.runner.clone();
        self.svc = Some(start_service_with(&self.home, self.bins.path(), runner, Some(opts)).await);
    }

    fn svc(&self) -> &Service {
        self.svc.as_ref().unwrap()
    }

    async fn call(&self, cmd: Value) -> Value {
        ipc_once(self.svc(), &self.home, cmd).await
    }

    async fn update(&self) -> Value {
        self.call(json!({"cmd":"status"})).await["update"].clone()
    }

    async fn wait_state(&self, want: &str) -> Value {
        let deadline = tokio::time::Instant::now() + WAIT;
        loop {
            let u = self.update().await;
            if u["state"] == want {
                return u;
            }
            assert!(tokio::time::Instant::now() < deadline, "never {want}: {u}");
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    }

    async fn wait_restart(&self) {
        tokio::time::timeout(WAIT, self.svc().restart_wanted()).await.expect("restart requested");
    }

    /// No restart within `d`.
    async fn no_restart_for(&self, d: Duration) {
        assert!(tokio::time::timeout(d, self.svc().restart_wanted()).await.is_err(), "restart requested");
    }

    fn calls_of(&self, prog: &str) -> Vec<Vec<String>> {
        self.runner.calls().into_iter().filter(|(p, _)| p == prog).map(|(_, a)| a).collect()
    }

    fn applied(&self) -> Value {
        serde_json::from_slice(&std::fs::read(self.home.join("update-applied.json")).unwrap()).unwrap()
    }

    fn previous(&self) -> PathBuf {
        self.home.join("previous/rapp.app")
    }

    fn gui_line(&self) -> String {
        format!("  999     1 {}/Contents/MacOS/rapp", s(&self.bundle))
    }
}

fn fake(
    k: &Knobs,
    bundle: &Path,
    cache: &Path,
    home: &Path,
    tmp: &Path,
    ps_extra: Arc<Mutex<Vec<String>>>,
    ps_code: Arc<AtomicI32>,
) -> FakeRunner {
    // sha and size of the zip the fake curl serves.
    let zip = zip_bytes();
    let probe = tmp.join("probe.zip");
    std::fs::write(&probe, &zip).unwrap();
    let sha = rapp_update::sha256_file(&probe).unwrap();
    let v = k.version;
    let manifest = json!({
        "version": v, "notes": "修了一些问题",
        "assets": {"macos-arm64": {
            "url": format!("https://example.invalid/releases/download/v{v}/rapp-{v}-macos-arm64.zip"),
            "sha256": sha, "size": zip.len(),
        }},
    })
    .to_string();
    let (curl_code, split) = (k.curl_code, k.split);
    let (cache_p, cache_c) = (cache.to_path_buf(), cache.to_path_buf());
    let prev = home.join("previous");
    let new_dr = k.new_dr.to_string();
    let bundle = s(bundle);
    FakeRunner::new()
        .on(PLUTIL, move |a| {
            let p = PathBuf::from(a.last().unwrap());
            if let Ok(rest) = p.strip_prefix(&cache_p) {
                return Out::ok(format!("{}\n", rest.iter().next().unwrap().to_string_lossy()));
            }
            Out::ok(if p.starts_with(&prev) { "0.4.0\n" } else { "0.4.1\n" })
        })
        .on(CODESIGN, move |a| {
            if a[0] == "--verify" {
                return Out::ok("");
            }
            let dr = if Path::new(a.last().unwrap()).starts_with(&cache_c) { new_dr.as_str() } else { DR };
            Out { code: 0, stdout: String::new(), stderr: format!("Executable=/x\ndesignated => {dr}\n") }
        })
        .on(CURL, move |a| {
            if curl_code != 0 {
                return Out::fail(curl_code, "");
            }
            let o = arg_after(a, "-o").unwrap();
            if o.ends_with("latest.json.tmp") {
                std::fs::write(o, &manifest).unwrap();
                return Out::ok("");
            }
            let mut f = std::fs::OpenOptions::new().create(true).append(true).open(o).unwrap();
            match split {
                Some(pause) => {
                    f.write_all(&zip[..zip.len() / 2]).unwrap();
                    f.flush().unwrap();
                    std::thread::sleep(pause);
                    f.write_all(&zip[zip.len() / 2..]).unwrap();
                }
                None => f.write_all(&zip).unwrap(),
            }
            Out::ok("")
        })
        .on(DITTO, |a| {
            if a.len() == 4 && a[0] == "-x" {
                make_app(&Path::new(&a[3]).join("rapp.app"), "new");
                return Out::ok("");
            }
            Out::fail(1, "")
        })
        .on(DF, |_| Out::ok(DF_PLENTY))
        .on(PS, move |_| {
            let code = ps_code.load(Ordering::SeqCst);
            if code != 0 {
                return Out::fail(code, "");
            }
            let me = std::process::id();
            let mut out = format!(
                "    1     0 /sbin/launchd\n{me} 1 {bundle}/Contents/MacOS/rapp-service\n4242 {me} {bundle}/Contents/MacOS/rapp-host\n"
            );
            for l in ps_extra.lock().unwrap().iter() {
                out.push_str(l);
                out.push('\n');
            }
            Out::ok(out)
        })
        .on(OPEN, |_| Out::ok(""))
}

/// Sends the worker token over an `open` stream and checks bytes go both ways.
async fn open_echo(conn: &quinn::Connection) -> rapp_net::quic::BiStream {
    let mut s = bi(conn.open_bi().await.unwrap());
    write_json(&mut s, &json!({"op":"open","app":"com.example.echo"})).await.unwrap();
    let r = read_json(&mut s).await.unwrap();
    assert_eq!(r["ok"], true, "{r}");
    let wt = r["token"].as_str().unwrap().to_string();
    let mut r = BufReader::new(&mut s);
    r.get_mut().write_all(format!("{wt}\n").as_bytes()).await.unwrap();
    let mut line = String::new();
    r.read_line(&mut line).await.unwrap();
    assert_eq!(line, "ok\n");
    s
}

/// A B session on A's echo app; the session ends when the returned pieces are dropped.
async fn session(svc: &Service) -> (quinn::Endpoint, quinn::Connection, rapp_net::quic::BiStream) {
    let ep = b_endpoint();
    let (conn, r) = direct(&ep, a_addr(svc), json!({"op":"auth","password":PASSWORD,"name":"mbp"})).await;
    assert_eq!(r["ok"], true, "{r}");
    let s = open_echo(&conn).await;
    (ep, conn, s)
}

#[tokio::test]
async fn not_in_bundle_is_off() {
    let (home, bins) = (tempfile::tempdir().unwrap(), bins());
    service_json(home.path(), None);
    let runner = Arc::new(FakeRunner::new());
    let svc = start_service_with(home.path(), bins.path(), runner.clone(), None).await;
    let st = ipc_once(&svc, home.path(), json!({"cmd":"status"})).await;
    assert_eq!(st["update"]["state"], "off", "{st}");
    let u = ipc_once(&svc, home.path(), json!({"cmd":"update_status"})).await;
    assert_eq!((&u["ok"], &u["state"]), (&json!(true), &json!("off")), "{u}");
    tokio::time::sleep(Duration::from_millis(200)).await;
    assert!(runner.calls().is_empty(), "{:?}", runner.calls());
}

#[tokio::test]
async fn idle_installs_writes_marker_and_requests_restart() {
    let mut e = Env::new(Knobs::default());
    e.start().await;
    e.wait_restart().await;
    assert_eq!(marker_of(&e.bundle), "new");
    assert_eq!(marker_of(&e.previous()), "current");
    let m = e.applied();
    assert_eq!(
        (&m["from"], &m["to"], &m["mode"], &m["gui_was_open"]),
        (&json!("0.4.1"), &json!("0.5.0"), &json!("auto"), &json!(false)),
        "{m}"
    );
    let ev = log_events(&e.home);
    let check =
        ev.iter().position(|v| v["ev"] == "update_check" && v["result"] == "available" && v["latest"] == "0.5.0");
    let dl = ev.iter().position(|v| v["ev"] == "update_download" && v["version"] == "0.5.0" && v["result"] == "ok");
    assert!(check.is_some() && dl.is_some() && check < dl, "{ev:?}");
    assert!(ev[dl.unwrap()]["bytes"].as_u64() == Some(zip_bytes().len() as u64), "{ev:?}");
    // Nobody had rapp open, so nothing was reopened.
    assert!(e.calls_of(OPEN).is_empty());
}

#[tokio::test]
async fn sessions_block_auto_install() {
    let mut e = Env::new(Knobs { cfg: json!({"check_updates": false}), ..Default::default() });
    e.start().await;
    let (_ep, conn, mut s) = session(e.svc()).await;
    assert_eq!(e.call(json!({"cmd":"update_check"})).await["ok"], true);
    e.wait_state("ready").await;
    e.no_restart_for(POLL * 3).await;
    assert_eq!(marker_of(&e.bundle), "current");

    s.writer_mut().finish().unwrap();
    drop(s);
    conn.close(0u32.into(), b"done");
    e.wait_restart().await;
    assert_eq!(marker_of(&e.bundle), "new");
}

#[tokio::test]
async fn gui_process_blocks_auto_install() {
    let mut e = Env::new(Knobs::default());
    e.ps_extra.lock().unwrap().push(e.gui_line());
    e.start().await;
    e.wait_state("ready").await;
    e.no_restart_for(POLL * 4).await;
    assert_eq!(e.update().await["state"], "ready");
    assert_eq!(marker_of(&e.bundle), "current");
    // Only the service's own child (rapp-host, ppid = service) is left: that is nobody.
    e.ps_extra.lock().unwrap().clear();
    e.wait_restart().await;
    assert_eq!(marker_of(&e.bundle), "new");
}

#[tokio::test]
async fn ps_failure_counts_as_in_use() {
    let mut e = Env::new(Knobs::default());
    e.ps_code.store(1, Ordering::SeqCst);
    e.start().await;
    e.wait_state("ready").await;
    e.no_restart_for(POLL * 4).await;
    assert_eq!(marker_of(&e.bundle), "current");
    assert!(!e.calls_of(PS).is_empty(), "ps was asked");
}

#[tokio::test]
async fn not_launchd_never_installs() {
    let mut e = Env::new(Knobs { launchd: false, ..Default::default() });
    e.start().await;
    e.wait_state("ready").await;
    e.no_restart_for(POLL * 4).await;
    let r = e.call(json!({"cmd":"update_apply"})).await;
    assert_eq!(r["ok"], false, "{r}");
    assert!(r["page"].as_str().is_some_and(|p| !p.is_empty()), "{r}");
    assert_eq!(e.call(json!({"cmd":"update_rollback"})).await["ok"], false);
    e.no_restart_for(POLL * 4).await;
    assert_eq!(marker_of(&e.bundle), "current");
}

#[tokio::test]
async fn auto_update_off_downloads_but_waits() {
    let mut e = Env::new(Knobs { cfg: json!({"auto_update": false}), ..Default::default() });
    e.start().await;
    let u = e.wait_state("ready").await;
    assert_eq!((&u["auto_update"], &u["latest"], &u["current"]), (&json!(false), &json!("0.5.0"), &json!("0.4.1")));
    assert_eq!(u["notes"], "修了一些问题");
    e.no_restart_for(POLL * 4).await;
    assert_eq!(marker_of(&e.bundle), "current");

    let mut gui = Ipc::open(e.svc(), &e.home).await;
    let r = gui.call(json!({"cmd":"update_apply"})).await;
    assert_eq!(r, json!({"ok": true}));
    drop(gui);
    e.wait_restart().await;
    assert_eq!(marker_of(&e.bundle), "new");
    let m = e.applied();
    assert_eq!((&m["mode"], &m["gui_was_open"]), (&json!("manual"), &json!(true)), "{m}");
}

#[tokio::test]
async fn signature_change_waits_for_confirm() {
    let mut e = Env::new(Knobs { new_dr: OTHER_DR, ..Default::default() });
    e.start().await;
    let u = e.wait_state("ready").await;
    assert_eq!(u["needs_confirm"], true, "{u}");
    e.no_restart_for(POLL * 4).await;
    assert_eq!(marker_of(&e.bundle), "current");

    let mut gui = Ipc::open(e.svc(), &e.home).await;
    assert_eq!(gui.call(json!({"cmd":"update_apply"})).await, json!({"ok": false, "error": "需要确认"}));
    let r = gui.call(json!({"cmd":"update_apply","confirm_signature_change":true})).await;
    assert_eq!(r["ok"], true, "{r}");
    drop(gui);
    e.wait_restart().await;
    assert_eq!(marker_of(&e.bundle), "new");
    assert_eq!(e.applied()["mode"], "manual");
}

#[tokio::test]
async fn manual_apply_with_sessions_is_refused() {
    let mut e = Env::new(Knobs { cfg: json!({"check_updates": false}), ..Default::default() });
    e.start().await;
    let (_ep, _conn, _s) = session(e.svc()).await;
    e.call(json!({"cmd":"update_check"})).await;
    e.wait_state("ready").await;
    let r = e.call(json!({"cmd":"update_apply"})).await;
    assert_eq!(r["ok"], false, "{r}");
    assert!(r["error"].as_str().unwrap().contains("个远程会话"), "{r}");
    e.no_restart_for(POLL * 4).await;
    assert_eq!(marker_of(&e.bundle), "current");
}

#[tokio::test]
async fn manual_apply_reopens_gui_when_still_in_use() {
    let mut e = Env::new(Knobs::default());
    e.ps_extra.lock().unwrap().push(e.gui_line());
    e.start().await;
    e.wait_state("ready").await;
    // The GUI keeps its connection open and never quits.
    let mut gui = Ipc::open(e.svc(), &e.home).await;
    assert_eq!(gui.call(json!({"cmd":"update_apply"})).await["ok"], true);
    let u = e.wait_state("failed").await;
    assert_eq!(u["error"], "rapp 还开着", "{u}");
    assert!(e.calls_of(OPEN).contains(&vec![s(&e.bundle)]), "{:?}", e.calls_of(OPEN));
    assert_eq!(marker_of(&e.bundle), "current");
    drop(gui);
}

#[tokio::test]
async fn dismiss_hides_that_version_and_check_clears_it() {
    let mut e = Env::new(Knobs::default());
    e.ps_extra.lock().unwrap().push(e.gui_line());
    e.start().await;
    e.wait_state("ready").await;
    assert_eq!(e.call(json!({"cmd":"update_dismiss","version":"0.5.0"})).await["ok"], true);
    let u = e.update().await;
    assert_eq!(u["dismissed"], true, "{u}");
    assert_ne!(u["state"], "ready", "{u}");
    e.ps_extra.lock().unwrap().clear();
    e.no_restart_for(POLL * 5).await;
    assert_eq!(marker_of(&e.bundle), "current");

    assert_eq!(e.call(json!({"cmd":"update_check"})).await, json!({"ok": true}));
    e.wait_restart().await;
    let cache: Value = serde_json::from_slice(&std::fs::read(e.home.join("update.json")).unwrap()).unwrap();
    assert_eq!(cache["dismissed_version"], Value::Null, "{cache}");
    assert_eq!(marker_of(&e.bundle), "new");
}

#[tokio::test]
async fn check_failure_keeps_cache_and_logs() {
    let mut e = Env::new(Knobs { curl_code: 22, ..Default::default() });
    e.start().await;
    let ev = wait_log(&e.home, "update_check", |v| v["result"] == "failed").await;
    assert_eq!(ev["reason"], "curl 退出码 22", "{ev}");
    let u = e.wait_state("failed").await;
    assert_eq!(u["error"], "curl 退出码 22");
    assert!(!e.home.join("update.json").exists());
}

#[tokio::test]
async fn bad_update_url_never_reaches_curl() {
    let mut e = Env::new(Knobs { cfg: json!({"update_url": "-K/etc/x"}), ..Default::default() });
    e.start().await;
    let u = e.wait_state("failed").await;
    assert_eq!(u["error"], "更新地址不对", "{u}");
    assert_eq!(e.call(json!({"cmd":"update_check"})).await["ok"], true);
    tokio::time::sleep(POLL * 3).await;
    assert!(e.calls_of(CURL).is_empty(), "{:?}", e.calls_of(CURL));
    assert!(!e.home.join("update.json").exists());
}

#[tokio::test]
async fn leftovers_from_a_failed_install_block_every_install() {
    let mut e = Env::new(Knobs::default());
    let staged = e.bundle.parent().unwrap().join(".rapp-new.app");
    make_app(&staged, "left");
    make_app(&e.previous(), "prev");
    e.start().await;
    let u = e.wait_state("failed").await;
    assert_eq!(u["error"], "上次升级没收拾干净，需要手动处理", "{u}");
    let f = wait_log(&e.home, "update_failed", |_| true).await;
    assert_eq!((&f["stage"], &f["reason"]), (&json!("install"), &json!("上次升级没收拾干净，需要手动处理")));
    let r = e.call(json!({"cmd":"update_rollback"})).await;
    assert_eq!(r["ok"], false, "{r}");
    e.no_restart_for(POLL * 4).await;
    assert_eq!(
        (marker_of(&e.bundle), marker_of(&staged), marker_of(&e.previous())),
        ("current".into(), "left".into(), "prev".into())
    );
}

#[tokio::test]
async fn old_previous_left_aside_blocks_rollback() {
    let mut e = Env::new(Knobs { cfg: json!({"check_updates": false}), ..Default::default() });
    make_app(&e.previous(), "prev");
    let aside = e.home.join("previous/.rapp-old.app");
    make_app(&aside, "older");
    e.start().await;
    let r = e.call(json!({"cmd":"update_rollback"})).await;
    assert_eq!(r, json!({"ok": false, "error": "上次升级没收拾干净，需要手动处理"}));
    e.no_restart_for(POLL * 4).await;
    assert_eq!((marker_of(&e.bundle), marker_of(&aside)), ("current".into(), "older".into()));
}

#[tokio::test]
async fn marker_on_start_logs_applied_and_reopens_gui() {
    let mut e = Env::new(Knobs { cfg: json!({"check_updates": false}), ..Default::default() });
    let m = json!({"from":"0.4.0","to":"0.4.1","at":1,"gui_was_open":true,"mode":"manual"});
    rapp_net::config::write_json(&e.home.join("update-applied.json"), &m).unwrap();
    std::fs::create_dir_all(&e.cache).unwrap();
    std::fs::write(e.cache.join("rapp-0.4.1.zip"), b"zip").unwrap();
    make_app(&e.cache.join("0.4.1/rapp.app"), "unpacked");
    e.start().await;
    let ev = wait_log(&e.home, "update_applied", |_| true).await;
    assert_eq!((&ev["from"], &ev["to"], &ev["mode"]), (&json!("0.4.0"), &json!("0.4.1"), &json!("manual")), "{ev}");
    assert!(e.calls_of(OPEN).contains(&vec![s(&e.bundle)]), "{:?}", e.calls_of(OPEN));
    assert!(e.home.join("update-applied.json").exists(), "kept until healthy_after");

    let deadline = tokio::time::Instant::now() + WAIT;
    while e.home.join("update-applied.json").exists() {
        assert!(tokio::time::Instant::now() < deadline, "marker never removed");
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    assert!(!e.cache.join("rapp-0.4.1.zip").exists());
    assert!(!e.cache.join("0.4.1").exists());
}

#[tokio::test]
async fn marker_with_wrong_version_logs_restart_failure() {
    let mut e = Env::new(Knobs { cfg: json!({"check_updates": false}), ..Default::default() });
    let m = json!({"from":"0.4.1","to":"0.9.9","at":1,"gui_was_open":true,"mode":"auto"});
    rapp_net::config::write_json(&e.home.join("update-applied.json"), &m).unwrap();
    e.start().await;
    let ev = wait_log(&e.home, "update_failed", |_| true).await;
    assert_eq!((&ev["stage"], &ev["reason"]), (&json!("restart"), &json!("重启后是 0.4.1，不是 0.9.9")), "{ev}");
    assert!(!e.home.join("update-applied.json").exists());
    assert!(e.calls_of(OPEN).is_empty());
    assert!(log_events(&e.home).iter().all(|v| v["ev"] != "update_applied"));
}

#[tokio::test]
async fn progress_is_reported() {
    let mut e = Env::new(Knobs { split: Some(Duration::from_millis(1200)), ..Default::default() });
    e.ps_extra.lock().unwrap().push(e.gui_line());
    e.start().await;
    let mut sub = Ipc::open(e.svc(), &e.home).await;
    assert_eq!(sub.call(json!({"cmd":"subscribe"})).await["ok"], true);
    let mut seen = Vec::new();
    let deadline = tokio::time::Instant::now() + WAIT;
    loop {
        let ev = sub.next().await;
        assert_eq!(ev["event"], "changed", "{ev}");
        let u = sub.call(json!({"cmd":"status"})).await["update"].clone();
        let done = u["state"] == "ready";
        seen.push(u);
        if done {
            break;
        }
        assert!(tokio::time::Instant::now() < deadline, "{seen:?}");
    }
    assert!(
        seen.iter()
            .any(|u| u["state"] == "downloading" && u["progress"].as_u64().is_some_and(|p| (1..=99).contains(&p))),
        "{seen:?}"
    );
    assert_eq!(seen.last().unwrap()["progress"], Value::Null);
}

#[tokio::test]
async fn rollback_swaps_and_restarts() {
    let mut e = Env::new(Knobs { cfg: json!({"check_updates": false}), ..Default::default() });
    make_app(&e.previous(), "prev");
    e.start().await;
    assert_eq!(e.update().await["can_rollback"], true);
    let mut gui = Ipc::open(e.svc(), &e.home).await;
    assert_eq!(gui.call(json!({"cmd":"update_rollback"})).await, json!({"ok": true}));
    drop(gui);
    e.wait_restart().await;
    assert_eq!(marker_of(&e.bundle), "prev");
    assert_eq!(marker_of(&e.previous()), "current");
    let m = e.applied();
    assert_eq!((&m["from"], &m["to"], &m["mode"]), (&json!("0.4.1"), &json!("0.4.0"), &json!("rollback")), "{m}");
}

#[tokio::test]
async fn update_logs_never_contain_urls() {
    let mut e = Env::new(Knobs::default());
    e.start().await;
    e.wait_restart().await;
    // The page the GUI may open is in status, never in the log.
    assert!(e.update().await["page"].as_str().is_some_and(|p| p.contains("example.invalid")));
    let text = std::fs::read_to_string(e.home.join("logs/service.log")).unwrap();
    assert!(text.contains("update_download"), "{text}");
    assert!(!text.contains("example.invalid") && !text.contains("https://"), "{text}");
}

#[tokio::test]
async fn set_update_persists() {
    let mut e = Env::new(Knobs { cfg: json!({"check_updates": false}), ..Default::default() });
    e.start().await;
    assert_eq!(e.update().await["auto_update"], true);
    assert_eq!(e.call(json!({"cmd":"set_update","auto_update":false})).await, json!({"ok": true}));
    let cfg: Value = serde_json::from_slice(&std::fs::read(e.home.join("service.json")).unwrap()).unwrap();
    assert_eq!((&cfg["auto_update"], &cfg["check_updates"]), (&json!(false), &json!(false)), "{cfg}");
    let u = e.update().await;
    assert_eq!((&u["auto_update"], &u["check_updates"]), (&json!(false), &json!(false)), "{u}");
    assert_eq!(e.call(json!({"cmd":"set_update","check_updates":true})).await["ok"], true);
    assert_eq!(e.update().await["check_updates"], true);
}

/// Fix round 1, Important 1: a B session whose rapp-host is still starting is not in the
/// session table yet, but it is about to be: no install may cut it off.
#[tokio::test]
async fn opening_session_blocks_auto_install() {
    let mut e = Env::new(Knobs { cfg: json!({"check_updates": false}), ..Default::default() });
    e.ps_extra.lock().unwrap().push(e.gui_line());
    e.start().await;
    e.call(json!({"cmd":"update_check"})).await;
    e.wait_state("ready").await;

    std::fs::write(e.bins.path().join("serve_delay"), "1500").unwrap();
    let addr = a_addr(e.svc());
    let opening = tokio::spawn(async move {
        let ep = b_endpoint();
        let (conn, r) = direct(&ep, addr, json!({"op":"auth","password":PASSWORD,"name":"mbp"})).await;
        assert_eq!(r["ok"], true, "{r}");
        let s = open_echo(&conn).await;
        (ep, conn, s)
    });
    let deadline = tokio::time::Instant::now() + WAIT;
    while !host_log(e.bins.path()).contains("delay com.example.echo") {
        assert!(tokio::time::Instant::now() < deadline, "rapp-host never started");
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    // The GUI goes; the only thing left is the session that is still opening.
    e.ps_extra.lock().unwrap().clear();
    e.no_restart_for(POLL * 6).await;
    assert!(!opening.is_finished(), "the session must still be opening during the check");
    assert_eq!(marker_of(&e.bundle), "current");

    let (_ep, conn, mut s) = opening.await.unwrap();
    e.no_restart_for(POLL * 3).await;
    s.writer_mut().finish().unwrap();
    drop(s);
    conn.close(0u32.into(), b"done");
    e.wait_restart().await;
    assert_eq!(marker_of(&e.bundle), "new");
}

/// Fix round 1, Important 1 (c): once the new version is going in, B's open is refused.
#[tokio::test]
async fn open_while_installing_is_refused() {
    let mut e = Env::new(Knobs::default());
    e.start().await;
    e.wait_restart().await;
    // In the real service the process exits now; here it stays, still `installing`.
    assert_eq!(e.update().await["state"], "installing");
    let ep = b_endpoint();
    let (conn, r) = direct(&ep, a_addr(e.svc()), json!({"op":"auth","password":PASSWORD,"name":"mbp"})).await;
    assert_eq!(r["ok"], true, "{r}");
    let mut s = bi(conn.open_bi().await.unwrap());
    write_json(&mut s, &json!({"op":"open","app":"com.example.echo"})).await.unwrap();
    let r = read_json(&mut s).await.unwrap();
    assert_eq!(r, json!({"ok": false, "error": "A 正在升级，请稍后再连"}));
    assert!(!host_log(e.bins.path()).contains("start com.example.echo"), "no rapp-host for it");
}

/// Fix round 1, Important 2: a refused apply must not use up the connection's close signal,
/// so the next apply on the same connection still waits for the GUI to go.
#[tokio::test]
async fn second_apply_on_one_connection_waits_for_close() {
    let mut e = Env::new(Knobs { new_dr: OTHER_DR, gui_wait: Duration::from_secs(5), ..Default::default() });
    e.start().await;
    e.wait_state("ready").await;
    let mut gui = Ipc::open(e.svc(), &e.home).await;
    assert_eq!(gui.call(json!({"cmd":"update_apply"})).await, json!({"ok": false, "error": "需要确认"}));
    let r = gui.call(json!({"cmd":"update_apply","confirm_signature_change":true})).await;
    assert_eq!(r, json!({"ok": true}));
    // The connection is still open: nothing goes in yet, although nobody else uses rapp.
    e.no_restart_for(Duration::from_millis(500)).await;
    assert_eq!(marker_of(&e.bundle), "current");
    drop(gui);
    e.wait_restart().await;
    assert_eq!(marker_of(&e.bundle), "new");
}

/// U-4c: a dismiss that lands while a check holds the pipeline leaves `ready` in memory but the
/// version dismissed in the cache. Simulated deterministically by writing the cache directly:
/// the version must not install, and the state goes back to idle.
#[tokio::test]
async fn dismissed_in_cache_never_installs() {
    let mut e = Env::new(Knobs { cfg: json!({"check_updates": false}), ..Default::default() });
    e.ps_extra.lock().unwrap().push(e.gui_line());
    e.start().await;
    e.call(json!({"cmd":"update_check"})).await;
    e.wait_state("ready").await;

    let p = e.home.join("update.json");
    let mut c: Value = serde_json::from_slice(&std::fs::read(&p).unwrap()).unwrap();
    c["dismissed_version"] = json!("0.5.0");
    rapp_net::config::write_json(&p, &c).unwrap();
    e.ps_extra.lock().unwrap().clear();
    e.no_restart_for(POLL * 6).await;
    assert_eq!(marker_of(&e.bundle), "current");
    assert_eq!(e.update().await["state"], "idle");
}
