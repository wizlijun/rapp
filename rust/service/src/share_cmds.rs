//! The local IPC `shares`, `share` and `unshare`. With `to` they ask another device through
//! `pipe` and answer in the same shape.

use crate::ipc::HOSTS_WAIT;
use crate::pipe::{self, known_hosts, target_id};
use crate::sharing::{self, Allow, By, SENSITIVE_WARN};
use crate::shares::sensitive;
use crate::state::State;
use rapp_net::line::{err, ok};
use rapp_net::log::clean_name;
use rapp_net::msg::Op;
use rapp_wire::Fp;
use serde_json::{json, Value};
use std::sync::Arc;

/// The device a command's `to` means, when it is not this one: its ID and the name this device
/// gives it (its entry in `hosts.json`, or the ID).
fn target(state: &State, cmd: &Value) -> Result<Option<(String, String)>, Value> {
    let Some(to) = cmd["to"].as_str() else { return Ok(None) };
    let id = target_id(to).ok_or_else(|| err("unknown name"))?;
    if state.cfg.lock().unwrap().id.as_deref() == Some(id.as_str()) {
        return Ok(None);
    }
    let name = known_hosts(&state.home).into_iter().find(|h| h.id == id).map(|h| clean_name(&h.name)).filter(|n| !n.is_empty());
    Ok(Some((id.clone(), name.unwrap_or(id))))
}

/// Sends `op` to the device `id`: its reply and fingerprint, or the error to answer with.
async fn ask_there(state: &State, id: &str, op: &Op) -> Result<(Value, Fp), Value> {
    match tokio::time::timeout(HOSTS_WAIT, pipe::set(state, id, op)).await {
        Ok(Ok(got)) => Ok(got),
        Ok(Err(e)) => Err(err(e.as_str())),
        Err(_) => Err(err("offline")),
    }
}

/// How a device is shown: this device is `本机`; the device asked is the name this device gives
/// it; any other is the name it gave (made safe to show), or the first 8 hex digits of its
/// fingerprint when it gave none.
pub fn shown(fp: &Fp, me: &Fp, target: Option<(&Fp, &str)>, given: &str) -> String {
    if fp == me {
        return "本机".into();
    }
    if let Some((t, name)) = target {
        if fp == t {
            return name.into();
        }
    }
    let given = clean_name(given);
    if given.is_empty() { fp.short() } else { given }
}

/// `{"fp","name"}` of a device as the panel reads it.
fn device(fp: &Fp, name: String) -> Value {
    json!({"fp": fp.to_string(), "name": name})
}

/// One row of the `shares` reply; `allow` is what `shown` made of each device.
fn row(id: &str, me: &Fp, port: u16, note: &str, allow: Vec<(Fp, String)>, listening: bool) -> Value {
    let url = format!("http://{id}.rapp:{port}");
    let addr = if port == 22 { format!("ssh {id}.rapp") } else { url.clone() };
    let mine = allow.is_empty() || allow.iter().any(|(fp, _)| fp == me);
    let allow: Vec<Value> = allow.into_iter().map(|(fp, name)| device(&fp, name)).collect();
    json!({
        "port": port, "note": note, "allow": allow, "url": url, "addr": addr, "web": port != 22,
        "listening": listening, "mine": mine,
    })
}

/// A device list of the other device's reply (`[{"fp","name"}]`).
fn devices(list: &Value) -> Vec<(Fp, String)> {
    let one = |d: &Value| Some((d["fp"].as_str()?.parse::<Fp>().ok()?, d["name"].as_str().unwrap_or("").to_string()));
    list.as_array().map(|a| a.iter().filter_map(one).collect()).unwrap_or_default()
}

/// `http://<id>.rapp:<port>`: the address other devices use for this device's `port`.
fn share_url(state: &State, port: u16) -> String {
    format!("http://{}.rapp:{port}", state.cfg.lock().unwrap().id.clone().unwrap_or_default())
}

/// The share table of this device, or of the device `to` means.
pub async fn shares(state: &Arc<State>, cmd: &Value) -> Value {
    let me = state.identity.fp;
    let target = match target(state, cmd) {
        Ok(t) => t,
        Err(e) => return e,
    };
    let Some((id, name)) = target else {
        let id = state.cfg.lock().unwrap().id.clone();
        let own = id.clone().unwrap_or_default();
        let named = |fp: &Fp| shown(fp, &me, None, &state.paired.name_of(fp).unwrap_or_default());
        let shares: Vec<Value> = sharing::table(state)
            .await
            .into_iter()
            .map(|(s, listening)| row(&own, &me, s.port, &s.note, s.allow.iter().map(|fp| (*fp, named(fp))).collect(), listening))
            .collect();
        let mut known = vec![device(&me, "本机".into())];
        known.extend(state.paired.list().iter().filter(|(fp, _)| *fp != me).map(|(fp, _)| device(fp, named(fp))));
        let relay = state.relay.lock().unwrap().0;
        return ok(json!({"id": id, "me": me.to_string(), "relay": relay, "shares": shares, "known": known}));
    };
    let (reply, tfp) = match ask_there(state, &id, &Op::Shares).await {
        Ok(got) => got,
        Err(e) => return e,
    };
    let named = |fp: &Fp, given: &str| shown(fp, &me, Some((&tfp, &name)), given);
    let shares: Vec<Value> = reply["shares"]
        .as_array()
        .map(|a| a.as_slice())
        .unwrap_or_default()
        .iter()
        .filter_map(|s| {
            let port = sharing::port_of(&s["port"])?;
            let allow = devices(&s["allow"]).into_iter().map(|(fp, n)| (fp, named(&fp, &n))).collect();
            Some(row(&id, &me, port, s["note"].as_str().unwrap_or(""), allow, s["listening"] == true))
        })
        .collect();
    let mut known = vec![device(&me, "本机".into())];
    known.extend(devices(&reply["known"]).into_iter().filter(|(fp, _)| *fp != me).map(|(fp, n)| device(&fp, named(&fp, &n))));
    ok(json!({"id": id, "me": me.to_string(), "shares": shares, "known": known}))
}

/// The devices of an `allow` as the user knows them: the name each one gave (made safe to show),
/// or the first 8 hex digits of its fingerprint when it gave none.
fn allow_names(state: &State, allow: &[Fp]) -> Vec<String> {
    let name = |fp: &Fp| state.paired.name_of(fp).map(|n| clean_name(&n)).filter(|n| !n.is_empty());
    allow.iter().map(|fp| name(fp).unwrap_or_else(|| fp.short())).collect()
}

/// Shares the ports of `cmd` (see `sharing::share`) and answers each one's address.
pub async fn share(state: &State, cmd: &Value) -> Value {
    match target(state, cmd) {
        Err(e) => return e,
        Ok(Some((id, _))) => {
            let note = cmd["note"].as_str().map(str::to_string);
            let op = Op::Share { ports: cmd["ports"].clone(), note, allow: cmd["allow"].clone() };
            return match ask_there(state, &id, &op).await {
                Ok((reply, _)) => ok(json!({"shared": reply["shared"]})),
                Err(e) => e,
            };
        }
        Ok(None) => {}
    }
    let done = match sharing::share(state, cmd, Allow::Names, &By::Local) {
        Ok(done) => done,
        Err(e) => return err(&e),
    };
    let shared: Vec<Value> = done
        .iter()
        .map(|d| {
            let (port, allow) = (d.share.port, &d.share.allow);
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

/// Stops sharing `cmd["port"]` and cuts its forwards that are running.
pub async fn unshare(state: &State, cmd: &Value) -> Value {
    match target(state, cmd) {
        Err(e) => return e,
        Ok(Some((id, _))) => {
            return match ask_there(state, &id, &Op::Unshare { port: cmd["port"].clone() }).await {
                Ok((reply, _)) => ok(json!({"was": reply["was"]})),
                Err(e) => e,
            };
        }
        Ok(None) => {}
    }
    match sharing::unshare(state, &cmd["port"], &By::Local) {
        Ok(was) => ok(json!({"was": was})),
        Err(e) => err(&e),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn names_from_the_other_device_are_cleaned() {
        let (x, me, t) = (Fp([1; 32]), Fp([2; 32]), Fp([3; 32]));
        assert_eq!(shown(&x, &me, Some((&t, "gpu1")), "\u{202e}mini\n"), "mini");
        assert_eq!(shown(&x, &me, Some((&t, "gpu1")), ""), x.short());
        assert_eq!(shown(&x, &me, None, "\u{7}\n"), x.short());
        assert_eq!(shown(&x, &me, None, &"a".repeat(200)).chars().count(), rapp_net::log::NAME_MAX);
        assert_eq!(shown(&me, &me, Some((&t, "gpu1")), "x"), "本机");
        assert_eq!(shown(&t, &me, Some((&t, "gpu1")), "whatever"), "gpu1");
    }
}
