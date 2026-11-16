//! Port sharing fixtures: an echo service, a service with a share table, a visiting device.

use super::*;
use quinn::Connection;
use rapp_conn::Pipe;
use rapp_net::line::read_json;
use serde_json::{json, Value};
use std::path::Path;
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;
use tokio::task::JoinHandle;

/// An echo service on `127.0.0.1:0`: writes back what it reads, and finishes writing when the
/// other side has finished.
pub async fn echo() -> (u16, JoinHandle<()>) {
    echo_on(TcpListener::bind("127.0.0.1:0").await.unwrap())
}

pub fn echo_on(l: TcpListener) -> (u16, JoinHandle<()>) {
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
pub fn share_file(home: &Path, shares: Value) {
    std::fs::write(home.join("shares.json"), serde_json::to_vec(&shares).unwrap()).unwrap();
}

/// A service started after `prepare` ran on its home, with a key set so that a device showing
/// the same key is trusted.
pub async fn start_sharing(prepare: impl FnOnce(&Path)) -> (TestService, rapp_wire::Key) {
    start_sharing_ports(prepare, (0, 0)).await
}

/// `start_sharing`, with the local ports of other devices' shares from `map_ports`.
pub async fn start_sharing_ports(prepare: impl FnOnce(&Path), map_ports: (u16, u16)) -> (TestService, rapp_wire::Key) {
    start_sharing_opts(prepare, map_ports, true, None).await
}

/// `start_sharing_ports`, with `own_ports` (see `start_service_opts`) and, when given, the `key`
/// to trust instead of a new one: two devices of one test share a key to trust each other.
pub async fn start_sharing_opts(
    prepare: impl FnOnce(&Path),
    map_ports: (u16, u16),
    own_ports: bool,
    key: Option<rapp_wire::Key>,
) -> (TestService, rapp_wire::Key) {
    let (home, bins) = (tempfile::tempdir().unwrap(), bins());
    service_json(home.path());
    if let Some(key) = &key {
        // Before start: what the service asks other devices at start needs the key already.
        let cfg = json!({"id": null, "name": "test-a", "password": PASSWORD, "port": 0, "ipc_port": 0, "key": key.to_string()});
        rapp_net::config::write_json(&home.path().join("service.json"), &cfg).unwrap();
    }
    prepare(home.path());
    let svc = start_service_opts(home.path(), bins.path(), Duration::from_secs(60), map_ports, own_ports).await;
    let id = ipc_once(&svc, home.path(), json!({"cmd":"status"})).await["id"].as_str().unwrap().to_string();
    let key = key.unwrap_or_else(rapp_wire::Key::new_local);
    let r = ipc_once(&svc, home.path(), json!({"cmd":"set_relay","relay":"","key":key.to_string()})).await;
    assert_eq!(r["ok"], true, "{r}");
    (TestService { svc, home, bins, id }, key)
}

/// A service whose `shares.json` is `shares`.
pub async fn sharing(shares: Value) -> (TestService, rapp_wire::Key) {
    start_sharing(|home| share_file(home, shares)).await
}

/// `sharing` with every port in `ports` shared with every trusted device.
pub async fn sharing_ports(ports: &[u16]) -> (TestService, rapp_wire::Key) {
    sharing(ports.iter().map(|p| json!({"port": p})).collect()).await
}

/// A visiting device: its own identity in a temp dir.
pub struct Visitor {
    pub _dir: tempfile::TempDir,
    pub id: rapp_wire::Identity,
}

pub fn visitor() -> Visitor {
    let dir = tempfile::tempdir().unwrap();
    let id = rapp_wire::Identity::load_or_create(dir.path(), "device").unwrap();
    Visitor { _dir: dir, id }
}

/// Sends `request` over a fresh `rapp/2` connection from `b`; returns the reply, the stream after
/// it, and the connection (which must be kept: dropping it closes the stream).
pub async fn ask(a: &TestService, key: &rapp_wire::Key, b: &Visitor, request: Value) -> (Value, Pipe, Connection) {
    let conn = dial2(a_addr(&a.svc), &b.id).await;
    let mut pipe = hello_and_send(&conn, &b.id, &a.id, Some(key), request).await.unwrap();
    let reply = tokio::time::timeout(WAIT, read_json(&mut pipe)).await.unwrap().unwrap();
    (reply, pipe, conn)
}

pub async fn forward(a: &TestService, key: &rapp_wire::Key, b: &Visitor, port: u16) -> (Value, Pipe, Connection) {
    ask(a, key, b, json!({"op":"forward","port":port})).await
}

/// A `hosts` reply without each share's `local`, `addr` and `wanted`, after checking them: a
/// local port from the real service's range, and an address that names it. `wanted` is there
/// when the sharer runs on the same machine and listens on its share number itself, so that
/// the visitor yields; that says nothing about what these tests look at.
pub fn without_local(mut reply: Value) -> Value {
    let (first, count) = rapp_service::MAP_PORTS;
    for h in reply.get_mut("hosts").and_then(Value::as_array_mut).into_iter().flatten() {
        for s in h.get_mut("shares").and_then(Value::as_array_mut).into_iter().flatten() {
            let s = s.as_object_mut().unwrap();
            let local = s.remove("local").and_then(|l| l.as_u64()).expect("a local port");
            assert!((first as u64..first as u64 + count as u64).contains(&local), "{local}");
            if let Some(wanted) = s.remove("wanted") {
                assert!(wanted.as_u64().is_some_and(|w| w != local), "{wanted}");
            }
            let addr = s.remove("addr").expect("an address");
            let want = ["http", "https", "tcp"].map(|p| format!("{p}://localhost:{local}"));
            let want = [&want[..], &[format!("ssh -p {local} localhost")]].concat();
            assert!(want.iter().any(|w| addr == w.as_str()), "{addr}");
        }
    }
    reply
}

/// Reads the stream to its end within `within`.
pub async fn read_all(pipe: &mut Pipe, within: Duration) -> Vec<u8> {
    let mut got = Vec::new();
    tokio::time::timeout(within, pipe.read_to_end(&mut got)).await.expect("stream ends in time").unwrap();
    got
}
