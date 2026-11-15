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
    // The access is on record while the stream is still open.
    let open = wait_log(a.home.path(), "forward_open", |v| v["port"] == port).await;
    assert_eq!((&open["fp"], &open["path"]), (&json!(b.id.fp.to_string()), &json!("lan")), "{open}");
    assert!(log_events(a.home.path()).iter().all(|v| v["ev"] != "forward"));
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
    // An address that does not answer, tried at the same time, does not hide the refusal.
    let (_socks, silent) = silent_addrs(1);
    let lan = [silent[0].clone(), a_addr(&a.svc).to_string()];
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

/// `n` addresses on `127.0.0.1` that take packets and never answer, as a LAN address does once
/// its device has left. The sockets must be kept for the addresses to stay silent.
fn silent_addrs(n: usize) -> (Vec<std::net::UdpSocket>, Vec<String>) {
    let socks: Vec<_> = (0..n).map(|_| std::net::UdpSocket::bind("127.0.0.1:0").unwrap()).collect();
    let addrs = socks.iter().map(|s| s.local_addr().unwrap().to_string()).collect();
    (socks, addrs)
}

#[tokio::test]
async fn silent_lan_addresses_cost_one_wait_and_the_relay_still_answers() {
    let rig = RelayRig::start().await;
    let (port, _echo) = echo().await;
    let a = a_on_relay(&rig, Some(vec![])).await;
    assert_eq!(ipc_once(&a.svc, a.home.path(), json!({"cmd":"share","ports":[port]})).await["ok"], true);
    let (_socks, lan) = silent_addrs(3);

    let dir = tempfile::tempdir().unwrap();
    let out = outbound(dir.path());
    let to = Target { id: &a.id, lan: &lan, known: None };
    let began = std::time::Instant::now();
    let sent = out.request(&Via { relay: Some(&rig.addr), key: &rig.key }, &to, &Op::Ping).await.unwrap();
    let took = began.elapsed();
    assert_eq!((&sent.reply["ok"], sent.path), (&json!(true), "relay"), "{}", sent.reply);
    // The three were waited for (they are silent, not refusing), all at the same time.
    assert!(took >= Duration::from_millis(900), "the LAN addresses were not tried: {took:?}");
    assert!(took < Duration::from_millis(2500), "took {took:?}");
    out.close();

    // The same through a service: its `hosts` lists what A offers, not `offline`.
    let b = a_on_relay(&rig, Some(vec![])).await;
    let hosts = json!([{"id": a.id, "name": "a", "lan": lan}]);
    std::fs::write(b.home.path().join("hosts.json"), hosts.to_string()).unwrap();
    let r = ipc_once(&b.svc, b.home.path(), json!({"cmd":"hosts"})).await;
    assert_eq!(r, json!({"ok":true,"hosts":[{"id": a.id, "name": "a", "shares": [{"port": port}]}]}));
}

#[tokio::test]
async fn relayed_requests_in_a_row_ask_the_relay_where_the_device_is_once() {
    let rig = RelayRig::start().await;
    let a = a_on_relay(&rig, Some(vec![])).await;
    let dir = tempfile::tempdir().unwrap();
    let out = outbound(dir.path());
    let via = Via { relay: Some(&rig.addr), key: &rig.key };
    // One LAN address that is dead: the first request waits for it, the next ones do not try it again.
    let (_socks, lan) = silent_addrs(1);
    let to = Target { id: &a.id, lan: &lan, known: None };
    let before = relay_connects(&rig, "ok");
    for i in 0..5 {
        let began = std::time::Instant::now();
        let sent = out.request(&via, &to, &Op::Ping).await.unwrap();
        let took = began.elapsed();
        assert_eq!((&sent.reply["ok"], sent.path), (&json!(true), "relay"), "{}", sent.reply);
        if i == 0 {
            assert!(took >= Duration::from_millis(900), "the LAN address was not tried: {took:?}");
        } else {
            assert!(took < Duration::from_millis(900), "request {i} tried the dead LAN address again: {took:?}");
        }
    }
    assert_eq!(relay_connects(&rig, "ok") - before, 1, "one `connect` for five relayed requests");

    // A relayed request that fails forgets what the relay said: the next one asks again.
    a.svc.stop();
    let deadline = tokio::time::Instant::now() + WAIT;
    while relay_connects(&rig, "offline") == 0 {
        let r = out.request(&via, &to, &Op::Ping).await;
        assert!(tokio::time::Instant::now() < deadline, "the relay was not asked again: {:?}", r.map(|s| s.reply));
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    assert_eq!(relay_connects(&rig, "ok") - before, 1);
    out.close();
}

// ---- the local IPC: shares, share, unshare (Task 7) ----

const SENSITIVE_WARN: &str = "分享这个端口，等于把这台机器能到的网络也交出去";

async fn ipc(a: &TestService) -> Ipc {
    Ipc::open(&a.svc, a.home.path()).await
}

/// The ports in a `shares` reply.
fn ports_of(r: &Value) -> Vec<u64> {
    r["shares"].as_array().unwrap_or_else(|| panic!("{r}")).iter().map(|s| s["port"].as_u64().unwrap()).collect()
}

/// The ports in `home/shares.json`.
fn saved_ports(home: &Path) -> Vec<u64> {
    let Ok(b) = std::fs::read(home.join("shares.json")) else { return vec![] };
    let v: Value = serde_json::from_slice(&b).unwrap();
    v.as_array().unwrap().iter().map(|s| s["port"].as_u64().unwrap()).collect()
}

#[tokio::test]
async fn share_then_shares_then_unshare() {
    let (port, _echo) = echo().await;
    let (a, _key) = start_sharing(|_| {}).await;
    let mut c = ipc(&a).await;
    let url = format!("http://{}.rapp:{port}", a.id);
    let r = c.call(json!({"cmd":"share","ports":[port]})).await;
    assert_eq!(r["ok"], true, "{r}");
    assert_eq!(r["shared"], json!([{"port": port, "url": url}]), "{r}");
    assert!(r["shared"][0].get("warn").is_none(), "{r}");
    let r = c.call(json!({"cmd":"shares"})).await;
    assert_eq!((&r["ok"], &r["id"]), (&json!(true), &json!(a.id)), "{r}");
    assert!(r["relay"].is_string(), "{r}");
    assert_eq!(ports_of(&r), [port as u64]);
    assert_eq!((&r["shares"][0]["listening"], &r["shares"][0]["url"]), (&json!(true), &json!(url)), "{r}");
    assert_eq!(r["shares"][0]["allow"], json!([]), "{r}");
    assert_eq!(saved_ports(a.home.path()), [port as u64]);
    assert_eq!(c.call(json!({"cmd":"unshare","port":port})).await, json!({"ok":true,"was":true}));
    assert_eq!(c.call(json!({"cmd":"unshare","port":port})).await, json!({"ok":true,"was":false}));
    assert!(saved_ports(a.home.path()).is_empty());
    assert!(ports_of(&c.call(json!({"cmd":"shares"})).await).is_empty());
    let l = wait_log(a.home.path(), "share", |v| v["port"] == port).await;
    assert_eq!(l["allow"], 0, "{l}");
    wait_log(a.home.path(), "unshare", |v| v["port"] == port).await;
}

#[tokio::test]
async fn shares_says_when_nothing_listens_and_keeps_the_note() {
    let port = dead_port().await;
    let (a, _key) = start_sharing(|_| {}).await;
    let mut c = ipc(&a).await;
    assert_eq!(c.call(json!({"cmd":"share","ports":[port],"note":"模型"})).await["ok"], true);
    let r = c.call(json!({"cmd":"shares"})).await;
    assert_eq!((&r["shares"][0]["listening"], &r["shares"][0]["note"]), (&json!(false), &json!("模型")), "{r}");
}

// The probe looks where a forward would connect: `[::1]` when `127.0.0.1` does not accept.
#[tokio::test]
async fn shares_sees_a_service_that_listens_on_ipv6_loopback_only() {
    let Ok(l) = TcpListener::bind("[::1]:0").await else {
        eprintln!("no IPv6 loopback here: skipped");
        return;
    };
    let (port, _echo) = echo_on(l);
    let (a, _key) = sharing_ports(&[port]).await;
    let r = ipc_once(&a.svc, a.home.path(), json!({"cmd":"shares"})).await;
    assert_eq!((&r["shares"][0]["port"], &r["shares"][0]["listening"]), (&json!(port), &json!(true)), "{r}");
}

#[tokio::test]
async fn sharing_a_sensitive_port_warns_and_still_shares() {
    let (a, _key) = start_sharing(|_| {}).await;
    let mut c = ipc(&a).await;
    let r = c.call(json!({"cmd":"share","ports":[8000, 22]})).await;
    assert_eq!(r["ok"], true, "{r}");
    assert!(r["shared"][0].get("warn").is_none(), "{r}");
    assert_eq!(r["shared"][1]["port"], 22, "{r}");
    assert_eq!(r["shared"][1]["warn"], SENSITIVE_WARN, "{r}");
    assert_eq!(r["shared"][1]["url"], format!("http://{}.rapp:22", a.id), "{r}");
    assert_eq!(ports_of(&c.call(json!({"cmd":"shares"})).await), [22, 8000]);
}

#[tokio::test]
async fn bad_ports_are_refused_before_anything_is_saved() {
    let (a, _key) = start_sharing(|_| {}).await;
    let mut c = ipc(&a).await;
    let bad = json!({"ok":false,"error":"bad port"});
    for ports in [json!([8000, 0]), json!([8000, 70000]), json!(["x"]), json!([]), json!([8000, -1]), json!([8000.5]), json!(8000)] {
        assert_eq!(c.call(json!({"cmd":"share","ports":ports})).await, bad, "{ports}");
        assert!(ports_of(&c.call(json!({"cmd":"shares"})).await).is_empty(), "{ports}");
    }
    assert_eq!(c.call(json!({"cmd":"share"})).await, bad);
    assert!(saved_ports(a.home.path()).is_empty());
    assert!(log_events(a.home.path()).iter().all(|v| v["ev"] != "share"));
}

#[tokio::test]
async fn the_65th_share_is_refused_and_nothing_of_it_is_saved() {
    let (a, _key) = start_sharing(|_| {}).await;
    let mut c = ipc(&a).await;
    let first: Vec<u16> = (10001..=10063).collect();
    assert_eq!(c.call(json!({"cmd":"share","ports":first})).await["ok"], true);
    assert_eq!(c.call(json!({"cmd":"share","ports":[20001, 20002]})).await, json!({"ok":false,"error":"limit"}));
    assert_eq!(saved_ports(a.home.path()).len(), 63);
    assert_eq!(c.call(json!({"cmd":"share","ports":[20001]})).await["ok"], true);
}

#[tokio::test]
async fn allow_names_a_known_device_or_is_refused() {
    let (port, _echo) = echo().await;
    let (a, key) = start_sharing(|_| {}).await;
    let b = visitor();
    // B connects once, so A's paired.json has B under the name B said.
    let (r, _, _conn) = ask(&a, &key, &b, json!({"op":"list_shares"})).await;
    assert_eq!(r, json!({"ok":true,"shares":[]}));
    let mut c = ipc(&a).await;
    let r = c.call(json!({"cmd":"share","ports":[port],"allow":["test-b"]})).await;
    assert_eq!(r["ok"], true, "{r}");
    let r = c.call(json!({"cmd":"shares"})).await;
    assert_eq!(r["shares"][0]["allow"], json!(["test-b"]), "{r}");
    let saved: Value = serde_json::from_slice(&std::fs::read(a.home.path().join("shares.json")).unwrap()).unwrap();
    assert_eq!(saved[0]["allow"], json!([b.id.fp.to_string()]));
    let l = wait_log(a.home.path(), "share", |v| v["port"] == port).await;
    assert_eq!(l["allow"], 1, "{l}");
    // B may use it; the fingerprint prefix means B too
    let (r, _, _conn) = ask(&a, &key, &b, json!({"op":"list_shares"})).await;
    assert_eq!(r, json!({"ok":true,"shares":[{"port":port}]}));
    let prefix = &b.id.fp.to_string()[..8].to_ascii_uppercase();
    assert_eq!(c.call(json!({"cmd":"share","ports":[port],"allow":[prefix]})).await["ok"], true);
    assert_eq!(c.call(json!({"cmd":"share","ports":[port],"allow":["nobody"]})).await,
               json!({"ok":false,"error":"unknown device: nobody"}));
    // a blank entry names no device
    for blank in ["", "  "] {
        assert_eq!(c.call(json!({"cmd":"share","ports":[port + 1],"allow":[blank]})).await,
                   json!({"ok":false,"error":format!("unknown device: {blank}")}), "{blank:?}");
    }
    // nothing of a refused share is saved
    assert_eq!(c.call(json!({"cmd":"share","ports":[port, port + 1],"allow":["test-b","nobody"]})).await["ok"], false);
    assert_eq!(saved_ports(a.home.path()), [port as u64]);
}

#[tokio::test]
async fn an_allow_that_means_two_devices_is_ambiguous() {
    let (a, key) = start_sharing(|_| {}).await;
    // two devices that both say they are `test-b`
    for b in [visitor(), visitor()] {
        let (r, _, _conn) = ask(&a, &key, &b, json!({"op":"list_shares"})).await;
        assert_eq!(r["ok"], true, "{r}");
    }
    let r = ipc_once(&a.svc, a.home.path(), json!({"cmd":"share","ports":[8000],"allow":["test-b"]})).await;
    assert_eq!(r, json!({"ok":false,"error":"ambiguous device: test-b"}));
    assert!(saved_ports(a.home.path()).is_empty());
}

#[tokio::test]
async fn unshare_cuts_what_is_running() {
    let (port, _echo) = echo().await;
    let (a, key) = sharing_ports(&[port]).await;
    let (r, mut s, _conn) = forward(&a, &key, &visitor(), port).await;
    assert_eq!(r, json!({"ok":true}));
    s.write_all(b"hello").await.unwrap();
    let mut got = [0u8; 5];
    tokio::time::timeout(WAIT, s.read_exact(&mut got)).await.unwrap().unwrap();
    assert_eq!(&got, b"hello");
    let r = ipc_once(&a.svc, a.home.path(), json!({"cmd":"unshare","port":port})).await;
    assert_eq!(r, json!({"ok":true,"was":true}));
    let mut b = [0u8; 16];
    let read = tokio::time::timeout(Duration::from_secs(2), s.read(&mut b)).await.expect("cut within 2 s");
    assert!(matches!(read, Ok(0) | Err(_)), "{read:?}");
}

#[tokio::test]
async fn narrowing_allow_cuts_the_forward_of_a_device_it_leaves_out() {
    let (port, _echo) = echo().await;
    let (a, key) = sharing_ports(&[port]).await;
    // B and C each have a forward running (and A knows both from their hellos).
    let (b, c) = (visitor(), visitor());
    let (r, mut to_b, _b_conn) = forward(&a, &key, &b, port).await;
    assert_eq!(r, json!({"ok":true}));
    let (r, _to_c, _c_conn) = forward(&a, &key, &c, port).await;
    assert_eq!(r, json!({"ok":true}));
    to_b.write_all(b"hello").await.unwrap();
    let mut got = [0u8; 5];
    tokio::time::timeout(WAIT, to_b.read_exact(&mut got)).await.unwrap().unwrap();
    assert_eq!(&got, b"hello");
    // From now on only C.
    let only_c = c.id.fp.to_string()[..8].to_string();
    let r = ipc_once(&a.svc, a.home.path(), json!({"cmd":"share","ports":[port],"allow":[only_c]})).await;
    assert_eq!(r["ok"], true, "{r}");
    let mut buf = [0u8; 16];
    let read = tokio::time::timeout(Duration::from_secs(2), to_b.read(&mut buf)).await.expect("cut within 2 s");
    assert!(matches!(read, Ok(0) | Err(_)), "{read:?}");
    // B cannot come back; C can.
    let (r, _, _conn) = forward(&a, &key, &b, port).await;
    assert_eq!(r, json!({"ok":false,"error":"not allowed"}));
    let (r, _, _conn) = forward(&a, &key, &c, port).await;
    assert_eq!(r, json!({"ok":true}));
}

#[tokio::test]
async fn sharing_again_without_allow_keeps_the_restriction() {
    let (port, _echo) = echo().await;
    let (a, key) = start_sharing(|_| {}).await;
    let b = visitor();
    // B connects once, so A's paired.json has B under the name B said.
    let (r, _, _conn) = ask(&a, &key, &b, json!({"op":"list_shares"})).await;
    assert_eq!(r["ok"], true, "{r}");
    let mut c = ipc(&a).await;
    let restricted = json!([{"port": port, "url": format!("http://{}.rapp:{port}", a.id), "allow": ["test-b"]}]);
    let r = c.call(json!({"cmd":"share","ports":[port],"allow":["test-b"],"note":"模型","raw":true})).await;
    assert_eq!((&r["ok"], &r["shared"]), (&json!(true), &restricted), "{r}");
    let (r, mut s, _conn) = forward(&a, &key, &b, port).await;
    assert_eq!(r, json!({"ok":true}));

    // Again, with nothing but the port: the share stays as it is, and the reply says who it is for.
    let r = c.call(json!({"cmd":"share","ports":[port]})).await;
    assert_eq!((&r["ok"], &r["shared"]), (&json!(true), &restricted), "{r}");
    let saved = || -> Value { serde_json::from_slice(&std::fs::read(a.home.path().join("shares.json")).unwrap()).unwrap() };
    assert_eq!(saved(), json!([{"port": port, "note": "模型", "allow": [b.id.fp.to_string()], "raw": true}]));
    let r = c.call(json!({"cmd":"shares"})).await;
    assert_eq!((&r["shares"][0]["allow"], &r["shares"][0]["note"]), (&json!(["test-b"]), &json!("模型")), "{r}");
    // Another device is still kept out, and B's forward was not cut: `allow` did not change.
    let (r, _, _conn) = forward(&a, &key, &visitor(), port).await;
    assert_eq!(r, json!({"ok":false,"error":"not allowed"}));
    tokio::time::sleep(Duration::from_millis(300)).await;
    s.write_all(b"still").await.unwrap();
    let mut got = [0u8; 5];
    tokio::time::timeout(WAIT, s.read_exact(&mut got)).await.unwrap().unwrap();
    assert_eq!(&got, b"still");

    // A field that is given replaces that field only.
    let r = c.call(json!({"cmd":"share","ports":[port],"note":"","raw":false})).await;
    assert_eq!((&r["ok"], &r["shared"]), (&json!(true), &restricted), "{r}");
    assert_eq!(saved(), json!([{"port": port, "allow": [b.id.fp.to_string()]}]));
    // A port that was not shared starts open to every trusted device: no `allow` in the reply.
    let r = c.call(json!({"cmd":"share","ports":[port, 8000]})).await;
    assert_eq!(r["shared"][0], restricted[0], "{r}");
    assert_eq!(r["shared"][1], json!({"port": 8000, "url": format!("http://{}.rapp:8000", a.id)}), "{r}");
    // The restriction goes with `unshare`, then `share`.
    assert_eq!(c.call(json!({"cmd":"unshare","port":port})).await, json!({"ok":true,"was":true}));
    let r = c.call(json!({"cmd":"share","ports":[port]})).await;
    assert!(r["shared"][0].get("allow").is_none(), "{r}");
    let (r, _, _conn) = forward(&a, &key, &visitor(), port).await;
    assert_eq!(r, json!({"ok":true}));
}

// ---- the local IPC: hosts and pipe, the simple local cases (Task 8 covers them end to end) ----

#[tokio::test]
async fn hosts_is_empty_without_a_hosts_file() {
    let a = service().await;
    assert_eq!(ipc_once(&a.svc, a.home.path(), json!({"cmd":"hosts"})).await, json!({"ok":true,"hosts":[]}));
}

// A on `rig` sharing an echo port; B, another service on `rig`, whose `hosts.json` names A with its LAN address.
#[tokio::test]
async fn pipe_carries_the_port_and_bytes_right_behind_the_command() {
    let rig = RelayRig::start().await;
    let (port, _echo) = echo().await;
    let a = a_on_relay(&rig, Some(vec![])).await;
    assert_eq!(ipc_once(&a.svc, a.home.path(), json!({"cmd":"share","ports":[port]})).await["ok"], true);
    let b = a_on_relay(&rig, Some(vec![])).await;
    let hosts = json!([{"id": a.id, "name": "a", "lan": [a_addr(&a.svc).to_string()]}]);
    std::fs::write(b.home.path().join("hosts.json"), hosts.to_string()).unwrap();
    // The token line, the pipe command and the first bytes in one write.
    let token = std::fs::read_to_string(b.home.path().join("ipc.token")).unwrap();
    let mut tcp = tokio::net::TcpStream::connect(("127.0.0.1", b.svc.ipc_port)).await.unwrap();
    let cmd = json!({"cmd":"pipe","to":format!("{}.rapp", a.id),"port":port});
    tcp.write_all(format!("{}\n{cmd}\nhello", json!({"token": token.trim()})).as_bytes()).await.unwrap();
    let mut line = Vec::new();
    while !line.ends_with(b"\n") {
        let mut one = [0u8; 1];
        tokio::time::timeout(WAIT, tcp.read_exact(&mut one)).await.expect("reply in time").unwrap();
        line.push(one[0]);
    }
    let r: Value = serde_json::from_slice(&line).unwrap();
    assert_eq!(r, json!({"ok":true,"path":"lan"}));
    let mut got = [0u8; 5];
    tokio::time::timeout(WAIT, tcp.read_exact(&mut got)).await.unwrap().unwrap();
    assert_eq!(&got, b"hello");
    // the IPC connection is the port's stream now: a half-close goes through, and the end comes back
    tcp.write_all(b" world").await.unwrap();
    tcp.shutdown().await.unwrap();
    let mut rest = Vec::new();
    tokio::time::timeout(WAIT, tcp.read_to_end(&mut rest)).await.unwrap().unwrap();
    assert_eq!(rest, b" world");
    // and B's hosts lists what A offers B
    let r = ipc_once(&b.svc, b.home.path(), json!({"cmd":"hosts"})).await;
    assert_eq!(r, json!({"ok":true,"hosts":[{"id": a.id, "name": "a", "shares": [{"port": port}]}]}));
}

#[tokio::test]
async fn a_device_that_gave_no_name_shows_its_fingerprint_prefix() {
    let fp = rapp_wire::Fp([0x12; 32]).to_string();
    let entry = json!([{"fp": fp, "name": "", "since": "2026-11-15T00:00:00Z"}]);
    let (a, _key) = start_sharing(|home| std::fs::write(home.join("paired.json"), entry.to_string()).unwrap()).await;
    let mut c = ipc(&a).await;
    assert_eq!(c.call(json!({"cmd":"share","ports":[8000],"allow":[""]})).await,
               json!({"ok":false,"error":"unknown device: "}));
    assert_eq!(c.call(json!({"cmd":"share","ports":[8000],"allow":[&fp[..8]]})).await["ok"], true);
    let r = c.call(json!({"cmd":"shares"})).await;
    assert_eq!(r["shares"][0]["allow"], json!([&fp[..8]]), "{r}");
}

// A name in paired.json is what another device said: the replies carry it made safe to show.
#[tokio::test]
async fn allow_names_in_the_replies_have_no_control_characters() {
    let fp = rapp_wire::Fp([0x34; 32]).to_string();
    let entry = json!([{"fp": fp, "name": "mi\u{1b}[31mni\n", "since": "2026-11-15T00:00:00Z"}]);
    let (a, _key) = start_sharing(|home| std::fs::write(home.join("paired.json"), entry.to_string()).unwrap()).await;
    let mut c = ipc(&a).await;
    let r = c.call(json!({"cmd":"share","ports":[8000],"allow":[&fp[..8]]})).await;
    assert_eq!((&r["ok"], &r["shared"][0]["allow"]), (&json!(true), &json!(["mi[31mni"])), "{r}");
    let r = c.call(json!({"cmd":"shares"})).await;
    assert_eq!(r["shares"][0]["allow"], json!(["mi[31mni"]), "{r}");
}

// ---- pipe end to end, over the LAN and over the relay (Task 8) ----
//
// `pipe_over_the_lan` and `bytes_sent_right_behind_the_command_are_not_lost` of the plan are
// `pipe_carries_the_port_and_bytes_right_behind_the_command` above: it pipes over the LAN path,
// sends the token line, the command and the first bytes in one write, and checks the echo.

/// Opens B's IPC, sends the token line and a `pipe` command, and reads back the first line only
/// (byte by byte, so nothing of what follows is taken). The reply and the TCP connection.
async fn pipe(ipc_port: u16, token: &str, to: &str, port: u16) -> (Value, tokio::net::TcpStream) {
    let mut tcp = tokio::net::TcpStream::connect(("127.0.0.1", ipc_port)).await.unwrap();
    let cmd = json!({"cmd":"pipe","to":to,"port":port});
    tcp.write_all(format!("{}\n{cmd}\n", json!({"token": token})).as_bytes()).await.unwrap();
    let mut line = Vec::new();
    while !line.ends_with(b"\n") {
        let mut one = [0u8; 1];
        let n = tokio::time::timeout(WAIT, tcp.read(&mut one)).await.expect("reply in time").unwrap();
        assert_eq!(n, 1, "the connection ended before the reply: {:?}", String::from_utf8_lossy(&line));
        line.push(one[0]);
    }
    (serde_json::from_slice(&line).unwrap(), tcp)
}

fn token_of(home: &Path) -> String {
    std::fs::read_to_string(home.join("ipc.token")).unwrap().trim().to_string()
}

/// A and B on one relay, neither registering a LAN address and B with no `hosts.json`, so a
/// pipe from B to A can only go through the relay. A shares an echo port.
struct OverRelay {
    rig: RelayRig,
    a: TestService,
    b: TestService,
    port: u16,
    _echo: JoinHandle<()>,
}

async fn over_relay() -> OverRelay {
    over_relay_on(RelayRig::start().await).await
}

async fn over_relay_on(rig: RelayRig) -> OverRelay {
    let (port, echo) = echo().await;
    let a = a_on_relay(&rig, Some(vec![])).await;
    assert_eq!(ipc_once(&a.svc, a.home.path(), json!({"cmd":"share","ports":[port]})).await["ok"], true);
    let b = a_on_relay(&rig, Some(vec![])).await;
    assert!(!b.home.path().join("hosts.json").exists());
    OverRelay { rig, a, b, port, _echo: echo }
}

impl OverRelay {
    async fn pipe(&self) -> (Value, tokio::net::TcpStream) {
        pipe(self.b.svc.ipc_port, &token_of(self.b.home.path()), &format!("{}.rapp", self.a.id), self.port).await
    }
}

/// Waits until the relay has written down more than `before` streams.
async fn streams_grow(rig: &RelayRig, before: u64) {
    let deadline = tokio::time::Instant::now() + WAIT;
    while rig.streams() <= before {
        assert!(tokio::time::Instant::now() < deadline, "nothing went through the relay");
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
}

/// Writes `sent`, finishes writing, and reads the connection to its end.
async fn echo_through(tcp: tokio::net::TcpStream, sent: &[u8]) -> Vec<u8> {
    let (mut rd, mut wr) = tcp.into_split();
    let data = sent.to_vec();
    let writer = tokio::spawn(async move {
        wr.write_all(&data).await.unwrap();
        wr.shutdown().await.unwrap();
        wr
    });
    let mut got = Vec::new();
    tokio::time::timeout(WAIT, rd.read_to_end(&mut got)).await.expect("the echo ends in time").unwrap();
    writer.await.unwrap();
    got
}

#[tokio::test]
async fn pipe_over_the_relay() {
    let t = over_relay().await;
    let before = t.rig.streams();
    let (r, mut tcp) = t.pipe().await;
    assert_eq!(r, json!({"ok":true,"path":"relay"}));
    tcp.write_all(b"hello").await.unwrap();
    let mut got = [0u8; 5];
    tokio::time::timeout(WAIT, tcp.read_exact(&mut got)).await.unwrap().unwrap();
    assert_eq!(&got, b"hello");
    // The relay writes a stream down when it ends.
    drop(tcp);
    streams_grow(&t.rig, before).await;
}

#[tokio::test]
async fn half_close_survives_the_relay() {
    let t = over_relay().await;
    let (r, tcp) = t.pipe().await;
    assert_eq!(r, json!({"ok":true,"path":"relay"}));
    let sent: Vec<u8> = (0..1 << 20).map(|i| (i % 251) as u8).collect();
    let got = echo_through(tcp, &sent).await;
    assert_eq!(got.len(), 1 << 20);
    assert!(got == sent, "the echo differs from what was sent");
}

/// Every regular file under `dir`, recursively (not the relay's admin socket).
fn files_under(dir: &Path) -> Vec<std::path::PathBuf> {
    let mut out = Vec::new();
    for e in std::fs::read_dir(dir).unwrap() {
        let e = e.unwrap();
        let kind = e.file_type().unwrap();
        if kind.is_dir() {
            out.extend(files_under(&e.path()));
        } else if kind.is_file() {
            out.push(e.path());
        }
    }
    out
}

#[tokio::test]
async fn the_relay_saw_nothing_it_could_read() {
    let t = over_relay().await;
    let before = t.rig.streams();
    let (r, tcp) = t.pipe().await;
    assert_eq!(r, json!({"ok":true,"path":"relay"}));
    let marker = b"rapp-marker:7f3c9e21a4b8d056e1f2";
    assert_eq!(marker.len(), 32);
    assert_eq!(echo_through(tcp, marker).await, marker);
    // `streams` flushes the audit, so what the relay keeps is on disk once it has grown.
    streams_grow(&t.rig, before).await;
    let files = files_under(t.rig.data.path());
    assert!(!files.is_empty());
    let port_fields = [format!("\"port\":{}", t.port), format!("\"port\": {}", t.port)];
    for f in files {
        let bytes = std::fs::read(&f).unwrap();
        assert!(!bytes.windows(marker.len()).any(|w| w == marker), "{} holds the marker", f.display());
        let text = String::from_utf8_lossy(&bytes);
        for field in &port_fields {
            assert!(!text.contains(field.as_str()), "{} holds {field}", f.display());
        }
        assert!(!text.contains("forward"), "{} mentions forward", f.display());
    }
}

/// `cmd` on `c` answers the error `want`, and the same connection still answers `status`.
async fn check(c: &mut Ipc, cmd: Value, want: &str) {
    assert_eq!(c.call(cmd.clone()).await, json!({"ok":false,"error":want}), "{cmd}");
    assert_eq!(c.call(json!({"cmd":"status"})).await["ok"], true, "after {cmd}");
}

/// Retries `cmd` on `c` until its reply is `want` (within `WAIT`).
async fn call_until(c: &mut Ipc, cmd: Value, want: Value) {
    let deadline = tokio::time::Instant::now() + WAIT;
    loop {
        let r = c.call(cmd.clone()).await;
        if r == want {
            return;
        }
        assert!(tokio::time::Instant::now() < deadline, "{cmd} still answers {r}, not {want}");
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
}

#[tokio::test]
async fn pipe_errors() {
    let rig = RelayRig::start().await;
    let a = a_on_relay(&rig, Some(vec![])).await;
    let mut a_ipc = ipc(&a).await;
    let to_a = format!("{}.rapp", a.id);
    // B starts with no key in its service.json.
    let b = service().await;
    let mut c = ipc(&b).await;
    let pipe_to = |to: &str, port: u16| json!({"cmd":"pipe","to":to,"port":port});
    let error = |e: &str| json!({"ok":false,"error":e});
    check(&mut c, pipe_to("gpu1.rapp", 22), "unknown name").await;
    check(&mut c, pipe_to(&to_a, 22), "no key").await;
    check(&mut c, pipe_to(&to_a, 0), "bad port").await;

    // B on the relay, with no hosts.json: everything goes by the relay.
    let r = c.call(json!({"cmd":"set_relay","relay":rig.addr,"key":rig.key.to_string()})).await;
    assert_eq!(r["ok"], true, "{r}");
    check(&mut c, pipe_to("999999999.rapp", 22), "offline").await;

    let shared = dead_port().await;
    check(&mut c, pipe_to(&to_a, shared), "not shared").await;
    // shared with another device only: one that A knows, so that `allow` can name it
    let other = visitor();
    let (r, _, _conn) = ask(&a, &rig.key, &other, json!({"op":"list_shares"})).await;
    assert_eq!(r["ok"], true, "{r}");
    let prefix = other.id.fp.to_string()[..8].to_string();
    let r = a_ipc.call(json!({"cmd":"share","ports":[shared],"allow":[prefix]})).await;
    assert_eq!(r["ok"], true, "{r}");
    check(&mut c, pipe_to(&to_a, shared), "not allowed").await;
    // shared with everyone, nothing listening (sharing again keeps `allow`: unshare first)
    assert_eq!(a_ipc.call(json!({"cmd":"unshare","port":shared})).await["ok"], true);
    assert_eq!(a_ipc.call(json!({"cmd":"share","ports":[shared]})).await["ok"], true);
    check(&mut c, pipe_to(&to_a, shared), "refused").await;

    // any other failure is the dialer's text: a device whose key differs is not trusted
    let hosts = json!([{"id": a.id, "name": "a", "lan": [a_addr(&a.svc).to_string()]}]);
    std::fs::write(b.home.path().join("hosts.json"), hosts.to_string()).unwrap();
    let other_key = rapp_wire::Key::new_local();
    let r = c.call(json!({"cmd":"set_relay","relay":"","key":other_key.to_string()})).await;
    assert_eq!(r["ok"], true, "{r}");
    check(&mut c, pipe_to(&to_a, shared), "not trusted").await;

    // a device the relay knows, but that is down
    std::fs::remove_file(b.home.path().join("hosts.json")).unwrap();
    let r = c.call(json!({"cmd":"set_relay","relay":rig.addr,"key":rig.key.to_string()})).await;
    assert_eq!(r["ok"], true, "{r}");
    drop(a_ipc);
    a.svc.stop();
    // The relay learns A is gone a moment after.
    call_until(&mut c, pipe_to(&to_a, shared), error("offline")).await;
    assert_eq!(c.call(json!({"cmd":"status"})).await["ok"], true);
}

#[tokio::test]
async fn hosts_lists_what_each_device_offers_this_one() {
    let rig = RelayRig::start().await;
    let (p, _echo) = echo().await;
    let q = dead_port().await;
    let a = a_on_relay(&rig, Some(vec![])).await;
    // Q only for another device, one that A knows so that `allow` can name it
    let other = visitor();
    let (r, _, _conn) = ask(&a, &rig.key, &other, json!({"op":"list_shares"})).await;
    assert_eq!(r["ok"], true, "{r}");
    let mut a_ipc = ipc(&a).await;
    assert_eq!(a_ipc.call(json!({"cmd":"share","ports":[p]})).await["ok"], true);
    let prefix = other.id.fp.to_string()[..8].to_string();
    assert_eq!(a_ipc.call(json!({"cmd":"share","ports":[q],"allow":[prefix]})).await["ok"], true);
    let b = a_on_relay(&rig, Some(vec![])).await;
    let made_up = "999999999";
    let hosts = json!([{"id": a.id, "name": "a"}, {"id": made_up, "name": "ghost"}]);
    std::fs::write(b.home.path().join("hosts.json"), hosts.to_string()).unwrap();
    let r = ipc_once(&b.svc, b.home.path(), json!({"cmd":"hosts"})).await;
    assert_eq!(r["ok"], true, "{r}");
    let entry = |id: &str| r["hosts"].as_array().unwrap().iter().find(|h| h["id"] == id).cloned().unwrap_or_else(|| panic!("{id}: {r}"));
    assert_eq!(entry(&a.id), json!({"id": a.id, "name": "a", "shares": [{"port": p}]}));
    assert_eq!(entry(made_up), json!({"id": made_up, "name": "ghost", "error": "offline"}));
    assert_eq!(r["hosts"].as_array().unwrap().len(), 2, "{r}");
}

/// `rapp-cli`, built next to the other programs of this test run. `cargo build` is the same
/// build the test run itself did (a no-op when the binary is current); it is bounded so a held
/// build lock cannot make the test wait forever.
fn cli_bin() -> std::path::PathBuf {
    static BIN: std::sync::OnceLock<std::path::PathBuf> = std::sync::OnceLock::new();
    BIN.get_or_init(|| {
        let dir = Path::new(env!("CARGO_BIN_EXE_fake-rapp-host")).parent().unwrap().to_path_buf();
        let mut build = std::process::Command::new(std::env::var_os("CARGO").unwrap_or_else(|| "cargo".into()));
        build.args(["build", "-p", "rapp-cli", "--quiet"]);
        if dir.file_name().is_some_and(|n| n == "release") {
            build.arg("--release");
        }
        let mut child = build.spawn().expect("cargo starts");
        let deadline = std::time::Instant::now() + Duration::from_secs(300);
        loop {
            match child.try_wait().unwrap() {
                Some(status) => {
                    assert!(status.success(), "cargo build -p rapp-cli failed");
                    break;
                }
                None if std::time::Instant::now() > deadline => {
                    let _ = child.kill();
                    panic!("cargo build -p rapp-cli took too long");
                }
                None => std::thread::sleep(Duration::from_millis(100)),
            }
        }
        let bin = dir.join("rapp-cli");
        assert!(bin.exists(), "{} was not built", bin.display());
        bin
    })
    .clone()
}

/// A `local/` directory the program can find a service by: the service's token, and the IPC port
/// the test's service picked (its own `service.json` says 0).
fn cli_local(svc: &TestService) -> tempfile::TempDir {
    let dir = tempfile::tempdir().unwrap();
    std::fs::write(dir.path().join("ipc.token"), token_of(svc.home.path())).unwrap();
    std::fs::write(dir.path().join("service.json"), json!({"ipc_port": svc.svc.ipc_port}).to_string()).unwrap();
    dir
}

/// Runs `rapp-cli args` against `local`, feeding `stdin` and then closing it.
async fn cli(local: &Path, args: &[&str], stdin: &[u8]) -> std::process::Output {
    let mut child = tokio::process::Command::new(cli_bin())
        .args(args)
        .env("RAPP_LOCAL", local)
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .spawn()
        .unwrap();
    let mut input = child.stdin.take().unwrap();
    input.write_all(stdin).await.unwrap();
    drop(input);
    tokio::time::timeout(WAIT, child.wait_with_output()).await.expect("the program ends in time").unwrap()
}

#[tokio::test]
async fn the_cli_shares_and_pipes() {
    let rig = over_relay().await;
    let (a_local, b_local) = (cli_local(&rig.a), cli_local(&rig.b));
    let (port, _echo) = echo().await;
    let out = cli(a_local.path(), &["share", &port.to_string()], b"").await;
    assert_eq!(String::from_utf8_lossy(&out.stdout), format!("已分享：http://{}.rapp:{port}\n", rig.a.id));
    assert_eq!(out.status.code(), Some(0));

    let out = cli(a_local.path(), &["share"], b"").await;
    assert!(String::from_utf8_lossy(&out.stdout).contains(&format!("http://{}.rapp:{port}", rig.a.id)));

    let out = cli(b_local.path(), &["pipe", &format!("{}.rapp", rig.a.id), &port.to_string()], b"hello").await;
    assert_eq!(out.stdout, b"hello");
    assert_eq!(out.status.code(), Some(0), "{}", String::from_utf8_lossy(&out.stderr));

    // B has connected, so A knows it by the name it gave. A share narrowed to B says so, and
    // sharing the port again with nothing but the port keeps it narrowed.
    let narrowed = format!("已分享：http://{}.rapp:{port}\n只给：test-a\n", rig.a.id);
    let out = cli(a_local.path(), &["share", &port.to_string(), "--allow", "test-a"], b"").await;
    assert_eq!(String::from_utf8_lossy(&out.stdout), narrowed, "{}", String::from_utf8_lossy(&out.stderr));
    let out = cli(a_local.path(), &["share", &port.to_string()], b"").await;
    assert_eq!(String::from_utf8_lossy(&out.stdout), narrowed);
    // An option with no port is an error, not the table.
    let out = cli(a_local.path(), &["share", "--raw"], b"").await;
    assert_eq!(out.status.code(), Some(2));
    assert!(String::from_utf8_lossy(&out.stderr).starts_with("要写端口\n"), "{}", String::from_utf8_lossy(&out.stderr));
    assert!(out.stdout.is_empty());

    let out = cli(b_local.path(), &["pipe", &rig.a.id, "9"], b"").await;
    assert_eq!(out.status.code(), Some(1));
    assert_eq!(String::from_utf8_lossy(&out.stderr), format!("{0} 没有分享 9。在 {0} 上运行 rapp share 9\n", rig.a.id));

    let out = cli(a_local.path(), &["unshare", &port.to_string()], b"").await;
    assert_eq!(out.status.code(), Some(0));
    let out = cli(b_local.path(), &["pipe", &rig.a.id, &port.to_string()], b"").await;
    assert_eq!(out.status.code(), Some(1));

    let empty = tempfile::tempdir().unwrap();
    let out = cli(empty.path(), &["share"], b"").await;
    assert_eq!(out.status.code(), Some(1));
    assert_eq!(String::from_utf8_lossy(&out.stderr), "本机的 rapp 服务没有在运行\n");
}

// ---- the forward measurement (Task 10) ----

#[tokio::test]
async fn measure_the_forward_over_the_relay() {
    // 100 forwards to one device in a few seconds: more than the relay's default of 60 a minute.
    let t = over_relay_on(RelayRig::start_with_connect_limit(1000).await).await;
    let plan = rapp_testkit::Plan {
        ipc_port: t.b.svc.ipc_port,
        token: token_of(t.b.home.path()),
        to: format!("{}.rapp", t.a.id),
        port: t.port,
        n: 50,
        parallel: 6,
    };
    let report = rapp_testkit::measure(&plan).await.unwrap();
    assert_eq!(report.open_seq.len(), 50);
    assert_eq!(report.open_par.len(), 50);
    assert_eq!(report.first_byte.len(), 50);
    // Nothing registered a LAN address, so every forward went through the relay.
    assert_eq!(report.path.keys().collect::<Vec<_>>(), ["relay"]);
    assert_eq!(report.path["relay"], 100);
    let lines = report.lines();
    assert_eq!(lines.len(), 4);
    assert!(lines[0].starts_with("open_seq") && lines[3].starts_with("path") && lines[3].ends_with("relay=100"), "{lines:?}");
    eprintln!("{}", lines.join("\n"));
}

#[tokio::test]
async fn a_local_share_and_unshare_are_logged_as_local() {
    let (a, _key) = start_sharing(|_| {}).await;
    let mut c = ipc(&a).await;
    assert_eq!(c.call(json!({"cmd":"share","ports":[8000]})).await["ok"], true);
    let l = wait_log(a.home.path(), "share", |v| v["port"] == 8000).await;
    assert_eq!(l["by"], "local", "{l}");
    assert_eq!(c.call(json!({"cmd":"unshare","port":8000})).await, json!({"ok":true,"was":true}));
    let l = wait_log(a.home.path(), "unshare", |v| v["port"] == 8000).await;
    assert_eq!(l["by"], "local", "{l}");
}

#[tokio::test]
async fn ipc_allow_takes_a_full_fingerprint_it_does_not_know() {
    let (a, _key) = start_sharing(|_| {}).await;
    let mut c = ipc(&a).await;
    let fp = rapp_wire::Identity::generate().unwrap().fp.to_string();
    assert_eq!(fp.len(), 64);
    let r = c.call(json!({"cmd":"share","ports":[8000],"allow":[fp]})).await;
    assert_eq!(r["ok"], true, "{r}");
    let saved: Value = serde_json::from_slice(&std::fs::read(a.home.path().join("shares.json")).unwrap()).unwrap();
    assert_eq!(saved[0]["allow"], json!([fp]), "{saved}");
    let r = c.call(json!({"cmd":"share","ports":[8001],"allow":["abababab"]})).await;
    assert_eq!(r, json!({"ok":false,"error":"unknown device: abababab"}));
}
