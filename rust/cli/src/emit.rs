//! `rapp emit <level> <text> [--key k] [--json]`: a program inside a rapp terminal tells the
//! center service one thing, through the local service's IPC. No service, or no center service
//! to take it, is not a failure: the program must not stop for it. The text goes only into the
//! IPC payload.

use crate::args::Cmd;
use crate::ipc::{self, Gone};
use crate::out::Out;
use serde_json::{json, Value};
use std::time::Duration;

const CALL: Duration = Duration::from_secs(10);

/// The IPC command; `session` is the terminal this runs in, if it is one.
pub fn ask(level: &str, text: &str, key: Option<&str>, session: Option<&str>) -> Value {
    let mut c = json!({"cmd": "emit", "level": level, "text": text});
    if let Some(k) = key {
        c["key"] = json!(k);
    }
    if let Some(s) = session.filter(|s| !s.is_empty()) {
        c["session"] = json!(s);
    }
    c
}

pub async fn run(cmd: Cmd) {
    let Cmd::Emit { level, text, key, json } = cmd else { return };
    let out = Out { json };
    if !matches!(level.as_str(), "done" | "ask" | "info" | "clear") {
        out.fail("usage", "级别只能是 done、ask、info、clear", None);
    }
    let session = std::env::var("RAPP_TERM").ok();
    let sink = match ipc::call(ask(&level, &text, key.as_deref(), session.as_deref()), CALL).await {
        Ok(r) if r["ok"] == true => r["sink"] == true,
        Ok(r) => out.fail("failed", &format!("没有成功：{}", crate::say::plain(r["error"].as_str().unwrap_or(""))), None),
        Err(Gone) => false,
    };
    // Nothing printed without `--json`; with it, only where the line went.
    if json {
        println!("{}", json!({"sink": sink}));
    }
    std::process::exit(0);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ask_carries_session_only_when_set() {
        let c = ask("ask", "t", Some("k"), Some("term:pty:a"));
        assert_eq!(c, json!({"cmd":"emit","level":"ask","text":"t","key":"k","session":"term:pty:a"}));
        assert_eq!(ask("done", "t", None, Some("")), json!({"cmd":"emit","level":"done","text":"t"}));
    }
}
