use std::net::SocketAddr;

use std::sync::{Arc, Mutex};

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
