//! Port sharing, the sharing side: `forward` and `list_shares` over `rapp/2` (port-sharing plan 1a, Task 4).

mod common;
use common::*;

use quinn::Connection;
use rapp_conn::Pipe;
use rapp_net::line::read_json;
use rapp_net::quic::ALPN_PEER;
use serde_json::{json, Value};
use std::path::Path;
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;
use tokio::task::JoinHandle;

/// An echo service on `127.0.0.1:0`: writes back what it reads, and finishes writing when the
/// other side has finished.
async fn echo() -> (u16, JoinHandle<()>) {
    echo_on(TcpListener::bind("127.0.0.1:0").await.unwrap())
}

fn echo_on(l: TcpListener) -> (u16, JoinHandle<()>) {
    let port = l.local_addr().unwrap().port();
    let task = tokio::spawn(async move {
        while let Ok((mut c, _)) = l.accept().await {
            tokio::spawn(async move {
                let (mut r, mut w) = c.split();
                if tokio::io::copy(&mut r, &mut w).await.is_ok() {
                    let _ = w.shutdown().await;
                }
            });
        }
    });
    (port, task)
}

/// Writes `home/shares.json` as given (before the service starts).
fn share_file(home: &Path, shares: Value) {
    std::fs::write(home.join("shares.json"), serde_json::to_vec(&shares).unwrap()).unwrap();
}

/// A service started after `prepare` ran on its home, with a key set so that a device showing
/// the same key is trusted.
async fn start_sharing(prepare: impl FnOnce(&Path)) -> (TestService, rapp_wire::Key) {
    let (home, bins) = (tempfile::tempdir().unwrap(), bins());
    service_json(home.path());
    prepare(home.path());
    let svc = start_service(home.path(), bins.path(), Duration::from_secs(60)).await;
    let id = ipc_once(&svc, home.path(), json!({"cmd":"status"})).await["id"].as_str().unwrap().to_string();
    let key = rapp_wire::Key::new_local();
    let r = ipc_once(&svc, home.path(), json!({"cmd":"set_relay","relay":"","key":key.to_string()})).await;
    assert_eq!(r["ok"], true, "{r}");
    (TestService { svc, home, bins, id }, key)
}

/// A service whose `shares.json` is `shares`.
async fn sharing(shares: Value) -> (TestService, rapp_wire::Key) {
    start_sharing(|home| share_file(home, shares)).await
}

/// `sharing` with every port in `ports` shared with every trusted device.
async fn sharing_ports(ports: &[u16]) -> (TestService, rapp_wire::Key) {
    sharing(ports.iter().map(|p| json!({"port": p})).collect()).await
}

/// A visiting device: its own identity in a temp dir.
struct Visitor {
    _dir: tempfile::TempDir,
    id: rapp_wire::Identity,
}

fn visitor() -> Visitor {
    let dir = tempfile::tempdir().unwrap();
    let id = rapp_wire::Identity::load_or_create(dir.path(), "device").unwrap();
    Visitor { _dir: dir, id }
}

/// Sends `request` over a fresh `rapp/2` connection from `b`; returns the reply, the stream after
/// it, and the connection (which must be kept: dropping it closes the stream).
async fn ask(a: &TestService, key: &rapp_wire::Key, b: &Visitor, request: Value) -> (Value, Pipe, Connection) {
    let conn = dial2(a_addr(&a.svc), &b.id).await;
    let mut pipe = hello_and_send(&conn, &b.id, &a.id, Some(key), request).await.unwrap();
    let reply = tokio::time::timeout(WAIT, read_json(&mut pipe)).await.unwrap().unwrap();
    (reply, pipe, conn)
}

async fn forward(a: &TestService, key: &rapp_wire::Key, b: &Visitor, port: u16) -> (Value, Pipe, Connection) {
    ask(a, key, b, json!({"op":"forward","port":port})).await
}

/// Reads the stream to its end within `within`.
async fn read_all(pipe: &mut Pipe, within: Duration) -> Vec<u8> {
    let mut got = Vec::new();
    tokio::time::timeout(within, pipe.read_to_end(&mut got)).await.expect("stream ends in time").unwrap();
    got
}

/// A port nothing listens on.
async fn dead_port() -> u16 {
    let l = TcpListener::bind("127.0.0.1:0").await.unwrap();
    l.local_addr().unwrap().port()
}

#[tokio::test]
async fn forward_reaches_the_shared_port_and_echoes() {
    let (port, _echo) = echo().await;
    let (a, key) = sharing_ports(&[port]).await;
    let (r, mut s, _conn) = forward(&a, &key, &visitor(), port).await;
    assert_eq!(r, json!({"ok":true}));
    s.write_all(b"hello").await.unwrap();
    let mut got = [0u8; 5];
    tokio::time::timeout(WAIT, s.read_exact(&mut got)).await.unwrap().unwrap();
    assert_eq!(&got, b"hello");
}

#[tokio::test]
async fn a_port_that_is_not_shared_is_refused() {
    let (a, key) = start_sharing(|_| {}).await;
    let port = dead_port().await;
    let (r, _, _conn) = forward(&a, &key, &visitor(), port).await;
    assert_eq!(r, json!({"ok":false,"error":"not shared"}));
    let l = wait_log(a.home.path(), "forward_refused", |v| v["port"] == port).await;
    assert_eq!(l["reason"], "not shared");
}

#[tokio::test]
async fn a_share_for_someone_else_is_not_allowed_and_not_listed() {
    let (port, _echo) = echo().await;
    let other = rapp_wire::Fp([7; 32]).to_string();
    assert_eq!(other.len(), 64);
    let (a, key) = sharing(json!([{"port": port, "allow": [other]}, {"port": 9}])).await;
    let b = visitor();
    let (r, _, _conn) = forward(&a, &key, &b, port).await;
    assert_eq!(r, json!({"ok":false,"error":"not allowed"}));
    let (r, _, _conn) = ask(&a, &key, &b, json!({"op":"list_shares"})).await;
    assert_eq!(r, json!({"ok":true,"shares":[{"port":9}]}));
}

#[tokio::test]
async fn list_shares_shows_the_note_and_what_is_allowed_to_this_device() {
    let b = visitor();
    let shares = json!([
        {"port": 11434, "note": "模型"},
        {"port": 8000, "allow": [b.id.fp.to_string()], "raw": true},
        {"port": 22, "allow": [rapp_wire::Fp([7; 32]).to_string()]},
    ]);
    let (a, key) = sharing(shares).await;
    let (r, _, _conn) = ask(&a, &key, &b, json!({"op":"list_shares"})).await;
    assert_eq!(r, json!({"ok":true,"shares":[{"port":8000},{"port":11434,"note":"模型"}]}));
}

#[tokio::test]
async fn nothing_listening_is_refused() {
    let port = dead_port().await;
    let (a, key) = sharing_ports(&[port]).await;
    let (r, _, _conn) = forward(&a, &key, &visitor(), port).await;
    assert_eq!(r, json!({"ok":false,"error":"refused"}));
    let l = wait_log(a.home.path(), "forward_refused", |v| v["port"] == port).await;
    assert_eq!(l["reason"], "refused");
}

#[tokio::test]
async fn a_password_connection_cannot_forward_or_list() {
    let (port, _echo) = echo().await;
    let (a, _key) = sharing_ports(&[port]).await;
    let ep = b_endpoint();
    let conn = dial(&ep, a_addr(&a.svc), ALPN_PEER).await;
    let r = req(&conn, json!({"op":"auth","password":PASSWORD,"name":"old-b"})).await;
    assert_eq!(r["ok"], true, "{r}");
    assert_eq!(req(&conn, json!({"op":"forward","port":port})).await, json!({"ok":false,"error":"not supported"}));
    assert_eq!(req(&conn, json!({"op":"list_shares"})).await, json!({"ok":false,"error":"not supported"}));
}

#[tokio::test]
async fn the_local_fallback_is_ipv6_loopback() {
    let Ok(l) = TcpListener::bind("[::1]:0").await else {
        eprintln!("no IPv6 loopback here: skipped");
        return;
    };
    let (port, _echo) = echo_on(l);
    let (a, key) = sharing_ports(&[port]).await;
    let (r, mut s, _conn) = forward(&a, &key, &visitor(), port).await;
    assert_eq!(r, json!({"ok":true}));
    s.write_all(b"via ::1").await.unwrap();
    s.shutdown().await.unwrap();
    assert_eq!(read_all(&mut s, WAIT).await, b"via ::1");
}

#[tokio::test]
async fn half_close_is_kept() {
    let (port, _echo) = echo().await;
    let (a, key) = sharing_ports(&[port]).await;
    let (r, s, _conn) = forward(&a, &key, &visitor(), port).await;
    assert_eq!(r, json!({"ok":true}));
    let (mut rd, mut wr) = tokio::io::split(s);
    let sent: Vec<u8> = (0..1 << 20).map(|i| (i % 251) as u8).collect();
    let data = sent.clone();
    let writer = tokio::spawn(async move {
        wr.write_all(&data).await.unwrap();
        wr.shutdown().await.unwrap();
        wr
    });
    let mut got = Vec::new();
    tokio::time::timeout(WAIT, rd.read_to_end(&mut got)).await.expect("echo ends in time").unwrap();
    writer.await.unwrap();
    assert_eq!(got.len(), 1 << 20);
    assert!(got == sent, "the echo differs from what was sent");
}

#[tokio::test]
async fn local_service_that_closes_at_once() {
    let l = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = l.local_addr().unwrap().port();
    let _closer = tokio::spawn(async move {
        while let Ok((c, _)) = l.accept().await {
            drop(c);
        }
    });
    let (a, key) = sharing_ports(&[port]).await;
    let (r, mut s, _conn) = forward(&a, &key, &visitor(), port).await;
    assert_eq!(r, json!({"ok":true}));
    let mut b = [0u8; 16];
    let n = tokio::time::timeout(Duration::from_secs(2), s.read(&mut b)).await.expect("ends within 2 s").unwrap();
    assert_eq!(n, 0);
}

#[tokio::test]
async fn a_reader_that_stalls_does_not_grow_memory() {
    const TOTAL: usize = 64 << 20;
    let l = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = l.local_addr().unwrap().port();
    let _firehose = tokio::spawn(async move {
        let (mut c, _) = l.accept().await.unwrap();
        let chunk = vec![0x5au8; 1 << 20];
        for _ in 0..TOTAL / chunk.len() {
            c.write_all(&chunk).await.unwrap();
        }
        c.shutdown().await.unwrap();
    });
    let (a, key) = sharing_ports(&[port]).await;
    let (r, mut s, _conn) = forward(&a, &key, &visitor(), port).await;
    assert_eq!(r, json!({"ok":true}));
    tokio::time::sleep(Duration::from_secs(2)).await;
    let mut n = 0usize;
    let mut buf = vec![0u8; 1 << 16];
    tokio::time::timeout(Duration::from_secs(120), async {
        loop {
            match s.read(&mut buf).await.unwrap() {
                0 => break,
                k => {
                    assert!(buf[..k].iter().all(|&b| b == 0x5a));
                    n += k;
                }
            }
        }
    })
    .await
    .expect("all of it arrives in time");
    assert_eq!(n, TOTAL);
}

#[tokio::test]
async fn a_finished_forward_is_recorded() {
    let (port, _echo) = echo().await;
    let (a, key) = sharing_ports(&[port]).await;
    let b = visitor();
    let (r, mut s, _conn) = forward(&a, &key, &b, port).await;
    assert_eq!(r, json!({"ok":true}));
    s.write_all(b"hello").await.unwrap();
    s.shutdown().await.unwrap();
    assert_eq!(read_all(&mut s, WAIT).await, b"hello");
    drop(s);
    let l = wait_log(a.home.path(), "forward", |v| v["port"] == port).await;
    assert_eq!((&l["bytes_in"], &l["bytes_out"]), (&json!(5), &json!(5)), "{l}");
    assert_eq!(l["fp"], b.id.fp.to_string());
}

#[tokio::test]
async fn an_unreadable_shares_file_starts_empty_and_says_so() {
    let (a, key) = start_sharing(|home| std::fs::write(home.join("shares.json"), b"{not json").unwrap()).await;
    let (r, _, _conn) = forward(&a, &key, &visitor(), 9).await;
    assert_eq!(r, json!({"ok":false,"error":"not shared"}));
    wait_log(a.home.path(), "shares_unreadable", |_| true).await;
    assert_eq!(std::fs::read(a.home.path().join("shares.json")).unwrap(), b"{not json");
}
