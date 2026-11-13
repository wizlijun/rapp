use rapp_testkit::weaknet::{self, Outage, Profile, ProxyStats};
use std::net::SocketAddr;
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::net::UdpSocket;

/// UDP echo server; records the source port of every packet it sees.
async fn echo() -> (SocketAddr, Arc<Mutex<Vec<u16>>>) {
    let s = UdpSocket::bind("127.0.0.1:0").await.unwrap();
    let addr = s.local_addr().unwrap();
    let ports = Arc::new(Mutex::new(Vec::new()));
    let p = ports.clone();
    tokio::spawn(async move {
        let mut buf = [0u8; 2048];
        while let Ok((n, from)) = s.recv_from(&mut buf).await {
            p.lock().unwrap().push(from.port());
            let _ = s.send_to(&buf[..n], from).await;
        }
    });
    (addr, ports)
}

async fn proxy(upstream: SocketAddr, p: Profile) -> (SocketAddr, Arc<ProxyStats>) {
    // Find a free port first, then hand it to the proxy.
    let probe = UdpSocket::bind("127.0.0.1:0").await.unwrap();
    let listen = probe.local_addr().unwrap();
    drop(probe);
    let stats = Arc::new(ProxyStats::default());
    let st = stats.clone();
    tokio::spawn(async move {
        let _ = weaknet::run(listen, upstream, p, st).await;
    });
    tokio::time::sleep(Duration::from_millis(100)).await;
    (listen, stats)
}

#[tokio::test]
async fn forwards_both_ways_on_lan() {
    let (up, _) = echo().await;
    let (px, stats) = proxy(up, Profile::named("lan").unwrap()).await;
    let c = UdpSocket::bind("127.0.0.1:0").await.unwrap();
    c.connect(px).await.unwrap();
    for i in 0..100u32 {
        c.send(&i.to_be_bytes()).await.unwrap();
    }
    let mut buf = [0u8; 64];
    for i in 0..100u32 {
        let n = tokio::time::timeout(Duration::from_secs(5), c.recv(&mut buf)).await.expect("timeout").unwrap();
        assert_eq!(&buf[..n], &i.to_be_bytes());
    }
    use std::sync::atomic::Ordering::Relaxed;
    assert_eq!(stats.up_pkts.load(Relaxed), 100);
    assert_eq!(stats.down_pkts.load(Relaxed), 100);
}

#[tokio::test]
async fn outage_blocks_then_resumes() {
    let (up, _) = echo().await;
    let mut p = Profile::named("lan").unwrap();
    p.outages = vec![Outage { every_s: 2.0, for_s: 1.0, offset_s: 0.5 }];
    let (px, _) = proxy(up, p).await; // proxy clock starts ~0.1 s before this returns
    let c = UdpSocket::bind("127.0.0.1:0").await.unwrap();
    c.connect(px).await.unwrap();
    let mut buf = [0u8; 64];
    // During the outage (clock ~0.8 s) nothing comes back.
    tokio::time::sleep(Duration::from_millis(700)).await;
    c.send(b"during").await.unwrap();
    assert!(tokio::time::timeout(Duration::from_millis(300), c.recv(&mut buf)).await.is_err());
    // After it (clock ~2.0 s) traffic flows again.
    tokio::time::sleep(Duration::from_millis(1200)).await;
    c.send(b"after").await.unwrap();
    let n = tokio::time::timeout(Duration::from_secs(3), c.recv(&mut buf)).await.expect("timeout").unwrap();
    assert_eq!(&buf[..n], b"after");
}

#[tokio::test]
async fn rebind_changes_source_port() {
    let (up, ports) = echo().await;
    let mut p = Profile::named("lan").unwrap();
    p.rebind_every_s = Some(0.5);
    let (px, _) = proxy(up, p).await;
    let c = UdpSocket::bind("127.0.0.1:0").await.unwrap();
    c.connect(px).await.unwrap();
    for _ in 0..24 {
        c.send(b"x").await.unwrap();
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    let mut seen = ports.lock().unwrap().clone();
    seen.sort();
    seen.dedup();
    assert!(seen.len() >= 3, "source ports seen: {seen:?}"); // at least 2 changes
}

#[tokio::test]
async fn quic_survives_rebind() {
    use rapp_net::quic::{bi, client_endpoint, connect, server_endpoint, ALPN_PEER};
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    let server = server_endpoint("127.0.0.1:0".parse().unwrap(), ALPN_PEER).unwrap();
    let saddr = server.local_addr().unwrap();
    tokio::spawn(async move {
        while let Some(inc) = server.accept().await {
            tokio::spawn(async move {
                let Ok(conn) = inc.await else { return };
                while let Ok(pair) = conn.accept_bi().await {
                    tokio::spawn(async move {
                        let mut s = bi(pair);
                        let mut b = vec![0u8; 1024];
                        if s.read_exact(&mut b).await.is_ok() {
                            let _ = s.write_all(&b).await;
                            let _ = s.shutdown().await;
                        }
                    });
                }
            });
        }
    });
    let mut p = Profile::named("n4").unwrap();
    p.rebind_every_s = Some(1.0);
    let (px, _) = proxy(saddr, p).await;
    let ep = client_endpoint("127.0.0.1:0".parse().unwrap()).unwrap();
    let conn = connect(&ep, px, ALPN_PEER, Duration::from_secs(10)).await.unwrap();
    for i in 0..30u8 {
        let msg = vec![i; 1024];
        let r = tokio::time::timeout(Duration::from_secs(10), async {
            let mut s = bi(conn.open_bi().await.unwrap());
            s.write_all(&msg).await.unwrap();
            let mut got = vec![0u8; 1024];
            s.read_exact(&mut got).await.unwrap();
            got
        })
        .await
        .expect("stream timed out");
        assert_eq!(r, msg);
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
}
