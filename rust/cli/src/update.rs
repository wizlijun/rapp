//! `rapp update [check|status|rollback]` (cli-update §5.3): a polling client of the service's
//! update IPC. Every wait has a deadline; the service restarting in the middle (connection
//! refused, new token, new port) is waited out, not reported.

use crate::args::Upd;
use crate::ipc::{self, Gone};
use crate::out::Out;
use serde_json::{json, Value};
use std::time::Duration;
use tokio::time::Instant;

const POLL: Duration = Duration::from_millis(500);
/// The longest one IPC call may take, other than the check itself.
const CALL: Duration = Duration::from_secs(10);
const NOT_RUNNING: &str = "本机的 rApp 服务没有在运行";
const NOT_BUNDLED: &str = "这个 rApp 不是从安装包装的，不能在线升级";

struct Clock {
    out: Out,
    deadline: Instant,
    secs: u64,
}

impl Clock {
    fn left(&self) -> Duration {
        let left = self.deadline.saturating_duration_since(Instant::now());
        if left.is_zero() {
            self.out.fail("timeout", &format!("等了 {} 秒还没好", self.secs), None);
        }
        left
    }

    async fn call(&self, cmd: Value) -> Result<Value, Gone> {
        let wait = CALL.min(self.left());
        let r = ipc::call(cmd, wait).await;
        self.left();
        r
    }

    /// `update_status`, or None while the service is away.
    async fn status(&self) -> Option<Value> {
        self.call(json!({"cmd":"update_status"})).await.ok().filter(|v| v["ok"] == true)
    }

    async fn sleep(&self) {
        tokio::time::sleep(POLL.min(self.left())).await;
        self.left();
    }
}

fn text(v: &Value) -> &str {
    v.as_str().unwrap_or("")
}

/// `v0.15.36` and `0.15.36` are the same version.
fn same_version(a: &Value, b: &Value) -> bool {
    let canon = |v: &Value| v.as_str().map(|s| s.trim_start_matches('v').to_string());
    canon(a).is_some() && canon(a) == canon(b)
}

fn page_of(u: &Value) -> Option<&str> {
    u["page"].as_str().or(u["reinstall_page"].as_str())
}

pub async fn run(what: Upd, yes: bool, timeout: Option<u64>, out: Out) -> ! {
    let secs = timeout.unwrap_or(match what {
        Upd::Install => 900,
        Upd::Check => 300,
        Upd::Rollback => 120,
        Upd::Status => 10,
    });
    let c = Clock { out, deadline: Instant::now() + Duration::from_secs(secs), secs };
    let Some(u) = c.status().await else { out.fail("not_running", NOT_RUNNING, None) };
    if what == Upd::Status {
        status(&u, out);
    }
    preflight(&u, out);
    match what {
        Upd::Check => {
            let u = check(&c).await;
            if u["state"] == "ready" {
                let line = format!("有新版本 {}，已下载好（当前 {}）", text(&u["latest"]), text(&u["current"]));
                let v = json!({"result": "ready", "current": u["current"], "latest": u["latest"], "needs_confirm": u["needs_confirm"]});
                out.ok(v, &line);
            }
            unexpected(&u, out)
        }
        Upd::Install => {
            let u = check(&c).await;
            if u["state"] != "ready" {
                unexpected(&u, out);
            }
            if u["needs_confirm"] == true && !yes {
                out.fail("needs_confirm", "新版本换了签名，确认后加 --yes 再运行", None);
            }
            if u["needs_admin"] == true {
                out.fail("needs_admin", "这次需要管理员密码，请从页面下载安装包", page_of(&u));
            }
            let (from, to) = (u["current"].clone(), u["latest"].clone());
            out.progress("安装中…");
            match c.call(json!({"cmd":"update_apply","confirm_signature_change":yes,"by":"cli"})).await {
                // An auto install got there first, or finished just now: wait for its version.
                Ok(r) if r["code"] == "busy" => out.progress("已经在装了，等它装好…"),
                Err(Gone) => {}
                Ok(r) => refused(&c, &r),
            }
            wait_restart(&c, |n| same_version(&n["current"], &to)).await;
            let line = format!("已升级到 {}（原来 {}）", text(&to), text(&from));
            out.ok(json!({"result": "updated", "from": from, "to": to}), &line)
        }
        Upd::Rollback => {
            if u["can_rollback"] != true {
                out.fail("no_previous", "没有上一版可以回去", None);
            }
            let from = u["current"].clone();
            out.progress("回滚中…");
            match c.call(json!({"cmd":"update_rollback","by":"cli"})).await {
                Ok(r) => refused(&c, &r),
                Err(Gone) => c.out.fail("not_running", NOT_RUNNING, None),
            }
            let n = wait_restart(&c, |n| n["current"].is_string() && !same_version(&n["current"], &from)).await;
            let to = n["current"].clone();
            let line = format!("已回到 {}（原来 {}）", text(&to), text(&from));
            out.ok(json!({"result": "rolled_back", "from": from, "to": to}), &line)
        }
        Upd::Status => unreachable!(),
    }
}

/// What has to be settled by hand before anything can install.
fn preflight(u: &Value, out: Out) {
    if u["state"] == "off" {
        // Spec §2: Linux has no launchd to restart the service after a swap.
        if cfg!(target_os = "linux") {
            out.fail("not_launchd", "Linux 上还不能在线升级，请从页面下载安装包", page_of(u));
        }
        out.fail("failed", NOT_BUNDLED, None);
    }
    // Missing (an older service): it was started by launchd as far as we know.
    if u["launchd"] == false {
        out.fail("not_launchd", "rApp 服务不是由 launchd 启动的，不能在线升级，请从页面下载安装包", page_of(u));
    }
    if u["needs_reinstall"] == true {
        out.fail("needs_reinstall", "安装包要重装一次才能在线升级，请从页面下载安装包", u["reinstall_page"].as_str());
    }
}

/// A check that ended neither up to date nor with a version ready.
fn unexpected(u: &Value, out: Out) -> ! {
    match text(&u["state"]) {
        "up_to_date" => {
            let cur = &u["current"];
            out.ok(json!({"result": "up_to_date", "current": cur}), &format!("已是最新（{}）", text(cur)))
        }
        "failed" => {
            let code = u["error_code"].as_str().unwrap_or("failed");
            out.fail(code, &format!("没有成功：{}", text(&u["error"])), None)
        }
        "installing" => out.fail("busy", "正在装新版本，稍后再试", None),
        _ => out.fail("nothing_to_install", "没有可以装的新版本", None),
    }
}

/// Asks for a check and waits for its end, saying how far the download got.
async fn check(c: &Clock) -> Value {
    c.out.progress("检查中…");
    // `wait`: the reply comes once this check is done, so no stale result is read after it.
    let wait = c.left();
    let mut asked = tokio::spawn(ipc::call(json!({"cmd":"update_check","wait":true}), wait));
    let mut said = String::new();
    let mut replied = false;
    loop {
        if !replied {
            tokio::select! {
                r = &mut asked => {
                    replied = true;
                    if r.ok().and_then(Result::ok).is_none() {
                        c.left();
                        c.out.fail("not_running", NOT_RUNNING, None);
                    }
                }
                _ = c.sleep() => {}
            }
        }
        let Some(u) = c.status().await else { c.out.fail("not_running", NOT_RUNNING, None) };
        let state = text(&u["state"]);
        let line = match state {
            "downloading" => match u["progress"].as_u64() {
                Some(p) => format!("下载中 {p}%"),
                None => "下载中…".into(),
            },
            "checking" => "检查中…".into(),
            _ if replied => return u,
            _ => String::new(),
        };
        if !line.is_empty() && line != said {
            c.out.progress(&line);
            said = line;
        }
        if replied {
            c.sleep().await;
        }
    }
}

/// The reply to an install or rollback; the connection closes with it, which lets it start.
fn refused(c: &Clock, r: &Value) {
    if r["ok"] != true {
        let code = r["code"].as_str().unwrap_or("failed");
        c.out.fail(code, &format!("没有成功：{}", text(&r["error"])), r["page"].as_str());
    }
}

/// Waits through the restart until `done` accepts the new service's status; a failure the old
/// one reports before restarting ends it.
async fn wait_restart(c: &Clock, done: impl Fn(&Value) -> bool) -> Value {
    let mut away = false;
    loop {
        c.sleep().await;
        let Some(u) = c.status().await else {
            if !away {
                c.out.progress("等新版本起来…");
                away = true;
            }
            continue;
        };
        if done(&u) && u["state"] != "installing" {
            return u;
        }
        if u["state"] == "failed" {
            let code = u["error_code"].as_str().unwrap_or("failed");
            c.out.fail(code, &format!("没有成功：{}", text(&u["error"])), None);
        }
        // Admin rights needed: the service puts the version back to ready and says so.
        if u["needs_admin"] == true && u["quit_gui"] != true {
            c.out.fail("needs_admin", "这次需要管理员密码，请从页面下载安装包", page_of(&u));
        }
    }
}

/// `rapp update status`: one look, nothing else.
fn status(u: &Value, out: Out) -> ! {
    let v = json!({
        "state": u["state"], "current": u["current"], "latest": u["latest"], "progress": u["progress"],
        "auto_update": u["auto_update"], "can_rollback": u["can_rollback"],
        "error": u["error"], "error_code": u["error_code"],
    });
    let state = match text(&u["state"]) {
        "off" => "不能在线升级（不是从安装包装的）".to_string(),
        "idle" => "没有新版本".into(),
        "checking" => "检查中".into(),
        "downloading" => match u["progress"].as_u64() {
            Some(p) => format!("下载中 {p}%"),
            None => "下载中".into(),
        },
        "ready" => "新版本已下载好".into(),
        "installing" => "安装中".into(),
        "failed" => "失败".into(),
        "up_to_date" => "已是最新".into(),
        other => other.into(),
    };
    let or_dash = |v: &Value| v.as_str().unwrap_or("—").to_string();
    let mut lines = vec![
        format!("当前版本：{}", or_dash(&u["current"])),
        format!("最新版本：{}", or_dash(&u["latest"])),
        format!("状态：{state}"),
        format!("自动升级：{}", if u["auto_update"] == true { "开" } else { "关" }),
        format!("可以回滚：{}", if u["can_rollback"] == true { "能" } else { "不能" }),
    ];
    if let Some(e) = u["error"].as_str() {
        lines.push(format!("错误：{e}"));
    }
    out.ok(v, &lines.join("\n"))
}
