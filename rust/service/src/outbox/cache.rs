use super::Me;
use serde_json::{json, Map, Value};
use std::collections::VecDeque;

/// Events kept for the state service to take.
pub const CACHE_MAX: usize = 200;

/// Numbered (from `Me::numbers`), enveloped events not yet taken; the oldest drop when it is full.
pub struct Cache {
    me: Me,
    events: VecDeque<Value>,
    dropped: u64,
    gap: bool,
}

impl Cache {
    pub fn new(me: Me) -> Self {
        Cache { me, events: VecDeque::new(), dropped: 0, gap: false }
    }

    fn envelope(&mut self, at: u64) -> Map<String, Value> {
        let n = self.me.numbers.take();
        let mut m = Map::new();
        m.insert("v".into(), json!(1));
        m.insert("fp".into(), json!(self.me.fp));
        if let Some(id) = &self.me.id {
            m.insert("id".into(), json!(id));
        }
        m.insert("device".into(), json!(self.me.device));
        m.insert("epoch".into(), json!(self.me.epoch));
        m.insert("n".into(), json!(n));
        m.insert("at".into(), json!(at));
        m.insert("src".into(), json!("term"));
        m
    }

    /// Number `body`, put the envelope on it and keep it; the oldest goes when there are [`CACHE_MAX`].
    pub fn push(&mut self, body: Value, at: u64) {
        let mut m = self.envelope(at);
        if let Value::Object(b) = body {
            m.extend(b);
        }
        if self.events.len() >= CACHE_MAX {
            self.events.pop_front();
            self.dropped += 1;
            self.gap = true;
        }
        self.events.push_back(Value::Object(m));
    }

    /// The oldest `max` events.
    pub fn head(&self, max: usize) -> Vec<Value> {
        self.events.iter().take(max).cloned().collect()
    }

    /// Forget what the service took: every event with `n <= through`.
    pub fn ack(&mut self, through: u64) {
        while self.events.front().is_some_and(|e| e["n"].as_u64().is_some_and(|n| n <= through)) {
            self.events.pop_front();
        }
    }

    /// A `snap` event with the next number (not kept); `gap:true` if events were lost since the last one taken.
    pub fn snap(&mut self, sessions: Vec<Value>, at: u64) -> Value {
        let mut m = self.envelope(at);
        m.insert("t".into(), json!("snap"));
        if self.gap {
            m.insert("gap".into(), json!(true));
        }
        m.insert("sessions".into(), Value::Array(sessions));
        Value::Object(m)
    }

    /// The snap was taken: the gap is told.
    pub fn snap_taken(&mut self) {
        self.gap = false;
    }

    pub fn len(&self) -> usize {
        self.events.len()
    }

    pub fn dropped(&self) -> u64 {
        self.dropped
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cache() -> Cache {
        Cache::new(Me { fp: "f".into(), id: None, device: "d".into(), epoch: "e".into(), numbers: Default::default() })
    }

    #[test]
    fn the_cache_keeps_200_and_marks_the_gap() {
        let mut c = cache();
        for i in 0..250 {
            c.push(json!({"t":"gone","session":format!("s{i}")}), 1);
        }
        assert_eq!(c.len(), 200);
        assert_eq!(c.head(1)[0]["n"], 51);
        assert_eq!(c.dropped(), 50);
        assert!(c.head(1)[0].get("id").is_none());
        let s = c.snap(vec![], 2);
        assert_eq!(s["gap"], true);
        c.snap_taken();
        assert!(c.snap(vec![], 3).get("gap").is_none());
    }

    #[test]
    fn ack_drops_what_was_taken() {
        let mut c = cache();
        for _ in 0..5 {
            c.push(json!({"t":"gone","session":"s"}), 1);
        }
        c.ack(3);
        assert_eq!(c.len(), 2);
        assert_eq!(c.head(10)[0]["n"], 4);
        c.ack(99);
        assert_eq!(c.len(), 0);
    }
}
