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
    },
    Relay {
        key: String,
        token: String,
    },
    // relay → A
    Incoming {
        token: String,
        peer: String,
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
    },
    ListApps,
    Open {
        app: String,
    },
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn wire_format() {
        let v = serde_json::to_value(Op::Auth { token: Some("t".into()), password: None }).unwrap();
        assert_eq!(v, json!({"op":"auth","token":"t"}));
        assert_eq!(serde_json::to_value(Op::ListApps).unwrap(), json!({"op":"list_apps"}));
        let op: Op = serde_json::from_value(json!({"op":"register","key":"k","id":null,"secret":"s",
            "name":"n","pw_salt":"a","pw_hash":"b","lan":["1.2.3.4:1"]}))
        .unwrap();
        assert!(matches!(op, Op::Register { id: None, .. }));
        let op: Op = serde_json::from_value(json!({"op":"auth","password":"p"})).unwrap();
        assert_eq!(op, Op::Auth { token: None, password: Some("p".into()) });
    }
}
