//! One line of the event stream: parsing and validation. The format is written down in `api/events.md`.

use serde_json::{Map, Value};

pub const TEXT_CHARS: usize = 500;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    State,
    Gone,
    Snap,
    Emit,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Event {
    /// `via` when given, else `fp`.
    pub sender: String,
    pub epoch: String,
    pub n: u64,
    pub at: u64,
    pub t: Kind,
    /// The whole line except `v`; unknown fields are kept as they came.
    pub body: Map<String, Value>,
}

impl Event {
    pub fn eid(&self) -> String {
        format!("{}:{}:{}", self.sender, self.epoch, self.n)
    }

    /// The reported device.
    pub fn fp(&self) -> &str {
        self.body.get("fp").and_then(Value::as_str).unwrap_or("")
    }
}

fn cut(v: &mut Value) {
    if let Some(s) = v.as_str() {
        if s.chars().count() > TEXT_CHARS {
            *v = Value::String(s.chars().take(TEXT_CHARS).collect());
        }
    }
}

fn cut_texts(m: &mut Map<String, Value>) {
    for k in ["msg", "text"] {
        if let Some(v) = m.get_mut(k) {
            cut(v);
        }
    }
}

pub fn parse_line(line: &str) -> Result<Event, String> {
    let v: Value = serde_json::from_str(line).map_err(|_| "not JSON".to_string())?;
    let Value::Object(mut body) = v else { return Err("not an object".into()) };
    if body.get("v").and_then(Value::as_u64) != Some(1) {
        return Err("bad v".into());
    }
    body.remove("v");
    let text = |k: &str| match body.get(k) {
        Some(Value::String(s)) if !s.is_empty() => Ok(s.clone()),
        _ => Err(format!("missing {k}")),
    };
    let fp = text("fp")?;
    let epoch = text("epoch")?;
    let n = body.get("n").and_then(Value::as_u64).filter(|n| *n >= 1).ok_or("bad n")?;
    let at = body.get("at").and_then(Value::as_u64).ok_or("bad at")?;
    let t = match body.get("t").and_then(Value::as_str) {
        Some("state") => Kind::State,
        Some("gone") => Kind::Gone,
        Some("snap") => Kind::Snap,
        Some("emit") => Kind::Emit,
        Some(_) => return Err("unknown t".into()),
        None => return Err("missing t".into()),
    };
    let sender = match body.get("via") {
        None | Some(Value::Null) => fp,
        Some(Value::String(s)) if !s.is_empty() => s.clone(),
        _ => return Err("bad via".into()),
    };
    if matches!(t, Kind::State | Kind::Gone) && !matches!(body.get("session"), Some(Value::String(s)) if !s.is_empty()) {
        return Err("missing session".into());
    }
    if t == Kind::Snap {
        match body.get_mut("sessions") {
            Some(Value::Array(items)) => {
                for it in items {
                    if let Value::Object(m) = it {
                        cut_texts(m);
                    }
                }
            }
            _ => return Err("missing sessions".into()),
        }
    }
    cut_texts(&mut body);
    Ok(Event { sender, epoch, n, at, t, body })
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn line(patch: Value) -> String {
        let mut v = json!({"v":1,"fp":"aa","epoch":"e","n":1,"at":10,"t":"state","session":"s","state":"idle","x-new":7});
        for (k, val) in patch.as_object().unwrap() {
            if val.is_null() {
                v.as_object_mut().unwrap().remove(k);
            } else {
                v[k] = val.clone();
            }
        }
        v.to_string()
    }

    #[test]
    fn a_line_needs_its_envelope() {
        let ev = parse_line(&line(json!({}))).unwrap();
        assert_eq!(ev.body["x-new"], 7);
        assert_eq!(ev.eid(), "aa:e:1");
        for k in ["fp", "epoch", "n", "t", "session", "v", "at"] {
            assert!(parse_line(&line(json!({ k: null }))).is_err(), "{k}");
        }
        assert!(parse_line(&line(json!({"v":2}))).is_err());
        assert!(parse_line(&line(json!({"t":"what"}))).is_err());
        assert!(parse_line(&line(json!({"n":0}))).is_err());
        assert!(parse_line("nope").is_err());
        assert!(parse_line(&line(json!({"t":"gone","session":null}))).is_err());
        assert!(parse_line(&line(json!({"t":"snap"}))).is_err());
    }

    #[test]
    fn the_sender_is_via_when_given() {
        assert_eq!(parse_line(&line(json!({}))).unwrap().sender, "aa");
        let ev = parse_line(&line(json!({"via":"bb"}))).unwrap();
        assert_eq!((ev.sender.as_str(), ev.fp()), ("bb", "aa"));
        assert_eq!(ev.eid(), "bb:e:1");
    }

    #[test]
    fn long_text_is_cut_by_chars() {
        let s = "字".repeat(600);
        let ev = parse_line(&line(json!({"msg": s}))).unwrap();
        assert_eq!(ev.body["msg"].as_str().unwrap().chars().count(), 500);
    }
}
