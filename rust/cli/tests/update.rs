//! `rapp update …` against a fake service IPC (cli-update §5.3/§5.4): the fake answers
//! `update_status` from a status object the test scripts, records every command, and can restart
//! with a new token and a new port in the middle of an install.

use serde_json::{json, Value};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::TcpListener;
use tokio::task::JoinHandle;

/// What happens after the fake replies to a command: status patches, each after a delay from the
/// reply; `{"restart": ms}` takes the service away for `ms` and brings it back elsewhere.
type After = Vec<(u64, Value)>;

#[derive(Clone, Default)]
struct Fake {
    local: PathBuf,
    status: Arc<Mutex<Value>>,
    seen: Arc<Mutex<Vec<Value>>>,
    replies: Arc<Mutex<HashMap<String, Value>>>,
    delays: Arc<Mutex<HashMap<String, u64>>>,
    after: Arc<Mutex<HashMap<String, After>>>,
    server: Arc<Mutex<Option<JoinHandle<()>>>>,
    starts: Arc<Mutex<u32>>,
}

fn merge(into: &mut Value, patch: &Value) {
    if let (Some(m), Some(p)) = (into.as_object_mut(), patch.as_object()) {
        for (k, v) in p {
            m.insert(k.clone(), v.clone());
        }
    }
}

impl Fake {
    async fn new(local: &Path, status: Value) -> Fake {
        let f = Fake { local: local.to_path_buf(), status: Arc::new(Mutex::new(status)), ..Default::default() };
        f.start();
        f
    }

    /// A new listener on a new port with a new token, both written where the CLI reads them.
    fn start(&self) {
        let l = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        l.set_nonblocking(true).unwrap();
        let l = TcpListener::from_std(l).unwrap();
        let port = l.local_addr().unwrap().port();
        let n = {
            let mut s = self.starts.lock().unwrap();
            *s += 1;
            *s
        };
        let token = format!("token-{n}-{port}");
        std::fs::write(self.local.join("ipc.token"), format!("{token}\n")).unwrap();
        std::fs::write(self.local.join("service.json"), json!({"ipc_port": port, "password": "PW-SECRET"}).to_string())
            .unwrap();
        let me = self.clone();
        let task = tokio::spawn(async move {
            loop {
                let Ok((tcp, _)) = l.accept().await else { return };
                let me = me.clone();
                let token = token.clone();
                tokio::spawn(async move { me.serve(tcp, token).await });
            }
        });
        *self.server.lock().unwrap() = Some(task);
    }

    fn stop(&self) {
        if let Some(t) = self.server.lock().unwrap().take() {
            t.abort();
        }
    }

    async fn serve(&self, tcp: tokio::net::TcpStream, token: String) {
        let (r, mut w) = tcp.into_split();
        let mut lines = BufReader::new(r).lines();
        let Ok(Some(first)) = lines.next_line().await else { return };
        let t: Value = serde_json::from_str(&first).unwrap_or_default();
        if t["token"] != token.as_str() {
            let _ = w.write_all(b"{\"ok\":false,\"error\":\"bad token\"}\n").await;
            return;
        }
        while let Ok(Some(line)) = lines.next_line().await {
            let cmd: Value = serde_json::from_str(&line).unwrap();
            let name = cmd["cmd"].as_str().unwrap_or("").to_string();
            self.seen.lock().unwrap().push(cmd.clone());
            let delay = self.delays.lock().unwrap().get(&name).copied();
            if let Some(ms) = delay {
                tokio::time::sleep(Duration::from_millis(ms)).await;
            }
            let reply = if name == "update_status" {
                let mut v = json!({"ok": true});
                merge(&mut v, &self.status.lock().unwrap());
                v
            } else {
                self.replies.lock().unwrap().get(&name).cloned().unwrap_or(json!({"ok": true}))
            };
            let mut steps = self.after.lock().unwrap().remove(&name);
            // Steps due at once land before the reply, as a service finishing its work would.
            while let Some(v) = steps.as_mut() {
                match v.first() {
                    Some((0, p)) if p["restart"].is_null() => merge(&mut self.status.lock().unwrap(), &v.remove(0).1),
                    _ => break,
                }
            }
            if w.write_all(format!("{reply}\n").as_bytes()).await.is_err() {
                return;
            }
            if let Some(steps) = steps.filter(|s| !s.is_empty()) {
                let me = self.clone();
                tokio::spawn(async move {
                    for (ms, patch) in steps {
                        tokio::time::sleep(Duration::from_millis(ms)).await;
                        if let Some(gap) = patch["restart"].as_u64() {
                            me.stop();
                            tokio::time::sleep(Duration::from_millis(gap)).await;
                            me.start();
                        } else {
                            merge(&mut me.status.lock().unwrap(), &patch);
                        }
                    }
                });
            }
        }
    }

    fn reply(&self, cmd: &str, v: Value) {
        self.replies.lock().unwrap().insert(cmd.into(), v);
    }

    fn delay(&self, cmd: &str, ms: u64) {
        self.delays.lock().unwrap().insert(cmd.into(), ms);
    }

    fn then(&self, cmd: &str, steps: After) {
        self.after.lock().unwrap().insert(cmd.into(), steps);
    }

    fn sent(&self, cmd: &str) -> Vec<Value> {
        self.seen.lock().unwrap().iter().filter(|c| c["cmd"] == cmd).cloned().collect()
    }
}

struct Run {
    code: i32,
    stdout: String,
    stderr: String,
}

impl Run {
    fn json(&self) -> Value {
        serde_json::from_str(self.stdout.trim()).unwrap_or_else(|e| panic!("{e}: {:?} / {:?}", self.stdout, self.stderr))
    }
}

async fn rapp(local: &Path, args: &str) -> Run {
    let o = tokio::process::Command::new(env!("CARGO_BIN_EXE_rapp-cli"))
        .args(args.split_whitespace())
        .env("RAPP_LOCAL", local)
        .stdin(Stdio::null())
        .output()
        .await
        .unwrap();
    Run {
        code: o.status.code().unwrap_or(-1),
        stdout: String::from_utf8_lossy(&o.stdout).into(),
        stderr: String::from_utf8_lossy(&o.stderr).into(),
    }
}

/// A service with a downloaded 0.15.36 waiting, run by launchd from the pkg.
fn ready() -> Value {
    json!({
        "state": "ready", "current": "0.15.35", "latest": "0.15.36", "progress": null, "error": null,
        "error_code": null, "auto_update": true, "can_rollback": false, "needs_confirm": false,
        "needs_admin": false, "page": null, "needs_reinstall": false,
        "reinstall_page": "https://example.invalid/releases", "launchd": true, "quit_gui": false,
    })
}

fn with(mut v: Value, patch: Value) -> Value {
    merge(&mut v, &patch);
    v
}

#[tokio::test]
async fn update_installs_and_reports() {
    let dir = tempfile::tempdir().unwrap();
    let f = Fake::new(dir.path(), ready()).await;
    f.then(
        "update_apply",
        vec![(100, json!({"state": "installing", "quit_gui": true})), (300, json!({"state": "idle", "current": "0.15.36", "quit_gui": false}))],
    );
    let r = rapp(dir.path(), "update --json").await;
    assert_eq!(r.code, 0, "{}", r.stderr);
    assert_eq!(r.json(), json!({"ok": true, "result": "updated", "from": "0.15.35", "to": "0.15.36"}));
    let apply = f.sent("update_apply");
    assert_eq!(apply.len(), 1);
    assert_eq!(apply[0]["by"], "cli");
    assert_eq!(apply[0]["confirm_signature_change"], false);
    assert_eq!(f.sent("update_check").first().map(|c| c["wait"].clone()), Some(json!(true)));
    // Text mode says it in a line.
    let f2 = Fake::new(dir.path(), ready()).await;
    f2.then("update_apply", vec![(100, json!({"current": "v0.15.36", "state": "idle"}))]);
    let r = rapp(dir.path(), "update").await;
    assert_eq!(r.code, 0, "{}", r.stderr);
    assert_eq!(r.stdout.trim(), "已升级到 0.15.36（原来 0.15.35）");
    assert!(r.stderr.contains("安装中"), "{}", r.stderr);
}

#[tokio::test]
async fn update_survives_restart_with_new_token() {
    let dir = tempfile::tempdir().unwrap();
    let f = Fake::new(dir.path(), ready()).await;
    f.then(
        "update_apply",
        vec![
            (100, json!({"state": "installing", "quit_gui": true})),
            (100, json!({"restart": 1500})),
            (0, json!({"state": "idle", "current": "0.15.36", "quit_gui": false})),
        ],
    );
    let r = rapp(dir.path(), "update --json").await;
    assert_eq!(r.code, 0, "{}", r.stderr);
    assert_eq!(r.json()["result"], "updated");
    assert_eq!(*f.starts.lock().unwrap(), 2, "the service did restart");
}

#[tokio::test]
async fn up_to_date_exits_0() {
    let dir = tempfile::tempdir().unwrap();
    let f = Fake::new(dir.path(), with(ready(), json!({"state": "idle", "latest": "0.15.35"}))).await;
    f.then("update_check", vec![(0, json!({"state": "up_to_date"}))]);
    f.delay("update_check", 200);
    let r = rapp(dir.path(), "update").await;
    assert_eq!(r.code, 0, "{}", r.stderr);
    assert_eq!(r.stdout.trim(), "已是最新（0.15.35）");
    assert!(f.sent("update_apply").is_empty());
}

#[tokio::test]
async fn needs_confirm_without_yes_exits_6() {
    let dir = tempfile::tempdir().unwrap();
    let f = Fake::new(dir.path(), with(ready(), json!({"needs_confirm": true}))).await;
    let r = rapp(dir.path(), "update --json").await;
    assert_eq!(r.code, 6, "{}", r.stdout);
    assert_eq!(r.json()["error"], "needs_confirm");
    assert!(f.sent("update_apply").is_empty());
}

#[tokio::test]
async fn with_yes_sends_confirm() {
    let dir = tempfile::tempdir().unwrap();
    let f = Fake::new(dir.path(), with(ready(), json!({"needs_confirm": true}))).await;
    f.then("update_apply", vec![(100, json!({"current": "0.15.36", "state": "idle"}))]);
    let r = rapp(dir.path(), "update --yes --json").await;
    assert_eq!(r.code, 0, "{}", r.stdout);
    assert_eq!(f.sent("update_apply")[0]["confirm_signature_change"], true);
}

#[tokio::test]
async fn needs_admin_exits_7_with_page() {
    let dir = tempfile::tempdir().unwrap();
    let f = Fake::new(dir.path(), with(ready(), json!({"needs_admin": true, "page": "https://example.invalid/v0.15.36"}))).await;
    let r = rapp(dir.path(), "update --json").await;
    assert_eq!(r.code, 7);
    let v = r.json();
    assert_eq!(v["error"], "needs_admin");
    assert_eq!(v["page"], "https://example.invalid/v0.15.36");
    assert!(f.sent("update_apply").is_empty());
    // The service's own refusal carries its code and page through as well.
    let f = Fake::new(dir.path(), ready()).await;
    f.reply("update_apply", json!({"ok": false, "error": "需要管理员", "code": "needs_admin", "page": "https://example.invalid/p"}));
    let r = rapp(dir.path(), "update").await;
    assert_eq!(r.code, 7);
    assert!(r.stderr.contains("https://example.invalid/p"), "{}", r.stderr);
}

#[tokio::test]
async fn needs_reinstall_exits_7() {
    let dir = tempfile::tempdir().unwrap();
    let f = Fake::new(dir.path(), with(ready(), json!({"needs_reinstall": true}))).await;
    let r = rapp(dir.path(), "update --json").await;
    assert_eq!(r.code, 7);
    assert_eq!(r.json()["error"], "needs_reinstall");
    assert_eq!(r.json()["page"], "https://example.invalid/releases");
    assert!(f.sent("update_check").is_empty(), "nothing is asked of a service that cannot install");
}

#[tokio::test]
async fn not_launchd_exits_7() {
    let dir = tempfile::tempdir().unwrap();
    let _f = Fake::new(dir.path(), with(ready(), json!({"launchd": false}))).await;
    let r = rapp(dir.path(), "update check --json").await;
    assert_eq!(r.code, 7);
    assert_eq!(r.json()["error"], "not_launchd");
    // Not from the pkg at all.
    let _f = Fake::new(dir.path(), with(ready(), json!({"state": "off", "current": null}))).await;
    let r = rapp(dir.path(), "update --json").await;
    assert_eq!(r.code, 1);
    assert_eq!(r.json()["error"], "failed");
}

#[tokio::test]
async fn failed_install_exits_1() {
    let dir = tempfile::tempdir().unwrap();
    let f = Fake::new(dir.path(), ready()).await;
    f.then(
        "update_apply",
        vec![
            (100, json!({"state": "installing", "quit_gui": true})),
            (200, json!({"state": "failed", "error": "rApp 窗口没有关掉", "error_code": "still_open", "quit_gui": false})),
        ],
    );
    let r = rapp(dir.path(), "update --json").await;
    assert_eq!(r.code, 1);
    let v = r.json();
    assert_eq!(v["error"], "still_open");
    assert!(v["message"].as_str().unwrap().contains("窗口没有关掉"));
}

#[tokio::test]
async fn busy_auto_install_is_waited_for() {
    // Review I3: the auto install holds the service; `rapp update` waits for the version it brings.
    let dir = tempfile::tempdir().unwrap();
    let f = Fake::new(dir.path(), ready()).await;
    f.reply("update_apply", json!({"ok": false, "error": "正在忙", "code": "busy"}));
    f.then(
        "update_apply",
        vec![(100, json!({"state": "installing", "quit_gui": true})), (200, json!({"restart": 300})), (0, json!({"state": "idle", "current": "0.15.36", "quit_gui": false}))],
    );
    let r = rapp(dir.path(), "update --json").await;
    assert_eq!(r.code, 0, "{}", r.stdout);
    assert_eq!(r.json()["result"], "updated");
    // Busy with nothing coming still ends at the deadline, not forever.
    let f = Fake::new(dir.path(), ready()).await;
    f.reply("update_apply", json!({"ok": false, "error": "正在忙", "code": "busy"}));
    let r = rapp(dir.path(), "update --timeout 2 --json").await;
    assert_eq!(r.code, 5);
}

#[tokio::test]
async fn timeout_exits_5() {
    let dir = tempfile::tempdir().unwrap();
    let f = Fake::new(dir.path(), ready()).await;
    f.then("update_apply", vec![(100, json!({"state": "installing", "quit_gui": true}))]);
    let t = std::time::Instant::now();
    let r = rapp(dir.path(), "update --timeout 2 --json").await;
    assert_eq!(r.code, 5, "{}", r.stdout);
    assert_eq!(r.json()["error"], "timeout");
    assert!(t.elapsed() < Duration::from_secs(5), "{:?}", t.elapsed());
    // A check that never ends is bounded the same way.
    let f = Fake::new(dir.path(), with(ready(), json!({"state": "downloading", "progress": 10}))).await;
    f.delay("update_check", 60_000);
    let r = rapp(dir.path(), "update check --timeout 1").await;
    assert_eq!(r.code, 5, "{}", r.stderr);
    assert!(r.stderr.contains("下载中 10%"), "{}", r.stderr);
}

#[tokio::test]
async fn json_not_running() {
    let dir = tempfile::tempdir().unwrap();
    let r = rapp(dir.path(), "update --json").await;
    assert_eq!(r.code, 3);
    assert_eq!(r.json()["error"], "not_running");
    let r = rapp(dir.path(), "update status").await;
    assert_eq!(r.code, 3);
    assert!(r.stderr.contains("没有在运行"));
    // The old commands say it with the same code.
    let r = rapp(dir.path(), "hosts").await;
    assert_eq!(r.code, 3);
    // A usage error asked for as JSON comes as JSON.
    let r = rapp(dir.path(), "update now --json").await;
    assert_eq!(r.code, 2);
    assert_eq!(r.json()["error"], "usage");
}

#[tokio::test]
async fn check_reports_ready_without_installing() {
    let dir = tempfile::tempdir().unwrap();
    let f = Fake::new(dir.path(), with(ready(), json!({"state": "idle", "latest": null}))).await;
    f.delay("update_check", 1200);
    f.then("update_check", vec![(0, json!({"state": "ready", "latest": "0.15.36"}))]);
    // The status the CLI polls while the check runs.
    {
        let f = f.clone();
        tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(300)).await;
            merge(&mut f.status.lock().unwrap(), &json!({"state": "downloading", "progress": 40}));
        });
    }
    let r = rapp(dir.path(), "update check").await;
    assert_eq!(r.code, 0, "{}", r.stderr);
    assert_eq!(r.stdout.trim(), "有新版本 0.15.36，已下载好（当前 0.15.35）");
    assert!(r.stderr.contains("下载中 40%"), "{}", r.stderr);
    assert!(f.sent("update_apply").is_empty());
    let r = rapp(dir.path(), "update check --json").await;
    assert_eq!(r.json(), json!({"ok": true, "result": "ready", "current": "0.15.35", "latest": "0.15.36", "needs_confirm": false}));
}

#[tokio::test]
async fn status_json_has_no_secrets() {
    let dir = tempfile::tempdir().unwrap();
    let _f = Fake::new(dir.path(), with(ready(), json!({"key": "KEY-SECRET", "password": "PW-SECRET"}))).await;
    let r = rapp(dir.path(), "update status --json").await;
    assert_eq!(r.code, 0);
    assert!(!r.stdout.contains("SECRET"), "{}", r.stdout);
    let v = r.json();
    for k in ["state", "current", "latest", "progress", "auto_update", "can_rollback", "error", "error_code"] {
        assert!(v.get(k).is_some(), "{k}");
    }
    assert_eq!(v["state"], "ready");
    let r = rapp(dir.path(), "update status").await;
    assert!(!r.stdout.contains("SECRET"));
    assert_eq!(
        r.stdout.trim(),
        "当前版本：0.15.35\n最新版本：0.15.36\n状态：新版本已下载好\n自动升级：开\n可以回滚：不能"
    );
}

#[tokio::test]
async fn rollback_reports_previous() {
    let dir = tempfile::tempdir().unwrap();
    let f = Fake::new(dir.path(), with(ready(), json!({"state": "idle", "current": "0.15.36", "latest": "0.15.36", "can_rollback": true}))).await;
    f.then(
        "update_rollback",
        vec![(100, json!({"state": "installing"})), (100, json!({"restart": 800})), (0, json!({"state": "idle", "current": "0.15.35"}))],
    );
    let r = rapp(dir.path(), "update rollback --json").await;
    assert_eq!(r.code, 0, "{}", r.stdout);
    assert_eq!(r.json(), json!({"ok": true, "result": "rolled_back", "from": "0.15.36", "to": "0.15.35"}));
    assert_eq!(f.sent("update_rollback")[0]["by"], "cli");
    // Nothing to go back to.
    let _f = Fake::new(dir.path(), with(ready(), json!({"can_rollback": false}))).await;
    let r = rapp(dir.path(), "update rollback --json").await;
    assert_eq!(r.code, 1);
    assert_eq!(r.json()["error"], "no_previous");
}
