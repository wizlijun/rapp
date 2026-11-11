//! Request lines shared by relay, service and hub (spec §2.2, §2.3).
//! Replies are plain `serde_json::Value`s built with `line::ok` / `line::err`.

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "op", rename_all = "snake_case")]
pub enum Op {
    // B or A → relay
    Register {
        key: String,
        id: Option<String>,
        secret: String,
        name: String,
        pw_salt: String,
        pw_hash: String,
        lan: Vec<String>,
    },
    Connect {
        key: String,
        id: String,
        password: String,
        /// Self-declared device name ("自称", observability spec §4); never trusted.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        name: Option<String>,
    },
    Relay {
        key: String,
        token: String,
    },
    // relay → A
    Incoming {
        token: String,
        peer: String,
        /// Self-declared device name ("自称", observability spec §4); never trusted.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        name: Option<String>,
    },
    Relayed {
        token: String,
    },
    // B → A
    Auth {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        token: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        password: Option<String>,
        /// Self-declared device name ("自称", observability spec §4); never trusted.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        name: Option<String>,
    },
    ListApps,
    Open {
        app: String,
        /// A file-transfer side connection, not a viewing session (kept out of 访问记录).
        #[serde(default, skip_serializing_if = "std::ops::Not::not")]
        side: bool,
    },
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn wire_format() {
        let v = serde_json::to_value(Op::Auth { token: Some("t".into()), password: None, name: None }).unwrap();
        assert_eq!(v, json!({"op":"auth","token":"t"}));
        assert_eq!(serde_json::to_value(Op::ListApps).unwrap(), json!({"op":"list_apps"}));
        let op: Op = serde_json::from_value(json!({"op":"register","key":"k","id":null,"secret":"s",
            "name":"n","pw_salt":"a","pw_hash":"b","lan":["1.2.3.4:1"]}))
        .unwrap();
        assert!(matches!(op, Op::Register { id: None, .. }));
        let op: Op = serde_json::from_value(json!({"op":"auth","password":"p"})).unwrap();
        assert_eq!(op, Op::Auth { token: None, password: Some("p".into()), name: None });
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
        let op: Op = serde_json::from_value(json!({"op":"connect","key":"k","id":"1","password":"p"})).unwrap();
        assert!(matches!(op, Op::Connect { name: None, .. }));
        let incoming = Op::Incoming { token: "t".into(), peer: "1.2.3.4:5".into(), name: Some("mbp".into()) };
        let v = serde_json::to_value(incoming).unwrap();
        assert_eq!(v, json!({"op":"incoming","token":"t","peer":"1.2.3.4:5","name":"mbp"}));
        let auth = Op::Auth { token: None, password: Some("p".into()), name: Some("mbp".into()) };
        assert_eq!(serde_json::to_value(auth).unwrap(), json!({"op":"auth","password":"p","name":"mbp"}));
    }
}
