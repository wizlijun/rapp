//! Local IPC (spec §3): TCP on 127.0.0.1, first line `{"token":…}` (from `ipc.token`),
//! then JSON-line commands. No reply to a good token line; a bad one gets an error and EOF.

use crate::state::State;
use crate::update;
use anyhow::Result;
use rapp_net::crypto::ct_eq;
use rapp_net::line::{err, ok, write_json};
use rapp_net::log::{read_recent, Lvl};
use serde_json::{json, Value};
use std::sync::Arc;
use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::net::{TcpListener, TcpStream};

pub async fn serve(state: Arc<State>, listener: TcpListener, token: String) {
    while let Ok((tcp, _)) = listener.accept().await {
        let (state, token) = (state.clone(), token.clone());
        tokio::spawn(async move {
            if let Err(e) = conn(&state, tcp, &token).await {
                state.log.msg(Lvl::Warn, format!("ipc: {e:#}"));
            }
        });
    }
}

async fn conn(state: &Arc<State>, tcp: TcpStream, token: &str) -> Result<()> {
    let (r, mut w) = tcp.into_split();
    // `Lines::next_line` is cancel-safe, so it can sit in `select!` with the change feed.
    let mut lines = BufReader::new(r).lines();
    let first: Value = serde_json::from_str(&lines.next_line().await?.unwrap_or_default()).unwrap_or_default();
    if !first["token"].as_str().is_some_and(|t| ct_eq(t, token)) {
        return write_json(&mut w, &err("bad token")).await;
    }
    let mut feed: Option<tokio::sync::watch::Receiver<u64>> = None;
    // Dropped when this function returns: every `update_apply`/`update_rollback` on this
    // connection gets its own receiver and sees the connection close (K21).
    let (_closed, closed) = tokio::sync::watch::channel(());
    loop {
        tokio::select! {
            line = lines.next_line() => {
                let Some(line) = line? else { return Ok(()) };
                let cmd: Value = serde_json::from_str(&line).unwrap_or_default();
                if cmd["cmd"] == "subscribe" {
                    let mut rx = state.changed.subscribe();
                    rx.mark_unchanged();
                    feed = Some(rx);
                }
                let reply = match cmd["cmd"].as_str().unwrap_or("") {
                    "permissions" => {
                        let perms = crate::workers::refresh_permissions(state, cmd["prompt"] == true).await;
                        ok(json!({"permissions": perms}))
                    }
                    "permissions_reset" => {
                        let mut r = crate::workers::reset_permissions(state).await;
                        r["ok"] = json!(true);
                        r
                    }
                    "update_check" => {
                        let state = state.clone();
                        tokio::spawn(async move { update::check_now(&state).await });
                        ok(json!({}))
                    }
                    "update_apply" => {
                        update::apply(state, cmd["confirm_signature_change"] == true, closed.clone()).await
                    }
                    "update_rollback" => update::rollback(state, closed.clone()).await,
                    _ => handle(state, &cmd),
                };
                write_json(&mut w, &reply).await?;
            }
            changed = async { feed.as_mut().expect("guarded").changed().await }, if feed.is_some() => {
                if changed.is_err() { return Ok(()) }
                write_json(&mut w, &json!({"event":"changed"})).await?;
            }
        }
    }
}

fn handle(state: &State, cmd: &Value) -> Value {
    match cmd["cmd"].as_str().unwrap_or("") {
        "status" => state.status(),
        "subscribe" => ok(json!({})),
        "set_password" => match cmd["password"].as_str().filter(|p| !p.is_empty()) {
            Some(p) => update(state, |c| c.password = p.to_string()),
            None => err("password required"),
        },
        "set_relay" => set_relay(state, cmd),
        "show_key" => ok(json!({"key": state.cfg.lock().unwrap().key})),
        "kick" => match cmd["sid"].as_u64() {
            Some(sid) if state.kick(sid) => ok(json!({})),
            _ => err("unknown sid"),
        },
        "update_status" => ok(update::status_json(state)),
        "update_dismiss" => update::dismiss(state, cmd["version"].as_str().unwrap_or("")),
        "set_update" => update::set(state, cmd["auto_update"].as_bool(), cmd["check_updates"].as_bool()),
        "term" => crate::term::settings(state),
        "set_term" => crate::term::set(state, cmd),
        "history" => {
            let limit = cmd["limit"].as_u64().unwrap_or(HISTORY_DEFAULT).min(HISTORY_MAX) as usize;
            ok(json!({"events": read_recent(&state.log_dir, crate::LOG_FILE, in_history, limit)}))
        }
        _ => err("unknown cmd"),
    }
}

const HISTORY_DEFAULT: u64 = 50;
const HISTORY_MAX: u64 = 500;

/// 访问记录 (spec §6): sessions, terminal inputs, failed auths, refused requests and blocked input; never side
/// connections, nor the hub's background `watch_terms` (polled like `ping`, not a user action).
fn in_history(v: &Value) -> bool {
    let shown = match v["ev"].as_str() {
        Some("session_start" | "session_end" | "term_inputs" | "auth_fail" | "rejected" | "input_blocked") => true,
        Some("request") => v["result"] != "ok" && v["op"] != "watch_terms",
        _ => false,
    };
    shown && v["side"] != true
}

fn update(state: &State, f: impl FnOnce(&mut crate::config::Config)) -> Value {
    let mut cfg = state.cfg.lock().unwrap();
    f(&mut cfg);
    if let Err(e) = cfg.save(&state.home) {
        return err(&format!("save config: {e:#}"));
    }
    drop(cfg);
    state.notify();
    ok(json!({}))
}

/// `host:port` with a numeric port 1-65535; no resolution here.
fn valid_relay(addr: &str) -> bool {
    addr.rsplit_once(':').is_some_and(|(host, port)| !host.is_empty() && port.parse::<u16>().is_ok_and(|p| p != 0))
}

/// Empty `relay` / `key` clear them. Saves, then wakes the relay connection so it starts over.
fn set_relay(state: &State, cmd: &Value) -> Value {
    let text = |k: &str| cmd[k].as_str().map(str::trim).filter(|s| !s.is_empty()).map(str::to_string);
    let (relay, key) = (text("relay"), text("key"));
    if key.as_deref().is_some_and(|k| k.parse::<rapp_wire::Key>().is_err()) {
        return err("bad key");
    }
    if relay.as_deref().is_some_and(|a| !valid_relay(a)) {
        return err("bad address");
    }
    let r = update(state, |c| (c.relay, c.key) = (relay, key));
    if r["ok"] == true {
        state.relay_settings.send_modify(|n| *n += 1);
    }
    r
}
