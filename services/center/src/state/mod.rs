//! The state queue, the first builtin: what each device's sessions are doing, the events queue
//! and "needs you". Its API is `api/http.md`; the rules are in `api/events.md`.

pub mod event;
pub mod store;

use std::sync::{Arc, Mutex, MutexGuard};
use std::time::Duration;

use http_body_util::{BodyExt, Full, Limited};
use hyper::body::{Bytes, Incoming};
use hyper::{Method, Request, Response, StatusCode};
use serde_json::{json, Value};
use tokio::task::JoinHandle;

use crate::builtin::{Builtin, Fut};
use crate::entry::{now, reply, Body, Ctx};
use crate::Log;
use event::parse_line;
use store::{Look, Store};

const MAX_BODY: usize = 256 * 1024;
const MAX_EVENTS: usize = 50;
const EXPIRE_EVERY: Duration = Duration::from_secs(600);
const FP_MAX: usize = 128;

pub(crate) struct StateBlock {
    store: Mutex<Store>,
    keep_days: u64,
    keep_events: usize,
}

impl StateBlock {
    pub(crate) fn new(keep_days: u64, keep_events: usize) -> StateBlock {
        StateBlock { store: Mutex::new(Store::new(keep_days, keep_events)), keep_days, keep_events }
    }

    fn lock(&self) -> MutexGuard<'_, Store> {
        self.store.lock().unwrap_or_else(|e| e.into_inner())
    }
}

impl Builtin for StateBlock {
    fn name(&self) -> &'static str {
        "state"
    }

    fn version(&self) -> u32 {
        1
    }

    fn file(&self) -> &'static str {
        "state.json"
    }

    fn handle<'a>(&'a self, cx: &'a Ctx, req: Request<Incoming>, rest: &'a str) -> Fut<'a> {
        Box::pin(self.route(cx, req, rest))
    }

    fn save(&self) -> serde_json::Result<Vec<u8>> {
        serde_json::to_vec(&*self.lock())
    }

    /// With this run's limits, and what has expired since the save dropped.
    fn load(&self, bytes: &[u8]) -> Result<(), String> {
        let mut st = serde_json::from_slice::<Store>(bytes).map_err(|_| "parse".to_string())?;
        st.set_limits(self.keep_days, self.keep_events);
        st.expire(now());
        st.take_changes(); // nobody watches yet
        *self.lock() = st;
        Ok(())
    }

    /// Expires old rows every 10 minutes.
    fn spawn(self: Arc<Self>, cx: Ctx) -> Option<JoinHandle<()>> {
        Some(tokio::spawn(async move {
            let mut tick = tokio::time::interval(EXPIRE_EVERY);
            loop {
                tick.tick().await;
                {
                    let mut st = self.lock();
                    st.expire(now());
                    cx.publish(st.take_changes());
                }
                cx.mark();
            }
        }))
    }
}

impl StateBlock {
    async fn route(&self, cx: &Ctx, req: Request<Incoming>, rest: &str) -> Response<Body> {
        if let Some(fp) = rest.strip_prefix("/v1/desk/") {
            if req.method() != Method::PUT {
                return reply(StatusCode::METHOD_NOT_ALLOWED, json!({"error": "method not allowed"}));
            }
            return self.put_desk(cx, fp, req).await;
        }
        let allowed = match rest {
            "/v1/state" | "/v1/queue" => &Method::GET,
            "/v1/events" => &Method::POST,
            "/v1/seen" => &Method::PUT,
            _ => return reply(StatusCode::NOT_FOUND, json!({"error": "not found"})),
        };
        if req.method() != allowed {
            return reply(StatusCode::METHOD_NOT_ALLOWED, json!({"error": "method not allowed"}));
        }
        match rest {
            "/v1/state" => reply(StatusCode::OK, self.lock().state()),
            "/v1/queue" => self.get_queue(req.uri().query()),
            "/v1/seen" => self.put_seen(cx, req).await,
            _ => self.post_events(cx, req).await,
        }
    }

    async fn post_events(&self, cx: &Ctx, req: Request<Incoming>) -> Response<Body> {
        let log = &cx.log;
        let too_many = |log: &Log| rejected(log, StatusCode::PAYLOAD_TOO_LARGE, 0, "too many events");
        let body = match Limited::new(req.into_body(), MAX_BODY).collect().await {
            Ok(b) => b.to_bytes(),
            Err(_) => return too_many(log),
        };
        let text = String::from_utf8_lossy(&body);
        let lines: Vec<(usize, &str)> =
            text.lines().enumerate().map(|(i, l)| (i + 1, l.trim())).filter(|(_, l)| !l.is_empty()).collect();
        if lines.len() > MAX_EVENTS {
            return rejected(log, StatusCode::PAYLOAD_TOO_LARGE, lines.len(), "too many events");
        }
        let mut events = Vec::with_capacity(lines.len());
        for (k, line) in &lines {
            match parse_line(line) {
                Ok(ev) => events.push(ev),
                Err(why) => {
                    return rejected(log, StatusCode::BAD_REQUEST, lines.len(), &format!("line {k}: {why}"));
                }
            }
        }
        let from: String = events.first().map(|e| e.sender.chars().take(8).collect()).unwrap_or_default();
        let (mut accepted, mut dup) = (0, 0);
        {
            let mut st = self.lock();
            let t = now();
            for ev in events {
                st.expire(t);
                if st.apply(ev, t) {
                    accepted += 1;
                } else {
                    dup += 1;
                }
            }
            cx.publish(st.take_changes());
        }
        if accepted > 0 {
            cx.mark();
        }
        log.emit("events", json!({"from": from, "accepted": accepted, "dup": dup}));
        no_content()
    }

    fn get_queue(&self, query: Option<&str>) -> Response<Body> {
        let mut before = None;
        let mut limit = 0usize;
        for pair in query.unwrap_or("").split('&').filter(|p| !p.is_empty()) {
            let (k, v) = pair.split_once('=').unwrap_or((pair, ""));
            match k {
                "before" => before = Some(v),
                "limit" => match v.parse() {
                    Ok(n) => limit = n,
                    Err(_) => return reply(StatusCode::BAD_REQUEST, json!({"error": "bad limit"})),
                },
                _ => {}
            }
        }
        match self.lock().queue(before, limit) {
            Ok(v) => reply(StatusCode::OK, v),
            Err(e) => reply(StatusCode::BAD_REQUEST, json!({"error": e})),
        }
    }

    async fn put_seen(&self, cx: &Ctx, req: Request<Incoming>) -> Response<Body> {
        let bad = || reply(StatusCode::BAD_REQUEST, json!({"error": "bad request"}));
        let body = match Limited::new(req.into_body(), MAX_BODY).collect().await {
            Ok(b) => b.to_bytes(),
            Err(_) => return bad(),
        };
        let Ok(v) = serde_json::from_slice::<Value>(&body) else { return bad() };
        let handled = v.get("handled").and_then(Value::as_bool).unwrap_or(false);
        let s = |k: &str| v.get(k).and_then(Value::as_str);
        let (look, by) = match (s("eid"), s("fp"), s("session")) {
            (Some(eid), _, _) => (Look::Eid(eid), "eid"),
            (None, Some(fp), Some(session)) => (Look::Session { fp, session }, "session"),
            _ => return bad(),
        };
        let result = {
            let mut st = self.lock();
            let r = st.mark_seen(look, handled, now());
            cx.publish(st.take_changes());
            r
        };
        match result {
            Ok(()) => {
                cx.mark();
                cx.log.emit("seen", json!({"by": by}));
                no_content()
            }
            Err(e) => reply(StatusCode::NOT_FOUND, json!({"error": e})),
        }
    }

    async fn put_desk(&self, cx: &Ctx, fp: &str, req: Request<Incoming>) -> Response<Body> {
        let bad = || reply(StatusCode::BAD_REQUEST, json!({"error": "bad request"}));
        if fp.is_empty() || fp.contains('/') || fp.chars().count() > FP_MAX {
            return bad();
        }
        let body = match Limited::new(req.into_body(), MAX_BODY).collect().await {
            Ok(b) => b.to_bytes(),
            Err(_) => return bad(),
        };
        let Ok(v) = serde_json::from_slice::<Value>(&body) else { return bad() };
        let result = {
            let mut st = self.lock();
            let r = st.put_desk(fp, &v, now());
            cx.publish(st.take_changes());
            r
        };
        match result {
            Ok(()) => {
                cx.mark();
                let n = v.get("sessions").and_then(Value::as_array).map_or(0, Vec::len);
                cx.log.emit("desk", json!({"fp": fp, "sessions": n}));
                no_content()
            }
            Err(_) => bad(),
        }
    }
}

fn rejected(log: &Log, status: StatusCode, count: usize, msg: &str) -> Response<Body> {
    log.emit("rejected", json!({"status": status.as_u16(), "count": count}));
    reply(status, json!({"error": msg}))
}

fn no_content() -> Response<Body> {
    Response::builder()
        .status(StatusCode::NO_CONTENT)
        .body(Full::new(Bytes::new()).boxed())
        .expect("static response parts are valid")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn filled() -> Store {
        let mut s = Store::new(100_000, 1000);
        for l in include_str!("../../api/samples/term-events.ndjson").lines().filter(|l| !l.trim().is_empty()) {
            s.apply(parse_line(l).unwrap(), now());
        }
        s
    }

    #[test]
    fn saved_and_loaded_are_the_same() {
        let mut s = filled();
        s.put_desk("appA", &json!({"device":"iPad","sessions":[{"id":"111111111","app":"x","name":"X"}]}), now()).unwrap();
        let saved = serde_json::to_vec(&s).unwrap();
        s.expire(now()); // the sample devices are old: loading expires them too
        let b = StateBlock::new(100_000, 1000);
        assert_eq!(b.load(&saved), Ok(()));
        assert_eq!(b.lock().state(), s.state());
        assert_eq!(b.lock().state()["desks"][0]["fp"], "appA");
        assert_eq!(b.lock().queue(None, 50).unwrap(), s.queue(None, 50).unwrap());
        assert_eq!(StateBlock::new(1, 1).save().unwrap(), serde_json::to_vec(&Store::new(1, 1)).unwrap());
    }

    #[test]
    fn an_old_file_without_desks_loads() {
        let mut v = serde_json::to_value(filled()).unwrap();
        assert!(v.as_object_mut().unwrap().remove("desks").is_some());
        let b = StateBlock::new(100_000, 1000);
        assert_eq!(b.load(v.to_string().as_bytes()), Ok(()));
        assert_eq!(b.lock().state()["desks"], json!([]));
    }

    #[test]
    fn a_broken_file_does_not_load() {
        let b = StateBlock::new(7, 1000);
        assert_eq!(b.load(b"{not json"), Err("parse".to_string()));
        assert_eq!(b.lock().state(), Store::new(7, 1000).state());
    }
}
