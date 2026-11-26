use std::net::SocketAddr;

use std::sync::{Arc, Mutex};
use std::time::Duration;

use rapp_state::{serve, serve_with_log, Config, Log};
use serde_json::{json, Value};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};

async fn start(cfg: Config) -> SocketAddr {
    let l = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = l.local_addr().unwrap();
    tokio::spawn(serve(cfg, l));
    addr
}

async fn get(addr: SocketAddr, path: &str) -> (u16, Value) {
    request(addr, "GET", path, "").await
}

async fn post(addr: SocketAddr, path: &str, body: &str) -> (u16, Value) {
    request(addr, "POST", path, body).await
}

async fn put(addr: SocketAddr, path: &str, body: &str) -> (u16, Option<Value>) {
    let (c, v) = request(addr, "PUT", path, body).await;
    (c, if v.is_null() { None } else { Some(v) })
}

async fn request(addr: SocketAddr, method: &str, path: &str, body: &str) -> (u16, Value) {
    let mut s = TcpStream::connect(addr).await.unwrap();
    let req = format!(
        "{method} {path} HTTP/1.1\r\nHost: x\r\nConnection: close\r\nContent-Length: {}\r\n\r\n{body}",
        body.len()
    );
    // The server may answer 413 and hang up before the whole body is sent.
    let _ = s.write_all(req.as_bytes()).await;
    let mut buf = Vec::new();
    let _ = s.read_to_end(&mut buf).await;
    let text = String::from_utf8(buf).unwrap();
    let (head, body) = text.split_once("\r\n\r\n").unwrap();
    let status = head.split_whitespace().nth(1).unwrap().parse().unwrap();
    (status, if body.is_empty() { Value::Null } else { serde_json::from_str(body).unwrap() })
}

#[tokio::test]
async fn health_says_who_it_is() {
    let addr = start(Config::default()).await;
    assert_eq!(get(addr, "/v1/health").await, (200, json!({"name":"rapp-state","v":1})));
    assert_eq!(get(addr, "/nope").await, (404, json!({"error":"not found"})));
}

/// The samples are dated 2025, so keep the queue far longer than 7 days.
fn old_ok() -> Config {
    Config { keep_days: 100_000, ..Config::default() }
}

const SAMPLES: &str = include_str!("../api/samples/term-events.ndjson");

#[tokio::test]
async fn posted_samples_show_in_state_and_queue() {
    let addr = start(old_ok()).await;
    assert_eq!(post(addr, "/v1/events", SAMPLES).await, (204, Value::Null));
    let (c, st) = get(addr, "/v1/state").await;
    assert_eq!((c, st["queued"].as_u64()), (200, Some(4)));
    let (c, q) = get(addr, "/v1/queue").await;
    assert_eq!(c, 200);
    assert_eq!(q["events"][0]["t"], "gone");
    assert_eq!(get(addr, "/v1/queue?limit=x").await, (400, json!({"error":"bad limit"})));
    assert_eq!(get(addr, "/v1/queue?before=zzz").await.0, 400);
    assert_eq!(get(addr, "/v1/queue?limit=1").await.0, 200);
}

#[tokio::test]
async fn a_bad_line_takes_nothing() {
    let addr = start(old_ok()).await;
    let lines: Vec<&str> = SAMPLES.lines().collect();
    let body = format!("{}\n{{nope\n{}\n", lines[0], lines[2]);
    let (c, v) = post(addr, "/v1/events", &body).await;
    assert_eq!(c, 400);
    assert!(v["error"].as_str().unwrap().starts_with("line 2:"), "{v}");
    assert_eq!(get(addr, "/v1/state").await.1["queued"], 0);
}

#[tokio::test]
async fn fifty_one_events_are_too_many() {
    let addr = start(old_ok()).await;
    let body = format!("{}\n", SAMPLES.lines().next().unwrap()).repeat(51);
    assert_eq!(post(addr, "/v1/events", &body).await, (413, json!({"error":"too many events"})));
    let big = "x".repeat(300 * 1024);
    assert_eq!(post(addr, "/v1/events", &big).await.0, 413);
}

#[tokio::test]
async fn a_resent_batch_is_taken_once() {
    let addr = start(old_ok()).await;
    assert_eq!(post(addr, "/v1/events", SAMPLES).await.0, 204);
    assert_eq!(post(addr, "/v1/events", SAMPLES).await.0, 204);
    assert_eq!(get(addr, "/v1/state").await.1["queued"], 4);
}

#[tokio::test]
async fn wrong_method_is_405() {
    let addr = start(old_ok()).await;
    assert_eq!(get(addr, "/v1/events").await, (405, json!({"error":"method not allowed"})));
    assert_eq!(post(addr, "/v1/state", "").await.0, 405);
}

#[tokio::test]
async fn the_log_has_counts_not_text() {
    let lines: Arc<Mutex<Vec<String>>> = Arc::default();
    let sink = lines.clone();
    let log = Log::new(move |v| sink.lock().unwrap().push(v.to_string()));
    let l = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = l.local_addr().unwrap();
    tokio::spawn(serve_with_log(old_ok(), l, log));
    let body = SAMPLES.replace("approve Bash: touch /tmp/x", "SECRET-TEXT");
    assert_eq!(post(addr, "/v1/events", &body).await.0, 204);
    assert_eq!(post(addr, "/v1/events", "{bad").await.0, 400);
    let all = lines.lock().unwrap().join("\n");
    assert!(!all.contains("SECRET-TEXT") && !all.contains("term:pty:"), "{all}");
    assert!(all.contains(r#""event":"events""#) && all.contains(r#""accepted":5"#), "{all}");
    assert!(all.contains(r#""event":"rejected""#) && all.contains(r#""status":400"#), "{all}");
}

#[tokio::test]
async fn a_restart_keeps_the_queue() {
    let d = tempfile::tempdir().unwrap();
    let cfg = Config { data: Some(d.path().join("data")), ..old_ok() };
    let l = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = l.local_addr().unwrap();
    let first = tokio::spawn(serve(cfg.clone(), l));
    assert_eq!(post(addr, "/v1/events", SAMPLES).await, (204, Value::Null));
    tokio::time::sleep(std::time::Duration::from_millis(1500)).await;
    first.abort();
    let _ = first.await;
    let addr = start(cfg).await;
    let (c, st) = get(addr, "/v1/state").await;
    assert_eq!((c, st["queued"].as_u64()), (200, Some(4)));
}

/// One request on an open keep-alive connection: the status, or None when the server is gone.
async fn on_conn(s: &mut TcpStream, path: &str) -> Option<u16> {
    let req = format!("GET {path} HTTP/1.1\r\nHost: x\r\n\r\n");
    s.write_all(req.as_bytes()).await.ok()?;
    let mut buf = vec![0u8; 4096];
    let n = tokio::time::timeout(std::time::Duration::from_secs(2), s.read(&mut buf)).await.ok()?.ok()?;
    let text = String::from_utf8_lossy(&buf[..n]).to_string();
    text.split_whitespace().nth(1)?.parse().ok()
}

#[tokio::test]
async fn a_stopped_serve_closes_its_connections() {
    let l = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = l.local_addr().unwrap();
    let task = tokio::spawn(serve(old_ok(), l));
    let mut s = TcpStream::connect(addr).await.unwrap();
    assert_eq!(on_conn(&mut s, "/v1/health").await, Some(200));
    task.abort();
    let _ = task.await;
    // The connection open before the stop must not keep serving the old store.
    assert_eq!(on_conn(&mut s, "/v1/state").await, None);
}

#[tokio::test]
async fn an_aborted_serve_does_not_save() {
    let d = tempfile::tempdir().unwrap();
    let data = d.path().join("data");
    let lines: Arc<Mutex<Vec<String>>> = Arc::default();
    let sink = lines.clone();
    let log = Log::new(move |v| sink.lock().unwrap().push(v.to_string()));
    let l = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = l.local_addr().unwrap();
    let task = tokio::spawn(serve_with_log(Config { data: Some(data.clone()), ..old_ok() }, l, log));
    assert_eq!(post(addr, "/v1/events", SAMPLES).await, (204, Value::Null));
    // Stopped inside the 1 s save delay: its saver must not live on and save after all.
    task.abort();
    let _ = task.await;
    tokio::time::sleep(std::time::Duration::from_millis(1500)).await;
    let all = lines.lock().unwrap().join("\n");
    assert!(!all.contains(r#""event":"saved""#), "{all}");
    assert!(!data.join("state.json").exists());
}

#[tokio::test]
async fn seen_answers_204_404_400() {
    let addr = start(old_ok()).await;
    // Dated now: a device silent for 30 days is dropped, which the 2025 samples would hit.
    let t = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_secs();
    let ev = |n: u64, kind: &str| json!({"v":1,"fp":"aa","epoch":"e","n":n,"at":t,"t":kind,"session":"s","state":"working","seq":n}).to_string();
    let first4 = format!("{}\n{}\n", ev(1, "state"), ev(2, "state"));
    assert_eq!(post(addr, "/v1/events", &first4).await, (204, Value::Null));
    let st = get(addr, "/v1/state").await.1;
    let (fp, sid) = (st["devices"][0]["fp"].clone(), st["devices"][0]["sessions"][0]["session"].clone());
    assert_eq!(put(addr, "/v1/seen", &json!({"fp": fp, "session": sid}).to_string()).await, (204, None));
    assert!(get(addr, "/v1/state").await.1["devices"][0]["sessions"].as_array().unwrap().iter().any(|r| r["seen"].is_u64()));
    assert_eq!(put(addr, "/v1/seen", r#"{"fp":"zz","session":"zz"}"#).await, (404, Some(json!({"error":"unknown session"}))));
    assert_eq!(put(addr, "/v1/seen", r#"{"eid":"a:b:9"}"#).await, (404, Some(json!({"error":"unknown eid"}))));
    assert_eq!(put(addr, "/v1/seen", r#"{"what":1}"#).await, (400, Some(json!({"error":"bad request"}))));
    assert_eq!(put(addr, "/v1/seen", "not json").await, (400, Some(json!({"error":"bad request"}))));
    assert_eq!(get(addr, "/v1/seen").await.0, 405);
    let eid = get(addr, "/v1/queue").await.1["events"][0]["eid"].clone();
    assert_eq!(put(addr, "/v1/seen", &json!({"eid": eid, "handled": true}).to_string()).await, (204, None));
    let row = get(addr, "/v1/queue?limit=1").await.1["events"][0].clone();
    assert_eq!(row["handled"], true);
    assert!(row["seen"].is_u64());
}

fn unix_now() -> u64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_secs()
}

/// Two states of session `s` on device `aa`, dated now (a device silent for 30 days is dropped).
async fn post_sample(addr: SocketAddr) {
    let t = unix_now();
    let ev = |n: u64| json!({"v":1,"fp":"aa","epoch":"e","n":n,"at":t,"t":"state","session":"s","state":"working","seq":n}).to_string();
    assert_eq!(post(addr, "/v1/events", &format!("{}\n{}\n", ev(1), ev(2))).await, (204, Value::Null));
}

async fn first_session_over_http(addr: SocketAddr) -> (String, String) {
    let st = get(addr, "/v1/state").await.1;
    let d = &st["devices"][0];
    (d["fp"].as_str().unwrap().into(), d["sessions"][0]["session"].as_str().unwrap().into())
}

/// Opens `GET /v1/watch` and hands over every `data:` line as JSON. Dropping the receiver hangs up.
async fn watch(addr: SocketAddr) -> tokio::sync::mpsc::Receiver<Value> {
    let mut s = TcpStream::connect(addr).await.unwrap();
    s.write_all(b"GET /v1/watch HTTP/1.1\r\nHost: x\r\n\r\n").await.unwrap();
    let (tx, rx) = tokio::sync::mpsc::channel(64);
    tokio::spawn(async move {
        let (mut buf, mut head_done) = (Vec::new(), false);
        let mut chunk = [0u8; 4096];
        loop {
            let n = tokio::select! {
                n = s.read(&mut chunk) => match n { Ok(n) if n > 0 => n, _ => return },
                _ = tx.closed() => return,
            };
            buf.extend_from_slice(&chunk[..n]);
            if !head_done {
                let Some(end) = buf.windows(4).position(|w| w == b"\r\n\r\n") else { continue };
                let head = String::from_utf8_lossy(&buf[..end]).to_lowercase();
                assert!(head.starts_with("http/1.1 200") && head.contains("content-type: text/event-stream"), "{head}");
                buf.drain(..end + 4);
                head_done = true;
            }
            // Chunk-size lines and `: ping` lines are not `data:` lines, so they are skipped.
            while let Some(nl) = buf.iter().position(|b| *b == b'\n') {
                let line: Vec<u8> = buf.drain(..=nl).collect();
                let line = String::from_utf8(line).unwrap();
                if let Some(data) = line.trim_end().strip_prefix("data: ") {
                    if tx.send(serde_json::from_str(data).unwrap()).await.is_err() {
                        return;
                    }
                }
            }
        }
    });
    rx
}

async fn recv(w: &mut tokio::sync::mpsc::Receiver<Value>) -> Value {
    tokio::time::timeout(Duration::from_secs(2), w.recv()).await.expect("no push within 2 s").expect("watch ended")
}

#[tokio::test]
async fn watch_says_hello_then_pushes_changes() {
    let addr = start(Config::default()).await;
    let mut w = watch(addr).await;
    assert_eq!(recv(&mut w).await, json!({"what":"hello"}));
    post_sample(addr).await;
    let mut pushed = vec![];
    while let Ok(Some(v)) = tokio::time::timeout(Duration::from_millis(500), w.recv()).await {
        pushed.push(v);
    }
    let whats: Vec<&str> = pushed.iter().map(|v| v["what"].as_str().unwrap()).collect();
    assert!(whats.contains(&"queue") && whats.contains(&"session"), "{whats:?}");
    // The pushed rows look exactly like the ones GET /v1/state and GET /v1/queue give.
    let last_row = pushed.iter().rev().find(|v| v["what"] == "session").unwrap();
    assert_eq!(last_row["row"], get(addr, "/v1/state").await.1["devices"][0]["sessions"][0]);
    let last_queued = pushed.iter().rev().find(|v| v["what"] == "queue").unwrap();
    assert_eq!(last_queued["row"], get(addr, "/v1/queue?limit=1").await.1["events"][0]);
    let (fp, sid) = first_session_over_http(addr).await;
    assert_eq!(put(addr, "/v1/seen", &json!({"fp": fp, "session": sid}).to_string()).await.0, 204);
    let seen = recv(&mut w).await;
    assert_eq!((seen["what"].as_str(), seen["session"].as_str()), (Some("seen"), Some(sid.as_str())));
    assert!(seen["at"].is_u64());
}

#[tokio::test]
async fn a_closed_watch_is_let_go() {
    let lines: Arc<Mutex<Vec<Value>>> = Arc::default();
    let sink = lines.clone();
    let log = Log::new(move |v| sink.lock().unwrap().push(v.clone()));
    let l = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = l.local_addr().unwrap();
    tokio::spawn(serve_with_log(Config::default(), l, log));
    let mut ws = vec![];
    for _ in 0..3 {
        let mut w = watch(addr).await;
        assert_eq!(recv(&mut w).await["what"], "hello");
        ws.push(w);
    }
    let watching = |name: &str| -> Vec<u64> {
        let all = lines.lock().unwrap();
        all.iter().filter(|v| v["event"] == name).map(|v| v["watching"].as_u64().unwrap()).collect()
    };
    assert_eq!(watching("watch_open"), [1, 2, 3]);
    drop(ws);
    tokio::time::sleep(Duration::from_millis(200)).await;
    // The three closes may log in any order; together they count down to none left.
    let mut closed = watching("watch_closed");
    closed.sort();
    assert_eq!(closed, [0, 1, 2]);
    let closed = lines.lock().unwrap().iter().filter(|v| v["event"] == "watch_closed").cloned().collect::<Vec<_>>();
    assert!(closed.iter().all(|v| v["lagged"] == false), "{closed:?}");
}
