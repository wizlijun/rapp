//! Per-connection and per-stream handling of register / connect / relay.

use crate::db::{self, Db, Device};
use crate::limit::Limiter;
use crate::Opts;
use anyhow::{anyhow, Result};
use quinn::{Connection, Endpoint};
use rapp_net::crypto::{ct_eq, is_valid_id, pw_hash, random_hex, random_id, sha256_hex};
use rapp_net::line::{check, err, ok, read_json, write_json};
use rapp_net::msg::Op;
use rapp_net::quic::{bi, splice, BiStream};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

const INCOMING_WAIT: Duration = Duration::from_secs(2);

struct Online {
    conn: Connection,
    lan: Vec<String>,
}

pub struct State {
    key: String,
    db_path: PathBuf,
    token_ttl: Duration,
    db: Mutex<Db>,
    online: Mutex<HashMap<String, Online>>,
    /// token → (device id, expiry)
    tokens: Mutex<HashMap<String, (String, Instant)>>,
    limiter: Mutex<Limiter>,
}

impl State {
    pub fn load(opts: Opts) -> Result<State> {
        Ok(State {
            db: Mutex::new(db::load(&opts.db)?),
            key: opts.key,
            db_path: opts.db,
            token_ttl: opts.token_ttl,
            online: Mutex::default(),
            tokens: Mutex::default(),
            limiter: Mutex::default(),
        })
    }
}

pub async fn accept_loop(endpoint: Endpoint, state: Arc<State>) {
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
    while let Ok(pair) = conn.accept_bi().await {
        let (state, conn) = (state.clone(), conn.clone());
        tokio::spawn(async move {
            let mut s = bi(pair);
            if let Err(e) = serve_stream(&state, &conn, &mut s).await {
                eprintln!("rapp-relay: {}: {e:#}", conn.remote_address());
            }
        });
    }
    // Forget this device if this was its registered connection.
    state.online.lock().unwrap().retain(|_, o| o.conn.stable_id() != conn.stable_id());
}

async fn serve_stream(state: &State, conn: &Connection, s: &mut BiStream) -> Result<()> {
    let req = read_json(s).await?;
    let op: Op = match serde_json::from_value(req) {
        Ok(op) => op,
        Err(_) => return reply(s, err("bad request")).await,
    };
    match op {
        Op::Register { key, .. } | Op::Connect { key, .. } | Op::Relay { key, .. } if !ct_eq(&key, &state.key) => {
            reply(s, err("bad relay key")).await
        }
        Op::Register { id, secret, name, pw_salt, pw_hash, lan, .. } => {
            let r = register(state, conn, id, Device { secret_hash: sha256_hex(secret.as_bytes()), pw_salt, pw_hash, name }, lan);
            reply(s, r).await
        }
        Op::Connect { id, password, .. } => {
            let r = connect(state, conn.remote_address(), &id, &password).await;
            reply(s, r).await
        }
        Op::Relay { token, .. } => relay(state, &token, s).await,
        _ => reply(s, err("unknown op")).await,
    }
}

async fn reply(s: &mut BiStream, v: Value) -> Result<()> {
    write_json(s, &v).await?;
    s.writer_mut().finish()?;
    Ok(())
}

fn register(state: &State, conn: &Connection, id: Option<String>, dev: Device, lan: Vec<String>) -> Value {
    let mut db = state.db.lock().unwrap();
    let id = match id {
        Some(id) if db.contains_key(&id) => {
            if !ct_eq(&db[&id].secret_hash, &dev.secret_hash) {
                return err("id taken");
            }
            id
        }
        Some(id) if is_valid_id(&id) => id,
        _ => loop {
            let id = random_id();
            if !db.contains_key(&id) {
                break id;
            }
        },
    };
    db.insert(id.clone(), dev);
    if let Err(e) = db::save(&state.db_path, &db) {
        eprintln!("rapp-relay: save db: {e:#}");
    }
    drop(db);
    let old = state.online.lock().unwrap().insert(id.clone(), Online { conn: conn.clone(), lan });
    if let Some(old) = old.filter(|o| o.conn.stable_id() != conn.stable_id()) {
        old.conn.close(0u32.into(), b"replaced by a new registration");
    }
    ok(json!({"id": id}))
}

async fn connect(state: &State, peer: SocketAddr, id: &str, password: &str) -> Value {
    let (id_key, ip_key) = (format!("id:{id}"), format!("ip:{}", peer.ip()));
    let now = Instant::now();
    {
        let mut lim = state.limiter.lock().unwrap();
        if let Some(secs) = lim.locked(&id_key, now).max(lim.locked(&ip_key, now)) {
            return err(&format!("locked, retry in {secs}s"));
        }
        let Some(dev) = state.db.lock().unwrap().get(id).cloned() else {
            lim.fail(&ip_key, now);
            return err("unknown id");
        };
        if !ct_eq(&pw_hash(&dev.pw_salt, password), &dev.pw_hash) {
            lim.fail(&id_key, now);
            lim.fail(&ip_key, now);
            return err("bad password");
        }
        lim.reset(&id_key);
        lim.reset(&ip_key);
    }
    let Some((a, lan)) = state.online.lock().unwrap().get(id).map(|o| (o.conn.clone(), o.lan.clone())) else {
        return err("offline");
    };
    let token = random_hex(16);
    let notify = json!({"op":"incoming","token":token,"peer":peer.to_string()});
    if tokio::time::timeout(INCOMING_WAIT, ask(&a, &notify)).await.map_err(|_| anyhow!("timeout")).and_then(|r| r).is_err() {
        return err("offline");
    }
    let name = state.db.lock().unwrap().get(id).map(|d| d.name.clone()).unwrap_or_default();
    {
        let mut tokens = state.tokens.lock().unwrap();
        tokens.retain(|_, (_, exp)| *exp > now);
        tokens.insert(token.clone(), (id.to_string(), Instant::now() + state.token_ttl));
    }
    ok(json!({"token": token, "name": name, "lan": lan, "public": a.remote_address().to_string()}))
}

/// One request/reply exchange on a new stream to A.
async fn ask(a: &Connection, v: &Value) -> Result<Value> {
    let mut s = bi(a.open_bi().await?);
    write_json(&mut s, v).await?;
    check(read_json(&mut s).await?)
}

async fn relay(state: &State, token: &str, b: &mut BiStream) -> Result<()> {
    let id = state.tokens.lock().unwrap().get(token).filter(|(_, exp)| *exp > Instant::now()).map(|(id, _)| id.clone());
    let Some(id) = id else { return reply(b, err("bad token")).await };
    let a = state.online.lock().unwrap().get(&id).map(|o| o.conn.clone());
    let Some(a) = a else { return reply(b, err("offline")).await };
    let mut s = bi(a.open_bi().await?);
    write_json(&mut s, &json!({"op":"relayed","token":token})).await?;
    splice(b, &mut s).await?;
    Ok(())
}
