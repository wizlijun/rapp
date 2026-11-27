//! The entry's own paths: health, the routes list, and each builtin under its prefix.

use std::net::SocketAddr;

use rapp_center::{serve, Config};
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
    let _ = s.write_all(req.as_bytes()).await;
    let mut buf = Vec::new();
    let _ = s.read_to_end(&mut buf).await;
    let text = String::from_utf8(buf).unwrap();
    let (head, body) = text.split_once("\r\n\r\n").unwrap();
    let status = head.split_whitespace().nth(1).unwrap().parse().unwrap();
    (status, if body.is_empty() { Value::Null } else { serde_json::from_str(body).unwrap() })
}

fn unix_now() -> u64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_secs()
}

/// Two states of session `s` on device `aa`, dated now.
async fn post_sample(addr: SocketAddr) {
    let t = unix_now();
    let ev = |n: u64| json!({"v":1,"fp":"aa","epoch":"e","n":n,"at":t,"t":"state","session":"s","state":"working","seq":n}).to_string();
    assert_eq!(post(addr, "/v1/events", &format!("{}\n{}\n", ev(1), ev(2))).await, (204, Value::Null));
}

#[tokio::test]
async fn health_is_v2_and_says_it_has_routes() {
    let addr = start(Config::default()).await;
    assert_eq!(get(addr, "/v1/health").await, (200, json!({"name":"rapp-state","service":"rapp-center","v":2,"routes":true})));
}

#[tokio::test]
async fn routes_lists_the_state_builtin() {
    let addr = start(Config::default()).await;
    assert_eq!(get(addr, "/v1/routes").await, (200, json!({"routes":[{"name":"state","kind":"builtin","v":1}]})));
    assert_eq!(request(addr, "POST", "/v1/routes", "").await.0, 405);
}

#[tokio::test]
async fn aliased_paths_answer_like_the_root() {
    let addr = start(Config::default()).await;
    post_sample(addr).await;
    assert_eq!(get(addr, "/state/v1/state").await, get(addr, "/v1/state").await);
    assert_eq!(get(addr, "/state/v1/queue?limit=1").await, get(addr, "/v1/queue?limit=1").await);
    assert_eq!(put(addr, "/state/v1/desk/aa", r#"{"sessions":[{"id":"111111111","app":"x"}]}"#).await.0, 204);
    assert_eq!(get(addr, "/v1/state").await.1["desks"][0]["fp"], "aa");
    assert_eq!(put(addr, "/state/v1/seen", r#"{"eid":"nope"}"#).await.0, put(addr, "/v1/seen", r#"{"eid":"nope"}"#).await.0);
    assert_eq!(request(addr, "POST", "/state/v1/events", "not json\n").await.0, request(addr, "POST", "/v1/events", "not json\n").await.0);
}

#[tokio::test]
async fn odd_paths_are_404() {
    let addr = start(Config::default()).await;
    for p in ["/state", "/state/", "/state/v1/watch", "/state/v1/health", "/STATE/v1/state", "/nope/v1/x", "//v1/state", "/v1/nope"] {
        assert_eq!(get(addr, p).await, (404, json!({"error":"not found"})), "{p}");
    }
}
