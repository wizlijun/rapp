//! The entry: one listener, the paths every builtin shares (`/v1/health`, `/v1/watch`), and each
//! builtin's loading, saving and background work.

use std::convert::Infallible;
use std::path::{Path, PathBuf};
use std::pin::Pin;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use std::task::{Context, Poll};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use http_body_util::combinators::BoxBody;
use http_body_util::{BodyExt, Full};
use hyper::body::{Bytes, Frame, Incoming};
use hyper::server::conn::http1;
use hyper::service::service_fn;
use hyper::{Method, Request, Response, StatusCode};
use hyper_util::rt::TokioIo;
use serde_json::{json, Value};
use tokio::net::TcpListener;
use tokio::sync::broadcast::error::RecvError;
use tokio::sync::{broadcast, mpsc, Notify};

use crate::builtin::{self, Builtin};
use crate::disk;
use crate::{Config, Log};

pub(crate) type Body = BoxBody<Bytes, Infallible>;

pub(crate) fn reply(status: StatusCode, body: Value) -> Response<Body> {
    Response::builder()
        .status(status)
        .header("content-type", "application/json")
        .body(Full::new(Bytes::from(body.to_string())).boxed())
        .expect("static response parts are valid")
}

pub(crate) fn now() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)
}

const SAVE_AFTER: Duration = Duration::from_secs(1);
/// After a failed accept, the next one is tried this much later.
const ACCEPT_PAUSE: Duration = Duration::from_millis(100);
/// A watcher further behind than this many changes is hung up on; it refetches on reconnect.
const WATCH_BACKLOG: usize = 256;
const PING_EVERY: Duration = Duration::from_secs(15);
const HELLO: &[u8] = b"data: {\"what\":\"hello\"}\n\n";
const PING: &[u8] = b": ping\n\n";

/// Wakes a builtin's saver; `None` in memory mode.
type Dirty = Option<Arc<Notify>>;

/// What a builtin gets: the log, the changes and the watcher count are shared by all of them;
/// `dirty` is its own.
#[derive(Clone)]
pub(crate) struct Ctx {
    pub log: Log,
    /// Each change, as one line of JSON.
    changes: broadcast::Sender<String>,
    watching: Arc<AtomicUsize>,
    dirty: Dirty,
}

impl Ctx {
    /// Sends changes to every watcher. Callers call it under their own lock on purpose: published
    /// under the lock, changes reach watchers in the order they were made (a `session` row or the
    /// `need` list is whole and unordered, so a late older one would overwrite a newer one).
    /// `send` never waits, so the lock is held only briefly.
    pub fn publish(&self, changes: impl IntoIterator<Item = Value>) {
        for c in changes {
            // No watcher is fine: the change is kept by the builtin anyway.
            let _ = self.changes.send(c.to_string());
        }
    }

    /// Something changed that should be saved.
    pub fn mark(&self) {
        if let Some(n) = &self.dirty {
            n.notify_one();
        }
    }
}

/// After a change, wait 1 s (batching further changes), then save a snapshot of the builtin.
async fn saver(b: Arc<dyn Builtin>, dir: PathBuf, notify: Arc<Notify>, log: Log) {
    loop {
        notify.notified().await;
        tokio::time::sleep(SAVE_AFTER).await;
        let written = match b.save() {
            Ok(j) => disk::write(&dir, b.file(), &j),
            Err(e) => Err(std::io::Error::other(e)),
        };
        match written {
            Ok(bytes) => log.emit("saved", json!({"bytes": bytes})),
            Err(e) => log.emit("save_failed", json!({"kind": format!("{:?}", e.kind())})),
        }
    }
}

/// Takes back the builtin's file; one that cannot be read or loaded is moved aside.
fn load(b: &dyn Builtin, dir: &Path, log: &Log) {
    let why = match disk::read(dir, b.file()) {
        Ok(None) => return,
        Ok(Some(bytes)) => match b.load(&bytes) {
            Ok(()) => return,
            Err(why) => why,
        },
        Err(why) => why,
    };
    disk::move_aside(dir, b.file());
    log.emit("load_failed", json!({"kind": why}));
}

/// A spawned task that is aborted when this is dropped.
struct Ends(tokio::task::JoinHandle<()>);

impl Drop for Ends {
    fn drop(&mut self) {
        self.0.abort();
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

/// A builtin with its own context.
struct Mounted {
    b: Arc<dyn Builtin>,
    cx: Ctx,
}

/// Every builtin and the entry's own context (shared log, changes and watchers; no `dirty`).
struct Entry {
    cx: Ctx,
    blocks: Vec<Mounted>,
}

async fn route(e: &Entry, req: Request<Incoming>) -> Response<Body> {
    let path = req.uri().path().to_string();
    let entry_path = matches!(path.as_str(), "/v1/health" | "/v1/watch");
    if entry_path {
        if req.method() != Method::GET {
            return reply(StatusCode::METHOD_NOT_ALLOWED, json!({"error": "method not allowed"}));
        }
        return match path.as_str() {
            "/v1/health" => reply(StatusCode::OK, json!({"name": "rapp-state", "v": 1})),
            _ => get_watch(&e.cx),
        };
    }
    match e.blocks.iter().find(|m| m.b.name() == "state") {
        Some(m) => m.b.handle(&m.cx, req, &path).await,
        None => reply(StatusCode::NOT_FOUND, json!({"error": "not found"})),
    }
}

pub async fn serve(cfg: Config, listener: TcpListener) -> anyhow::Result<()> {
    serve_with_log(cfg, listener, Log::stderr()).await
}

pub async fn serve_with_log(cfg: Config, listener: TcpListener, log: Log) -> anyhow::Result<()> {
    let (changes, _) = broadcast::channel(WATCH_BACKLOG);
    let base = Ctx { log: log.clone(), changes, watching: Arc::default(), dirty: None };
    // Every task this spawns ends with it, also when the caller drops (aborts) it: a stopped
    // service must not go on answering, sweeping or saving its old data over a newer one's.
    let mut tasks = Vec::new();
    let mut blocks = Vec::new();
    for b in builtin::table(&cfg) {
        let mut cx = base.clone();
        if let Some(dir) = &cfg.data {
            load(&*b, dir, &log);
            let n = Arc::new(Notify::new());
            cx.dirty = Some(n.clone());
            tasks.push(Ends(tokio::spawn(saver(b.clone(), dir.clone(), n, log.clone()))));
            cx.mark(); // the load may have expired rows
        }
        if let Some(t) = b.clone().spawn(cx.clone()) {
            tasks.push(Ends(t));
        }
        blocks.push(Mounted { b, cx });
    }
    let _tasks = tasks;
    accept_loop(Arc::new(Entry { cx: base, blocks }), listener).await
}

async fn accept_loop(e: Arc<Entry>, listener: TcpListener) -> anyhow::Result<()> {
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
            Err(err) => {
                e.cx.log.emit("accept_failed", json!({"kind": format!("{:?}", err.kind())}));
                tokio::time::sleep(ACCEPT_PAUSE).await;
                continue;
            }
        };
        let e = e.clone();
        conns.spawn(async move {
            let svc = service_fn(move |req| {
                let e = e.clone();
                async move { Ok::<_, Infallible>(route(&e, req).await) }
            });
            let _ = http1::Builder::new().serve_connection(TokioIo::new(stream), svc).await;
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

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
