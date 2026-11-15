//! The local IPC `shares`, `share` and `unshare`.

use crate::sharing::{self, Allow, By};
use crate::shares::sensitive;
use crate::state::State;
use rapp_net::line::{err, ok};
use rapp_net::log::clean_name;
use rapp_wire::Fp;
use serde_json::{json, Value};
use std::sync::Arc;
use std::time::Duration;

/// How long `shares` gives each local address of a shared port to accept before saying nothing listens there.
const LISTENING_WAIT: Duration = Duration::from_millis(200);
const SENSITIVE_WARN: &str = "分享这个端口，等于把这台机器能到的网络也交出去";

/// `http://<id>.rapp:<port>`: the address other devices use for this device's `port`.
fn share_url(state: &State, port: u16) -> String {
    format!("http://{}.rapp:{port}", state.cfg.lock().unwrap().id.clone().unwrap_or_default())
}

/// This device's shares, each with whether something accepts on the port now: on the addresses
/// a forward would reach (`127.0.0.1`, then `[::1]`).
pub async fn shares(state: &Arc<State>) -> Value {
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

/// Shares the ports of `cmd` (see `sharing::share`) and answers each one's address.
pub fn share(state: &State, cmd: &Value) -> Value {
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
pub fn unshare(state: &State, cmd: &Value) -> Value {
    match sharing::unshare(state, &cmd["port"], &By::Local) {
        Ok(was) => ok(json!({"was": was})),
        Err(e) => err(&e),
    }
}
