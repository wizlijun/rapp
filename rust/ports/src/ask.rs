//! Asking another device, the same from the service and the embedded hub: for its shares
//! (`shares_of`) and for a forward to one of its ports (`open`), through an `Outbound`.

use std::path::Path;

use rapp_conn::dial::{NotReached, Outbound, Target, Via};
use rapp_conn::Pipe;
use rapp_net::msg::Op;
use rapp_wire::{Fp, Key};
use serde::Deserialize;
use serde_json::Value;

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

/// The IDs of the devices in `<home>/hosts.json`; None when the file is missing or unreadable
/// (which is not the same as a list with no device in it).
pub fn known_ids(home: &Path) -> Option<Vec<String>> {
    let hosts: Option<Vec<KnownHost>> = rapp_net::config::read_json(&home.join("hosts.json")).ok().flatten();
    hosts.map(|hosts| hosts.into_iter().map(|h| h.id).collect())
}

/// The road to other devices: the `Outbound` that dials them, the home whose `hosts.json` knows
/// their LAN addresses and keys, and the relay and key as set now.
pub struct Way<'a> {
    pub out: &'a Outbound,
    pub home: &'a Path,
    pub relay: Option<&'a str>,
    /// None: no key is set, and nothing is dialed.
    pub key: Option<&'a Key>,
}

/// Sends `op` to the device `id`: the pipe, the reply, the path it went by (`lan`, `direct` or
/// `relay`) and the device's fingerprint.
pub async fn request(way: &Way<'_>, id: &str, op: &Op) -> Result<(Pipe, Value, &'static str, Fp), PipeErr> {
    let key = way.key.ok_or(PipeErr::NoKey)?;
    let known = known_hosts(way.home).into_iter().find(|h| h.id == id);
    let (lan, fp) = known.map(|h| (h.lan, h.fp)).unwrap_or_default();
    let to = Target { id, lan: &lan, known: fp };
    let via = Via { relay: way.relay, key };
    match way.out.request(&via, &to, op).await {
        Ok(sent) => Ok((sent.pipe, sent.reply, sent.path, sent.fp)),
        Err(e) if e.downcast_ref::<NotReached>().is_some() => Err(PipeErr::Offline),
        Err(e) => Err(PipeErr::Other(e.to_string())),
    }
}

/// Opens a forward to `port` of the device `id`. The pipe carries the port's bytes; the second
/// value is the path it goes by.
pub async fn open(way: &Way<'_>, id: &str, port: u16) -> Result<(Pipe, &'static str), PipeErr> {
    let (pipe, reply, path, _) = request(way, id, &Op::Forward { port }).await?;
    answer(&reply)?;
    Ok((pipe, path))
}

/// The shares the device `id` offers this one: the `shares` array of its reply.
pub async fn shares_of(way: &Way<'_>, id: &str) -> Result<Value, PipeErr> {
    let (_, reply, _, _) = request(way, id, &Op::ListShares).await?;
    answer(&reply)?;
    Ok(reply["shares"].clone())
}

/// The error of a refused reply: `Old` when the other device does not know the request.
pub fn reply_err(reply: &Value) -> PipeErr {
    match reply["error"].as_str().unwrap_or("bad reply") {
        "unknown op" | "bad request" => PipeErr::Old,
        e => PipeErr::Refused(e.to_string()),
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

    #[tokio::test]
    async fn no_key_is_no_key_without_dialing() {
        let dir = tempfile::tempdir().unwrap();
        let identity = std::sync::Arc::new(rapp_wire::Identity::load_or_create(dir.path(), "device").unwrap());
        let ep = rapp_net::quic::client_endpoint(([127, 0, 0, 1], 0).into()).unwrap();
        let out = Outbound::new(ep, identity, "t".into());
        let way = Way { out: &out, home: dir.path(), relay: None, key: None };
        let got = request(&way, "123456789", &Op::ListShares).await.map(|_| ());
        assert_eq!(got.err(), Some(PipeErr::NoKey));
    }
}
