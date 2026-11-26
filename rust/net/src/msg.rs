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
    /// Read this device's logs (log screen spec §3); answered from `State::log_dir`.
    Logs(crate::logq::LogQuery),
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
    /// A new text terminal: a window on this device that runs `rapp-term run`, started with `app`; `shell` is one
    /// of the device's listed shells (none: its default).
    OpenTerm {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        shell: Option<String>,
        /// A terminal session id: the new one opens beside it (same directory).
        #[serde(default, skip_serializing_if = "Option::is_none")]
        from: Option<String>,
        app: String,
        /// A terminal session id that is gone: its label (title and note) moves to the new terminal.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        label_from: Option<String>,
    },
    /// End terminal session `term`.
    EndTerm { term: String },
    /// Restore saved terminals (those of `keys`; none given: all of them), opened with `app`.
    RestoreTerms {
        #[serde(default)]
        keys: Vec<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        app: Option<String>,
    },
    /// Forget saved terminals (those of `keys`; none given: all of them).
    ForgetTerms {
        #[serde(default)]
        keys: Vec<String>,
    },
    /// Give terminal session `term` the name `name`.
    RenameTerm { term: String, name: String },
    /// The device's session labels now and whenever they change (the whole table each time), until the stream closes.
    WatchLabels,
    /// Label session `app` (a bundle id or a terminal id) with `title` and `note`; both empty clears it.
    SetLabel { app: String, title: String, note: String },
    /// Clear session `app`'s label; a missing one is not an error.
    ResetLabel { app: String },
    /// The ports this device shares with the caller.
    ListShares,
    /// Open a TCP forward to one of the ports this device shares with the caller.
    Forward { port: u16 },
    /// Turn this connection into a multiplexed channel carrying many streams.
    Mux,
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
        /// What the share speaks (`http`, `https`, `tcp`, `ssh`); a bad one is answered "bad proto".
        /// Left out of the wire when None, so an older device sees the request it knows.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        proto: Option<String>,
    },
    Unshare {
        #[serde(default)]
        port: Value,
    },
    /// This device's load (device-load spec §10), once: `history` adds the last hour, `top` the busiest processes.
    Load {
        #[serde(default, skip_serializing_if = "std::ops::Not::not")]
        history: bool,
        #[serde(default, skip_serializing_if = "std::ops::Not::not")]
        top: bool,
    },
    /// This device's load with its history, then one line per sample, until the stream closes.
    WatchLoad,
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
    fn logs_op_wire() {
        use crate::logq::LogQuery;
        assert_eq!(serde_json::to_value(Op::Logs(LogQuery::default())).unwrap(), json!({"op":"logs"}));
        let q = LogQuery { limit: Some(5), problems: true, ..Default::default() };
        let v = json!({"op":"logs","limit":5,"problems":true});
        assert_eq!(serde_json::to_value(Op::Logs(q.clone())).unwrap(), v);
        assert_eq!(serde_json::from_value::<Op>(v).unwrap(), Op::Logs(q));
    }

    #[test]
    fn mux_op() {
        assert_eq!(serde_json::to_value(Op::Mux).unwrap(), json!({"op":"mux"}));
        assert_eq!(serde_json::from_value::<Op>(json!({"op":"mux"})).unwrap(), Op::Mux);
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
            Op::Share { ports: json!([8000]), note: Some("jupyter".into()), allow: Value::Null, proto: None }
        );
        // A bad port still parses: sharing.rs answers "bad port", not peer.rs "unknown op".
        assert!(serde_json::from_value::<Op>(json!({"op":"share","ports":[70000]})).is_ok());
        assert!(serde_json::from_value::<Op>(json!({"op":"unshare","port":"x"})).is_ok());
        assert_eq!(
            serde_json::to_value(Op::Share { ports: json!([22]), note: None, allow: Value::Null, proto: None }).unwrap(),
            json!({"op":"share","ports":[22]})
        );
    }

    /// A share request without a protocol is the one an older device knows: `proto` is not written.
    #[test]
    fn share_proto_is_written_only_when_given() {
        let none = Op::Share { ports: json!([22]), note: None, allow: json!([]), proto: None };
        assert_eq!(serde_json::to_value(none).unwrap(), json!({"op":"share","ports":[22],"allow":[]}));
        let some = Op::Share { ports: json!([22]), note: None, allow: Value::Null, proto: Some("tcp".into()) };
        assert_eq!(serde_json::to_value(&some).unwrap(), json!({"op":"share","ports":[22],"proto":"tcp"}));
        assert_eq!(serde_json::from_value::<Op>(json!({"op":"share","ports":[22],"proto":"tcp"})).unwrap(), some);
    }

    #[test]
    fn terminal_requests() {
        assert_eq!(serde_json::to_value(Op::ListTerms).unwrap(), json!({"op":"list_terms"}));
        assert_eq!(serde_json::to_value(Op::WatchTerms).unwrap(), json!({"op":"watch_terms"}));
        let op = Op::OpenTerm { shell: None, from: None, app: "Terminal".into(), label_from: None };
        assert_eq!(serde_json::to_value(&op).unwrap(), json!({"op":"open_term","app":"Terminal"}));
        let op = Op::OpenTerm { shell: Some("zsh".into()), from: None, app: "iTerm".into(), label_from: None };
        assert_eq!(serde_json::to_value(&op).unwrap(), json!({"op":"open_term","shell":"zsh","app":"iTerm"}));
        assert_eq!(serde_json::from_value::<Op>(json!({"op":"open_term","shell":"zsh","app":"iTerm"})).unwrap(), op);
        // An old GUI's cwd, name and command are ignored.
        let old = json!({"op":"open_term","cwd":"/x","name":"n","command":"claude","app":"Terminal"});
        assert_eq!(serde_json::from_value::<Op>(old).unwrap(), Op::OpenTerm { shell: None, from: None, app: "Terminal".into(), label_from: None });
        let rename = Op::RenameTerm { term: "term:pty:k".into(), name: "n".into() };
        assert_eq!(serde_json::to_value(&rename).unwrap(), json!({"op":"rename_term","term":"term:pty:k","name":"n"}));
        assert_eq!(serde_json::from_value::<Op>(serde_json::to_value(&rename).unwrap()).unwrap(), rename);
    }

    #[test]
    fn load_requests() {
        assert_eq!(serde_json::to_value(Op::Load { history: false, top: false }).unwrap(), json!({"op":"load"}));
        assert_eq!(serde_json::to_value(Op::Load { history: true, top: false }).unwrap(), json!({"op":"load","history":true}));
        assert_eq!(serde_json::to_value(Op::Load { history: false, top: true }).unwrap(), json!({"op":"load","top":true}));
        assert_eq!(serde_json::from_value::<Op>(json!({"op":"load"})).unwrap(), Op::Load { history: false, top: false });
        assert_eq!(serde_json::to_value(Op::WatchLoad).unwrap(), json!({"op":"watch_load"}));
        assert_eq!(serde_json::from_value::<Op>(json!({"op":"watch_load"})).unwrap(), Op::WatchLoad);
    }

    #[test]
    fn label_ops_have_their_json_shape() {
        assert_eq!(serde_json::to_value(Op::WatchLabels).unwrap(), json!({"op":"watch_labels"}));
        let set = Op::SetLabel { app: "term:pty:k".into(), title: "后端".into(), note: "n".into() };
        assert_eq!(serde_json::to_value(&set).unwrap(), json!({"op":"set_label","app":"term:pty:k","title":"后端","note":"n"}));
        assert_eq!(serde_json::from_value::<Op>(serde_json::to_value(&set).unwrap()).unwrap(), set);
        let reset = Op::ResetLabel { app: "com.apple.Safari".into() };
        assert_eq!(serde_json::to_value(&reset).unwrap(), json!({"op":"reset_label","app":"com.apple.Safari"}));
        let op = Op::OpenTerm { shell: None, from: None, app: "Terminal".into(), label_from: Some("term:pty:old".into()) };
        assert_eq!(serde_json::to_value(&op).unwrap(), json!({"op":"open_term","app":"Terminal","label_from":"term:pty:old"}));
        assert_eq!(serde_json::from_value::<Op>(serde_json::to_value(&op).unwrap()).unwrap(), op);
    }

    #[test]
    fn end_term_roundtrip() {
        let op = Op::EndTerm { term: "term:pty:k".into() };
        assert_eq!(serde_json::to_value(&op).unwrap(), json!({"op":"end_term","term":"term:pty:k"}));
        assert_eq!(serde_json::from_value::<Op>(json!({"op":"end_term","term":"term:pty:k"})).unwrap(), op);
    }

    #[test]
    fn restore_and_forget_terms_roundtrip() {
        let v = json!({"op":"restore_terms","keys":["k"],"app":"Terminal"});
        let op = Op::RestoreTerms { keys: vec!["k".into()], app: Some("Terminal".into()) };
        assert_eq!(serde_json::to_value(&op).unwrap(), v);
        assert_eq!(serde_json::from_value::<Op>(v).unwrap(), op);
        let bare = serde_json::from_value::<Op>(json!({"op":"restore_terms"})).unwrap();
        assert_eq!(bare, Op::RestoreTerms { keys: vec![], app: None });
        assert_eq!(serde_json::to_value(&bare).unwrap(), json!({"op":"restore_terms","keys":[]}));
        let f = json!({"op":"forget_terms","keys":["a","b"]});
        let op = Op::ForgetTerms { keys: vec!["a".into(), "b".into()] };
        assert_eq!(serde_json::to_value(&op).unwrap(), f);
        assert_eq!(serde_json::from_value::<Op>(f).unwrap(), op);
        assert_eq!(serde_json::from_value::<Op>(json!({"op":"forget_terms"})).unwrap(), Op::ForgetTerms { keys: vec![] });
        // `saved` is local to serve and no Op.
        assert!(serde_json::from_value::<Op>(json!({"op":"saved"})).is_err());
    }

    #[test]
    fn open_term_from_is_optional() {
        let old = json!({"op":"open_term","app":"Terminal"});
        assert_eq!(serde_json::from_value::<Op>(old).unwrap(), Op::OpenTerm { shell: None, from: None, app: "Terminal".into(), label_from: None });
        let op = Op::OpenTerm { shell: None, from: Some("term:pty:k".into()), app: "Terminal".into(), label_from: None };
        assert_eq!(serde_json::to_value(&op).unwrap(), json!({"op":"open_term","from":"term:pty:k","app":"Terminal"}));
        assert_eq!(serde_json::from_value::<Op>(serde_json::to_value(&op).unwrap()).unwrap(), op);
    }

    #[test]
    fn the_tmux_and_target_ops_are_gone() {
        for op in [
            json!({"op":"new_term","command":["claude"],"cols":120,"rows":40}),
            json!({"op":"add_term_target","name":"gpu1","target":"me@gpu1"}),
            json!({"op":"remove_term_target","name":"gpu1"}),
        ] {
            assert!(serde_json::from_value::<Op>(op.clone()).is_err(), "{op}");
        }
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
