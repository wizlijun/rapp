//! Request lines shared by service and hub (spec §2.2, §2.3).
//! Replies are plain `serde_json::Value`s built with `line::ok` / `line::err`.

use serde::{Deserialize, Serialize};

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
