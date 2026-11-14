//! Congestion-controller comparison over the weak-link proxy (Task 17). Run by hand:
//! `cargo test -p rapp-testkit --release --test cc_compare -- --ignored --nocapture`
//!
//! VERDICT RULE (fixed before running): BBR replaces the default (cubic) in both `transport()` fns only if
//! its throughput is >= 1.2x cubic on n3 and >= 1.0x on s0 and n2, and its ping p95 is no more than 20% worse
//! than cubic's on all three profiles. Otherwise nothing changes.
use quinn::congestion::{BbrConfig, CubicConfig, NewRenoConfig};
use quinn::crypto::rustls::QuicServerConfig;
use quinn::{ClientConfig, Endpoint, ServerConfig, TransportConfig};
use rapp_net::quic::{client_config, ALPN_PEER, SNI};
use rapp_testkit::weaknet::{self, Profile, ProxyStats};
use rustls::pki_types::{PrivateKeyDer, PrivatePkcs8KeyDer};
use std::net::SocketAddr;
use std::sync::atomic::{AtomicU64, Ordering::Relaxed};
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::net::UdpSocket;

const RUN: Duration = Duration::from_secs(20);

fn transport(cc: &str) -> Arc<TransportConfig> {
    let mut t = TransportConfig::default();
    t.keep_alive_interval(Some(Duration::from_secs(10)));
    t.max_idle_timeout(Some(Duration::from_secs(30).try_into().unwrap()));
    t.max_concurrent_bidi_streams(1024u32.into());
    match cc {
        "cubic" => t.congestion_controller_factory(Arc::new(CubicConfig::default())),
        "newreno" => t.congestion_controller_factory(Arc::new(NewRenoConfig::default())),
        "bbr" => t.congestion_controller_factory(Arc::new(BbrConfig::default())),
        _ => panic!("unknown controller {cc}"),
    };
    Arc::new(t)
}

fn server(cc: &str) -> Endpoint {
    let ck = rcgen::generate_simple_self_signed(vec![SNI.to_string()]).unwrap();
    let key = PrivateKeyDer::Pkcs8(PrivatePkcs8KeyDer::from(ck.signing_key.serialize_der()));
    let provider = Arc::new(rustls::crypto::ring::default_provider());
    let mut tls = rustls::ServerConfig::builder_with_provider(provider)
        .with_protocol_versions(&[&rustls::version::TLS13])
        .unwrap()
        .with_no_client_auth()
        .with_single_cert(vec![ck.cert.der().clone()], key)
        .unwrap();
    tls.alpn_protocols = vec![ALPN_PEER.to_vec()];
    let mut sc = ServerConfig::with_crypto(Arc::new(QuicServerConfig::try_from(tls).unwrap()));
    sc.transport_config(transport(cc));
    Endpoint::server(sc, "127.0.0.1:0".parse().unwrap()).unwrap()
}

fn client(cc: &str) -> ClientConfig {
    let mut c = client_config(ALPN_PEER).unwrap();
    c.transport_config(transport(cc));
    c
}

async fn proxy(upstream: SocketAddr, p: Profile) -> SocketAddr {
    let probe = UdpSocket::bind("127.0.0.1:0").await.unwrap();
    let listen = probe.local_addr().unwrap();
    drop(probe);
    tokio::spawn(async move {
        let _ = weaknet::run(listen, upstream, p, Arc::new(ProxyStats::default())).await;
    });
    tokio::time::sleep(Duration::from_millis(100)).await;
    listen
}

struct Result1 {
    kbps: f64,
    sent: usize,
    p50: f64,
    p95: f64,
}

async fn one(cc: &str, profile: &str) -> Result1 {
    let mut p = Profile::named(profile).unwrap();
    p.outages.clear();
    let srv = server(cc);
    let srv_addr = srv.local_addr().unwrap();
    let got = Arc::new(AtomicU64::new(0));
    let g = got.clone();
    tokio::spawn(async move {
        while let Some(inc) = srv.accept().await {
            let Ok(conn) = inc.await else { continue };
            let (c1, g) = (conn.clone(), g.clone());
            tokio::spawn(async move {
                while let Ok(mut r) = c1.accept_uni().await {
                    let g = g.clone();
                    tokio::spawn(async move {
                        let mut buf = vec![0u8; 65536];
                        while let Ok(Some(n)) = r.read(&mut buf).await {
                            g.fetch_add(n as u64, Relaxed);
                        }
                    });
                }
            });
            tokio::spawn(async move {
                while let Ok((mut s, mut r)) = conn.accept_bi().await {
                    tokio::spawn(async move {
                        let mut b = [0u8; 1024];
                        if r.read_exact(&mut b).await.is_ok() {
                            let _ = s.write_all(&b).await;
                            let _ = s.finish();
                        }
                    });
                }
            });
        }
    });
    let px = proxy(srv_addr, p).await;
    let ep = Endpoint::client("127.0.0.1:0".parse().unwrap()).unwrap();
    let conn = tokio::time::timeout(Duration::from_secs(20), ep.connect_with(client(cc), px, SNI).unwrap())
        .await
        .expect("handshake timed out")
        .expect("handshake failed");

    let start = Instant::now();
    let c2 = conn.clone();
    let bulk = tokio::spawn(async move {
        let mut s = c2.open_uni().await.unwrap();
        let buf = vec![7u8; 65536];
        while start.elapsed() < RUN {
            if s.write_all(&buf).await.is_err() {
                break;
            }
        }
    });
    let mut pings = Vec::new();
    while start.elapsed() < RUN {
        let c = conn.clone();
        let t0 = Instant::now();
        pings.push(tokio::spawn(async move {
            let (mut s, mut r) = c.open_bi().await.ok()?;
            s.write_all(&[1u8; 1024]).await.ok()?;
            s.finish().ok()?;
            let mut b = [0u8; 1024];
            r.read_exact(&mut b).await.ok()?;
            Some(t0.elapsed().as_secs_f64() * 1000.0)
        }));
        tokio::time::sleep(Duration::from_millis(200)).await;
    }
    let bytes = got.load(Relaxed);
    let elapsed = start.elapsed().as_secs_f64();
    // Pings still in flight count as their age so far (they are at least that slow).
    let sent = pings.len();
    let mut ms = Vec::new();
    for (i, h) in pings.into_iter().enumerate() {
        let age = elapsed * 1000.0 - i as f64 * 200.0;
        if h.is_finished() {
            ms.push(h.await.unwrap().unwrap_or(age));
        } else {
            h.abort();
            ms.push(age);
        }
    }
    ms.sort_by(|a, b| a.partial_cmp(b).unwrap());
    let q = |f: f64| ms[((ms.len() as f64 * f) as usize).min(ms.len() - 1)];
    bulk.abort();
    conn.close(0u32.into(), b"");
    Result1 { kbps: bytes as f64 * 8.0 / 1000.0 / elapsed, sent, p50: q(0.5), p95: q(0.95) }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore]
async fn cc_table() {
    println!(
        "VERDICT RULE: BBR >= 1.2x cubic throughput on n3, >= 1.0x on s0 and n2, ping p95 <= 1.2x cubic on all three."
    );
    println!("{:8} {:8} {:>10} {:>8} {:>9} {:>9}", "profile", "cc", "kbit/s", "pings", "p50 ms", "p95 ms");
    for profile in ["s0", "n2", "n3"] {
        for cc in ["cubic", "newreno", "bbr"] {
            let r = one(cc, profile).await;
            println!("{profile:8} {cc:8} {:>10.1} {:>8} {:>9.0} {:>9.0}", r.kbps, r.sent, r.p50, r.p95);
        }
    }
}
