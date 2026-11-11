//! Local IPC (spec §3): TCP on 127.0.0.1, first line `{"token":…}` (from `ipc.token`),
//! then JSON-line commands. No reply to a good token line; a bad one gets an error and EOF.

use crate::state::{RelayCmd, State};
use anyhow::Result;
use rapp_net::crypto::ct_eq;
use rapp_net::line::{err, ok, write_json};
use serde_json::{json, Value};
use std::sync::Arc;
use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::net::{TcpListener, TcpStream};

pub async fn serve(state: Arc<State>, listener: TcpListener, token: String) {
    while let Ok((tcp, _)) = listener.accept().await {
        let (state, token) = (state.clone(), token.clone());
        tokio::spawn(async move {
            if let Err(e) = conn(&state, tcp, &token).await {
                eprintln!("rapp-service: ipc: {e:#}");
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
                let reply = if cmd["cmd"] == "permissions" {
                    let perms = crate::workers::refresh_permissions(state, cmd["prompt"] == true).await;
                    ok(json!({"permissions": perms}))
                } else {
                    handle(state, &cmd)
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
            Some(p) => update(state, |c| c.password = p.to_string(), RelayCmd::Reregister),
            None => err("password required"),
        },
        "set_relay" => {
            let relay = cmd["relay"].as_str().map(str::to_string);
            let key = cmd["key"].as_str().map(str::to_string);
            update(state, |c| (c.relay, c.key) = (relay, key), RelayCmd::Reconnect)
        }
        "kick" => match cmd["sid"].as_u64() {
            Some(sid) if state.kick(sid) => ok(json!({})),
            _ => err("unknown sid"),
        },
        _ => err("unknown cmd"),
    }
}

fn update(state: &State, f: impl FnOnce(&mut crate::config::Config), then: RelayCmd) -> Value {
    let mut cfg = state.cfg.lock().unwrap();
    f(&mut cfg);
    if let Err(e) = cfg.save(&state.home) {
        return err(&format!("save config: {e:#}"));
    }
    drop(cfg);
    let _ = state.relay_cmd.send(then);
    state.notify();
    ok(json!({}))
}
