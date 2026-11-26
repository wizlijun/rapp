use std::convert::Infallible;

use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use http_body_util::{BodyExt, Full, Limited};
use hyper::body::{Bytes, Incoming};
use hyper::server::conn::http1;
use hyper::service::service_fn;
use hyper::{Method, Request, Response, StatusCode};
use hyper_util::rt::TokioIo;
use serde_json::{json, Value};
use tokio::net::TcpListener;

use crate::event::parse_line;
use crate::store::Store;
use crate::{Config, Log};

fn reply(status: StatusCode, body: Value) -> Response<Full<Bytes>> {
    Response::builder()
        .status(status)
        .header("content-type", "application/json")
        .body(Full::new(Bytes::from(body.to_string())))
        .expect("static response parts are valid")
}

const MAX_BODY: usize = 256 * 1024;
const MAX_EVENTS: usize = 50;
const EXPIRE_EVERY: Duration = Duration::from_secs(600);

type Shared = Arc<Mutex<Store>>;

/// The one place the store is built; Task 4 swaps in loading from disk.
fn make_store(cfg: &Config) -> Store {
    Store::new(cfg.keep_days, cfg.keep_events)
}

fn now() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)
}

fn lock(store: &Shared) -> std::sync::MutexGuard<'_, Store> {
    store.lock().unwrap_or_else(|e| e.into_inner())
}

fn rejected(log: &Log, status: StatusCode, count: usize, msg: &str) -> Response<Full<Bytes>> {
    log.emit("rejected", json!({"status": status.as_u16(), "count": count}));
    reply(status, json!({"error": msg}))
}

async fn post_events(store: &Shared, log: &Log, req: Request<Incoming>) -> Response<Full<Bytes>> {
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
        let mut st = lock(store);
        let t = now();
        for ev in events {
            st.expire(t);
            if st.apply(ev, t) {
                accepted += 1;
            } else {
                dup += 1;
            }
        }
    }
    log.emit("events", json!({"from": from, "accepted": accepted, "dup": dup}));
    Response::builder().status(StatusCode::NO_CONTENT).body(Full::new(Bytes::new())).expect("static response parts are valid")
}

fn get_queue(store: &Shared, query: Option<&str>) -> Response<Full<Bytes>> {
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

async fn route(store: &Shared, log: &Log, req: Request<Incoming>) -> Response<Full<Bytes>> {
    let path = req.uri().path().to_string();
    let allowed = match path.as_str() {
        "/v1/health" | "/v1/state" | "/v1/queue" => &Method::GET,
        "/v1/events" => &Method::POST,
        _ => return reply(StatusCode::NOT_FOUND, json!({"error": "not found"})),
    };
    if req.method() != allowed {
        return reply(StatusCode::METHOD_NOT_ALLOWED, json!({"error": "method not allowed"}));
    }
    match path.as_str() {
        "/v1/health" => reply(StatusCode::OK, json!({"name": "rapp-state", "v": 1})),
        "/v1/state" => reply(StatusCode::OK, lock(store).state()),
        "/v1/queue" => get_queue(store, req.uri().query()),
        _ => post_events(store, log, req).await,
    }
}

pub async fn serve(cfg: Config, listener: TcpListener) -> anyhow::Result<()> {
    serve_with_log(cfg, listener, Log::stderr()).await
}

pub async fn serve_with_log(cfg: Config, listener: TcpListener, log: Log) -> anyhow::Result<()> {
    let store: Shared = Arc::new(Mutex::new(make_store(&cfg)));
    let sweeper = store.clone();
    let task = tokio::spawn(async move {
        let mut tick = tokio::time::interval(EXPIRE_EVERY);
        loop {
            tick.tick().await;
            lock(&sweeper).expire(now());
        }
    });
    let result = accept_loop(store, log, listener).await;
    task.abort();
    result
}

async fn accept_loop(store: Shared, log: Log, listener: TcpListener) -> anyhow::Result<()> {
    loop {
        let (stream, _) = listener.accept().await?;
        let (store, log) = (store.clone(), log.clone());
        tokio::spawn(async move {
            let svc = service_fn(move |req| {
                let (store, log) = (store.clone(), log.clone());
                async move { Ok::<_, Infallible>(route(&store, &log, req).await) }
            });
            let _ = http1::Builder::new().serve_connection(TokioIo::new(stream), svc).await;
        });
    }
}
