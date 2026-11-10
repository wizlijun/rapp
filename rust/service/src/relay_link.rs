//! A's long-lived relay connection (spec §2.2, §3): register, reconnect with
//! 1 s … 60 s backoff, answer `incoming` (and punch), serve `relayed` streams.

use crate::peer::serve_request;
use crate::state::{RelayCmd, State};
use anyhow::{anyhow, Result};
use quinn::Connection;
use rapp_net::crypto::{pw_hash, random_hex};
use rapp_net::line::{check, err, ok, read_json, write_json};
use rapp_net::msg::Op;
use rapp_net::quic::{bi, connect, resolve, ALPN_PEER, ALPN_RELAY};
use serde_json::json;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc::UnboundedReceiver;

const CONNECT_WAIT: Duration = Duration::from_secs(5);
const MAX_BACKOFF: Duration = Duration::from_secs(60);

pub async fn run(state: Arc<State>, mut cmds: UnboundedReceiver<RelayCmd>) {
    let mut backoff = Duration::from_secs(1);
    loop {
        let Some((relay, key)) = state.cfg.lock().unwrap().relay() else {
            state.set_relay_status("off", None);
            if cmds.recv().await.is_none() {
                return;
            }
            continue;
        };
        let prev_err = state.relay.lock().unwrap().1.clone();
        state.set_relay_status("connecting", prev_err);
        let conn = match open(&state, &relay, &key).await {
            Ok(c) => c,
            Err(e) => {
                state.set_relay_status("connecting", Some(format!("{e:#}")));
                tokio::select! {
                    _ = tokio::time::sleep(backoff) => backoff = (backoff * 2).min(MAX_BACKOFF),
                    c = cmds.recv() => if c.is_none() { return },
                }
                continue;
            }
        };
        backoff = Duration::from_secs(1);
        state.set_relay_status("connected", None);
        let reason = serve(&state, &conn, &key, &mut cmds).await;
        conn.close(0u32.into(), b"bye");
        match reason {
            Ended::Closed => {
                state.set_relay_status("connecting", Some("relay connection lost".into()));
                tokio::time::sleep(backoff).await;
            }
            Ended::Error(e) => state.set_relay_status("connecting", Some(e)),
            Ended::Reconnect => {}
            Ended::Shutdown => return,
        }
    }
}

enum Ended {
    Closed,
    Error(String),
    Reconnect,
    Shutdown,
}

async fn open(state: &Arc<State>, relay: &str, key: &str) -> Result<Connection> {
    let addr = resolve(relay).await?;
    let conn = connect(&state.endpoint, addr, ALPN_RELAY, CONNECT_WAIT).await?;
    if let Err(e) = register(state, &conn, key).await {
        conn.close(0u32.into(), b"register failed");
        return Err(e);
    }
    Ok(conn)
}

async fn register(state: &Arc<State>, conn: &Connection, key: &str) -> Result<()> {
    let cfg = state.cfg.lock().unwrap().clone();
    let pw_salt = random_hex(16);
    let op = Op::Register {
        key: key.to_string(),
        id: cfg.id.clone(),
        secret: cfg.secret.clone(),
        name: cfg.name.clone(),
        pw_hash: pw_hash(&pw_salt, &cfg.password),
        pw_salt,
        lan: rapp_net::addr::lan_addrs(state.port),
    };
    let mut s = bi(conn.open_bi().await?);
    write_json(&mut s, &op).await?;
    let r = check(read_json(&mut s).await?)?;
    let id = r["id"].as_str().ok_or_else(|| anyhow!("register reply without id"))?.to_string();
    let mut cfg = state.cfg.lock().unwrap();
    if cfg.id.as_deref() != Some(&id) {
        cfg.id = Some(id.clone());
        cfg.save(&state.home)?;
        drop(cfg);
        state.notify();
    }
    eprintln!("rapp-service: registered as {id}");
    Ok(())
}

async fn serve(state: &Arc<State>, conn: &Connection, key: &str, cmds: &mut UnboundedReceiver<RelayCmd>) -> Ended {
    loop {
        tokio::select! {
            pair = conn.accept_bi() => match pair {
                Ok(pair) => {
                    let state = state.clone();
                    tokio::spawn(async move {
                        if let Err(e) = from_relay(&state, bi(pair)).await {
                            eprintln!("rapp-service: relay stream: {e:#}");
                        }
                    });
                }
                Err(_) => return Ended::Closed,
            },
            cmd = cmds.recv() => match cmd {
                Some(RelayCmd::Reregister) => {
                    if let Err(e) = register(state, conn, key).await {
                        return Ended::Error(format!("{e:#}"));
                    }
                }
                Some(RelayCmd::Reconnect) => return Ended::Reconnect,
                None => return Ended::Shutdown,
            },
        }
    }
}

/// A stream the relay opened: `incoming` (a B is about to connect) or `relayed`.
async fn from_relay(state: &Arc<State>, mut s: rapp_net::quic::BiStream) -> Result<()> {
    match serde_json::from_value(read_json(&mut s).await?) {
        Ok(Op::Incoming { token, peer }) => {
            state.add_token(token, peer.clone());
            write_json(&mut s, &ok(json!({}))).await?;
            s.writer_mut().finish()?;
            punch(state, &peer);
            Ok(())
        }
        Ok(Op::Relayed { token }) => match state.token_peer(&token) {
            Some(peer) => serve_request(state, s, peer, "relay").await,
            None => {
                write_json(&mut s, &err("bad token")).await?;
                s.writer_mut().finish()?;
                Ok(())
            }
        },
        _ => {
            write_json(&mut s, &err("unknown op")).await?;
            Ok(())
        }
    }
}

/// Dial B once without waiting, to open a mapping in our NAT (spec §2.2).
fn punch(state: &Arc<State>, peer: &str) {
    let Ok(addr) = peer.parse() else { return };
    let ep = state.endpoint.clone();
    tokio::spawn(async move {
        let _ = connect(&ep, addr, ALPN_PEER, Duration::from_secs(2)).await;
    });
}
