//! Changing this device's share table: the one code path for the local IPC and (Task 2) a device that may set it.

use crate::shares::{Patch, Shared};
use crate::state::{Peer, State};
use rapp_net::log::Lvl;
use rapp_wire::Fp;
use serde_json::{json, Value};

/// Who sets the table; the `share` / `unshare` log lines say so.
pub enum By<'a> {
    Local,
    // Task 2 is its first caller.
    #[allow(dead_code)]
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
    let patch = Patch { note: req["note"].as_str().map(str::to_string), allow, raw };
    let done = state.shares.share_all(&ports, &patch).map_err(|e| format!("{e:#}"))?;
    for d in &done {
        let (port, allow) = (d.share.port, &d.share.allow);
        state.log.event(Lvl::Info, "share", by.fields(json!({"port": port, "allow": allow.len()})));
        if d.allow_changed {
            state.forwards.cut(port);
        }
    }
    Ok(done)
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
    Ok(was)
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
