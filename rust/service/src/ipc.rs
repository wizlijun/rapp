//! Local IPC (spec §3): TCP on 127.0.0.1, first line `{"token":…}` (from `ipc.token`),
//! then JSON-line commands. No reply to a good token line; a bad one gets an error and EOF.

use crate::state::State;
use crate::update;
use anyhow::Result;
use rapp_conn::Pipe;
use rapp_net::crypto::ct_eq;
use rapp_net::line::{err, ok, write_json};
use rapp_net::log::{read_recent, Lvl};
use serde_json::{json, Value};
use std::sync::Arc;
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::net::{TcpListener, TcpStream};

/// How long `hosts` waits for each device's list of shares: the LAN addresses in `hosts.json`
/// and the ones the relay knows cost one `DIRECT_WAIT` each list, and the relayed request follows.
pub(crate) const HOSTS_WAIT: Duration = Duration::from_secs(6);

/// Numbers the IPC connections, so that each GUI's `gui_windows` count is its own.
static CONN_IDS: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(1);

/// Forgets a connection's `gui_windows` count when it ends, however it ends.
struct Windows<'a>(&'a State, u64);

impl Drop for Windows<'_> {
    fn drop(&mut self) {
        self.0.activity.drop_conn(self.1);
    }
}

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
    let windows = Windows(state, CONN_IDS.fetch_add(1, std::sync::atomic::Ordering::Relaxed));
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
                    // `wait`: reply once the check is done (`rapp update check`), not right away.
                    "update_check" if cmd["wait"] == true => {
                        update::check_now(state).await;
                        ok(json!({}))
                    }
                    "update_check" => {
                        let state = state.clone();
                        tokio::spawn(async move { update::check_now(&state).await });
                        ok(json!({}))
                    }
                    "update_apply" => {
                        update::apply(state, cmd["confirm_signature_change"] == true, by(&cmd), closed.clone()).await
                    }
                    "update_rollback" => update::rollback(state, by(&cmd), closed.clone()).await,
                    // The GUI's remote windows other than text terminals: they keep the auto-update out.
                    "gui_windows" => match cmd["count"].as_u64() {
                        Some(n) => {
                            state.activity.set_windows(windows.1, n as usize);
                            ok(json!({}))
                        }
                        None => err("count"),
                    },
                    "shares" => crate::share_cmds::shares(state, &cmd).await,
                    "share" => crate::share_cmds::share(state, &cmd).await,
                    "unshare" => crate::share_cmds::unshare(state, &cmd).await,
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
    let meter = rapp_net::quic::Meter::default();
    let tick = rapp_net::quic::TRAFFIC_TICK;
    let _ = rapp_net::quic::splice_watched(&mut near, &mut far, &meter, tick, || state.activity.touch()).await;
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
/// Who sent an `update_apply`/`update_rollback`: `rapp update` says `"by": "cli"`.
fn by(cmd: &Value) -> update::By {
    if cmd["by"] == "cli" {
        update::By::Cli
    } else {
        update::By::Gui
    }
}

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

/// What each device in `hosts.json` offers this one, all asked at the same time.
async fn hosts(state: &Arc<State>) -> Value {
    if let Some(known) = crate::pipe::known_ids(&state.home) {
        state.maps.keep_devices(&known);
    }
    let asks: Vec<_> = crate::pipe::known_hosts(&state.home)
        .into_iter()
        .map(|h| {
            let state = state.clone();
            tokio::spawn(async move {
                let got = tokio::time::timeout(HOSTS_WAIT, crate::pipe::shares_of(&state, &h.id)).await;
                let mut v = json!({"id": h.id, "name": h.name});
                match got {
                    Ok(Ok(shares)) => v["shares"] = reached(&state, &h.id, &h.name, shares).await,
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

/// The shares the device `id` (known here as `name`) offers this one, each with the local port
/// it is reached on here (`local`, on its share number when it can), what to type or open
/// (`addr`), and what it speaks; neither `local` nor `addr` when no local port could be had.
/// The local ports of shares it no longer offers are given back.
async fn reached(state: &Arc<State>, id: &str, name: &str, mut shares: Value) -> Value {
    use crate::share_cmds::{addr, number, numbers, protocol, told};
    let list = shares.as_array_mut().map(std::mem::take).unwrap_or_default();
    crate::numbers::saw(state, id, name, &numbers(&list));
    let wants = rapp_ports::wants(&list);
    state.maps.keep(id, &wants.iter().map(|(port, _)| *port).collect::<Vec<u16>>());
    let locals = crate::maps::ensure_all(state, id, &wants).await;
    let list = list
        .into_iter()
        .map(|mut s| {
            let Some(port) = crate::sharing::port_of(&s["port"]) else { return s };
            let local = wants.iter().zip(&locals).find(|((p, _), _)| *p == port).and_then(|(_, l)| *l);
            let proto = protocol(&s, port);
            let item = s.clone();
            told(&mut s, &item, proto, local, state.maps.honoured(number(&item)));
            match local {
                Some(local) => (s["local"], s["addr"]) = (json!(local), json!(addr(proto, local))),
                // The share number the sharer sent is not a port of this device.
                None => {
                    s.as_object_mut().map(|o| o.remove("local"));
                }
            }
            s
        })
        .collect();
    Value::Array(list)
}

/// Opens a forward to `port` of the device `to` names.
async fn pipe(state: &State, cmd: &Value) -> Result<(Pipe, &'static str), String> {
    let port = crate::sharing::port_of(&cmd["port"]).ok_or("bad port")?;
    crate::pipe::open(state, cmd["to"].as_str().unwrap_or(""), port).await.map_err(|e| e.as_str().to_string())
}
