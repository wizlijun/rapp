//! Device-to-device side of A (spec §2.3): direct QUIC connections (auth first) and
//! the request handler shared with relayed streams.

use crate::state::State;
use crate::workers;
use anyhow::Result;
use quinn::{Connection, Endpoint};
use rapp_net::addr::is_private;
use rapp_net::crypto::ct_eq;
use rapp_net::line::{err, ok, read_json, write_json};
use rapp_net::msg::Op;
use rapp_net::quic::{bi, splice, BiStream};
use serde_json::{json, Value};
use std::sync::Arc;
use std::time::Duration;
use tokio::net::TcpStream;

const AUTH_WAIT: Duration = Duration::from_secs(10);

pub async fn accept_loop(state: Arc<State>, endpoint: Endpoint) {
    while let Some(incoming) = endpoint.accept().await {
        let state = state.clone();
        tokio::spawn(async move {
            if let Ok(conn) = incoming.await {
                serve_conn(state, conn).await;
            }
        });
    }
}

async fn serve_conn(state: Arc<State>, conn: Connection) {
    let remote = conn.remote_address();
    let private = is_private(remote.ip());
    let authed = match tokio::time::timeout(AUTH_WAIT, auth(&state, &conn, private)).await {
        Ok(Ok(a)) => a,
        _ => false,
    };
    if !authed {
        // Give the error line a moment to arrive before closing.
        let _ = tokio::time::timeout(Duration::from_secs(1), conn.closed()).await;
        conn.close(1u32.into(), b"auth failed");
        return;
    }
    let path = if private { "lan" } else { "direct" };
    while let Ok(pair) = conn.accept_bi().await {
        let state = state.clone();
        tokio::spawn(async move {
            if let Err(e) = serve_request(&state, bi(pair), remote.to_string(), path).await {
                eprintln!("rapp-service: {remote}: {e:#}");
            }
        });
    }
}

/// The first stream must be `{"op":"auth",...}`; returns whether it passed.
async fn auth(state: &State, conn: &Connection, private: bool) -> Result<bool> {
    let mut s = bi(conn.accept_bi().await?);
    let reply = match serde_json::from_value(read_json(&mut s).await?) {
        Ok(Op::Auth { token: Some(t), .. }) if state.token_peer(&t).is_some() => ok(json!({})),
        Ok(Op::Auth { token: Some(_), .. }) => err("bad token"),
        Ok(Op::Auth { password: Some(p), .. }) if private => {
            if ct_eq(&p, &state.cfg.lock().unwrap().password) {
                ok(json!({}))
            } else {
                err("bad password")
            }
        }
        Ok(Op::Auth { password: Some(_), .. }) => err("password auth only from private networks"),
        _ => err("auth required"),
    };
    let passed = reply["ok"] == true;
    write_json(&mut s, &reply).await?;
    s.writer_mut().finish()?;
    Ok(passed)
}

async fn reply_and_finish(s: &mut BiStream, v: Value) -> Result<()> {
    write_json(s, &v).await?;
    s.writer_mut().finish()?;
    Ok(())
}

/// One request on an authenticated stream (direct or relayed).
pub async fn serve_request(state: &Arc<State>, mut s: BiStream, peer: String, path: &'static str) -> Result<()> {
    match serde_json::from_value(read_json(&mut s).await?) {
        Ok(Op::ListApps) => {
            let r = match workers::list_apps(state).await {
                Ok(apps) => ok(json!({"apps": apps})),
                Err(e) => err(&e.to_string()),
            };
            reply_and_finish(&mut s, r).await
        }
        Ok(Op::Open { app }) => open(state, s, &app, peer, path).await,
        _ => reply_and_finish(&mut s, err("unknown op")).await,
    }
}

async fn open(state: &Arc<State>, mut s: BiStream, app: &str, peer: String, path: &'static str) -> Result<()> {
    let (port, token) = match workers::start_session(state, app).await {
        Ok(w) => w,
        Err(e) => return reply_and_finish(&mut s, err(&e.to_string())).await,
    };
    let result = splice_session(state, &mut s, app, port, &token, peer, path).await;
    workers::end_session(state, app);
    result
}

async fn splice_session(
    state: &Arc<State>,
    s: &mut BiStream,
    app: &str,
    port: u16,
    token: &str,
    peer: String,
    path: &'static str,
) -> Result<()> {
    let mut tcp = match TcpStream::connect(("127.0.0.1", port)).await {
        Ok(t) => t,
        Err(e) => return reply_and_finish(s, err(&format!("worker unreachable: {e}"))).await,
    };
    tcp.set_nodelay(true)?;
    write_json(s, &ok(json!({"token": token}))).await?;
    let (sid, kick) = state.add_session(peer, app, path);
    crate::cm::ensure_running(state);
    tokio::select! {
        r = splice(s, &mut tcp) => { let _ = r; }
        _ = kick.notified() => {}
    }
    state.end_session(sid);
    Ok(())
}
