//! Local IPC (spec §3): TCP on 127.0.0.1, first line `{"token":…}` (from `ipc.token`),
//! then JSON-line commands. No reply to a good token line; a bad one gets an error and EOF.

use crate::shares::{sensitive, Patch};
use crate::state::State;
use crate::update;
use anyhow::Result;
use rapp_conn::Pipe;
use rapp_net::crypto::ct_eq;
use rapp_net::line::{err, ok, write_json};
use rapp_net::log::{clean_name, read_recent, Lvl};
use rapp_wire::Fp;
use serde_json::{json, Value};
use std::sync::Arc;
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::net::{TcpListener, TcpStream};

/// How long `shares` gives each local address of a shared port to accept before saying nothing listens there.
const LISTENING_WAIT: Duration = Duration::from_millis(200);
/// How long `hosts` waits for each device's list of shares: the LAN addresses in `hosts.json`
/// and the ones the relay knows cost one `DIRECT_WAIT` each list, and the relayed request follows.
const HOSTS_WAIT: Duration = Duration::from_secs(6);
const SENSITIVE_WARN: &str = "分享这个端口，等于把这台机器能到的网络也交出去";

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
    // Set by a `pipe` that opened: from then on the connection carries that port's bytes.
    let mut piped: Option<Pipe> = None;
    while piped.is_none() {
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
                    "shares" => shares(state).await,
                    "share" => share(state, &cmd),
                    "unshare" => unshare(state, &cmd),
                    "hosts" => hosts(state).await,
                    "pipe" => match pipe(state, &cmd).await {
                        Ok((p, path)) => {
                            piped = Some(p);
                            ok(json!({"path": path}))
                        }
                        Err(e) => err(&e),
                    },
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
    let Some(mut far) = piped else { return Ok(()) };
    // The reader's buffer may already hold bytes the client sent right behind the command line,
    // so the stream is read through it, never through the socket underneath.
    let mut near = tokio::io::join(lines.into_inner(), w);
    // However the stream ends (closed, reset), that is the port's business, not an IPC failure.
    let _ = rapp_net::quic::splice(&mut near, &mut far).await;
    Ok(())
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
        "set_auto_lock" => match cmd["on"].as_bool() {
            Some(on) => update(state, |c| c.auto_lock = Some(on)),
            None => err("on required"),
        },
        _ => err("unknown cmd"),
    }
}

const HISTORY_DEFAULT: u64 = 50;
const HISTORY_MAX: u64 = 500;

/// 访问记录 (spec §6): sessions, terminal inputs, failed auths, refused requests and blocked input; never side
/// connections, nor the hub's background `watch_terms` (polled like `ping`, not a user action).
fn in_history(v: &Value) -> bool {
    let shown = match v["ev"].as_str() {
        Some("session_start" | "session_end" | "term_inputs" | "auth_fail" | "rejected" | "input_blocked" | "unlock" | "auto_lock" | "auto_lock_failed") => true,
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

/// `http://<id>.rapp:<port>`: the address other devices use for this device's `port`.
fn share_url(state: &State, port: u16) -> String {
    format!("http://{}.rapp:{port}", state.cfg.lock().unwrap().id.clone().unwrap_or_default())
}

/// This device's shares, each with whether something accepts on the port now: on the addresses
/// a forward would reach (`127.0.0.1`, then `[::1]`).
async fn shares(state: &Arc<State>) -> Value {
    let list = state.shares.list();
    let probes: Vec<_> = list
        .iter()
        .map(|s| {
            let port = s.port;
            tokio::spawn(async move {
                crate::forward::connect_local(&crate::forward::local_addrs(port), LISTENING_WAIT).await.is_some()
            })
        })
        .collect();
    let mut shares = Vec::new();
    for (s, probe) in list.iter().zip(probes) {
        shares.push(json!({
            "port": s.port, "note": s.note, "allow": allow_names(state, &s.allow), "url": share_url(state, s.port),
            "listening": probe.await.unwrap_or(false),
        }));
    }
    let id = state.cfg.lock().unwrap().id.clone();
    let relay = state.relay.lock().unwrap().0;
    ok(json!({"id": id, "relay": relay, "shares": shares}))
}

/// The devices of an `allow` as the user knows them: the name each one gave (made safe to show),
/// or the first 8 hex digits of its fingerprint when it gave none.
fn allow_names(state: &State, allow: &[Fp]) -> Vec<String> {
    let name = |fp: &Fp| state.paired.name_of(fp).map(|n| clean_name(&n)).filter(|n| !n.is_empty());
    allow.iter().map(|fp| name(fp).unwrap_or_else(|| fp.short())).collect()
}

/// A port from JSON: an integer 1-65535.
fn port_of(v: &Value) -> Option<u16> {
    v.as_u64().and_then(|p| u16::try_from(p).ok()).filter(|&p| p != 0)
}

/// Shares every port of `ports` with the `note`, `allow` and `raw` given; one that is left out
/// stays as the port's share has it now, so sharing a port again never widens it in silence.
/// Every port is checked before anything is saved, so either all of them are shared or none.
/// A port whose `allow` changed has its running forwards cut: a device that was left out must
/// not go on, and one that still may connects again.
fn share(state: &State, cmd: &Value) -> Value {
    let Some(ports) = cmd["ports"].as_array().filter(|p| !p.is_empty()) else { return err("bad port") };
    let Some(ports) = ports.iter().map(port_of).collect::<Option<Vec<u16>>>() else { return err("bad port") };
    let allow = match &cmd["allow"] {
        Value::Null => None,
        names => match allowed(state, names) {
            Ok(a) => Some(a),
            Err(e) => return err(&e),
        },
    };
    let patch = Patch { note: cmd["note"].as_str().map(str::to_string), allow, raw: cmd["raw"].as_bool() };
    let done = match state.shares.share_all(&ports, &patch) {
        Ok(done) => done,
        Err(e) => return err(&format!("{e:#}")),
    };
    let shared: Vec<Value> = done
        .iter()
        .map(|d| {
            let (port, allow) = (d.share.port, &d.share.allow);
            state.log.event(Lvl::Info, "share", json!({"port": port, "allow": allow.len()}));
            if d.allow_changed {
                state.forwards.cut(port);
            }
            let mut v = json!({"port": port, "url": share_url(state, port)});
            if !allow.is_empty() {
                v["allow"] = json!(allow_names(state, allow));
            }
            if sensitive(port) {
                v["warn"] = json!(SENSITIVE_WARN);
            }
            v
        })
        .collect();
    ok(json!({"shared": shared}))
}

/// The devices the `allow` array names (an empty one: none, which means every trusted device).
/// Each entry must mean exactly one device `paired.json` knows.
fn allowed(state: &State, allow: &Value) -> Result<Vec<Fp>, String> {
    let Some(names) = allow.as_array() else { return Err("bad allow".into()) };
    let mut fps = Vec::new();
    for name in names {
        let Some(name) = name.as_str() else { return Err("bad allow".into()) };
        // A blank entry names no device (and must not match the ones that gave no name).
        let found = if name.trim().is_empty() { Vec::new() } else { state.paired.find(name) };
        let fp = match found.as_slice() {
            [] => return Err(format!("unknown device: {name}")),
            [(fp, _)] => *fp,
            _ => return Err(format!("ambiguous device: {name}")),
        };
        if !fps.contains(&fp) {
            fps.push(fp);
        }
    }
    Ok(fps)
}

/// Stops sharing `port` and cuts its forwards that are running.
fn unshare(state: &State, cmd: &Value) -> Value {
    let Some(port) = port_of(&cmd["port"]) else { return err("bad port") };
    let was = match state.shares.remove(port) {
        Ok(was) => was,
        Err(e) => return err(&format!("{e:#}")),
    };
    if was {
        state.log.event(Lvl::Info, "unshare", json!({"port": port}));
    }
    // Also when it was not shared: a forward may still run from a share removed by hand.
    state.forwards.cut(port);
    ok(json!({"was": was}))
}

/// What each device in `hosts.json` offers this one, all asked at the same time.
async fn hosts(state: &Arc<State>) -> Value {
    let asks: Vec<_> = crate::pipe::known_hosts(&state.home)
        .into_iter()
        .map(|h| {
            let state = state.clone();
            tokio::spawn(async move {
                let got = tokio::time::timeout(HOSTS_WAIT, crate::pipe::shares_of(&state, &h.id)).await;
                let mut v = json!({"id": h.id, "name": h.name});
                match got {
                    Ok(Ok(shares)) => v["shares"] = shares,
                    Ok(Err(e)) => v["error"] = json!(e.as_str()),
                    Err(_) => v["error"] = json!(crate::pipe::PipeErr::Offline.as_str()),
                }
                v
            })
        })
        .collect();
    let mut hosts = Vec::new();
    for ask in asks {
        if let Ok(v) = ask.await {
            hosts.push(v);
        }
    }
    ok(json!({"hosts": hosts}))
}

/// Opens a forward to `port` of the device `to` names.
async fn pipe(state: &State, cmd: &Value) -> Result<(Pipe, &'static str), String> {
    let port = port_of(&cmd["port"]).ok_or("bad port")?;
    crate::pipe::open(state, cmd["to"].as_str().unwrap_or(""), port).await.map_err(|e| e.as_str().to_string())
}
