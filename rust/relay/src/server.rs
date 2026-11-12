//! Per-connection and per-stream handling of register / connect / relay.

use crate::db::{self, Db, Device};
use crate::limit::{Limiter, Seldom};
use crate::Opts;
use anyhow::{anyhow, Result};
use quinn::{Connection, Endpoint};
use rapp_net::crypto::{ct_eq, is_valid_id, pw_hash, random_hex, random_id, sha256_hex};
use rapp_net::line::{check, err, ok, read_json, write_json};
use rapp_net::log::{clean_name, Lvl, Log};
use rapp_net::msg::Op;
use rapp_net::quic::{bi, splice_metered, BiStream, Meter};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

const INCOMING_WAIT: Duration = Duration::from_secs(2);

/// A relayed stream shorter than this and smaller than `PROBE_BYTES` (both ways together) is a
/// presence ping or a like-sized control request, not a session: its `relayed` line is Debug, so
/// a 30 s probe does not fill the access record. A ping costs about 100 bytes and well under a
/// second; a session sends its first frame (tens of KB) at once and lasts longer than this.
const PROBE_TIME: Duration = Duration::from_secs(5);
const PROBE_BYTES: u64 = 8 * 1024;

/// `connect` → `offline` is a Warn line at most this often per (source ip, target id).
const OFFLINE_LOG_EVERY: Duration = Duration::from_secs(600);

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
    /// (source ip, target id) pairs whose `offline` was logged lately.
    offline_seen: Mutex<Seldom>,
    pub log: Log,
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
            offline_seen: Mutex::new(Seldom::new(OFFLINE_LOG_EVERY)),
            log: opts.log,
        })
    }

    pub fn devices(&self) -> usize {
        self.db.lock().unwrap().len()
    }
}

/// `ok` when the reply has no error, else the error text with its variable tail cut
/// ("locked, retry in 3s" → "locked").
fn result_of(r: &Value) -> String {
    match r["error"].as_str() {
        None => "ok".into(),
        Some(e) => e.split(',').next().unwrap_or(e).to_string(),
    }
}

fn lvl_of(result: &str) -> Lvl {
    if matches!(result, "ok" | "new" | "replaced") { Lvl::Info } else { Lvl::Warn }
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
                state.log.msg(Lvl::Warn, format!("{}: {e:#}", conn.remote_address()));
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
        Op::Register { key, ref id, .. } if !ct_eq(&key, &state.key) => {
            let id = id.as_deref().map(clean_name);
            state.log.event(Lvl::Warn, "register", json!({"id": id, "ip": ip_of(conn), "result": "bad key"}));
            reply(s, err("bad relay key")).await
        }
        Op::Connect { key, ref id, ref name, .. } if !ct_eq(&key, &state.key) => {
            log_connect(state, conn, name.as_deref(), Some(id), "bad key");
            reply(s, err("bad relay key")).await
        }
        Op::Relay { key, .. } if !ct_eq(&key, &state.key) => {
            log_connect(state, conn, None, None, "bad key");
            reply(s, err("bad relay key")).await
        }
        Op::Register { id, secret, name, pw_salt, pw_hash, lan, .. } => {
            let name = clean_name(&name);
            let (r, result) =
                register(state, conn, id, Device { secret_hash: sha256_hex(secret.as_bytes()), pw_salt, pw_hash, name }, lan);
            let id = r["id"].as_str().map(str::to_string);
            state.log.event(lvl_of(result), "register", json!({"id": id, "ip": ip_of(conn), "result": result}));
            reply(s, r).await
        }
        Op::Connect { id, password, name, .. } => {
            let name = name.as_deref().map(clean_name);
            let r = connect(state, conn.remote_address(), &id, &password, name.as_deref()).await;
            log_connect(state, conn, name.as_deref(), Some(&id), &result_of(&r));
            reply(s, r).await
        }
        Op::Relay { token, .. } => relay(state, conn, &token, s).await,
        _ => reply(s, err("unknown op")).await,
    }
}

async fn reply(s: &mut BiStream, v: Value) -> Result<()> {
    write_json(s, &v).await?;
    s.writer_mut().finish()?;
    Ok(())
}

fn ip_of(conn: &Connection) -> String {
    conn.remote_address().ip().to_string()
}

/// One `connect` event (spec §4.2); `from` is B's address as the relay sees it.
/// A repeated `offline` for the same (source ip, target id) within 10 minutes is Debug (I-2).
fn log_connect(state: &State, conn: &Connection, name: Option<&str>, to: Option<&str>, result: &str) {
    let (name, to) = (name.map(clean_name), to.map(clean_name));
    let mut lvl = lvl_of(result);
    if result == "offline" {
        let pair = format!("{}|{}", ip_of(conn), to.as_deref().unwrap_or(""));
        if !state.offline_seen.lock().unwrap().first(&pair, Instant::now()) {
            lvl = Lvl::Debug;
        }
    }
    let fields = json!({"from": conn.remote_address().to_string(), "name": name, "to": to, "result": result});
    state.log.event(lvl, "connect", fields);
}

/// The reply and the `register` event's result (`new`, `ok`, `replaced`, `id taken`).
fn register(state: &State, conn: &Connection, id: Option<String>, dev: Device, lan: Vec<String>) -> (Value, &'static str) {
    let mut db = state.db.lock().unwrap();
    let (id, mut result) = match id {
        Some(id) if db.contains_key(&id) => {
            if !ct_eq(&db[&id].secret_hash, &dev.secret_hash) {
                return (err("id taken"), "id taken");
            }
            (id, "ok")
        }
        Some(id) if is_valid_id(&id) => (id, "new"),
        _ => loop {
            let id = random_id();
            if !db.contains_key(&id) {
                break (id, "new");
            }
        },
    };
    db.insert(id.clone(), dev);
    if let Err(e) = db::save(&state.db_path, &db) {
        state.log.msg(Lvl::Error, format!("save db: {e:#}"));
    }
    drop(db);
    let old = state.online.lock().unwrap().insert(id.clone(), Online { conn: conn.clone(), lan });
    if let Some(old) = old.filter(|o| o.conn.stable_id() != conn.stable_id()) {
        old.conn.close(0u32.into(), b"replaced by a new registration");
        result = "replaced";
    }
    (ok(json!({"id": id})), result)
}

fn fail(state: &State, lim: &mut Limiter, key: &str, now: Instant) {
    if let Some(secs) = lim.fail(key, now) {
        state.log.event(Lvl::Warn, "lockout", json!({"key": key, "secs": secs}));
    }
}

async fn connect(state: &State, peer: SocketAddr, id: &str, password: &str, name: Option<&str>) -> Value {
    let (id_key, ip_key) = (format!("id:{id}"), format!("ip:{}", peer.ip()));
    let now = Instant::now();
    {
        let mut lim = state.limiter.lock().unwrap();
        if let Some(secs) = lim.locked(&id_key, now).max(lim.locked(&ip_key, now)) {
            return err(&format!("locked, retry in {secs}s"));
        }
        let Some(dev) = state.db.lock().unwrap().get(id).cloned() else {
            fail(state, &mut lim, &ip_key, now);
            return err("unknown id");
        };
        if !ct_eq(&pw_hash(&dev.pw_salt, password), &dev.pw_hash) {
            fail(state, &mut lim, &id_key, now);
            fail(state, &mut lim, &ip_key, now);
            return err("bad password");
        }
        lim.reset(&id_key);
        lim.reset(&ip_key);
    }
    let Some((a, lan)) = state.online.lock().unwrap().get(id).map(|o| (o.conn.clone(), o.lan.clone())) else {
        return err("offline");
    };
    let token = random_hex(16);
    let mut notify = json!({"op":"incoming","token":token,"peer":peer.to_string()});
    if let Some(name) = name {
        notify["name"] = name.into();
    }
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

async fn relay(state: &State, conn: &Connection, token: &str, b: &mut BiStream) -> Result<()> {
    let id = state.tokens.lock().unwrap().get(token).filter(|(_, exp)| *exp > Instant::now()).map(|(id, _)| id.clone());
    let Some(id) = id else {
        log_connect(state, conn, None, None, "bad token");
        return reply(b, err("bad token")).await;
    };
    let a = state.online.lock().unwrap().get(&id).map(|o| o.conn.clone());
    let Some(a) = a else {
        log_connect(state, conn, None, Some(&id), "offline");
        return reply(b, err("offline")).await;
    };
    let mut s = bi(a.open_bi().await?);
    write_json(&mut s, &json!({"op":"relayed","token":token})).await?;
    let (since, meter) = (Instant::now(), Meter::default());
    let r = splice_metered(b, &mut s, &meter).await;
    let (up, down) = meter.get();
    let took = since.elapsed();
    let probe = took < PROBE_TIME && up.saturating_add(down) < PROBE_BYTES;
    let fields = json!({"to": id, "from": conn.remote_address().to_string(), "secs": took.as_secs(), "up": up, "down": down});
    state.log.event(if probe { Lvl::Debug } else { Lvl::Info }, "relayed", fields);
    r.map_err(Into::into)
}
