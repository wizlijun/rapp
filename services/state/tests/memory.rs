//! Its own process: it changes the current directory and HOME, which must not leak into other tests.

use rapp_state::{serve, Config};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};

#[tokio::test]
async fn memory_mode_writes_nothing() {
    let d = tempfile::tempdir().unwrap();
    std::env::set_current_dir(d.path()).unwrap();
    std::env::set_var("HOME", d.path());
    let l = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = l.local_addr().unwrap();
    tokio::spawn(serve(Config { keep_days: 100_000, ..Config::default() }, l));
    let body = include_str!("../api/samples/term-events.ndjson");
    let mut s = TcpStream::connect(addr).await.unwrap();
    let req = format!("POST /v1/events HTTP/1.1\r\nHost: x\r\nConnection: close\r\nContent-Length: {}\r\n\r\n{body}", body.len());
    s.write_all(req.as_bytes()).await.unwrap();
    let mut buf = Vec::new();
    s.read_to_end(&mut buf).await.unwrap();
    assert!(String::from_utf8(buf).unwrap().starts_with("HTTP/1.1 204"));
    tokio::time::sleep(std::time::Duration::from_millis(1500)).await;
    assert_eq!(std::fs::read_dir(d.path()).unwrap().count(), 0);
}
