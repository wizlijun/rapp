//! Changing this device's share table: the one code path for the local IPC and (Task 2) a device that may set it.

use crate::forward::{admit, Caller};
use crate::shares::{sensitive, Patch, Proto, Share, Shared};
use crate::state::{Peer, State};
use anyhow::Result;
use rapp_conn::Pipe;
use rapp_net::line::{err, ok, write_json};
use rapp_net::log::{clean_name, Lvl};
use rapp_net::msg::Op;
use rapp_wire::Fp;
use serde_json::{json, Value};
use std::sync::Arc;
use std::time::Duration;
use tokio::io::AsyncWriteExt;

/// How long `table` gives each local address of a shared port to accept before saying nothing listens there.
const LISTENING_WAIT: Duration = Duration::from_millis(200);
/// Said with a share of a port that usually exposes a login, a proxy, a database or a container API.
pub const SENSITIVE_WARN: &str = "分享这个端口，等于把这台机器能到的网络也交出去";

/// Who sets the table; the `share` / `unshare` log lines say so.
pub enum By<'a> {
    Local,
    Remote(&'a Peer),
}

impl By<'_> {
    /// `more` plus `by`: "local", or the first 8 hex digits of the device's fingerprint with the
    /// `peer`, `path` and `name` of its connection.
    pub fn fields(&self, more: Value) -> Value {
        match self {
            By::Local => {
                let mut v = more;
                v["by"] = json!("local");
                v
            }
            By::Remote(peer) => {
                let mut v = peer.fields(more);
                v["by"] = json!(peer.fp.map(|fp| fp.short()).unwrap_or_default());
                v
            }
        }
    }
}

/// How the entries of `allow` name a device.
#[derive(Clone, Copy, PartialEq)]
pub enum Allow {
    /// The local IPC: a full fingerprint, or a name or fingerprint prefix `paired.json` knows.
    Names,
    /// A remote device: full fingerprints only.
    Fps,
}

/// A port from JSON: an integer 1-65535.
pub fn port_of(v: &Value) -> Option<u16> {
    v.as_u64().and_then(|p| u16::try_from(p).ok()).filter(|&p| p != 0)
}

/// Shares every port of `req["ports"]` with the `note`, `allow` (and, from `By::Local`, `raw`)
/// given; one that is left out stays as the port's share has it now, so sharing a port again
/// never widens it in silence. Every port is checked before anything is saved, so either all
/// of them are shared or none. A port whose `allow` changed has its running forwards cut: a
/// device that was left out must not go on, and one that still may connects again.
pub fn share(state: &State, req: &Value, allow: Allow, by: &By) -> Result<Vec<Shared>, String> {
    let ports = req["ports"].as_array().filter(|p| !p.is_empty()).ok_or("bad port")?;
    let ports = ports.iter().map(port_of).collect::<Option<Vec<u16>>>().ok_or("bad port")?;
    let allow = match &req["allow"] {
        Value::Null => None,
        names => Some(allowed(state, names, allow)?),
    };
    let raw = match by {
        By::Local => req["raw"].as_bool(),
        By::Remote(_) => None,
    };
    let proto = match &req["proto"] {
        Value::Null => None,
        v => Some(v.as_str().and_then(Proto::parse).ok_or("bad proto")?),
    };
    let patch = Patch { note: req["note"].as_str().map(str::to_string), allow, raw, proto };
    let done = state.shares.share_all(&ports, &patch, &|used| crate::numbers::pick(state, used)).map_err(|e| format!("{e:#}"))?;
    for d in &done {
        let (port, allow) = (d.share.port, &d.share.allow);
        // Sharing a port again is how the user says they saw that it moved.
        state.numbers.clear_renumbered(port);
        state.log.event(Lvl::Info, "share", by.fields(json!({"port": port, "allow": allow.len()})));
        if d.allow_changed {
            state.forwards.cut(port);
        }
    }
    sync_own(state);
    Ok(done)
}

/// Makes this device listen on the numbers of its shares as the table has them now. A number
/// another program has is logged (`share_number_taken`) once per share and number, not on every
/// call: the table asks again each time it is read, to take the number once it is free.
pub fn sync_own(state: &State) {
    for s in state.own.sync(&state.shares.list()) {
        let Some(local) = s.local else { continue };
        if state.own.first_taken(s.port, local) {
            state.log.event(Lvl::Warn, "share_number_taken", json!({"port": s.port, "local": local}));
        }
    }
}

/// The devices the `allow` array names (an empty one: none, which means every trusted device).
/// With `Allow::Names` each entry must mean exactly one device `paired.json` knows, unless it is
/// a full fingerprint.
fn allowed(state: &State, allow: &Value, how: Allow) -> Result<Vec<Fp>, String> {
    let Some(names) = allow.as_array() else { return Err("bad allow".into()) };
    let mut fps = Vec::new();
    for name in names {
        let Some(name) = name.as_str() else { return Err("bad allow".into()) };
        let fp = match name.parse::<Fp>() {
            Ok(fp) => fp,
            Err(_) if how == Allow::Fps => return Err("bad allow".into()),
            Err(_) => {
                // A blank entry names no device (and must not match the ones that gave no name).
                let found = if name.trim().is_empty() { Vec::new() } else { state.paired.find(name) };
                match found.as_slice() {
                    [] => return Err(format!("unknown device: {name}")),
                    [(fp, _)] => *fp,
                    _ => return Err(format!("ambiguous device: {name}")),
                }
            }
        };
        if !fps.contains(&fp) {
            fps.push(fp);
        }
    }
    Ok(fps)
}

/// Stops sharing `port` and cuts its forwards that are running. Whether it was shared.
pub fn unshare(state: &State, port: &Value, by: &By) -> Result<bool, String> {
    let port = port_of(port).ok_or("bad port")?;
    let was = state.shares.remove(port).map_err(|e| format!("{e:#}"))?;
    if was {
        state.log.event(Lvl::Info, "unshare", by.fields(json!({"port": port})));
    }
    // Also when it was not shared: a forward may still run from a share removed by hand.
    state.forwards.cut(port);
    sync_own(state);
    Ok(was)
}

/// The whole share table, each share with whether something accepts on its port now: on the
/// addresses a forward would reach (`127.0.0.1`, then `[::1]`). All ports are probed at once.
pub async fn table(state: &Arc<State>) -> Vec<(Share, bool)> {
    // Retries a number another program had.
    sync_own(state);
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
    let mut out = Vec::new();
    for (s, probe) in list.into_iter().zip(probes) {
        out.push((s, probe.await.unwrap_or(false)));
    }
    out
}

/// Answers `shares`, `share` or `unshare` from another device with one JSON line, then closes
/// the stream. Only a key-trusted device may (the checkpoint's steps 1-3).
pub async fn serve(state: &Arc<State>, mut s: Pipe, op: Op, peer: Peer) -> Result<()> {
    let reply = answer(state, &op, &peer).await;
    write_json(&mut s, &reply).await?;
    s.shutdown().await?;
    Ok(())
}

async fn answer(state: &Arc<State>, op: &Op, peer: &Peer) -> Value {
    let name = match op {
        Op::Shares => "shares",
        Op::Share { .. } => "share",
        _ => "unshare",
    };
    if let Err(d) = admit(&Caller { fp: peer.fp.as_ref(), server: false }, true) {
        state.log.event(Lvl::Warn, "share_refused", By::Remote(peer).fields(json!({"op": name, "reason": d.as_str()})));
        return err(d.as_str());
    }
    let by = By::Remote(peer);
    match op {
        Op::Shares => {
            let shares: Vec<Value> = table(state)
                .await
                .into_iter()
                .map(|(s, listening)| {
                    let allow: Vec<Value> = s.allow.iter().map(|fp| device(fp, &state.paired.name_of(fp).unwrap_or_default())).collect();
                    let mut v = json!({
                        "port": s.port, "note": s.note, "allow": allow, "listening": listening,
                        "proto": s.protocol().as_str(), "proto_auto": s.proto_auto,
                    });
                    if let Some(local) = s.local {
                        v["local"] = json!(local);
                    }
                    v
                })
                .collect();
            let known: Vec<Value> = state.paired.list().iter().map(|(fp, n)| device(fp, n)).collect();
            ok(json!({"shares": shares, "known": known}))
        }
        Op::Share { ports, note, allow, proto } => {
            let mut req = json!({"ports": ports, "allow": allow, "proto": proto});
            if let Some(note) = note {
                req["note"] = json!(note);
            }
            match share(state, &req, Allow::Fps, &by) {
                Ok(done) => {
                    let shared: Vec<Value> = done
                        .iter()
                        .map(|d| {
                            let mut v = json!({"port": d.share.port, "proto": d.share.protocol().as_str(), "proto_auto": d.share.proto_auto});
                            if let Some(local) = d.share.local {
                                v["local"] = json!(local);
                            }
                            if sensitive(d.share.port) {
                                v["warn"] = json!(SENSITIVE_WARN);
                            }
                            v
                        })
                        .collect();
                    ok(json!({"shared": shared}))
                }
                Err(e) => refused(state, peer, name, e),
            }
        }
        Op::Unshare { port } => match unshare(state, port, &by) {
            Ok(was) => ok(json!({"was": was})),
            Err(e) => refused(state, peer, name, e),
        },
        _ => err("unknown op"),
    }
}

fn refused(state: &State, peer: &Peer, op: &str, reason: String) -> Value {
    state.log.event(Lvl::Warn, "share_refused", By::Remote(peer).fields(json!({"op": op, "reason": reason})));
    err(&reason)
}

/// `{"fp","name"}`: a device with the name `paired.json` has for it (made safe to show), or "".
fn device(fp: &Fp, name: &str) -> Value {
    json!({"fp": fp.to_string(), "name": clean_name(name)})
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn by_fields_say_who_set_it() {
        assert_eq!(By::Local.fields(json!({"port": 1})), json!({"port": 1, "by": "local"}));
        let fp: Fp = "ab".repeat(32).parse().unwrap();
        let peer = Peer { addr: "1.2.3.4:5".into(), name: Some("mini".into()), path: "lan", fp: Some(fp) };
        assert_eq!(
            By::Remote(&peer).fields(json!({"port": 1})),
            json!({"port": 1, "by": "abababab", "peer": "1.2.3.4:5", "path": "lan", "name": "mini"})
        );
    }
}
