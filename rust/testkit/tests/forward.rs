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

// ---- Outbound: one request to another device, LAN first, then the relay (Task 5) ----

use rapp_conn::dial::{NotReached, Outbound, Target, Via};
use rapp_net::msg::Op;
use std::sync::Arc;

/// An `Outbound` that dials as the device whose identity is kept in `home`.
fn outbound(home: &Path) -> Outbound {
    let identity = Arc::new(rapp_wire::Identity::load_or_create(home, "device").unwrap());
    Outbound::new(b_endpoint(), identity, "test-b".into())
}

/// The fingerprint a service shows, as `status` reports it.
async fn fp_of(a: &TestService) -> String {
    ipc_once(&a.svc, a.home.path(), json!({"cmd":"status"})).await["fp"].as_str().unwrap().to_string()
}

/// The `NotReached` text of `e`, if it is one.
fn not_reached(e: &anyhow::Error) -> Option<&'static str> {
    e.downcast_ref::<NotReached>().map(|n| n.0)
}

#[tokio::test]
async fn outbound_reaches_a_device_on_the_lan_address() {
    let rig = RelayRig::start().await;
    let a = a_on_relay(&rig, Some(vec![])).await;
    let b = tempfile::tempdir().unwrap();
    let out = outbound(b.path());
    let lan = [a_addr(&a.svc).to_string()];
    let to = Target { id: &a.id, lan: &lan, known: None };
    let sent = out.request(&Via { relay: None, key: &rig.key }, &to, &Op::Ping).await.unwrap();
    assert_eq!(sent.reply["ok"], true, "{}", sent.reply);
    // 127.0.0.1 is a private address by the hub's `direct_path` rule.
    assert_eq!(sent.path, "lan");
    assert_eq!(sent.fp.to_string(), fp_of(&a).await);
    out.close();
}

#[tokio::test]
async fn outbound_goes_through_the_relay_when_there_is_no_address() {
    let rig = RelayRig::start().await;
    let a = a_on_relay(&rig, Some(vec![])).await;
    let b = tempfile::tempdir().unwrap();
    let out = outbound(b.path());
    let before = rig.streams();
    let to = Target { id: &a.id, lan: &[], known: None };
    let sent = out.request(&Via { relay: Some(&rig.addr), key: &rig.key }, &to, &Op::Ping).await.unwrap();
    assert_eq!(sent.reply["ok"], true, "{}", sent.reply);
    assert_eq!(sent.path, "relay");
    assert_eq!(sent.fp.to_string(), fp_of(&a).await);
    // The relay writes a stream down when it ends.
    drop(sent);
    let deadline = tokio::time::Instant::now() + WAIT;
    while rig.streams() == before {
        assert!(tokio::time::Instant::now() < deadline, "nothing went through the relay");
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    assert_eq!(rig.streams(), before + 1);
    out.close();
}

#[tokio::test]
async fn a_second_request_reuses_the_direct_connection() {
    let rig = RelayRig::start().await;
    let a = a_on_relay(&rig, Some(vec![])).await;
    let b = tempfile::tempdir().unwrap();
    let b_fp = rapp_wire::Identity::load_or_create(b.path(), "device").unwrap().fp.to_string();
    let out = outbound(b.path());
    let lan = [a_addr(&a.svc).to_string()];
    let to = Target { id: &a.id, lan: &lan, known: None };
    let via = Via { relay: None, key: &rig.key };
    for _ in 0..2 {
        let sent = out.request(&via, &to, &Op::Ping).await.unwrap();
        assert_eq!((&sent.reply["ok"], sent.path), (&json!(true), "lan"), "{}", sent.reply);
    }
    wait_log(a.home.path(), "trust", |v| v["fp"] == b_fp).await;
    let trusts = log_events(a.home.path()).into_iter().filter(|v| v["ev"] == "trust" && v["fp"] == b_fp).count();
    assert_eq!(trusts, 1, "{:?}", log_events(a.home.path()));
    out.close();
}

#[tokio::test]
async fn an_id_the_relay_does_not_know_and_one_that_is_offline() {
    let rig = RelayRig::start().await;
    let a = a_on_relay(&rig, Some(vec![])).await;
    let b = tempfile::tempdir().unwrap();
    let out = outbound(b.path());
    let via = Via { relay: Some(&rig.addr), key: &rig.key };
    let e = out.request(&via, &Target { id: "999999999", lan: &[], known: None }, &Op::Ping).await.err().unwrap();
    assert_eq!(not_reached(&e), Some("unknown id"), "{e:#}");
    assert_eq!(e.to_string(), "unknown id");
    let to = Target { id: &a.id, lan: &[], known: None };
    assert_eq!(out.request(&via, &to, &Op::Ping).await.unwrap().reply["ok"], true);
    a.svc.stop();
    // The relay learns A is gone a moment after.
    let deadline = tokio::time::Instant::now() + WAIT;
    loop {
        let r = out.request(&via, &to, &Op::Ping).await;
        if let Err(e) = &r {
            if not_reached(e) == Some("offline") {
                assert_eq!(e.to_string(), "offline");
                break;
            }
        }
        assert!(tokio::time::Instant::now() < deadline, "{:?}", r.map(|s| s.reply));
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    out.close();
}

#[tokio::test]
async fn a_device_with_another_key_is_not_trusted() {
    let rig = RelayRig::start().await;
    let a = a_on_relay(&rig, Some(vec![])).await;
    let b = tempfile::tempdir().unwrap();
    let out = outbound(b.path());
    let other = rapp_wire::Key::new_local();
    let lan = [a_addr(&a.svc).to_string()];
    let to = Target { id: &a.id, lan: &lan, known: None };
    let r = out.request(&Via { relay: None, key: &other }, &to, &Op::Ping).await;
    let e = r.err().expect("an error, not a reply");
    assert_eq!(not_reached(&e), None, "{e:#}");
    assert_eq!(e.to_string(), "not trusted");
    wait_log(a.home.path(), "trust", |v| v["result"] == "refused").await;
    out.close();
}

/// A `rapp/2` device on `127.0.0.1` that says it is `id` and trusts `key`: it welcomes the hello
/// and answers its `ping`, then closes the connection when the next stream comes. Its address.
fn fails_after_hello(id: String, key: rapp_wire::Key) -> (std::net::SocketAddr, quinn::Endpoint, tempfile::TempDir) {
    let home = tempfile::tempdir().unwrap();
    let me = rapp_wire::Identity::generate().unwrap();
    let cfg = rapp_wire::tls::device_server_config(&me, &[rapp_wire::tls::ALPN_DEVICE]).unwrap();
    let ep = quinn::Endpoint::server(cfg, "127.0.0.1:0".parse().unwrap()).unwrap();
    let (addr, server, paired) = (ep.local_addr().unwrap(), ep.clone(), rapp_conn::Paired::empty(home.path()));
    tokio::spawn(async move {
        while let Some(incoming) = server.accept().await {
            let Ok(conn) = incoming.await else { continue };
            let Ok(pair) = conn.accept_bi().await else { continue };
            let mut pipe: Pipe = Box::new(rapp_net::quic::bi(pair));
            let facts = rapp_conn::quic_facts(&conn, &me.fp, rapp_conn::Role::Server).unwrap();
            let hello = rapp_conn::Me { id: &id, name: "fake-a", key: Some(&key) };
            rapp_conn::hello_server(&mut pipe, &facts, &hello, &paired).await.unwrap();
            assert_eq!(read_json(&mut pipe).await.unwrap()["op"], "ping");
            rapp_net::line::write_json(&mut pipe, &json!({"ok": true})).await.unwrap();
            pipe.shutdown().await.unwrap();
            let _ = conn.accept_bi().await;
            conn.close(0u32.into(), b"fake");
        }
    });
    (addr, ep, home)
}

#[tokio::test]
async fn a_lan_link_whose_request_fails_gives_way_to_the_relay() {
    let rig = RelayRig::start().await;
    let a = a_on_relay(&rig, Some(vec![])).await;
    let key = rapp_wire::Key { relay: rig.key.relay, root: rig.key.root };
    let (fake, _ep, _home) = fails_after_hello(a.id.clone(), key);
    let b = tempfile::tempdir().unwrap();
    let out = outbound(b.path());
    let lan = [fake.to_string()];
    let to = Target { id: &a.id, lan: &lan, known: None };
    let via = Via { relay: Some(&rig.addr), key: &rig.key };
    let sent = out.request(&via, &to, &Op::Ping).await.unwrap();
    assert_eq!((&sent.reply["ok"], sent.path), (&json!(true), "relay"), "{}", sent.reply);
    assert_eq!(sent.fp.to_string(), fp_of(&a).await);
    out.close();
}
