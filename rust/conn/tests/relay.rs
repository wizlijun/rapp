use std::time::Duration;

use rapp_conn::relay::{Pushed, RelayConn};
use rapp_conn::{e2e_accept, e2e_connect};
use rapp_net::log::Log;
use rapp_relay::config::Config;
use rapp_relay::server::{Opts, Relay};
use rapp_wire::{join_hash, Fp, Identity, Key};
use tempfile::TempDir;
use tokio::io::{AsyncReadExt, AsyncWriteExt};

const WAIT: Duration = Duration::from_secs(5);
const A_ID: &str = "123456789";

struct Rig {
    relay: Relay,
    _data: TempDir,
    key: Key,
    addr: String,
}

async fn start() -> Rig {
    let data = tempfile::tempdir().unwrap();
    let config = Config { listen: "127.0.0.1:0".parse().unwrap(), ..Config::default() };
    let opts = Opts {
        data: data.path().to_path_buf(),
        config,
        log: Log::file(data.path(), "relay.log"),
        enroll_from_env: false,
    };
    let relay = Relay::start(opts).await.expect("relay starts");
    let key = Key::new_for_relay(&relay.fp);
    relay.registry().set_join_hash(&join_hash(&key.join())).unwrap();
    let addr = relay.addr.to_string();
    Rig { relay, _data: data, key, addr }
}

fn endpoint() -> quinn::Endpoint {
    quinn::Endpoint::client("127.0.0.1:0".parse().unwrap()).unwrap()
}

async fn dial(r: &Rig, ep: &quinn::Endpoint, id: &Identity) -> RelayConn {
    tokio::time::timeout(WAIT, RelayConn::dial(ep, &r.addr, &r.key, id)).await.unwrap().unwrap()
}

async fn push(c: &RelayConn) -> Pushed {
    tokio::time::timeout(WAIT, c.next_push()).await.expect("a push within WAIT").unwrap()
}

/// The next push that is not the `Revoked` the relay sends on admitting a device.
async fn push_skipping_revoked(c: &RelayConn) -> Pushed {
    loop {
        match push(c).await {
            Pushed::Revoked(_) => continue,
            p => return p,
        }
    }
}

#[tokio::test]
async fn register_then_connect() {
    let r = start().await;
    let (ea, eb) = (endpoint(), endpoint());
    let (ia, ib) = (Identity::generate().unwrap(), Identity::generate().unwrap());
    let a = dial(&r, &ea, &ia).await;
    a.register(A_ID, &["10.0.0.5:22028".to_string()]).await.unwrap();
    let b = dial(&r, &eb, &ib).await;
    // The relay waits for A's answer before it replies to B.
    let answer = async {
        match push_skipping_revoked(&a).await {
            Pushed::Incoming { mut reply, .. } => {
                reply.write_all(b"{\"ok\":true}\n").await.unwrap();
                reply.flush().await.unwrap();
            }
            _ => panic!("expected Incoming"),
        }
    };
    let (found, ()) = tokio::join!(tokio::time::timeout(WAIT, b.connect_to(A_ID)), answer);
    let found = found.unwrap().unwrap();
    assert_eq!(found.lan, vec!["10.0.0.5:22028".to_string()]);
    assert!(!found.public.is_empty());
}

#[tokio::test]
async fn relay_bytes_both_ways() {
    let r = start().await;
    let (ea, eb) = (endpoint(), endpoint());
    let (ia, ib) = (Identity::generate().unwrap(), Identity::generate().unwrap());
    let a = dial(&r, &ea, &ia).await;
    a.register(A_ID, &[]).await.unwrap();
    let b = dial(&r, &eb, &ib).await;

    let mut bs = tokio::time::timeout(WAIT, b.relay_to(A_ID)).await.unwrap().unwrap();
    bs.write_all(b"hello").await.unwrap();
    let Pushed::Relayed { mut stream, .. } = push_skipping_revoked(&a).await else { panic!("expected Relayed") };
    let mut buf = [0u8; 5];
    tokio::time::timeout(WAIT, stream.read_exact(&mut buf)).await.unwrap().unwrap();
    assert_eq!(&buf, b"hello");
    stream.write_all(b"world").await.unwrap();
    tokio::time::timeout(WAIT, bs.read_exact(&mut buf)).await.unwrap().unwrap();
    assert_eq!(&buf, b"world");

    // A TLS handshake right behind the relayed line: no byte of it was eaten.
    let bs2 = tokio::time::timeout(WAIT, b.relay_to(A_ID)).await.unwrap().unwrap();
    let accept = async {
        let Pushed::Relayed { stream, .. } = push_skipping_revoked(&a).await else { panic!("expected Relayed") };
        e2e_accept(stream, &ia).await
    };
    let (acc, con) = tokio::time::timeout(WAIT, async { tokio::join!(accept, e2e_connect(bs2, &ib)) }).await.unwrap();
    let ((_, af), (_, bf)) = (acc.unwrap(), con.unwrap());
    assert_eq!((af.peer, bf.peer), (ib.fp, ia.fp));
}

#[tokio::test]
async fn wrong_relay_half() {
    let r = start().await;
    let key = Key { relay: Some([7u8; 16]), root: r.key.root };
    let err = RelayConn::dial(&endpoint(), &r.addr, &key, &Identity::generate().unwrap()).await.err().unwrap();
    assert_eq!(err.to_string(), "relay identity mismatch");
}

#[tokio::test]
async fn no_relay_half() {
    let r = start().await;
    let err =
        RelayConn::dial(&endpoint(), &r.addr, &Key::new_local(), &Identity::generate().unwrap()).await.err().unwrap();
    assert_eq!(err.to_string(), "relay not set: add the host as id@ip");
}

#[tokio::test]
async fn unreachable_relay() {
    let r = start().await;
    let addr = r.addr.clone();
    r.relay.stop().await;
    let err = RelayConn::dial(&endpoint(), &addr, &r.key, &Identity::generate().unwrap()).await.err().unwrap();
    assert!(err.to_string().starts_with("relay unreachable: "), "{err}");
}

#[tokio::test]
async fn wrong_root_half() {
    let r = start().await;
    let key = Key { relay: r.key.relay, root: [9u8; 16] };
    let ep = endpoint();
    let a = RelayConn::dial(&ep, &r.addr, &key, &Identity::generate().unwrap()).await.unwrap();
    let err = tokio::time::timeout(WAIT, a.register(A_ID, &[])).await.unwrap().unwrap_err();
    assert_eq!(err.to_string(), "bad key");
    // The relay then closes the connection.
    match push(&a).await {
        Pushed::Closed { code, .. } => assert_eq!(code, 3),
        _ => panic!("expected Closed"),
    }
}

#[tokio::test]
async fn unknown_and_offline() {
    let r = start().await;
    let (ea, eb) = (endpoint(), endpoint());
    let (ia, ib) = (Identity::generate().unwrap(), Identity::generate().unwrap());
    let b = dial(&r, &eb, &ib).await;
    let err = tokio::time::timeout(WAIT, b.connect_to("987654321")).await.unwrap().unwrap_err();
    assert_eq!(err.to_string(), "unknown id");
    let a = dial(&r, &ea, &ia).await;
    a.register(A_ID, &[]).await.unwrap();
    a.close();
    tokio::time::timeout(WAIT, ea.wait_idle()).await.unwrap();
    // The relay notices the close asynchronously.
    let mut last = String::new();
    let deadline = tokio::time::Instant::now() + WAIT;
    while tokio::time::Instant::now() < deadline {
        match tokio::time::timeout(WAIT, b.connect_to(A_ID)).await.unwrap() {
            Err(e) => {
                last = e.to_string();
                if last == "offline" {
                    break;
                }
            }
            Ok(_) => last = "ok".into(),
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    assert_eq!(last, "offline");
}

#[tokio::test]
async fn relay_to_unknown_id_fails_on_first_read() {
    let r = start().await;
    let ib = Identity::generate().unwrap();
    let b = dial(&r, &endpoint(), &ib).await;
    let mut s = tokio::time::timeout(WAIT, b.relay_to("987654321")).await.unwrap().unwrap();
    let mut buf = [0u8; 1];
    let err = tokio::time::timeout(WAIT, s.read(&mut buf)).await.unwrap().unwrap_err();
    assert_eq!(err.to_string(), "unknown id");
}

#[tokio::test]
async fn going_away_is_pushed() {
    let r = start().await;
    let a = dial(&r, &endpoint(), &Identity::generate().unwrap()).await;
    a.register(A_ID, &[]).await.unwrap();
    let stop = tokio::spawn(r.relay.stop());
    assert!(matches!(push_skipping_revoked(&a).await, Pushed::GoingAway { .. }));
    let _ = tokio::time::timeout(WAIT, stop).await;
}

#[tokio::test]
async fn big_revoked_line_is_read() {
    let r = start().await;
    let a = dial(&r, &endpoint(), &Identity::generate().unwrap()).await;
    a.register(A_ID, &[]).await.unwrap();
    let reg = r.relay.registry();
    let mut last = Fp([0; 32]);
    for i in 0..300u32 {
        let mut b = [0u8; 32];
        b[..4].copy_from_slice(&i.to_be_bytes());
        b[4] = 1;
        last = Fp(b);
        reg.enroll(last, "default").unwrap();
        if i < 299 {
            reg.revoke(&last);
        }
    }
    r.relay.revoke(&last).await;
    let got = loop {
        match push(&a).await {
            Pushed::Revoked(v) if v.len() == 300 => break v,
            Pushed::Revoked(_) => continue,
            _ => panic!("unexpected push"),
        }
    };
    assert_eq!(got.len(), 300);
}

#[tokio::test]
async fn an_unreadable_revoked_push_closes_the_connection() {
    // A relay that sends a `revoked` push which is not JSON.
    let sid = Identity::generate().unwrap();
    let sc = rapp_wire::tls::server_config(&sid, rapp_wire::tls::ALPN_RELAY, 8).unwrap();
    let srv = quinn::Endpoint::server(sc, "127.0.0.1:0".parse().unwrap()).unwrap();
    let addr = srv.local_addr().unwrap().to_string();
    let serve = tokio::spawn(async move {
        let conn = srv.accept().await.unwrap().await.unwrap();
        let mut uni = conn.open_uni().await.unwrap();
        uni.write_all(b"{\"op\":\"revoked\",\"fps\":[\n").await.unwrap();
        uni.finish().unwrap();
        let _ = tokio::time::timeout(WAIT, conn.closed()).await;
    });
    let key = Key { relay: Some(sid.fp.prefix16()), root: [1u8; 16] };
    let a = tokio::time::timeout(WAIT, RelayConn::dial(&endpoint(), &addr, &key, &Identity::generate().unwrap()))
        .await
        .unwrap()
        .unwrap();
    match push(&a).await {
        Pushed::Closed { code, reason } => assert_eq!((code, reason.as_str()), (0, "bad push")),
        _ => panic!("expected Closed"),
    }
    serve.abort();
}
