//! What the HTTP tests share: starting a service and talking to it over plain TCP.
#![allow(dead_code)] // each test file uses its own part

use std::net::SocketAddr;
use std::time::Duration;

use rapp_center::{serve, Config};
use serde_json::Value;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};

pub async fn start(cfg: Config) -> SocketAddr {
    let l = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = l.local_addr().unwrap();
    tokio::spawn(serve(cfg, l));
    addr
}

pub async fn get(addr: SocketAddr, path: &str) -> (u16, Value) {
    request(addr, "GET", path, "").await
}

pub async fn post(addr: SocketAddr, path: &str, body: &str) -> (u16, Value) {
    request(addr, "POST", path, body).await
}

pub async fn put(addr: SocketAddr, path: &str, body: &str) -> (u16, Option<Value>) {
    let (c, v) = request(addr, "PUT", path, body).await;
    (c, if v.is_null() { None } else { Some(v) })
}

pub async fn request(addr: SocketAddr, method: &str, path: &str, body: &str) -> (u16, Value) {
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

pub fn unix_now() -> u64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_secs()
}

/// Opens `GET /v1/watch` and hands over every `data:` line as JSON. Dropping the receiver hangs up.
pub async fn watch(addr: SocketAddr) -> tokio::sync::mpsc::Receiver<Value> {
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

pub async fn recv(w: &mut tokio::sync::mpsc::Receiver<Value>) -> Value {
    tokio::time::timeout(Duration::from_secs(2), w.recv()).await.expect("no push within 2 s").expect("watch ended")
}
