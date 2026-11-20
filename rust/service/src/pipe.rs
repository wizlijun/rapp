//! The visiting side of port sharing: which device a name means, and asking that device for a
//! port (`open`) or for the shares it offers this one (`shares_of`), through `Outbound`; the
//! asking itself is `rapp_ports`, shared with the embedded hub.

use rapp_conn::Pipe;
use rapp_net::msg::Op;
use rapp_wire::{Fp, Key};
use serde_json::Value;

use crate::state::State;

pub use rapp_ports::{known_hosts, known_ids, PipeErr};
use rapp_ports::reply_err;

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

/// Sends `op` to the device `name` means, with the relay and key as configured now.
async fn ask(state: &State, name: &str, op: &Op) -> Result<(Pipe, Value, &'static str, Fp), PipeErr> {
    let id = target_id(name).ok_or(PipeErr::UnknownName)?;
    let (relay, key) = {
        let cfg = state.cfg.lock().unwrap();
        (cfg.relay.clone(), cfg.key.clone())
    };
    let key: Option<Key> = key.and_then(|k| k.parse().ok());
    let way = rapp_ports::Way { out: &state.outbound, home: &state.home, relay: relay.as_deref(), key: key.as_ref() };
    rapp_ports::request(&way, &id, op).await
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
    fn known_ids_tells_no_list_from_an_empty_one() {
        let dir = tempfile::tempdir().unwrap();
        assert_eq!(known_ids(dir.path()), None);
        std::fs::write(dir.path().join("hosts.json"), "{ not json").unwrap();
        assert_eq!(known_ids(dir.path()), None);
        std::fs::write(dir.path().join("hosts.json"), "[]").unwrap();
        assert_eq!(known_ids(dir.path()), Some(vec![]));
        std::fs::write(dir.path().join("hosts.json"), r#"[{"id":"111111111","name":"a"}]"#).unwrap();
        assert_eq!(known_ids(dir.path()), Some(vec!["111111111".to_string()]));
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
