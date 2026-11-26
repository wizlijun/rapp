use std::net::SocketAddr;

use rapp_state::{serve, Config};
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
    let mut s = TcpStream::connect(addr).await.unwrap();
    s.write_all(format!("GET {path} HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n").as_bytes()).await.unwrap();
    let mut buf = Vec::new();
    s.read_to_end(&mut buf).await.unwrap();
    let text = String::from_utf8(buf).unwrap();
    let (head, body) = text.split_once("\r\n\r\n").unwrap();
    let status = head.split_whitespace().nth(1).unwrap().parse().unwrap();
    (status, serde_json::from_str(body).unwrap())
}

#[tokio::test]
async fn health_says_who_it_is() {
    let addr = start(Config::default()).await;
    assert_eq!(get(addr, "/v1/health").await, (200, json!({"name":"rapp-state","v":1})));
    assert_eq!(get(addr, "/nope").await, (404, json!({"error":"not found"})));
}
