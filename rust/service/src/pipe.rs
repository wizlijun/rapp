//! The visiting side of port sharing: which device a name means, and asking that device for a
//! port (`open`) or for the shares it offers this one (`shares_of`), through `Outbound`.

use std::path::Path;

use rapp_conn::dial::{NotReached, Target, Via};
use rapp_conn::Pipe;
use rapp_net::msg::Op;
use rapp_wire::{Fp, Key};
use serde::Deserialize;
use serde_json::Value;

use crate::state::State;

/// The device a name means, in this step: the 9-digit ID that is the last label before `.rapp`
/// (or the whole name, when it is just the ID). Anything else is None.
pub fn target_id(name: &str) -> Option<String> {
    let name = name.trim().to_ascii_lowercase();
    let name = name.strip_suffix('.').unwrap_or(&name);
    let labels: Vec<&str> = name.split('.').collect();
    let id = match labels.as_slice() {
        [id] => id,
        [.., id, "rapp"] => id,
        _ => return None,
    };
    (id.len() == 9 && id.bytes().all(|b| b.is_ascii_digit())).then(|| id.to_string())
}

#[derive(Debug, PartialEq)]
pub enum PipeErr {
    /// The name does not mean a device.
    UnknownName,
    /// This device has no relay key set.
    NoKey,
    /// The device cannot be reached (`offline` or `unknown id`).
    Offline,
    /// The other device does not know the request (an older version).
    Old,
    /// The other device's own error text: `not shared`, `not allowed`, `refused`, `limit`, ...
    Refused(String),
    /// Anything else that went wrong on the way.
    Other(String),
}

impl PipeErr {
    pub fn as_str(&self) -> &str {
        match self {
            PipeErr::Old => "old version",
            PipeErr::UnknownName => "unknown name",
            PipeErr::NoKey => "no key",
            PipeErr::Offline => "offline",
            PipeErr::Refused(s) | PipeErr::Other(s) => s,
        }
    }
}

/// One entry of `local/hosts.json` (the hub's `hosts::Host`, without what is not needed here).
#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct KnownHost {
    pub id: String,
    pub name: String,
    /// LAN addresses already known; may be empty.
    #[serde(default)]
    pub lan: Vec<String>,
    /// The fingerprint of the device's key, once seen.
    #[serde(default)]
    pub fp: Option<Fp>,
}

/// Every entry of `<home>/hosts.json`; empty when the file is missing or unreadable.
pub fn known_hosts(home: &Path) -> Vec<KnownHost> {
    rapp_net::config::read_json(&home.join("hosts.json")).ok().flatten().unwrap_or_default()
}

/// Opens a forward to `port` of the device `name` means. The pipe carries the port's bytes;
/// the second value is the path it goes by (`lan`, `direct` or `relay`).
pub async fn open(state: &State, name: &str, port: u16) -> Result<(Pipe, &'static str), PipeErr> {
    let (pipe, reply, path, _) = ask(state, name, &Op::Forward { port }).await?;
    answer(&reply)?;
    Ok((pipe, path))
}

/// The shares the device `name` means offers this one: the `shares` array of its reply.
pub async fn shares_of(state: &State, name: &str) -> Result<Value, PipeErr> {
    let (_, reply, _, _) = ask(state, name, &Op::ListShares).await?;
    answer(&reply)?;
    Ok(reply["shares"].clone())
}

/// Sends a share-table request (`Shares`, `Share`, `Unshare`) to the device `name` means: its
/// reply and its fingerprint. A device that does not know the request is `Old`.
pub async fn set(state: &State, name: &str, op: &Op) -> Result<(Value, Fp), PipeErr> {
    let (_, reply, _, fp) = ask(state, name, op).await?;
    if reply["ok"] != true {
        return Err(reply_err(&reply));
    }
    Ok((reply, fp))
}

/// The error of a refused reply: `Old` when the other device does not know the request.
fn reply_err(reply: &Value) -> PipeErr {
    match reply["error"].as_str().unwrap_or("bad reply") {
        "unknown op" | "bad request" => PipeErr::Old,
        e => PipeErr::Refused(e.to_string()),
    }
}

/// Sends `op` to the device `name` means, with the relay and key as configured now.
async fn ask(state: &State, name: &str, op: &Op) -> Result<(Pipe, Value, &'static str, Fp), PipeErr> {
    let id = target_id(name).ok_or(PipeErr::UnknownName)?;
    let (relay, key) = {
        let cfg = state.cfg.lock().unwrap();
        (cfg.relay.clone(), cfg.key.clone())
    };
    let key: Key = key.and_then(|k| k.parse().ok()).ok_or(PipeErr::NoKey)?;
    let known = known_hosts(&state.home).into_iter().find(|h| h.id == id);
    let (lan, fp) = known.map(|h| (h.lan, h.fp)).unwrap_or_default();
    let to = Target { id: &id, lan: &lan, known: fp };
    let via = Via { relay: relay.as_deref(), key: &key };
    match state.outbound.request(&via, &to, op).await {
        Ok(sent) => Ok((sent.pipe, sent.reply, sent.path, sent.fp)),
        Err(e) if e.downcast_ref::<NotReached>().is_some() => Err(PipeErr::Offline),
        Err(e) => Err(PipeErr::Other(e.to_string())),
    }
}

/// The other device's `{"ok":false,"error":..}` as `Refused`.
fn answer(reply: &Value) -> Result<(), PipeErr> {
    if reply["ok"] == true {
        return Ok(());
    }
    Err(PipeErr::Refused(reply["error"].as_str().unwrap_or("bad reply").to_string()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn target_spellings() {
        for ok in ["123456789", "123456789.rapp", "123456789.RAPP", "a.b.123456789.rapp", "123456789.rapp.", " 123456789.rapp "] {
            assert_eq!(target_id(ok).as_deref(), Some("123456789"), "{ok}");
        }
        for bad in ["", "rapp", ".rapp", "gpu1", "gpu1.rapp", "12345678.rapp", "1234567890.rapp", "123456789.com", "123456789.rapp.com"] {
            assert_eq!(target_id(bad), None, "{bad}");
        }
    }

    #[test]
    fn an_old_device_is_old() {
        for e in ["unknown op", "bad request"] {
            assert_eq!(reply_err(&serde_json::json!({"ok":false,"error":e})), PipeErr::Old, "{e}");
        }
        assert_eq!(reply_err(&serde_json::json!({"ok":false,"error":"policy"})), PipeErr::Refused("policy".into()));
        assert_eq!(PipeErr::Old.as_str(), "old version");
    }

    #[test]
    fn error_texts() {
        assert_eq!(PipeErr::UnknownName.as_str(), "unknown name");
        assert_eq!(PipeErr::NoKey.as_str(), "no key");
        assert_eq!(PipeErr::Offline.as_str(), "offline");
        assert_eq!(PipeErr::Refused("not shared".into()).as_str(), "not shared");
    }

    #[test]
    fn known_hosts_reads_every_entry() {
        let dir = tempfile::tempdir().unwrap();
        let fp = rapp_wire::Identity::generate().unwrap().fp;
        let file = serde_json::json!([
            {"id": "111111111", "name": "a", "password": "", "lan": ["10.0.0.2:22025"], "fp": fp.to_string()},
            {"id": "222222222", "name": "b"},
        ]);
        std::fs::write(dir.path().join("hosts.json"), file.to_string()).unwrap();
        let hosts = known_hosts(dir.path());
        assert_eq!(hosts.len(), 2);
        assert_eq!((hosts[0].id.as_str(), hosts[0].name.as_str()), ("111111111", "a"));
        assert_eq!((hosts[0].lan.clone(), hosts[0].fp), (vec!["10.0.0.2:22025".to_string()], Some(fp)));
        assert_eq!((hosts[1].id.as_str(), hosts[1].lan.is_empty(), hosts[1].fp), ("222222222", true, None));
    }

    #[test]
    fn known_hosts_is_empty_when_the_file_is_missing_or_unreadable() {
        let dir = tempfile::tempdir().unwrap();
        assert!(known_hosts(dir.path()).is_empty());
        std::fs::write(dir.path().join("hosts.json"), "{ not json").unwrap();
        assert!(known_hosts(dir.path()).is_empty());
        std::fs::write(dir.path().join("hosts.json"), r#"{"id":"1"}"#).unwrap();
        assert!(known_hosts(dir.path()).is_empty());
    }
}
