//! Device-to-device side of A (spec §2.3): direct QUIC connections (auth first) and
//! the request handler shared with relayed streams.

use crate::state::{Peer, State};
use crate::workers;
use anyhow::Result;
use quinn::{Connection, Endpoint};
use rapp_net::addr::is_private;
use rapp_net::crypto::ct_eq;
use rapp_net::line::{err, ok, read_json, write_json};
use rapp_net::log::{clean_name, Lvl};
use rapp_net::msg::Op;
use rapp_net::quic::{bi, splice_metered, BiStream, Meter};
use serde_json::{json, Value};
use std::sync::Arc;
use std::time::{Duration, Instant};
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
    let mut peer = Peer { addr: remote.to_string(), name: None, path: if private { "lan" } else { "direct" } };
    let reason = match tokio::time::timeout(AUTH_WAIT, auth(&state, &conn, private, &mut peer)).await {
        Ok(Ok(None)) => None,
        Ok(Ok(Some(reason))) => Some(reason),
        Err(_) => Some("timeout".to_string()),
        // Gone before saying anything (a dropped probe): nothing worth recording.
        Ok(Err(_)) => {
            conn.close(1u32.into(), b"auth failed");
            return;
        }
    };
    if let Some(reason) = reason {
        state.log.event(Lvl::Warn, "auth_fail", peer.fields(json!({"reason": reason})));
        // Give the error line a moment to arrive before closing.
        let _ = tokio::time::timeout(Duration::from_secs(1), conn.closed()).await;
        conn.close(1u32.into(), b"auth failed");
        return;
    }
    while let Ok(pair) = conn.accept_bi().await {
        let (state, peer) = (state.clone(), peer.clone());
        tokio::spawn(async move {
            if let Err(e) = serve_request(&state, bi(pair), peer).await {
                state.log.msg(Lvl::Warn, format!("{remote}: {e:#}"));
            }
        });
    }
}

/// The first stream must be `{"op":"auth",...}`. None when it passed, else the reason;
/// `peer.name` picks up the name B declared (or the one it gave the relay), cleaned.
/// Err only when B never opened a stream (a dropped probe).
async fn auth(state: &State, conn: &Connection, private: bool, peer: &mut Peer) -> Result<Option<String>> {
    let mut s = bi(conn.accept_bi().await?);
    let declared = |n: Option<String>| n.map(|n| clean_name(&n)).filter(|n| !n.is_empty());
    let reply = match read_json(&mut s).await.map(serde_json::from_value) {
        Err(_) => err("bad request"),
        Ok(Ok(Op::Auth { token, password, name })) => {
            peer.name = declared(name);
            match (token, password) {
                (Some(t), _) => match state.token_peer(&t) {
                    Some((_, relay_name)) => {
                        peer.name = peer.name.take().or(declared(relay_name));
                        ok(json!({}))
                    }
                    None => err("bad token"),
                },
                (None, Some(p)) if private => {
                    let cfg = state.cfg.lock().unwrap().clone();
                    if ct_eq(&p, &cfg.password) {
                        // Named so B can check the ID behind an `id@ip` it was given (§2.3).
                        ok(json!({"id": cfg.id, "name": cfg.name}))
                    } else {
                        err("bad password")
                    }
                }
                (None, Some(_)) => err("password auth only from private networks"),
                (None, None) => err("auth required"),
            }
        }
        _ => err("auth required"),
    };
    // The attempt is recorded even when B is already gone.
    let _ = reply_and_finish(&mut s, reply.clone()).await;
    Ok(reply["error"].as_str().map(str::to_string))
}

async fn reply_and_finish(s: &mut BiStream, v: Value) -> Result<()> {
    write_json(s, &v).await?;
    s.writer_mut().finish()?;
    Ok(())
}

/// One request on an authenticated stream (direct or relayed).
pub async fn serve_request(state: &Arc<State>, mut s: BiStream, peer: Peer) -> Result<()> {
    match serde_json::from_value(read_json(&mut s).await?) {
        Ok(Op::ListApps) => {
            let r = match workers::list_apps(state).await {
                Ok((apps, Some(perms))) => ok(json!({"apps": apps, "permissions": perms})),
                Ok((apps, None)) => ok(json!({"apps": apps})),
                Err(e) => err(&e.to_string()),
            };
            log_request(state, &peer, json!({"op": "list_apps"}), &r);
            reply_and_finish(&mut s, r).await
        }
        Ok(Op::Open { app, side }) => open(state, s, &app, side, peer).await,
        _ => reply_and_finish(&mut s, err("unknown op")).await,
    }
}

/// `request {peer, name?, path, op, app?, side?, result}`; result is "ok" or the error text.
fn log_request(state: &State, peer: &Peer, what: Value, reply: &Value) {
    let result = reply["error"].as_str().unwrap_or("ok");
    let lvl = if result == "ok" { Lvl::Info } else { Lvl::Warn };
    let mut fields = peer.fields(what);
    fields["result"] = json!(result);
    state.log.event(lvl, "request", fields);
}

/// `{"app","side"?}` for the open's log lines.
fn open_fields(app: &str, side: bool) -> Value {
    let mut v = json!({"op": "open", "app": app});
    if side {
        v["side"] = json!(true);
    }
    v
}

async fn open(state: &Arc<State>, mut s: BiStream, app: &str, side: bool, peer: Peer) -> Result<()> {
    let (port, token) = match workers::start_session(state, app).await {
        Ok(w) => w,
        Err(e) => {
            let e = format!("{e:#}");
            if e.contains("missing permission") {
                workers::refresh_permissions(state, false).await;
            }
            let r = err(&e);
            log_request(state, &peer, open_fields(app, side), &r);
            return reply_and_finish(&mut s, r).await;
        }
    };
    let result = splice_session(state, &mut s, app, side, port, &token, &peer).await;
    workers::end_session(state, app);
    result
}

async fn splice_session(
    state: &Arc<State>,
    s: &mut BiStream,
    app: &str,
    side: bool,
    port: u16,
    token: &str,
    peer: &Peer,
) -> Result<()> {
    let mut tcp = match TcpStream::connect(("127.0.0.1", port)).await {
        Ok(t) => t,
        Err(e) => {
            let r = err(&format!("worker unreachable: {e}"));
            log_request(state, peer, open_fields(app, side), &r);
            return reply_and_finish(s, r).await;
        }
    };
    tcp.set_nodelay(true)?;
    let reply = ok(json!({"token": token}));
    log_request(state, peer, open_fields(app, side), &reply);
    // Registered before B hears `ok`, so worker events B triggers find their sid.
    let (sid, kick) = state.add_session(peer, app, side);
    let mut fields = peer.session_fields(app, side, sid);
    state.log.event(Lvl::Info, "session_start", fields.clone());
    let (meter, began) = (Meter::default(), Instant::now());
    let reason = match write_json(s, &reply).await {
        Err(e) => format!("{e:#}"),
        Ok(()) => {
            crate::cm::ensure_running(state);
            tokio::select! {
                r = splice_metered(s, &mut tcp, &meter) => match r {
                    Ok(()) => "closed".to_string(),
                    Err(e) => format!("{e:#}"),
                },
                _ = kick.notified() => "kicked".to_string(),
            }
        }
    };
    if !state.end_session(sid) {
        return Ok(()); // the stopping service already wrote its end line
    }
    // The meter counts on B's stream: read from B = up (B→A), written to B = down.
    let (up, down) = meter.get();
    fields["secs"] = json!(began.elapsed().as_secs());
    (fields["up"], fields["down"], fields["reason"]) = (json!(up), json!(down), json!(reason));
    state.log.event(Lvl::Info, "session_end", fields);
    Ok(())
}
