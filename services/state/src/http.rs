use std::convert::Infallible;

use std::path::PathBuf;
use std::pin::Pin;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::task::{Context, Poll};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use http_body_util::combinators::BoxBody;
use http_body_util::{BodyExt, Full, Limited};
use hyper::body::{Bytes, Frame, Incoming};
use hyper::server::conn::http1;
use hyper::service::service_fn;
use hyper::{Method, Request, Response, StatusCode};
use hyper_util::rt::TokioIo;
use serde_json::{json, Value};
use tokio::net::TcpListener;
use tokio::sync::broadcast::error::RecvError;
use tokio::sync::{broadcast, mpsc, Notify};

use crate::disk;
use crate::event::parse_line;
use crate::store::{Look, Store};
use crate::{Config, Log};

type Body = BoxBody<Bytes, Infallible>;

fn reply(status: StatusCode, body: Value) -> Response<Body> {
    Response::builder()
        .status(status)
        .header("content-type", "application/json")
        .body(Full::new(Bytes::from(body.to_string())).boxed())
        .expect("static response parts are valid")
}

const MAX_BODY: usize = 256 * 1024;
const MAX_EVENTS: usize = 50;
const SAVE_AFTER: Duration = Duration::from_secs(1);
const EXPIRE_EVERY: Duration = Duration::from_secs(600);
/// After a failed accept, the next one is tried this much later.
const ACCEPT_PAUSE: Duration = Duration::from_millis(100);
/// A watcher further behind than this many changes is hung up on; it refetches on reconnect.
const WATCH_BACKLOG: usize = 256;
const PING_EVERY: Duration = Duration::from_secs(15);
const HELLO: &[u8] = b"data: {\"what\":\"hello\"}\n\n";
const PING: &[u8] = b": ping\n\n";

type Shared = Arc<Mutex<Store>>;

/// What every request handler shares.
#[derive(Clone)]
struct Ctx {
    store: Shared,
    dirty: Dirty,
    log: Log,
    /// Each change from the store, as one line of JSON.
    changes: broadcast::Sender<String>,
    watching: Arc<AtomicUsize>,
}

impl Ctx {
    /// Sends what the store gathered to every watcher. It takes the locked store on purpose:
    /// published under the lock, changes reach watchers in the order the store made them (a
    /// `session` row or the `need` list is whole and unordered, so a late older one would
    /// overwrite a newer one). `send` never waits, so this holds the lock only briefly.
    fn publish(&self, st: &mut Store) {
        for c in st.take_changes() {
            // No watcher is fine: the change is in the store anyway.
            let _ = self.changes.send(c.to_string());
        }
    }
}

/// The one place the store is built: loaded from `cfg.data` when set, with this run's limits.
fn make_store(cfg: &Config, log: &Log) -> Store {
    let loaded = cfg.data.as_deref().and_then(|dir| {
        let (store, why) = disk::load(dir);
        if let Some(kind) = why {
            log.emit("load_failed", json!({"kind": kind}));
        }
        store
    });
    match loaded {
        Some(mut st) => {
            st.set_limits(cfg.keep_days, cfg.keep_events);
            st.expire(now());
            st.take_changes(); // nobody watches yet
            st
        }
        None => Store::new(cfg.keep_days, cfg.keep_events),
    }
}

/// Wakes the saver; `None` in memory mode.
type Dirty = Option<Arc<Notify>>;

fn mark(dirty: &Dirty) {
    if let Some(n) = dirty {
        n.notify_one();
    }
}

/// After a change, wait 1 s (batching further changes), then save a snapshot.
async fn saver(store: Shared, dir: PathBuf, notify: Arc<Notify>, log: Log) {
    loop {
        notify.notified().await;
        tokio::time::sleep(SAVE_AFTER).await;
        let json = serde_json::to_vec(&*lock(&store));
        let written = match json {
            Ok(j) => disk::write_bytes(&dir, &j),
            Err(e) => Err(std::io::Error::other(e)),
        };
        match written {
            Ok(bytes) => log.emit("saved", json!({"bytes": bytes})),
            Err(e) => log.emit("save_failed", json!({"kind": format!("{:?}", e.kind())})),
        }
    }
}

fn now() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)
}

fn lock(store: &Shared) -> std::sync::MutexGuard<'_, Store> {
    store.lock().unwrap_or_else(|e| e.into_inner())
}

fn rejected(log: &Log, status: StatusCode, count: usize, msg: &str) -> Response<Body> {
    log.emit("rejected", json!({"status": status.as_u16(), "count": count}));
    reply(status, json!({"error": msg}))
}

async fn post_events(cx: &Ctx, req: Request<Incoming>) -> Response<Body> {
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
        let mut st = lock(&cx.store);
        let t = now();
        for ev in events {
            st.expire(t);
            if st.apply(ev, t) {
                accepted += 1;
            } else {
                dup += 1;
            }
        }
        cx.publish(&mut st);
    }
    if accepted > 0 {
        mark(&cx.dirty);
    }
    log.emit("events", json!({"from": from, "accepted": accepted, "dup": dup}));
    no_content()
}

fn get_queue(store: &Shared, query: Option<&str>) -> Response<Body> {
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
    match lock(store).queue(before, limit) {
        Ok(v) => reply(StatusCode::OK, v),
        Err(e) => reply(StatusCode::BAD_REQUEST, json!({"error": e})),
    }
}

fn no_content() -> Response<Body> {
    Response::builder()
        .status(StatusCode::NO_CONTENT)
        .body(Full::new(Bytes::new()).boxed())
        .expect("static response parts are valid")
}

async fn put_seen(cx: &Ctx, req: Request<Incoming>) -> Response<Body> {
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
        let mut st = lock(&cx.store);
        let r = st.mark_seen(look, handled, now());
        cx.publish(&mut st);
        r
    };
    match result {
        Ok(()) => {
            mark(&cx.dirty);
            cx.log.emit("seen", json!({"by": by}));
            no_content()
        }
        Err(e) => reply(StatusCode::NOT_FOUND, json!({"error": e})),
    }
}

/// The body of a `GET /v1/watch` reply: whatever its watcher task sends, until that task ends.
struct SseBody(mpsc::Receiver<Bytes>);

impl hyper::body::Body for SseBody {
    type Data = Bytes;
    type Error = Infallible;

    fn poll_frame(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Option<Result<Frame<Bytes>, Infallible>>> {
        self.0.poll_recv(cx).map(|b| b.map(|b| Ok(Frame::data(b))))
    }
}

fn get_watch(cx: &Ctx) -> Response<Body> {
    // Subscribed before the reply goes out, so no change between the two is missed.
    let changes = cx.changes.subscribe();
    let (out, body) = mpsc::channel(16);
    let n = cx.watching.fetch_add(1, Ordering::SeqCst) + 1;
    cx.log.emit("watch_open", json!({"watching": n}));
    tokio::spawn(watcher(changes, out, cx.watching.clone(), cx.log.clone()));
    Response::builder()
        .header("content-type", "text/event-stream")
        .header("cache-control", "no-cache")
        .body(SseBody(body).boxed())
        .expect("static response parts are valid")
}

/// Feeds one watch reply: hello, then each change and a ping every 15 s. It ends when the
/// client is gone (the reply body dropped), when it falls behind, or when the service stops.
async fn watcher(mut changes: broadcast::Receiver<String>, out: mpsc::Sender<Bytes>, watching: Arc<AtomicUsize>, log: Log) {
    let mut lagged = false;
    if out.send(Bytes::from_static(HELLO)).await.is_ok() {
        let mut ping = tokio::time::interval_at(tokio::time::Instant::now() + PING_EVERY, PING_EVERY);
        ping.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        loop {
            let frame = tokio::select! {
                c = changes.recv() => match c {
                    Ok(c) => Bytes::from(format!("data: {c}\n\n")),
                    Err(RecvError::Lagged(_)) => {
                        lagged = true;
                        break;
                    }
                    Err(RecvError::Closed) => break,
                },
                _ = ping.tick() => Bytes::from_static(PING),
                _ = out.closed() => break,
            };
            if out.send(frame).await.is_err() {
                break;
            }
        }
    }
    let n = watching.fetch_sub(1, Ordering::SeqCst) - 1;
    log.emit("watch_closed", json!({"watching": n, "lagged": lagged}));
}

const FP_MAX: usize = 128;

async fn put_desk(cx: &Ctx, fp: &str, req: Request<Incoming>) -> Response<Body> {
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
        let mut st = lock(&cx.store);
        let r = st.put_desk(fp, &v, now());
        cx.publish(&mut st);
        r
    };
    match result {
        Ok(()) => {
            mark(&cx.dirty);
            let n = v.get("sessions").and_then(Value::as_array).map_or(0, Vec::len);
            cx.log.emit("desk", json!({"fp": fp, "sessions": n}));
            no_content()
        }
        Err(_) => bad(),
    }
}

async fn route(cx: &Ctx, req: Request<Incoming>) -> Response<Body> {
    let path = req.uri().path().to_string();
    if let Some(fp) = path.strip_prefix("/v1/desk/") {
        if req.method() != Method::PUT {
            return reply(StatusCode::METHOD_NOT_ALLOWED, json!({"error": "method not allowed"}));
        }
        return put_desk(cx, fp, req).await;
    }
    let allowed = match path.as_str() {
        "/v1/health" | "/v1/state" | "/v1/queue" | "/v1/watch" => &Method::GET,
        "/v1/events" => &Method::POST,
        "/v1/seen" => &Method::PUT,
        _ => return reply(StatusCode::NOT_FOUND, json!({"error": "not found"})),
    };
    if req.method() != allowed {
        return reply(StatusCode::METHOD_NOT_ALLOWED, json!({"error": "method not allowed"}));
    }
    match path.as_str() {
        "/v1/health" => reply(StatusCode::OK, json!({"name": "rapp-state", "v": 1})),
        "/v1/state" => reply(StatusCode::OK, lock(&cx.store).state()),
        "/v1/queue" => get_queue(&cx.store, req.uri().query()),
        "/v1/watch" => get_watch(cx),
        "/v1/seen" => put_seen(cx, req).await,
        _ => post_events(cx, req).await,
    }
}

pub async fn serve(cfg: Config, listener: TcpListener) -> anyhow::Result<()> {
    serve_with_log(cfg, listener, Log::stderr()).await
}

pub async fn serve_with_log(cfg: Config, listener: TcpListener, log: Log) -> anyhow::Result<()> {
    let store: Shared = Arc::new(Mutex::new(make_store(&cfg, &log)));
    let dirty: Dirty = cfg.data.as_ref().map(|_| Arc::new(Notify::new()));
    // Every task this spawns ends with it, also when the caller drops (aborts) it: a stopped
    // service must not go on answering, sweeping or saving its old store over a newer one's.
    let _saver = match (&cfg.data, &dirty) {
        (Some(dir), Some(n)) => {
            mark(&dirty); // the load may have expired rows
            Some(Ends(tokio::spawn(saver(store.clone(), dir.clone(), n.clone(), log.clone()))))
        }
        _ => None,
    };
    let (changes, _) = broadcast::channel(WATCH_BACKLOG);
    let cx = Ctx { store, dirty, log, changes, watching: Arc::default() };
    let sweeper = cx.clone();
    let _sweeper = Ends(tokio::spawn(async move {
        let mut tick = tokio::time::interval(EXPIRE_EVERY);
        loop {
            tick.tick().await;
            {
                let mut st = lock(&sweeper.store);
                st.expire(now());
                sweeper.publish(&mut st);
            }
            mark(&sweeper.dirty);
        }
    }));
    accept_loop(cx, listener).await
}

/// A spawned task that is aborted when this is dropped.
struct Ends(tokio::task::JoinHandle<()>);

impl Drop for Ends {
    fn drop(&mut self) {
        self.0.abort();
    }
}

async fn accept_loop(cx: Ctx, listener: TcpListener) -> anyhow::Result<()> {
    // Dropped with the loop: every open connection is then aborted.
    let mut conns = tokio::task::JoinSet::new();
    loop {
        let accepted = tokio::select! {
            accepted = listener.accept() => accepted,
            // Reap the finished ones so the set does not grow.
            Some(_) = conns.join_next(), if !conns.is_empty() => continue,
        };
        // A failed accept (out of file descriptors, a connection reset before it was taken) is
        // for now only: the service keeps listening. Only an abort or a drop ends it.
        let stream = match accepted {
            Ok((stream, _)) => stream,
            Err(e) => {
                cx.log.emit("accept_failed", json!({"kind": format!("{:?}", e.kind())}));
                tokio::time::sleep(ACCEPT_PAUSE).await;
                continue;
            }
        };
        let cx = cx.clone();
        conns.spawn(async move {
            let svc = service_fn(move |req| {
                let cx = cx.clone();
                async move { Ok::<_, Infallible>(route(&cx, req).await) }
            });
            let _ = http1::Builder::new().serve_connection(TokioIo::new(stream), svc).await;
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn a_watcher_that_falls_behind_is_hung_up_on() {
        let (tx, sub) = broadcast::channel(WATCH_BACKLOG);
        for i in 0..=WATCH_BACKLOG {
            tx.send(i.to_string()).unwrap();
        }
        drop(tx);
        let lines: Arc<Mutex<Vec<Value>>> = Arc::default();
        let sink = lines.clone();
        let log = Log::new(move |v| sink.lock().unwrap().push(v.clone()));
        let (out, mut body) = mpsc::channel(16);
        let task = tokio::spawn(watcher(sub, out, Arc::new(AtomicUsize::new(1)), log));
        let mut frames = vec![];
        while let Ok(Some(f)) = tokio::time::timeout(Duration::from_secs(2), body.recv()).await {
            frames.push(f);
        }
        assert_eq!(frames, [Bytes::from_static(HELLO)]);
        task.await.unwrap();
        let last = lines.lock().unwrap().last().cloned().unwrap();
        assert_eq!((last["event"].as_str(), last["watching"].as_u64(), last["lagged"].as_bool()), (Some("watch_closed"), Some(0), Some(true)));
    }
}
