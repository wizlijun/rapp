//! The pure in-memory model: current state per device, the event queue, and "needs you".
//! No I/O. The rules are in `api/events.md`; the whole struct is what gets saved to disk.

use std::collections::{BTreeMap, BTreeSet};

use serde::{Deserialize, Serialize};
use serde_json::{json, Map, Value};

use crate::event::{Event, Kind};

pub use crate::event::TEXT_CHARS;
pub const DEVICE_DAYS: u64 = 30;
pub const PAGE_MAX: usize = 200;
const PAGE_DEFAULT: usize = 50;
const EPOCHS_KEPT: usize = 4;

#[derive(Debug, Clone, Serialize, Deserialize)]
struct Row {
    data: Map<String, Value>,
    /// When the row entered its current state and `seq`.
    first: u64,
    /// When a user last looked at this session (Unix seconds); kept across new states.
    #[serde(default)]
    seen: Option<u64>,
    /// A proxy row's (`src: "app"`) senders that report it now. Old files have none: their `by` stands in.
    #[serde(default, skip_serializing_if = "BTreeSet::is_empty")]
    vias: BTreeSet<String>,
}

impl Row {
    fn proxy(&self) -> bool {
        is_proxy(&self.data)
    }

    fn by(&self) -> Option<&str> {
        self.data.get("by").and_then(Value::as_str)
    }

    /// The senders reporting this proxy row.
    fn reporters(&mut self) -> &mut BTreeSet<String> {
        if self.vias.is_empty() {
            if let Some(b) = self.by().map(str::to_string) {
                self.vias.insert(b);
            }
        }
        &mut self.vias
    }

    /// Takes `sender` off this proxy row; true when nobody reports it any more. `by` moves to one who still does.
    fn leave(&mut self, sender: &str) -> bool {
        let set = self.reporters();
        set.remove(sender);
        let Some(next) = set.iter().next().cloned() else { return true };
        if self.by() == Some(sender) {
            self.data.insert("by".into(), json!(next));
        }
        false
    }
}

fn is_proxy(data: &Map<String, Value>) -> bool {
    data.get("src").and_then(Value::as_str) == Some("app")
}

/// Two proxy reports say the same thing.
fn same_report(a: &Map<String, Value>, b: &Map<String, Value>) -> bool {
    ["state", "kind", "app"].iter().all(|k| a.get(*k) == b.get(*k))
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct Device {
    fp: String,
    id: Option<String>,
    device: Option<String>,
    last: u64,
    sessions: BTreeMap<String, Row>,
}

/// What one app says it has open, replaced whole by `PUT /v1/desk/<fp>`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Desk {
    device: Option<String>,
    at: u64,
    sessions: Vec<Value>,
}

const DESK_MAX: usize = 200;

#[derive(Debug, Clone, Serialize, Deserialize)]
struct Queued {
    at: u64,
    arr: u64,
    row: Value,
    #[serde(default)]
    seen: Option<u64>,
    #[serde(default)]
    handled: bool,
}

/// What a "seen" mark points at.
pub enum Look<'a> {
    Session { fp: &'a str, session: &'a str },
    Eid(&'a str),
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Store {
    keep_days: u64,
    keep_events: usize,
    arrivals: u64,
    /// sender -> (epoch, highest n seen), most recently used first.
    seen: BTreeMap<String, Vec<(String, u64)>>,
    devices: BTreeMap<String, Device>,
    /// app fp -> what that app has open. Old files have none.
    #[serde(default)]
    desks: BTreeMap<String, Desk>,
    /// Oldest first, sorted by (at, arr).
    queue: Vec<Queued>,
    /// What moved since the last `take_changes`, in the shapes `GET /v1/watch` pushes.
    #[serde(skip)]
    changes: Vec<Value>,
}

const ENVELOPE: [&str; 8] = ["fp", "id", "device", "epoch", "n", "t", "via", "src"];

impl Store {
    pub fn new(keep_days: u64, keep_events: usize) -> Store {
        Store {
            keep_days,
            keep_events,
            arrivals: 0,
            seen: BTreeMap::new(),
            devices: BTreeMap::new(),
            desks: BTreeMap::new(),
            queue: Vec::new(),
            changes: Vec::new(),
        }
    }

    /// Hands over the changes gathered so far and starts a new list.
    pub fn take_changes(&mut self) -> Vec<Value> {
        std::mem::take(&mut self.changes)
    }

    pub fn set_limits(&mut self, keep_days: u64, keep_events: usize) {
        self.keep_days = keep_days;
        self.keep_events = keep_events;
        self.trim();
    }

    /// Returns false for a duplicate (already seen sender, epoch, n).
    pub fn apply(&mut self, ev: Event, _now: u64) -> bool {
        if !self.note_seen(&ev) {
            return false;
        }
        let needs_before = self.needs();
        let eid = ev.eid();
        let fp = ev.fp().to_string();
        let dev = self.devices.entry(fp.clone()).or_insert_with(|| Device { fp: fp.clone(), id: None, device: None, last: 0, sessions: BTreeMap::new() });
        if let Some(s) = ev.body.get("id").and_then(Value::as_str) {
            dev.id = Some(s.to_string());
        }
        if let Some(s) = ev.body.get("device").and_then(Value::as_str) {
            dev.device = Some(s.to_string());
        }
        dev.last = dev.last.max(ev.at);
        let via = ev.body.get("via").is_some();
        // A proxy report that changes nothing a watcher sees: no push, no queue line.
        let mut quiet = false;
        match ev.t {
            Kind::State => {
                let session = ev.body["session"].as_str().unwrap_or_default().to_string();
                let data = row_data(&ev.body, ev.at, &ev.sender, ev.body.get("src"));
                match put_report(dev, &session, data, &ev.sender, via) {
                    Put::Joined => quiet = true,
                    Put::Replaced => self.changes.push(session_change(dev, &session, dev.sessions.get(&session))),
                }
            }
            Kind::Gone => {
                if let Some(s) = ev.body.get("session").and_then(Value::as_str) {
                    // A proxy's gone (it names `via`) takes only that proxy off the row; the row goes with its
                    // last reporter. A gone without `via` deletes the row whoever reported it.
                    let drop = match dev.sessions.get_mut(s) {
                        None => false,
                        Some(_) if !via => true,
                        Some(r) if r.proxy() => r.leave(&ev.sender),
                        Some(r) => r.by() == Some(ev.sender.as_str()),
                    };
                    if drop {
                        dev.sessions.remove(s);
                        self.changes.push(session_change(dev, s, None));
                    } else if via {
                        quiet = true;
                    }
                }
            }
            Kind::Snap => {
                let mut dropped = Vec::new();
                dev.sessions.retain(|sid, r| {
                    let keep = if r.proxy() { !r.leave(&ev.sender) } else { r.by() != Some(ev.sender.as_str()) };
                    if !keep {
                        dropped.push(sid.clone());
                    }
                    keep
                });
                let mut put = Vec::new();
                for it in ev.body.get("sessions").and_then(Value::as_array).into_iter().flatten() {
                    if let Some(m) = it.as_object() {
                        if let Some(s) = m.get("session").and_then(Value::as_str) {
                            let data = row_data(m, ev.at, &ev.sender, ev.body.get("src"));
                            if let Put::Replaced = put_report(dev, s, data, &ev.sender, via) {
                                put.push(s.to_string());
                            }
                        }
                    }
                }
                // A row the snap brought back is pushed once, with its new content.
                for sid in dropped.iter().filter(|sid| !dev.sessions.contains_key(*sid)) {
                    self.changes.push(session_change(dev, sid, None));
                }
                for sid in &put {
                    self.changes.push(session_change(dev, sid, dev.sessions.get(sid)));
                }
            }
            Kind::Emit => {}
        }
        let row = match ev.t {
            Kind::Snap if ev.body.get("gap").and_then(Value::as_bool) == Some(true) => {
                let mut r = json!({"t": "gap", "fp": fp, "at": ev.at, "eid": eid});
                for k in ["id", "device"] {
                    if let Some(v) = ev.body.get(k) {
                        r[k] = v.clone();
                    }
                }
                Some(r)
            }
            Kind::Snap => None,
            _ if quiet => None,
            _ => {
                let mut r = ev.body.clone();
                r.insert("eid".into(), Value::String(eid));
                Some(Value::Object(r))
            }
        };
        if let Some(row) = row {
            self.arrivals += 1;
            let key = (ev.at, self.arrivals);
            let pos = self.queue.partition_point(|q| (q.at, q.arr) <= key);
            let q = Queued { at: ev.at, arr: self.arrivals, row, seen: None, handled: false };
            self.changes.push(json!({"what": "queue", "row": queued_json(&q)}));
            self.queue.insert(pos, q);
            self.trim();
        }
        self.note_needs(needs_before);
        true
    }

    /// Adds a `need` change when the needs are no longer `before`.
    fn note_needs(&mut self, before: Value) {
        let after = self.needs();
        if after != before {
            self.changes.push(json!({"what": "need", "needs": after}));
        }
    }

    fn note_seen(&mut self, ev: &Event) -> bool {
        let list = self.seen.entry(ev.sender.clone()).or_default();
        match list.iter().position(|(e, _)| *e == ev.epoch) {
            Some(i) => {
                if ev.n <= list[i].1 {
                    return false;
                }
                let mut e = list.remove(i);
                e.1 = ev.n;
                list.insert(0, e);
            }
            None => {
                list.insert(0, (ev.epoch.clone(), ev.n));
                list.truncate(EPOCHS_KEPT);
            }
        }
        true
    }

    fn trim(&mut self) {
        if self.queue.len() > self.keep_events {
            let drop = self.queue.len() - self.keep_events;
            self.queue.drain(..drop);
        }
    }

    pub fn expire(&mut self, now: u64) {
        let q_min = now.saturating_sub(self.keep_days.saturating_mul(86400));
        self.queue.retain(|q| q.at >= q_min);
        let d_min = now.saturating_sub(DEVICE_DAYS.saturating_mul(86400));
        let old: Vec<String> = self.desks.iter().filter(|(_, d)| d.at < d_min).map(|(k, _)| k.clone()).collect();
        for fp in old {
            self.desks.remove(&fp);
            self.changes.push(json!({"what": "desk", "fp": fp, "desk": Value::Null}));
        }
        if self.devices.values().all(|d| d.last >= d_min) {
            return;
        }
        let needs_before = self.needs();
        let (kept, gone): (BTreeMap<_, _>, BTreeMap<_, _>) =
            std::mem::take(&mut self.devices).into_iter().partition(|(_, d)| d.last >= d_min);
        self.devices = kept;
        for d in gone.values() {
            for sid in d.sessions.keys() {
                self.changes.push(session_change(d, sid, None));
            }
        }
        self.note_needs(needs_before);
    }

    /// The sessions that wait for the user, oldest first: `needs` in `state()`.
    fn needs(&self) -> Value {
        let mut needs: Vec<(u64, String, String, Value)> = Vec::new();
        for d in self.devices.values() {
            for (sid, r) in &d.sessions {
                if r.data.get("state").and_then(Value::as_str) != Some("blocked") {
                    continue;
                }
                let since = r.data.get("since").and_then(Value::as_u64).unwrap_or(r.first);
                let mut n = json!({"fp": d.fp, "session": sid, "since": since});
                if let Some(v) = &d.id {
                    n["id"] = json!(v);
                }
                if let Some(v) = &d.device {
                    n["device"] = json!(v);
                }
                for k in ["kind", "app", "msg", "src"] {
                    if let Some(v) = r.data.get(k) {
                        n[k] = v.clone();
                    }
                }
                needs.push((since, d.fp.clone(), sid.clone(), n));
            }
        }
        needs.sort_by(|a, b| (a.0, &a.1, &a.2).cmp(&(b.0, &b.1, &b.2)));
        Value::Array(needs.into_iter().map(|n| n.3).collect())
    }

    pub fn state(&self) -> Value {
        let devices: Vec<Value> = self
            .devices
            .values()
            .map(|d| {
                let mut o = json!({"fp": d.fp, "last": d.last,
                    "sessions": d.sessions.values().map(row_json).collect::<Vec<_>>()});
                if let Some(v) = &d.id {
                    o["id"] = json!(v);
                }
                if let Some(v) = &d.device {
                    o["device"] = json!(v);
                }
                o
            })
            .collect();
        let desks: Vec<Value> = self.desks.iter().map(|(fp, d)| desk_json(fp, d)).collect();
        json!({"devices": devices, "desks": desks, "needs": self.needs(), "queued": self.queue.len()})
    }

    /// Replaces the desk of app `fp`. An empty `sessions` removes it. A bad body is refused whole.
    pub fn put_desk(&mut self, fp: &str, body: &Value, now: u64) -> Result<(), &'static str> {
        const BAD: &str = "bad request";
        let device = match body.get("device") {
            None | Some(Value::Null) => None,
            Some(Value::String(s)) => Some(s.clone()),
            _ => return Err(BAD),
        };
        let items = body.get("sessions").and_then(Value::as_array).filter(|a| a.len() <= DESK_MAX).ok_or(BAD)?;
        let mut sessions = Vec::with_capacity(items.len());
        for it in items {
            let m = it.as_object().ok_or(BAD)?;
            if !matches!(m.get("app"), Some(Value::String(a)) if !a.is_empty()) {
                return Err(BAD);
            }
            let mut o = Map::new();
            for k in ["fp", "id", "name"] {
                match m.get(k) {
                    None => {}
                    Some(Value::String(v)) if k == "name" => {
                        o.insert(k.into(), Value::String(v.chars().take(TEXT_CHARS).collect()));
                    }
                    Some(Value::String(v)) => {
                        o.insert(k.into(), Value::String(v.clone()));
                    }
                    Some(_) => return Err(BAD),
                }
            }
            if !o.contains_key("fp") && !o.contains_key("id") {
                return Err(BAD);
            }
            o.insert("app".into(), m["app"].clone());
            sessions.push(Value::Object(o));
        }
        if sessions.is_empty() {
            if self.desks.remove(fp).is_some() {
                self.changes.push(json!({"what": "desk", "fp": fp, "desk": Value::Null}));
            }
            return Ok(());
        }
        let same = self.desks.get(fp).is_some_and(|d| d.device == device && d.sessions == sessions);
        let desk = Desk { device, at: now, sessions };
        if !same {
            self.changes.push(json!({"what": "desk", "fp": fp, "desk": desk_json(fp, &desk)}));
        }
        self.desks.insert(fp.to_string(), desk);
        Ok(())
    }

    /// Marks a session (by device and session id) or a queue row (by eid) as seen at `now`.
    pub fn mark_seen(&mut self, look: Look, handled: bool, now: u64) -> Result<(), &'static str> {
        match look {
            Look::Session { fp, session } => {
                let row = self.devices.get_mut(fp).and_then(|d| d.sessions.get_mut(session)).ok_or("unknown session")?;
                row.seen = Some(now);
                self.changes.push(json!({"what": "seen", "fp": fp, "session": session, "at": now}));
            }
            Look::Eid(eid) => {
                let q = self.queue.iter_mut().find(|q| q.row["eid"] == eid).ok_or("unknown eid")?;
                q.seen = Some(now);
                q.handled |= handled;
                let mut c = json!({"what": "seen", "eid": eid, "at": now});
                if q.handled {
                    c["handled"] = json!(true);
                }
                self.changes.push(c);
            }
        }
        Ok(())
    }

    pub fn queue(&self, before: Option<&str>, limit: usize) -> Result<Value, String> {
        let limit = if limit == 0 { PAGE_DEFAULT } else { limit.min(PAGE_MAX) };
        let newest_first = || self.queue.iter().rev();
        let skip = match before {
            None => 0,
            Some(c) => newest_first().position(|q| q.row["eid"] == c).ok_or("bad cursor")? + 1,
        };
        let rest: Vec<&Queued> = newest_first().skip(skip).collect();
        let events: Vec<Value> = rest.iter().take(limit).map(|q| queued_json(q)).collect();
        Ok(json!({"events": events, "more": rest.len() > limit}))
    }
}

fn row_json(r: &Row) -> Value {
    let mut m = r.data.clone();
    if let Some(t) = r.seen {
        m.insert("seen".into(), json!(t));
    }
    if r.proxy() {
        let vias: Vec<&str> = if r.vias.is_empty() { r.by().into_iter().collect() } else { r.vias.iter().map(String::as_str).collect() };
        m.insert("vias".into(), json!(vias));
    }
    Value::Object(m)
}

/// `{"what":"session",…}`; a `None` row means the session is gone. It names the device with the `id` and
/// `device` that `state()` gives it (left out when unknown), so a watcher can place a device it has not seen yet.
fn session_change(dev: &Device, session: &str, row: Option<&Row>) -> Value {
    let mut c = json!({"what": "session", "fp": dev.fp, "session": session, "row": row.map(row_json)});
    if let Some(v) = &dev.id {
        c["id"] = json!(v);
    }
    if let Some(v) = &dev.device {
        c["device"] = json!(v);
    }
    c
}

fn desk_json(fp: &str, d: &Desk) -> Value {
    let mut o = json!({"fp": fp, "at": d.at, "sessions": d.sessions});
    if let Some(v) = &d.device {
        o["device"] = json!(v);
    }
    o
}

fn queued_json(q: &Queued) -> Value {
    let mut v = q.row.clone();
    if let Some(t) = q.seen {
        v["seen"] = json!(t);
    }
    if q.handled {
        v["handled"] = json!(true);
    }
    v
}

/// A session row: the event body without the envelope, plus `at`, `by` and the envelope's `src` when it has one.
fn row_data(src: &Map<String, Value>, at: u64, by: &str, envelope_src: Option<&Value>) -> Map<String, Value> {
    let mut m = src.clone();
    for k in ENVELOPE {
        m.remove(k);
    }
    m.remove("sessions");
    m.remove("gap");
    m.insert("at".into(), json!(at));
    m.insert("by".into(), json!(by));
    if let Some(v) = envelope_src {
        m.insert("src".into(), v.clone());
    }
    m
}

enum Put {
    /// Another proxy already reported the same: the sender joins the row's reporters, nothing else moves.
    Joined,
    Replaced,
}

/// Puts a `state` body (or a snap item) as the row of `session`. A proxy report that says what the row already
/// says joins it; any other report replaces the row, and a proxy row's reporters become this sender alone (or
/// stay as they were when this sender was among them).
fn put_report(dev: &mut Device, session: &str, data: Map<String, Value>, sender: &str, via: bool) -> Put {
    let proxy = via && is_proxy(&data);
    let mut vias = BTreeSet::new();
    if proxy {
        if let Some(r) = dev.sessions.get_mut(session).filter(|r| r.proxy() && same_report(&r.data, &data)) {
            let set = r.reporters();
            if !set.contains(sender) {
                set.insert(sender.to_string());
                return Put::Joined;
            }
            vias = set.clone();
        }
        vias.insert(sender.to_string());
    }
    let at = data["at"].as_u64().unwrap_or(0);
    let old = dev.sessions.get(session);
    let first = match old {
        Some(old) if old.data.get("state") == data.get("state") && old.data.get("seq") == data.get("seq") => old.first,
        _ => at,
    };
    let seen = old.and_then(|old| old.seen);
    dev.sessions.insert(session.to_string(), Row { data, first, seen, vias });
    Put::Replaced
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::event::parse_line;

    const TERM: &str = include_str!("../api/samples/term-events.ndjson");
    const MIXED: &str = include_str!("../api/samples/mixed.ndjson");
    const A: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";

    fn feed(s: &mut Store, text: &str, take: usize) -> Vec<bool> {
        text.lines().take(take).map(|l| s.apply(parse_line(l).unwrap(), 1764130100)).collect()
    }
    fn st() -> Store {
        Store::new(7, 1000)
    }
    fn ns(v: &Value) -> Vec<u64> {
        v["events"].as_array().unwrap().iter().map(|e| e["n"].as_u64().unwrap()).collect()
    }
    fn ev(n: u64, at: u64) -> Event {
        parse_line(&json!({"v":1,"fp":"aa","epoch":"e","n":n,"at":at,"t":"state","session":"s","state":"working","seq":n}).to_string()).unwrap()
    }

    fn first_session(s: &Store) -> (String, String) {
        let d = &s.state()["devices"][0];
        (d["fp"].as_str().unwrap().into(), d["sessions"][0]["session"].as_str().unwrap().into())
    }
    fn session_row(s: &Store, fp: &str, sid: &str) -> Value {
        let v = s.state();
        let d = v["devices"].as_array().unwrap().iter().find(|d| d["fp"] == fp).unwrap();
        d["sessions"].as_array().unwrap().iter().find(|r| r["session"] == sid).unwrap().clone()
    }
    fn feed_one(s: &mut Store, fp: &str, sid: &str, state: &str, at: u64) {
        let l = json!({"v":1,"fp":fp,"epoch":"e9","n":at,"at":at,"t":"state","session":sid,"state":state,"seq":at});
        s.apply(parse_line(&l.to_string()).unwrap(), at);
    }

    #[test]
    fn seen_sticks_to_the_session_and_survives_a_new_state() {
        let mut s = st();
        feed(&mut s, TERM, 4);
        let (fp, sid) = first_session(&s);
        s.mark_seen(Look::Session { fp: &fp, session: &sid }, false, 500).unwrap();
        assert_eq!(session_row(&s, &fp, &sid)["seen"], 500);
        feed_one(&mut s, &fp, &sid, "working", 600);
        assert_eq!(session_row(&s, &fp, &sid)["seen"], 500);
        assert_eq!(s.mark_seen(Look::Session { fp: "nope", session: &sid }, false, 1), Err("unknown session"));
    }

    fn feed_gone(s: &mut Store, fp: &str, sid: &str, at: u64) {
        let l = json!({"v":1,"fp":fp,"epoch":"e9","n":at,"at":at,"t":"gone","session":sid});
        s.apply(parse_line(&l.to_string()).unwrap(), at);
    }

    fn feed_line(s: &mut Store, l: Value) {
        s.apply(parse_line(&l.to_string()).unwrap(), 1);
    }

    #[test]
    fn a_desk_is_replaced_whole_and_an_empty_one_is_removed() {
        let mut s = st();
        s.put_desk("appA", &json!({"device":"iPad","sessions":[{"id":"111111111","app":"com.x","name":"X","junk":1}]}), 100).unwrap();
        let d = &s.state()["desks"][0];
        assert_eq!((d["fp"].as_str(), d["device"].as_str(), d["at"].as_u64()), (Some("appA"), Some("iPad"), Some(100)));
        assert_eq!(d["sessions"], json!([{"id":"111111111","app":"com.x","name":"X"}]));
        assert_eq!(s.take_changes().last().unwrap()["what"], "desk");
        s.put_desk("appA", &json!({"device":"iPad","sessions":[{"id":"111111111","app":"com.x","name":"X"}]}), 200).unwrap();
        assert!(s.take_changes().is_empty(), "same content: no push");
        assert_eq!(s.state()["desks"][0]["at"], 200, "at still moves");
        s.put_desk("appA", &json!({"sessions":[]}), 300).unwrap();
        assert_eq!(s.state()["desks"], json!([]));
        assert_eq!(s.take_changes().last().unwrap()["desk"], Value::Null);
    }

    #[test]
    fn a_bad_desk_is_refused() {
        let mut s = st();
        for b in [json!({}), json!({"sessions":[{"app":"x"}]}), json!({"sessions":[{"id":"1"}]}), json!({"sessions":[{"id":1,"app":"x"}]}),
                  json!({"device":3,"sessions":[]})] {
            assert_eq!(s.put_desk("a", &b, 1), Err("bad request"), "{b}");
        }
        let many: Vec<Value> = (0..201).map(|i| json!({"id":"1","app":format!("a{i}")})).collect();
        assert_eq!(s.put_desk("a", &json!({"sessions": many}), 1), Err("bad request"));
    }

    #[test]
    fn an_old_desk_expires() {
        let mut s = st();
        s.put_desk("a", &json!({"sessions":[{"id":"1","app":"x"}]}), 1_000).unwrap();
        s.take_changes();
        s.expire(1_000 + 31 * 86_400);
        assert_eq!(s.state()["desks"], json!([]));
        assert!(s.take_changes().iter().any(|c| c["what"] == "desk" && c["desk"].is_null()));
    }

    #[test]
    fn rows_and_needs_carry_src() {
        let mut s = st();
        feed_line(&mut s, json!({"v":1,"fp":"devA","id":"111111111","epoch":"e1","n":1,"at":10,"src":"app","via":"appA",
                                 "t":"state","session":"com.x","name":"X","state":"blocked","kind":"permission"}));
        assert_eq!(session_row(&s, "devA", "com.x")["src"], "app");
        assert_eq!(s.state()["needs"][0]["src"], "app");
        assert!(s.state()["devices"][0].get("device").is_none_or(Value::is_null), "a proxy event names no device");
    }

    #[test]
    fn a_proxy_gone_removes_only_its_own_row() {
        let mut s = st();
        let ev = |via: &str, n: u64, t: &str| json!({"v":1,"fp":"devA","epoch":"e","n":n,"at":10,"src":"app","via":via,
                                                     "t":t,"session":"com.x","name":"X","state":"blocked","kind":"permission"});
        feed_line(&mut s, ev("appMac", 1, "state"));
        feed_line(&mut s, ev("appPad", 1, "gone"));
        assert_eq!(session_row(&s, "devA", "com.x")["by"], "appMac", "iPad's gone leaves the Mac's report");
        feed_line(&mut s, ev("appMac", 2, "gone"));
        assert!(s.state()["devices"][0]["sessions"].as_array().unwrap().is_empty());
    }

    fn proxy(via: &str, n: u64, t: &str, state: &str) -> Value {
        json!({"v":1,"fp":"devA","id":"111111111","epoch":"e","n":n,"at":10 + n,"src":"app","via":via,
               "t":t,"session":"com.x","name":"X","state":state,"kind":"permission","app":"com.x"})
    }
    fn queued_ts(s: &Store) -> Vec<String> {
        s.queue(None, 50).unwrap()["events"].as_array().unwrap().iter().map(|e| e["t"].as_str().unwrap().to_string()).collect()
    }

    #[test]
    fn a_shared_proxy_row_outlives_one_reporter_going() {
        let mut s = st();
        feed_line(&mut s, proxy("appMac", 1, "state", "blocked"));
        s.take_changes();
        feed_line(&mut s, proxy("appPad", 1, "state", "blocked"));
        assert!(s.take_changes().is_empty(), "the same report from a second app moves nothing");
        assert_eq!(session_row(&s, "devA", "com.x")["vias"], json!(["appMac", "appPad"]));
        feed_line(&mut s, proxy("appPad", 2, "gone", "blocked"));
        assert!(s.take_changes().is_empty(), "the iPad's gone leaves the Mac's report standing");
        let row = session_row(&s, "devA", "com.x");
        assert_eq!((row["state"].as_str(), row["by"].as_str()), (Some("blocked"), Some("appMac")));
        assert_eq!(row["vias"], json!(["appMac"]));
        assert_eq!(s.state()["needs"].as_array().unwrap().len(), 1);
        assert_eq!(queued_ts(&s), ["state"], "one thing, one queue line");
        feed_line(&mut s, proxy("appMac", 2, "gone", "blocked"));
        assert!(s.state()["devices"][0]["sessions"].as_array().unwrap().is_empty());
        assert_eq!(queued_ts(&s), ["gone", "state"]);
    }

    #[test]
    fn a_different_proxy_report_takes_the_row_over() {
        let mut s = st();
        feed_line(&mut s, proxy("appMac", 1, "state", "blocked"));
        feed_line(&mut s, proxy("appPad", 1, "state", "working"));
        let row = session_row(&s, "devA", "com.x");
        assert_eq!((row["state"].as_str(), row["by"].as_str()), (Some("working"), Some("appPad")));
        assert_eq!(row["vias"], json!(["appPad"]));
        assert_eq!(queued_ts(&s), ["state", "state"]);
        s.take_changes();
        feed_line(&mut s, proxy("appPad", 2, "gone", "working"));
        assert!(s.state()["devices"][0]["sessions"].as_array().unwrap().is_empty());
        assert!(s.take_changes().iter().any(|c| c["what"] == "session" && c["row"].is_null()));
    }

    #[test]
    fn a_proxy_snap_leaves_a_shared_row_in_place() {
        let mut s = st();
        feed_line(&mut s, proxy("appMac", 1, "state", "blocked"));
        feed_line(&mut s, proxy("appPad", 1, "state", "blocked"));
        s.take_changes();
        feed_line(&mut s, json!({"v":1,"fp":"devA","epoch":"e","n":2,"at":20,"src":"app","via":"appPad","t":"snap","sessions":[]}));
        assert!(s.take_changes().iter().all(|c| c["what"] != "session"), "nothing a watcher sees moved");
        let row = session_row(&s, "devA", "com.x");
        assert_eq!((row["state"].as_str(), row["by"].as_str()), (Some("blocked"), Some("appMac")));
        assert_eq!(row["vias"], json!(["appMac"]));
        // A snap that carries the same report joins it again, quietly.
        feed_line(&mut s, json!({"v":1,"fp":"devA","epoch":"e","n":3,"at":30,"src":"app","via":"appPad","t":"snap",
                                 "sessions":[{"session":"com.x","name":"X","state":"blocked","kind":"permission","app":"com.x"}]}));
        assert!(s.take_changes().iter().all(|c| c["what"] != "session"));
        assert_eq!(session_row(&s, "devA", "com.x")["vias"], json!(["appMac", "appPad"]));
        // The last reporter's snap drops it.
        feed_line(&mut s, json!({"v":1,"fp":"devA","epoch":"e","n":4,"at":40,"src":"app","via":"appPad","t":"snap","sessions":[]}));
        feed_line(&mut s, json!({"v":1,"fp":"devA","epoch":"e","n":3,"at":40,"src":"app","via":"appMac","t":"snap","sessions":[]}));
        assert!(s.state()["devices"][0]["sessions"].as_array().unwrap().is_empty());
    }

    #[test]
    fn an_old_files_proxy_row_counts_its_by_as_the_reporter() {
        let mut s = st();
        feed_line(&mut s, proxy("appMac", 1, "state", "blocked"));
        let mut v = serde_json::to_value(&s).unwrap();
        v["devices"]["devA"]["sessions"]["com.x"].as_object_mut().unwrap().remove("vias");
        let mut s: Store = serde_json::from_value(v).unwrap();
        feed_line(&mut s, proxy("appPad", 1, "state", "blocked"));
        feed_line(&mut s, proxy("appPad", 2, "gone", "blocked"));
        assert_eq!(session_row(&s, "devA", "com.x")["by"], "appMac");
        feed_line(&mut s, proxy("appMac", 2, "gone", "blocked"));
        assert!(s.state()["devices"][0]["sessions"].as_array().unwrap().is_empty());
    }

    #[test]
    fn changes_name_what_moved() {
        let mut s = st();
        feed(&mut s, TERM, 2);
        let ch = s.take_changes();
        let whats: Vec<&str> = ch.iter().map(|c| c["what"].as_str().unwrap()).collect();
        assert!(whats.contains(&"session") && whats.contains(&"queue"), "{whats:?}");
        let row = ch.iter().rev().find(|c| c["what"] == "session").unwrap();
        assert_eq!(row["row"], session_row(&s, A, "term:pty:a"));
        let q = ch.iter().find(|c| c["what"] == "queue").unwrap();
        assert_eq!(q["row"], s.queue(None, 1).unwrap()["events"][0]);
        assert!(s.take_changes().is_empty());
        // A blocked state brings a need, the whole list as in state().
        feed_one(&mut s, "fpA", "t9", "blocked", 900);
        let need = s.take_changes().into_iter().find(|c| c["what"] == "need").unwrap();
        assert_eq!(need["needs"], s.state()["needs"]);
        assert_eq!(need["needs"].as_array().unwrap().len(), 1);
        // A state that leaves the needs as they were brings none.
        feed_one(&mut s, A, "term:pty:a", "working", 901);
        assert!(!s.take_changes().iter().any(|c| c["what"] == "need"));
        // gone -> session/null, and the need goes too.
        feed_gone(&mut s, "fpA", "t9", 902);
        let ch = s.take_changes();
        assert!(ch.iter().any(|c| c["what"] == "session" && c["fp"] == "fpA" && c["session"] == "t9" && c["row"].is_null()));
        assert!(ch.iter().any(|c| c["what"] == "need" && c["needs"] == json!([])));
    }

    #[test]
    fn a_session_change_names_its_device_as_state_does() {
        let mut s = st();
        feed(&mut s, TERM, 2);
        let ch = s.take_changes();
        let c = ch.iter().rev().find(|c| c["what"] == "session").unwrap();
        let d = &s.state()["devices"][0];
        assert_eq!((&c["id"], &c["device"]), (&d["id"], &d["device"]));
        assert_eq!((c["id"].as_str(), c["device"].as_str()), (Some("111111111"), Some("mac")));
        // A device that never said who it is pushes neither field, as /v1/state leaves them out.
        feed_one(&mut s, "fpB", "t1", "working", 900);
        let c = s.take_changes().into_iter().find(|c| c["what"] == "session").unwrap();
        assert!(c.get("id").is_none() && c.get("device").is_none(), "{c}");
    }

    #[test]
    fn a_snap_pushes_null_only_for_rows_it_dropped() {
        let mut s = st();
        feed(&mut s, MIXED, 6);
        s.take_changes();
        let l = json!({"v":1,"fp":A,"epoch":"e2","n":99,"at":2000,"t":"snap","sessions":[{"session":"term:pty:z","state":"idle"}]});
        s.apply(parse_line(&l.to_string()).unwrap(), 2000);
        let ch: Vec<(String, bool)> = s
            .take_changes()
            .iter()
            .filter(|c| c["what"] == "session")
            .map(|c| (c["session"].as_str().unwrap().to_string(), c["row"].is_null()))
            .collect();
        assert!(ch.contains(&("term:pty:z".into(), false)), "{ch:?}");
        assert!(ch.contains(&("term:pty:c".into(), true)), "{ch:?}");
        assert!(!ch.iter().any(|(sid, _)| sid == "claude:s1"), "another sender's row stays: {ch:?}");
    }

    #[test]
    fn seen_and_expire_are_changes_too() {
        let mut s = st();
        feed(&mut s, TERM, 2);
        s.take_changes();
        s.mark_seen(Look::Session { fp: A, session: "term:pty:a" }, false, 500).unwrap();
        assert_eq!(s.take_changes(), [json!({"what":"seen","fp":A,"session":"term:pty:a","at":500})]);
        let eid = s.queue(None, 1).unwrap()["events"][0]["eid"].as_str().unwrap().to_string();
        s.mark_seen(Look::Eid(&eid), true, 600).unwrap();
        assert_eq!(s.take_changes(), [json!({"what":"seen","eid":eid,"at":600,"handled":true})]);
        s.expire(1764130010 + 31 * 86400);
        assert_eq!(
            s.take_changes(),
            [json!({"what":"session","fp":A,"id":"111111111","device":"mac","session":"term:pty:a","row":null})]
        );
    }

    #[test]
    fn a_later_mark_keeps_handled() {
        let mut s = st();
        feed(&mut s, TERM, 2);
        let eid = s.queue(None, 1).unwrap()["events"][0]["eid"].as_str().unwrap().to_string();
        s.mark_seen(Look::Eid(&eid), true, 700).unwrap();
        s.mark_seen(Look::Eid(&eid), false, 800).unwrap();
        assert_eq!(s.queue(None, 1).unwrap()["events"][0]["handled"], true);
    }

    #[test]
    fn seen_and_handled_mark_a_queue_row() {
        let mut s = st();
        feed(&mut s, TERM, 2);
        let eid = s.queue(None, 1).unwrap()["events"][0]["eid"].as_str().unwrap().to_string();
        s.mark_seen(Look::Eid(&eid), true, 700).unwrap();
        let row = &s.queue(None, 1).unwrap()["events"][0];
        assert_eq!((row["seen"].as_u64(), row["handled"].as_bool()), (Some(700), Some(true)));
        assert_eq!(s.mark_seen(Look::Eid("x:y:1"), false, 1), Err("unknown eid"));
    }

    #[test]
    fn samples_give_the_state_and_queue_in_events_md() {
        let mut s = st();
        feed(&mut s, TERM, 5);
        let v = s.state();
        assert_eq!(v["devices"][0]["fp"], A);
        assert_eq!(v["devices"][0]["sessions"], json!([]));
        assert_eq!(v["needs"], json!([]));
        assert_eq!(v["queued"], 4);
        let q = s.queue(None, 50).unwrap();
        assert_eq!(q["more"], false);
        let t: Vec<&str> = q["events"].as_array().unwrap().iter().map(|e| e["t"].as_str().unwrap()).collect();
        assert_eq!(t, ["gone", "state", "state", "state"]);
        assert_eq!(q["events"][0]["eid"], format!("{A}:e1:5"));
        assert!(q["events"][0].get("v").is_none());
    }

    #[test]
    fn blocked_is_a_need_until_it_changes() {
        let mut s = st();
        feed(&mut s, TERM, 3);
        let n = s.state()["needs"].clone();
        assert_eq!(n.as_array().unwrap().len(), 1);
        assert_eq!(n[0]["fp"], A);
        assert_eq!(n[0]["session"], "term:pty:a");
        assert_eq!(n[0]["kind"], "permission");
        assert_eq!(n[0]["app"], "claude-code");
        assert_eq!(n[0]["since"], 1764130020);
        feed(&mut s, TERM, 4); // 1-3 are duplicates, 4 applies
        assert_eq!(s.state()["needs"], json!([]));
    }

    #[test]
    fn since_survives_a_repeat_of_the_same_seq() {
        let mut s = st();
        let b = |n: u64, at: u64, seq: u64| {
            parse_line(&json!({"v":1,"fp":"aa","epoch":"e","n":n,"at":at,"t":"state","session":"s","state":"blocked","seq":seq}).to_string()).unwrap()
        };
        s.apply(b(1, 100, 1), 100);
        s.apply(b(2, 200, 1), 200);
        assert_eq!(s.state()["needs"][0]["since"], 100);
        s.apply(b(3, 300, 2), 300);
        assert_eq!(s.state()["needs"][0]["since"], 300);
    }

    #[test]
    fn a_duplicate_is_ignored() {
        let mut s = st();
        let l = TERM.lines().nth(1).unwrap();
        assert!(s.apply(parse_line(l).unwrap(), 0));
        assert!(!s.apply(parse_line(l).unwrap(), 0));
        assert_eq!(s.state()["queued"], 1);
        let mut s = st();
        assert_eq!(feed(&mut s, MIXED, 3), [true, true, false]);
    }

    #[test]
    fn a_snap_replaces_only_its_senders_rows() {
        let mut s = st();
        let r = feed(&mut s, MIXED, 6);
        assert_eq!(r, [true, true, false, true, true, true]);
        let v = s.state();
        let devs = v["devices"].as_array().unwrap();
        assert_eq!(devs.len(), 2);
        let aa = devs.iter().find(|d| d["fp"] == A).unwrap();
        let names: Vec<&str> = aa["sessions"].as_array().unwrap().iter().map(|r| r["session"].as_str().unwrap()).collect();
        assert_eq!(names, ["claude:s1", "term:pty:c"]);
        assert_eq!(aa["sessions"][0]["by"], "c".repeat(64));
        assert_eq!(aa["sessions"][1]["by"], A);
        let q = s.queue(None, 50).unwrap();
        assert_eq!(q["events"][0]["t"], "gap");
        assert_eq!(q["events"][0]["eid"], format!("{A}:e2:1"));
        assert_eq!(v["queued"], 4);
        assert_eq!(v["needs"][0]["session"], "term:pty:b");
    }

    #[test]
    fn text_is_cut_at_500_chars() {
        let mut s = st();
        let l = json!({"v":1,"fp":"aa","epoch":"e","n":1,"at":5,"t":"state","session":"s","state":"blocked","msg":"字".repeat(600)}).to_string();
        s.apply(parse_line(&l).unwrap(), 5);
        assert_eq!(s.state()["devices"][0]["sessions"][0]["msg"].as_str().unwrap().chars().count(), 500);
        assert_eq!(s.queue(None, 5).unwrap()["events"][0]["msg"].as_str().unwrap().chars().count(), 500);
    }

    #[test]
    fn the_queue_keeps_its_limits() {
        let mut s = Store::new(7, 3);
        for n in 1..=5 {
            s.apply(ev(n, 1000 + n), 1000);
        }
        assert_eq!(ns(&s.queue(None, 50).unwrap()), [5, 4, 3]);
        s.expire(1005 + 8 * 86400);
        assert_eq!(s.state()["queued"], 0);
        for n in 6..=8 {
            s.apply(ev(n, 2000 + n), 2000);
        }
        s.set_limits(7, 1);
        assert_eq!(ns(&s.queue(None, 50).unwrap()), [8]);
    }

    #[test]
    fn a_huge_keep_days_keeps_everything() {
        let mut s = Store::new(u64::MAX, 1000);
        s.apply(ev(1, 1000), 1000);
        s.expire(u64::MAX);
        assert_eq!(s.state()["queued"], 1);
    }

    #[test]
    fn a_silent_device_goes_after_30_days() {
        let mut s = Store::new(100, 1000);
        s.apply(ev(1, 1000), 1000);
        s.expire(1000 + 29 * 86400);
        assert_eq!(s.state()["devices"].as_array().unwrap().len(), 1);
        s.expire(1000 + 31 * 86400);
        assert_eq!(s.state()["devices"], json!([]));
        assert_eq!(s.state()["queued"], 1);
    }

    #[test]
    fn pages_go_back_by_cursor() {
        let mut s = st();
        for n in 1..=5 {
            s.apply(ev(n, 1000 + n), 1000);
        }
        let p1 = s.queue(None, 2).unwrap();
        assert_eq!((ns(&p1), p1["more"].clone()), (vec![5, 4], json!(true)));
        let cur = p1["events"][1]["eid"].as_str().unwrap().to_string();
        let p2 = s.queue(Some(&cur), 2).unwrap();
        assert_eq!((ns(&p2), p2["more"].clone()), (vec![3, 2], json!(true)));
        let cur = p2["events"][1]["eid"].as_str().unwrap().to_string();
        let p3 = s.queue(Some(&cur), 2).unwrap();
        assert_eq!((ns(&p3), p3["more"].clone()), (vec![1], json!(false)));
        assert_eq!(s.queue(Some("x:y:9"), 2).unwrap_err(), "bad cursor");
    }

    #[test]
    fn same_second_keeps_arrival_order() {
        let mut s = st();
        s.apply(ev(2, 100), 100);
        s.apply(ev(3, 100), 100);
        s.apply(ev(4, 99), 100);
        assert_eq!(ns(&s.queue(None, 50).unwrap()), [3, 2, 4]);
    }

    #[test]
    fn the_store_survives_a_json_round_trip() {
        let mut s = st();
        feed(&mut s, MIXED, 6);
        let back: Store = serde_json::from_str(&serde_json::to_string(&s).unwrap()).unwrap();
        assert_eq!(back.state(), s.state());
        assert_eq!(back.queue(None, 50).unwrap(), s.queue(None, 50).unwrap());
    }
}
