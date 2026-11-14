//! Relay request and push messages: one JSON line each.
//!
//! Every reply is `{"ok":true,…}` or `{"ok":false,"error":…}` (see `line::ok`/`line::err`).
//! The whole set of error texts: `bad request`, `bad key`, `no key`, `closed`, `limit`,
//! `not enrolled`, `bad id`, `id taken`, `unknown id`, `offline`, `locked, retry in <N>s`, `redirect`,
//! `key changed`.
//! Connection close codes: `0` normal, `2` revoked, `3` connection limit reached (or another failed
//! enroll), `4` key changed (the relay's key changed; the device needs the new one), `5` bad key.
//! A client stops on `4` and `5` until its key changes.

use serde::{Deserialize, Serialize};

use crate::Fp;

/// Device → relay, one bidirectional stream per request.
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(tag = "op", rename_all = "snake_case", deny_unknown_fields)]
pub enum Req {
    /// `join`: the enrollment secret, 64 hex digits.
    Enroll {
        join: String,
    },
    Register {
        id: String,
        lan: Vec<String>,
    },
    Connect {
        id: String,
    },
    Relay {
        id: String,
    },
}

/// Relay → device. `peer` is the other side's `ip:port` as the relay sees it.
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(tag = "op", rename_all = "snake_case")]
pub enum Push {
    /// Bidirectional stream; the device answers `{"ok":true}`.
    Incoming { peer: String, fp: Fp },
    /// Bidirectional stream; the peer's bytes follow this line.
    Relayed { peer: String, fp: Fp },
    /// Unidirectional stream.
    Revoked { fps: Vec<Fp> },
    /// Unidirectional stream.
    GoingAway { after_ms: u64 },
}

/// At most this many `lan` entries in `register`, each at most `MAX_LAN_LEN` bytes.
pub const MAX_LAN: usize = 16;
pub const MAX_LAN_LEN: usize = 64;

/// Nine digits, the first not `0`.
pub fn is_valid_id(id: &str) -> bool {
    id.len() == 9 && id.bytes().all(|b| b.is_ascii_digit()) && !id.starts_with('0')
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::Identity;
    use serde_json::json;

    #[test]
    fn wire_format_is_pinned() {
        assert_eq!(
            serde_json::to_value(Req::Connect { id: "123456789".into() }).unwrap(),
            json!({"op":"connect","id":"123456789"})
        );
        assert!(serde_json::from_value::<Req>(json!({"op":"connect","id":"1","key":"x"})).is_err()); // extra field refused
        assert!(serde_json::from_value::<Req>(json!({"op":"open","app":"x"})).is_err());
        assert!(is_valid_id("123456789") && !is_valid_id("012345678") && !is_valid_id("12345678"));
    }

    #[test]
    fn push_wire_format() {
        let fp = Identity::generate().unwrap().fp;
        let p = Push::Relayed { peer: "1.2.3.4:5".into(), fp };
        let v = serde_json::to_value(&p).unwrap();
        assert_eq!(v, json!({"op":"relayed","peer":"1.2.3.4:5","fp":fp.to_string()}));
        assert_eq!(serde_json::from_value::<Push>(v).unwrap(), p);
        assert_eq!(
            serde_json::to_value(Push::GoingAway { after_ms: 5 }).unwrap(),
            json!({"op":"going_away","after_ms":5})
        );
        assert_eq!(
            serde_json::to_value(Req::Register { id: "123456789".into(), lan: vec![] }).unwrap(),
            json!({"op":"register","id":"123456789","lan":[]})
        );
    }

    #[test]
    fn id_rules() {
        assert!(is_valid_id("900000000"));
        assert!(!is_valid_id("1234567890"));
        assert!(!is_valid_id("12345678a"));
        assert!(!is_valid_id("１２３４５６７８９"));
        assert!(!is_valid_id(""));
    }
}
