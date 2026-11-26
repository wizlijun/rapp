use serde_json::{json, Map, Value};
use std::collections::HashMap;

const MSG_MAX: usize = 500;

/// What one live session says now; `key` is what makes a change news.
#[derive(Clone)]
struct Row {
    key: (String, u64),
    body: Map<String, Value>,
}

/// Compares the terminal worker's session lists, one after the other.
#[derive(Default)]
pub struct Diff {
    seen: Option<HashMap<String, Row>>,
}

fn put(m: &mut Map<String, Value>, k: &str, v: Option<&Value>) {
    if let Some(v) = v.filter(|v| !v.is_null()) {
        m.insert(k.into(), v.clone());
    }
}

fn rows(list: &Value) -> Vec<(String, Row)> {
    let mut out = vec![];
    for r in list["terms"].as_array().into_iter().flatten() {
        if r["dead"].as_bool().unwrap_or(false) {
            continue;
        }
        let (Some(id), Some(ps)) = (r["id"].as_str(), r["ps"].as_object()) else { continue };
        let Some(state) = ps.get("state").and_then(Value::as_str) else { continue };
        let seq = ps.get("seq").and_then(Value::as_u64).unwrap_or(0);
        let since = ps.get("since").and_then(Value::as_u64).unwrap_or(0);
        let mut b = Map::new();
        b.insert("session".into(), json!(id));
        b.insert("name".into(), r.get("name").cloned().unwrap_or_else(|| json!("")));
        put(&mut b, "title", r.get("title"));
        put(&mut b, "fg", r.get("fg"));
        put(&mut b, "host", r.get("host"));
        b.insert("state".into(), json!(state));
        put(&mut b, "kind", ps.get("kind"));
        put(&mut b, "app", ps.get("app"));
        if let Some(msg) = ps.get("msg").and_then(Value::as_str) {
            b.insert("msg".into(), json!(msg.chars().take(MSG_MAX).collect::<String>()));
        }
        b.insert("seq".into(), json!(seq));
        b.insert("since".into(), json!(since));
        let key = (state.to_string(), if state == "blocked" { seq } else { 0 });
        out.push((id.to_string(), Row { key, body: b }));
    }
    out
}

impl Diff {
    /// The first list is only remembered (empty answer); after that, the event bodies (`t` and fields).
    pub fn feed(&mut self, list: &Value, _at: u64) -> Vec<Value> {
        let now = rows(list);
        let mut events = vec![];
        if let Some(was) = &self.seen {
            for (id, row) in &now {
                if was.get(id).is_none_or(|w| w.key != row.key) {
                    let mut m = Map::new();
                    m.insert("t".into(), json!("state"));
                    m.extend(row.body.clone());
                    events.push(Value::Object(m));
                }
            }
            let mut gone: Vec<&String> = was.keys().filter(|k| !now.iter().any(|(i, _)| i == *k)).collect();
            gone.sort();
            for id in gone {
                events.push(json!({"t":"gone","session":id}));
            }
        }
        self.seen = Some(now.into_iter().collect());
        events
    }

    /// One item per live session, with the latest values.
    pub fn snap(&self) -> Vec<Value> {
        let mut v: Vec<&Row> = self.seen.iter().flat_map(|m| m.values()).collect();
        v.sort_by(|a, b| a.body["session"].as_str().cmp(&b.body["session"].as_str()));
        v.into_iter().map(|r| Value::Object(r.body.clone())).collect()
    }

    pub fn ready(&self) -> bool {
        self.seen.is_some()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn list(rows: Vec<Value>) -> Value {
        json!({"terms": rows, "hosts": []})
    }
    fn row(state: &str, seq: u64) -> Value {
        json!({"id":"t1","name":"a","dead":false,"ps":{"state":state,"seq":seq,"since":5}})
    }

    #[test]
    fn the_first_list_is_no_change() {
        let mut d = Diff::default();
        assert!(!d.ready());
        assert!(d.feed(&list(vec![row("idle", 0)]), 1).is_empty());
        assert!(d.ready());
        assert_eq!(d.snap().len(), 1);
    }

    #[test]
    fn progress_alone_says_nothing() {
        let mut d = Diff::default();
        d.feed(&list(vec![row("working", 1)]), 1);
        let mut r = row("working", 1);
        r["ps"]["progress"] = json!(40);
        r["ps"]["msg"] = json!("later");
        assert!(d.feed(&list(vec![r]), 2).is_empty());
        assert_eq!(d.snap()[0]["msg"], "later");
    }

    #[test]
    fn a_new_question_while_blocked_is_news() {
        let mut d = Diff::default();
        d.feed(&list(vec![row("blocked", 2)]), 1);
        assert!(d.feed(&list(vec![row("blocked", 2)]), 2).is_empty());
        let ev = d.feed(&list(vec![row("blocked", 3)]), 3);
        assert_eq!(ev.len(), 1);
        assert_eq!(ev[0]["t"], "state");
        assert_eq!(ev[0]["seq"], 3);
    }

    #[test]
    fn dead_or_statusless_rows_are_gone() {
        let mut d = Diff::default();
        let two = vec![row("idle", 0), json!({"id":"t2","name":"b","dead":false,"ps":{"state":"idle","seq":0,"since":1}})];
        d.feed(&list(two), 1);
        let mut dead = row("idle", 0);
        dead["dead"] = json!(true);
        let nops = json!({"id":"t2","name":"b","dead":false});
        let ev = d.feed(&list(vec![dead, nops]), 2);
        assert_eq!(ev, vec![json!({"t":"gone","session":"t1"}), json!({"t":"gone","session":"t2"})]);
        assert!(d.snap().is_empty());
    }

    #[test]
    fn msg_is_cut_to_500_chars() {
        let mut d = Diff::default();
        d.feed(&list(vec![]), 1);
        let mut r = row("blocked", 1);
        r["ps"]["msg"] = json!("é".repeat(600));
        let ev = d.feed(&list(vec![r]), 2);
        assert_eq!(ev[0]["msg"].as_str().unwrap().chars().count(), 500);
    }
}
