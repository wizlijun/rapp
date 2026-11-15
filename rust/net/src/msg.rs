//! Request lines shared by service and hub (spec §2.2, §2.3).
//! Replies are plain `serde_json::Value`s built with `line::ok` / `line::err`.

use serde::{Deserialize, Serialize};
use serde_json::Value;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "op", rename_all = "snake_case")]
pub enum Op {
    // B → A
    Auth {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        password: Option<String>,
        /// Self-declared device name ("自称", observability spec §4); never trusted.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        name: Option<String>,
    },
    ListApps,
    /// Presence probe: answered ok, never logged, starts nothing.
    Ping,
    Open {
        app: String,
        /// A file-transfer side connection, not a viewing session (kept out of 访问记录).
        #[serde(default, skip_serializing_if = "std::ops::Not::not")]
        side: bool,
    },
    /// The device's terminal sessions, once.
    ListTerms,
    /// The device's terminal sessions now and whenever they change, until the stream closes.
    WatchTerms,
    NewTerm {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        host: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        name: Option<String>,
        command: Vec<String>,
        cols: u16,
        rows: u16,
    },
    /// A new text terminal: a window on this device that runs `rapp-term run`, started with `app`.
    OpenTerm {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        cwd: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        name: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        command: Option<String>,
        app: String,
    },
    AddTermTarget {
        name: String,
        target: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        tmux: Option<String>,
    },
    RemoveTermTarget {
        name: String,
    },
    /// The ports this device shares with the caller.
    ListShares,
    /// Open a TCP forward to one of the ports this device shares with the caller.
    Forward { port: u16 },
    /// This device's whole share table (for a device that is allowed to set it).
    Shares,
    /// Share `ports`. `ports` and `allow` stay raw JSON: a bad one is answered "bad port" by sharing.rs, not "unknown op".
    Share {
        #[serde(default)]
        ports: Value,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        note: Option<String>,
        #[serde(default, skip_serializing_if = "Value::is_null")]
        allow: Value,
    },
    Unshare {
        #[serde(default)]
        port: Value,
    },
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn wire_format() {
        let v = serde_json::to_value(Op::Auth { password: None, name: None }).unwrap();
        assert_eq!(v, json!({"op":"auth"}));
        assert_eq!(serde_json::to_value(Op::ListApps).unwrap(), json!({"op":"list_apps"}));
        assert_eq!(serde_json::to_value(Op::Ping).unwrap(), json!({"op":"ping"}));
        let op: Op = serde_json::from_value(json!({"op":"auth","password":"p"})).unwrap();
        assert_eq!(op, Op::Auth { password: Some("p".into()), name: None });
    }

    #[test]
    fn share_requests() {
        assert_eq!(serde_json::to_value(Op::ListShares).unwrap(), json!({"op":"list_shares"}));
        assert_eq!(serde_json::to_value(Op::Forward { port: 8000 }).unwrap(), json!({"op":"forward","port":8000}));
        assert_eq!(serde_json::from_value::<Op>(json!({"op":"forward","port":22})).unwrap(), Op::Forward { port: 22 });
        assert!(serde_json::from_value::<Op>(json!({"op":"forward","port":70000})).is_err());
        assert!(serde_json::from_value::<Op>(json!({"op":"forward"})).is_err());
        assert_eq!(serde_json::to_value(Op::Shares).unwrap(), json!({"op":"shares"}));
        assert_eq!(
            serde_json::from_value::<Op>(json!({"op":"share","ports":[8000],"note":"jupyter"})).unwrap(),
            Op::Share { ports: json!([8000]), note: Some("jupyter".into()), allow: Value::Null }
        );
        // A bad port still parses: sharing.rs answers "bad port", not peer.rs "unknown op".
        assert!(serde_json::from_value::<Op>(json!({"op":"share","ports":[70000]})).is_ok());
        assert!(serde_json::from_value::<Op>(json!({"op":"unshare","port":"x"})).is_ok());
        assert_eq!(
            serde_json::to_value(Op::Share { ports: json!([22]), note: None, allow: Value::Null }).unwrap(),
            json!({"op":"share","ports":[22]})
        );
    }

    #[test]
    fn terminal_requests() {
        assert_eq!(serde_json::to_value(Op::ListTerms).unwrap(), json!({"op":"list_terms"}));
        assert_eq!(serde_json::to_value(Op::WatchTerms).unwrap(), json!({"op":"watch_terms"}));
        let new = Op::NewTerm { host: None, name: None, command: vec!["claude".into()], cols: 120, rows: 40 };
        assert_eq!(
            serde_json::to_value(new).unwrap(),
            json!({"op":"new_term","command":["claude"],"cols":120,"rows":40})
        );
        let op = Op::OpenTerm { cwd: None, name: None, command: Some("claude".into()), app: "Terminal".into() };
        assert_eq!(serde_json::to_value(&op).unwrap(), json!({"op":"open_term","command":"claude","app":"Terminal"}));
        let new = Op::NewTerm { host: Some("gpu1".into()), name: Some("x".into()), command: vec![], cols: 1, rows: 2 };
        let v = serde_json::to_value(&new).unwrap();
        assert_eq!(v["host"], "gpu1");
        assert_eq!(serde_json::from_value::<Op>(v).unwrap(), new);
        assert_eq!(
            serde_json::from_value::<Op>(json!({"op":"add_term_target","name":"gpu1","target":"me@gpu1"})).unwrap(),
            Op::AddTermTarget { name: "gpu1".into(), target: "me@gpu1".into(), tmux: None }
        );
        let add = Op::AddTermTarget { name: "g".into(), target: "t".into(), tmux: Some("/x/tmux".into()) };
        assert_eq!(
            serde_json::to_value(add).unwrap(),
            json!({"op":"add_term_target","name":"g","target":"t","tmux":"/x/tmux"})
        );
        assert_eq!(
            serde_json::to_value(Op::RemoveTermTarget { name: "gpu1".into() }).unwrap(),
            json!({"op":"remove_term_target","name":"gpu1"})
        );
    }

    #[test]
    fn old_token_field_is_ignored() {
        let op: Op = serde_json::from_value(json!({"op":"auth","token":"t"})).unwrap();
        assert_eq!(op, Op::Auth { password: None, name: None });
    }

    #[test]
    fn name_and_side_are_optional_on_the_wire() {
        // Old peers omit them; new peers only send them when set.
        let op: Op = serde_json::from_value(json!({"op":"open","app":"Calculator"})).unwrap();
        assert_eq!(op, Op::Open { app: "Calculator".into(), side: false });
        let v = serde_json::to_value(Op::Open { app: "Calculator".into(), side: false }).unwrap();
        assert_eq!(v, json!({"op":"open","app":"Calculator"}));
        let v = serde_json::to_value(Op::Open { app: "Calculator".into(), side: true }).unwrap();
        assert_eq!(v, json!({"op":"open","app":"Calculator","side":true}));
        let auth = Op::Auth { password: Some("p".into()), name: Some("mbp".into()) };
        assert_eq!(serde_json::to_value(auth).unwrap(), json!({"op":"auth","password":"p","name":"mbp"}));
    }
}
