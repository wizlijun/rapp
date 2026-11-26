//! Talking to the state service: HTTP/1.1 over a dialled pipe, a health check, then posts.

use http_body_util::{BodyExt, Full, Limited};
use hyper::body::Bytes;
use hyper::client::conn::http1::{self, SendRequest};
use hyper::header::{CONTENT_TYPE, HOST};
use hyper::{Method, Request};
use hyper_util::rt::TokioIo;
use serde_json::Value;
use std::future::Future;

/// The most of a reply body read (and thrown away, except for the health check).
const REPLY_MAX: usize = 64 * 1024;

/// Why there is no pipe to the state service.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DialErr {
    /// The other side says it has no such share: forget the service.
    Gone,
    /// Not now (`offline`, `refused`, `io`…); the kind is only for the log.
    Down(&'static str),
}

/// Opens a pipe to the state service.
pub trait Dial: Send + Sync {
    fn dial(&self) -> impl Future<Output = Result<rapp_conn::Pipe, DialErr>> + Send;
}

/// One HTTP/1.1 connection to a checked state service.
pub struct Conn {
    tx: SendRequest<Full<Bytes>>,
}

/// What the service said to a post.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Posted {
    /// 2xx: the service has the lines.
    Taken,
    /// 4xx: the service will not take this batch; it is not sent again.
    Refused(u16),
}

/// HTTP/1.1 handshake, then `GET /v1/health`: it must be 200 with `name == "rapp-state"`.
pub async fn connect(io: rapp_conn::Pipe) -> Result<Conn, &'static str> {
    let (tx, conn) = http1::handshake(TokioIo::new(io)).await.map_err(|_| "io")?;
    tokio::spawn(async move {
        let _ = conn.await;
    });
    let mut c = Conn { tx };
    let (status, body) = c.ask(Method::GET, "/v1/health", Bytes::new()).await?;
    let name = serde_json::from_slice::<Value>(&body).ok().and_then(|v| v["name"].as_str().map(str::to_owned));
    if status != 200 || name.as_deref() != Some("rapp-state") {
        return Err("not rapp-state");
    }
    Ok(c)
}

impl Conn {
    /// `POST /v1/events`, one line per event: 2xx → `Taken`, 4xx → `Refused`, 5xx and I/O errors → `Err`.
    pub async fn post(&mut self, lines: &[Value]) -> Result<Posted, &'static str> {
        let mut body = String::new();
        for l in lines {
            body.push_str(&l.to_string());
            body.push('\n');
        }
        let (status, _) = self.ask(Method::POST, "/v1/events", Bytes::from(body)).await?;
        match status {
            200..=299 => Ok(Posted::Taken),
            400..=499 => Ok(Posted::Refused(status)),
            _ => Err("status"),
        }
    }

    /// `GET path`: the status and up to `max` bytes of the body (more is an error).
    pub async fn get(&mut self, path: &str, max: usize) -> Result<(u16, Bytes), &'static str> {
        self.ask_up_to(Method::GET, path, Bytes::new(), max).await
    }

    /// One request; the status and up to [`REPLY_MAX`] of the body (read to the end so the
    /// connection can carry the next request).
    async fn ask(&mut self, method: Method, path: &str, body: Bytes) -> Result<(u16, Bytes), &'static str> {
        self.ask_up_to(method, path, body, REPLY_MAX).await
    }

    async fn ask_up_to(&mut self, method: Method, path: &str, body: Bytes, max: usize) -> Result<(u16, Bytes), &'static str> {
        let req = Request::builder()
            .method(method)
            .uri(path)
            .header(HOST, "rapp-state")
            .header(CONTENT_TYPE, "application/x-ndjson")
            .body(Full::new(body))
            .map_err(|_| "io")?;
        self.tx.ready().await.map_err(|_| "io")?;
        let res = self.tx.send_request(req).await.map_err(|_| "io")?;
        let status = res.status().as_u16();
        let body = Limited::new(res.into_body(), max).collect().await.map_err(|_| "io")?.to_bytes();
        Ok((status, body))
    }
}

/// A fake state service for the tests: hyper over `tokio::io::duplex`, recording every request.
#[cfg(test)]
pub(super) mod fake {
    use super::*;
    use hyper::body::Incoming;
    use hyper::service::service_fn;
    use hyper::{Response, StatusCode};
    use std::collections::VecDeque;
    use std::convert::Infallible;
    use std::sync::{Arc, Mutex};
    use tokio::sync::watch;

    /// One `POST /v1/events` as the service saw it.
    #[derive(Clone, Debug)]
    pub struct Got {
        pub status: u16,
        pub lines: Vec<Value>,
    }

    pub struct Rules {
        /// What `/v1/health` says its name is.
        pub name: &'static str,
        /// Statuses for the next posts, in order; 204 after them.
        pub statuses: VecDeque<u16>,
        /// Posts get 503 while this is on.
        pub down: bool,
    }

    pub struct Fake {
        pub rules: Mutex<Rules>,
        pub got: Mutex<Vec<Got>>,
        tick: watch::Sender<usize>,
        /// While on, a post is recorded but its reply waits.
        hold: watch::Sender<bool>,
    }

    impl Fake {
        pub fn new(name: &'static str) -> Arc<Fake> {
            Arc::new(Fake {
                rules: Mutex::new(Rules { name, statuses: VecDeque::new(), down: false }),
                got: Mutex::new(vec![]),
                tick: watch::channel(0).0,
                hold: watch::channel(false).0,
            })
        }

        /// Hold the replies to posts (each post is still recorded when it comes), or let them go.
        pub fn hold(&self, on: bool) {
            self.hold.send_replace(on);
        }

        /// One end of a fresh pipe; the other end is served by this fake.
        pub fn pipe(self: &Arc<Self>) -> rapp_conn::Pipe {
            let (a, b) = tokio::io::duplex(1 << 20);
            let me = self.clone();
            tokio::spawn(async move {
                let svc = service_fn(move |req| {
                    let me = me.clone();
                    async move { Ok::<_, Infallible>(me.answer(req).await) }
                });
                let _ = hyper::server::conn::http1::Builder::new().serve_connection(TokioIo::new(b), svc).await;
            });
            Box::new(a)
        }

        async fn answer(&self, req: Request<Incoming>) -> Response<Full<Bytes>> {
            let (head, body) = req.into_parts();
            let body = body.collect().await.map(|b| b.to_bytes()).unwrap_or_default();
            let reply = |status: u16, text: String| {
                Response::builder().status(StatusCode::from_u16(status).unwrap()).body(Full::new(Bytes::from(text))).unwrap()
            };
            if head.method == Method::GET && head.uri.path() == "/v1/health" {
                let name = self.rules.lock().unwrap().name;
                return reply(200, serde_json::json!({"name": name, "v": 1}).to_string());
            }
            assert_eq!(head.method, Method::POST);
            assert_eq!(head.uri.path(), "/v1/events");
            assert_eq!(head.headers[HOST], "rapp-state");
            assert_eq!(head.headers[CONTENT_TYPE], "application/x-ndjson");
            let lines: Vec<Value> = String::from_utf8(body.to_vec())
                .unwrap()
                .lines()
                .map(|l| serde_json::from_str(l).unwrap())
                .collect();
            let status = {
                let mut r = self.rules.lock().unwrap();
                if r.down {
                    503
                } else {
                    r.statuses.pop_front().unwrap_or(204)
                }
            };
            self.got.lock().unwrap().push(Got { status, lines });
            self.tick.send_modify(|n| *n += 1);
            let _ = self.hold.subscribe().wait_for(|h| !*h).await;
            reply(status, if status == 204 { String::new() } else { "{\"error\":\"no\"}".into() })
        }

        /// Wait until what the service got satisfies `f`; a test that would wait forever fails
        /// instead (under the paused clock the hour passes as soon as everything is idle).
        pub async fn until(&self, f: impl Fn(&[Got]) -> bool) {
            let mut rx = self.tick.subscribe();
            let wait = rx.wait_for(|_| f(&self.got.lock().unwrap()));
            let got = tokio::time::timeout(std::time::Duration::from_secs(3600), wait).await;
            assert!(got.is_ok(), "the service never got it: {:?}", self.got.lock().unwrap());
        }

        /// Every line the service took (2xx), in order.
        pub fn taken(&self) -> Vec<Value> {
            self.got.lock().unwrap().iter().filter(|g| g.status / 100 == 2).flat_map(|g| g.lines.clone()).collect()
        }
    }
}

#[cfg(test)]
mod tests {
    use super::fake::Fake;
    use super::*;
    use serde_json::json;

    #[tokio::test]
    async fn health_must_say_rapp_state() {
        let other = Fake::new("other");
        assert_eq!(connect(other.pipe()).await.err(), Some("not rapp-state"));
        let state = Fake::new("rapp-state");
        let mut c = connect(state.pipe()).await.unwrap();
        assert_eq!(c.post(&[json!({"n":1}), json!({"n":2})]).await, Ok(Posted::Taken));
        state.rules.lock().unwrap().statuses.extend([400, 500]);
        assert_eq!(c.post(&[json!({"n":3})]).await, Ok(Posted::Refused(400)));
        assert!(c.post(&[json!({"n":4})]).await.is_err());
        let got = state.got.lock().unwrap().clone();
        assert_eq!(got.len(), 3);
        assert_eq!(got[0].lines, vec![json!({"n":1}), json!({"n":2})]);
    }
}
