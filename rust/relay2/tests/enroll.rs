//! Transport, admission and enrollment (spec §6.4, §9.2).
mod common;

use std::net::SocketAddr;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use common::*;
use quinn::crypto::rustls::QuicClientConfig;
use rapp_wire::msg::Req;
use rapp_wire::tls::{Expect, ALPN_RELAY, SNI};
use rapp_wire::{Identity, Key};
use rustls::client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier};
use rustls::crypto::WebPkiSupportedAlgorithms;
use rustls::pki_types::{CertificateDer, ServerName, UnixTime};
use rustls::{DigitallySignedStruct, SignatureScheme};
use serde_json::json;
use tokio::net::UdpSocket;
use tokio::sync::oneshot;
use tokio::time::timeout;

const ID: &str = "123456789";

fn register() -> Req {
    Req::Register { id: ID.into(), lan: vec![] }
}

fn app_close_code(e: &quinn::ConnectionError) -> Option<u64> {
    match e {
        quinn::ConnectionError::ApplicationClosed(c) => Some(c.error_code.into_inner()),
        _ => None,
    }
}

#[tokio::test]
async fn right_key_enrolls_and_is_audited() {
    let r = start_relay(|_| {}).await;
    let d = FakeDevice::dial(&r).await;
    let v = d.enroll(&r.key).await;
    assert_eq!(v["ok"], true, "{v}");
    assert_eq!(v["relay"], json!({"version": env!("CARGO_PKG_VERSION"), "features": []}));
    assert_eq!(v["from"], d.local_addr().to_string(), "the reply names the address the relay saw");

    let dev = r.relay.registry().get(&d.id.fp).expect("device is in the registry");
    assert_eq!(dev.tenant, "default");
    assert!(!dev.revoked);

    let lines = audit_lines(&r, "enroll");
    assert_eq!(lines.len(), 1, "{lines:?}");
    let l = &lines[0];
    assert_eq!(l["result"], "ok");
    assert_eq!(l["fp"], d.id.fp.to_string());
    assert_eq!(l["fp"].as_str().unwrap().len(), 64);
    assert!(l["from"].as_str().unwrap().starts_with("127.0.0.1:"), "{l}");
    assert_eq!(l["tenant"], "default");
}

#[tokio::test]
async fn wrong_key_is_refused_audited_and_backs_off() {
    let r = start_relay(|_| {}).await;
    let wrong = Key::new_for_relay(&r.relay.fp);
    // Every failed enroll ends its connection, so each attempt dials again.
    for _ in 0..5 {
        let v = FakeDevice::dial(&r).await.enroll(&wrong).await;
        assert_eq!(v, json!({"ok": false, "error": "bad key"}));
    }
    // Locked now: even the right key is refused, and not by checking it.
    let d = FakeDevice::dial(&r).await;
    let v = d.enroll(&r.key).await;
    let e = v["error"].as_str().unwrap();
    assert!(e.starts_with("locked, retry in ") && e.ends_with('s'), "{v}");
    assert_eq!(v["ok"], false);
    assert!(r.relay.registry().get(&d.id.fp).is_none());

    let lockouts = audit_lines(&r, "lockout");
    assert_eq!(lockouts.len(), 1, "{lockouts:?}");
    assert_eq!(lockouts[0]["key"], "127.0.0.1");
    assert_eq!(lockouts[0]["secs"], 1);
    let results: Vec<_> = audit_lines(&r, "enroll").iter().map(|l| l["result"].as_str().unwrap().to_string()).collect();
    assert_eq!(results[..5], ["bad key"; 5]);
    assert!(results[5].starts_with("locked, retry in "), "{results:?}");

    // A garbled key is a wrong key too.
    tokio::time::sleep(Duration::from_millis(1100)).await;
    let v = FakeDevice::dial(&r).await.req(&Req::Enroll { join: "not hex".into() }).await;
    assert_eq!(v["error"], "bad key");
}

#[tokio::test]
async fn unenrolled_device_can_do_nothing_else() {
    let r = start_relay(|_| {}).await;
    let d = FakeDevice::dial(&r).await;
    for req in [register(), Req::Connect { id: ID.into() }, Req::Relay { id: ID.into() }] {
        assert_eq!(d.req(&req).await, json!({"ok": false, "error": "not enrolled"}), "{req:?}");
    }
    assert!(r.relay.registry().get(&d.id.fp).is_none());
    // Once enrolled, the same connection is past the gate.
    assert_eq!(d.enroll(&r.key).await["ok"], true);
    assert_ne!(d.req(&register()).await["error"], "not enrolled");
}

#[tokio::test]
async fn unenrolled_connection_is_dropped_after_idle() {
    let r = start_relay(|c| c.limits.unenrolled_idle_secs = 1).await;
    let idle = FakeDevice::dial(&r).await;
    let enrolled = FakeDevice::dial(&r).await;
    assert_eq!(enrolled.enroll(&r.key).await["ok"], true);

    let t = Instant::now();
    let e = timeout(Duration::from_secs(2), idle.conn.closed()).await.expect("unenrolled connection was not dropped");
    assert!(t.elapsed() >= Duration::from_millis(500), "dropped too early: {:?}", t.elapsed());
    assert_eq!(app_close_code(&e), Some(0), "{e:?}");
    if let quinn::ConnectionError::ApplicationClosed(c) = &e {
        assert_eq!(&c.reason[..], b"enroll timeout");
    }
    // The enrolled one, connected at the same moment, stays.
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert!(enrolled.conn.close_reason().is_none());
    assert_eq!(enrolled.enroll(&r.key).await["ok"], true);
}

#[tokio::test]
async fn closed_enrollment_refuses_even_the_right_key() {
    let r = start_relay(|c| c.enroll = rapp_relay2::config::Enroll::Closed).await;
    let d = FakeDevice::dial(&r).await;
    assert_eq!(d.enroll(&r.key).await, json!({"ok": false, "error": "closed"}));
    assert!(r.relay.registry().get(&d.id.fp).is_none());
    assert_eq!(audit_lines(&r, "enroll")[0]["result"], "closed");
}

#[tokio::test]
async fn relay_without_a_key_says_so() {
    let r = start_relay_without_key(|_| {}).await;
    let d = FakeDevice::dial(&r).await;
    assert_eq!(d.enroll(&r.key).await, json!({"ok": false, "error": "no key"}));
    assert!(r.relay.registry().get(&d.id.fp).is_none());
}

#[tokio::test]
async fn enrollment_survives_reconnect_and_restart() {
    let r = start_relay(|_| {}).await;
    let id = Identity::generate().unwrap();
    let d = FakeDevice::dial_as(&r, same_identity(&id)).await.unwrap();
    assert_eq!(d.enroll(&r.key).await["ok"], true);
    d.conn.close(0u32.into(), b"bye");
    drop(d);

    let d = FakeDevice::dial_as(&r, same_identity(&id)).await.unwrap();
    assert_ne!(d.req(&register()).await["error"], "not enrolled");
    drop(d);

    let fp_before = r.relay.fp;
    let r = r.restart().await;
    assert_eq!(r.relay.fp, fp_before, "the relay keeps its identity");
    let d = FakeDevice::dial_as(&r, same_identity(&id)).await.unwrap();
    assert_ne!(d.req(&register()).await["error"], "not enrolled");
    // A device that never enrolled is still at the gate.
    let stranger = FakeDevice::dial(&r).await;
    assert_eq!(stranger.req(&register()).await["error"], "not enrolled");

    assert_eq!(audit_lines(&r, "relay_start").len(), 2);
    let stops = audit_lines(&r, "relay_stop");
    assert_eq!(stops.len(), 1);
    assert_eq!(stops[0]["version"], env!("CARGO_PKG_VERSION"));
    let start = &audit_lines(&r, "relay_start")[0];
    assert_eq!(start["version"], env!("CARGO_PKG_VERSION"));
    assert_eq!(start["config"]["limits"]["max_devices"], 1024);
}

#[tokio::test]
async fn device_cap_and_per_ip_rate_are_enforced() {
    let r = start_relay(|c| c.limits.max_devices = 1).await;
    let a = FakeDevice::dial(&r).await;
    let b = FakeDevice::dial(&r).await;
    assert_eq!(a.enroll(&r.key).await["ok"], true);
    assert_eq!(b.enroll(&r.key).await, json!({"ok": false, "error": "limit"}));
    assert!(r.relay.registry().get(&b.id.fp).is_none());
    // An already enrolled device does not count against the cap.
    assert_eq!(a.enroll(&r.key).await["ok"], true);
    let limits = audit_lines(&r, "limit");
    assert_eq!(limits.len(), 1, "{limits:?}");
    assert_eq!(limits[0]["what"], "max_devices");
    assert_eq!(limits[0]["fp"], b.id.fp.to_string());
    assert!(limits[0]["from"].as_str().unwrap().starts_with("127.0.0.1:"));

    let r = start_relay(|c| c.limits.enroll_per_ip_per_min = 2).await;
    let a = FakeDevice::dial(&r).await;
    assert_eq!(a.enroll(&r.key).await["ok"], true);
    assert_eq!(a.enroll(&r.key).await["ok"], true);
    let c = FakeDevice::dial(&r).await;
    assert_eq!(c.enroll(&r.key).await, json!({"ok": false, "error": "limit"}));
    let limits = audit_lines(&r, "limit");
    assert_eq!(limits.len(), 1, "{limits:?}");
    assert_eq!(limits[0]["what"], "enroll_per_ip_per_min");
    assert_eq!(limits[0]["fp"], c.id.fp.to_string());
    assert_eq!(audit_lines(&r, "enroll")[2]["result"], "limit");
}

#[tokio::test]
async fn a_failed_enroll_ends_the_connection() {
    let r = start_relay(|_| {}).await;
    let wrong = Key::new_for_relay(&r.relay.fp);
    let d = FakeDevice::dial(&r).await;
    assert_eq!(d.enroll(&wrong).await, json!({"ok": false, "error": "bad key"}));
    // The reply arrived, then the connection closed: no second enroll on it.
    let code = tokio::time::timeout(WAIT, d.conn.closed()).await.expect("closed after a failed enroll");
    let closed_with_3 = matches!(&code, quinn::ConnectionError::ApplicationClosed(c) if c.error_code.into_inner() == 3);
    assert!(closed_with_3, "{code:?}");
    // A fresh connection still enrolls; failures do not block it.
    assert_eq!(FakeDevice::dial(&r).await.enroll(&r.key).await["ok"], true);
}

#[cfg(unix)]
#[tokio::test]
async fn a_failed_registry_write_does_not_enroll() {
    use std::os::unix::fs::PermissionsExt;
    let r = start_relay(|_| {}).await;
    let id = Identity::generate().unwrap();
    let d = FakeDevice::dial_as(&r, same_identity(&id)).await.unwrap();
    let dir = r.data.path();
    std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o500)).unwrap();
    let writable_anyway = std::fs::write(dir.join("probe"), b"x").is_ok(); // running as root
    let v = d.enroll(&r.key).await;
    // The failed enroll also ends the connection.
    let closed = tokio::time::timeout(WAIT, d.conn.closed()).await.is_ok();
    std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700)).unwrap();
    if writable_anyway {
        return;
    }
    assert_eq!(v["ok"], false, "{v}");
    assert_eq!(v["error"], "unavailable", "a registry write failure is retryable, not a bad request");
    assert!(closed);
    assert!(r.relay.registry().get(&id.fp).is_none());
    assert_ne!(audit_lines(&r, "enroll")[0]["result"], "ok");

    let d = FakeDevice::dial_as(&r, same_identity(&id)).await.unwrap();
    assert_eq!(d.req(&register()).await["error"], "not enrolled");
}

#[tokio::test]
async fn a_stalled_half_line_is_reset_after_the_timeout() {
    let r = start_relay(|c| c.limits.request_timeout_secs = 1).await;
    let d = FakeDevice::dial(&r).await;
    assert_eq!(d.enroll(&r.key).await["ok"], true);

    let (mut send, mut recv) = d.conn.open_bi().await.unwrap();
    send.write_all(br#"{"op":"conn"#).await.unwrap();
    let t = Instant::now();
    let res = timeout(Duration::from_secs(2), recv.read_to_end(1024)).await.expect("stream was not reset in time");
    assert!(
        matches!(res, Err(quinn::ReadToEndError::Read(quinn::ReadError::Reset(_)))),
        "expected a reset, got {res:?}"
    );
    assert!(t.elapsed() >= Duration::from_millis(800), "reset too early: {:?}", t.elapsed());

    // The connection is fine: the next request is answered.
    assert!(d.conn.close_reason().is_none());
    assert_eq!(d.enroll(&r.key).await["ok"], true);
}

/// Accepts any server certificate (still checking its handshake signature).
#[derive(Debug)]
struct AnyServer(WebPkiSupportedAlgorithms);

impl ServerCertVerifier for AnyServer {
    fn verify_server_cert(
        &self,
        _: &CertificateDer<'_>,
        _: &[CertificateDer<'_>],
        _: &ServerName<'_>,
        _: &[u8],
        _: UnixTime,
    ) -> Result<ServerCertVerified, rustls::Error> {
        Ok(ServerCertVerified::assertion())
    }

    fn verify_tls12_signature(
        &self,
        _: &[u8],
        _: &CertificateDer<'_>,
        _: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        Err(rustls::Error::General("TLS 1.2".into()))
    }

    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls13_signature(message, cert, dss, &self.0)
    }

    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        self.0.supported_schemes()
    }
}

/// TLS 1.3 client that shows no certificate at all.
fn no_cert_client() -> quinn::ClientConfig {
    let provider = Arc::new(rustls::crypto::ring::default_provider());
    let mut tls = rustls::ClientConfig::builder_with_provider(provider.clone())
        .with_protocol_versions(&[&rustls::version::TLS13])
        .unwrap()
        .dangerous()
        .with_custom_certificate_verifier(Arc::new(AnyServer(provider.signature_verification_algorithms)))
        .with_no_client_auth();
    tls.alpn_protocols = vec![ALPN_RELAY.to_vec()];
    quinn::ClientConfig::new(Arc::new(QuicClientConfig::try_from(tls).unwrap()))
}

fn handshake_failures(r: &TestRelay) -> usize {
    r.log_text().lines().filter(|l| l.contains(r#""ev":"handshake_failed""#)).count()
}

#[tokio::test]
async fn a_client_without_a_certificate_never_gets_a_request_through() {
    let r = start_relay(|_| {}).await;
    let ep = client_endpoint();
    let res = timeout(WAIT, ep.connect_with(no_cert_client(), r.relay.addr, SNI).unwrap()).await.unwrap();
    if let Ok(conn) = res {
        // The client may finish its half before the refusal lands; nothing must get through.
        let attempt = timeout(WAIT, async {
            let (mut send, recv) = conn.open_bi().await?;
            let mut line = serde_json::to_vec(&Req::Enroll { join: join_hex(&r.key) }).unwrap();
            line.push(b'\n');
            send.write_all(&line).await?;
            let _ = send.finish();
            let mut recv = tokio::io::BufReader::new(recv);
            rapp_wire::line::read_json(&mut recv, 8192).await
        })
        .await
        .expect("request neither answered nor refused");
        assert!(attempt.is_err(), "a request got through: {attempt:?}");
    }

    let t = Instant::now();
    while handshake_failures(&r) == 0 && t.elapsed() < WAIT {
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    assert_eq!(handshake_failures(&r), 1, "{}", r.log_text());
    assert!(audit_lines(&r, "enroll").is_empty());

    let d = FakeDevice::dial(&r).await;
    assert_eq!(d.enroll(&r.key).await["ok"], true);
}

/// client <-> forwarder <-> relay; the first datagram from the relay comes out of `first`.
async fn udp_forwarder(relay: SocketAddr) -> (SocketAddr, oneshot::Receiver<Vec<u8>>) {
    let front = Arc::new(UdpSocket::bind("127.0.0.1:0").await.unwrap());
    let back = Arc::new(UdpSocket::bind("127.0.0.1:0").await.unwrap());
    let addr = front.local_addr().unwrap();
    let client = Arc::new(Mutex::new(None::<SocketAddr>));
    let (tx, first) = oneshot::channel();
    {
        let (front, back, client) = (front.clone(), back.clone(), client.clone());
        tokio::spawn(async move {
            let mut buf = vec![0u8; 65536];
            while let Ok((n, from)) = front.recv_from(&mut buf).await {
                *client.lock().unwrap() = Some(from);
                let _ = back.send_to(&buf[..n], relay).await;
            }
        });
    }
    tokio::spawn(async move {
        let mut buf = vec![0u8; 65536];
        let mut tx = Some(tx);
        while let Ok((n, _)) = back.recv_from(&mut buf).await {
            if let Some(tx) = tx.take() {
                let _ = tx.send(buf[..n].to_vec());
            }
            let to = *client.lock().unwrap();
            if let Some(to) = to {
                let _ = front.send_to(&buf[..n], to).await;
            }
        }
    });
    (addr, first)
}

#[tokio::test]
async fn the_first_reply_to_a_new_address_is_a_retry() {
    let r = start_relay(|_| {}).await;
    let (fwd, first) = udp_forwarder(r.relay.addr).await;
    let d = FakeDevice::dial_to(fwd, Identity::generate().unwrap(), Expect::Pin(r.relay.fp.prefix16()))
        .await
        .expect("handshake through the forwarder");
    let first = timeout(WAIT, first).await.unwrap().unwrap();
    // Long header, fixed bit, packet type 0b11 = Retry.
    assert_eq!(first[0] & 0xF0, 0xF0, "first datagram starts {:#04x}, not a Retry", first[0]);
    assert_eq!(d.enroll(&r.key).await["ok"], true);
}

#[tokio::test]
async fn a_device_pinning_the_wrong_relay_fails_the_handshake() {
    let r = start_relay(|_| {}).await;
    let other = Identity::generate().unwrap().fp;
    let res = FakeDevice::dial_to(r.relay.addr, Identity::generate().unwrap(), Expect::Pin(other.prefix16())).await;
    assert!(res.is_err());
}

#[tokio::test]
async fn connection_cap_closes_with_code_3() {
    let r = start_relay(|c| c.limits.max_conns_per_ip = 1).await;
    let a = FakeDevice::dial(&r).await;
    let second = FakeDevice::dial_as(&r, Identity::generate().unwrap()).await;
    let e = match second {
        Ok(b) => timeout(WAIT, b.conn.closed()).await.expect("second connection stays open"),
        Err(e) => e.downcast::<quinn::ConnectionError>().expect("a connection error"),
    };
    assert_eq!(app_close_code(&e), Some(3), "{e:?}");
    // The first connection is untouched.
    assert_eq!(a.enroll(&r.key).await["ok"], true);
    let limits = audit_lines(&r, "limit");
    assert_eq!(limits.len(), 1, "{limits:?}");
    assert_eq!(limits[0]["what"], "max_conns_per_ip");
    assert!(limits[0]["from"].as_str().unwrap().starts_with("127.0.0.1:"));
}

#[tokio::test]
async fn revoked_device_is_closed_with_code_2() {
    let r = start_relay(|_| {}).await;
    let id = Identity::generate().unwrap();
    let d = FakeDevice::dial_as(&r, same_identity(&id)).await.unwrap();
    assert_eq!(d.enroll(&r.key).await["ok"], true);
    assert!(r.relay.registry().revoke(&id.fp).changed);
    drop(d);
    let e = match FakeDevice::dial_as(&r, same_identity(&id)).await {
        Ok(d) => timeout(WAIT, d.conn.closed()).await.expect("revoked device stays connected"),
        Err(e) => e.downcast::<quinn::ConnectionError>().expect("a connection error"),
    };
    assert_eq!(app_close_code(&e), Some(2), "{e:?}");
}

#[tokio::test]
async fn oversized_and_malformed_requests_get_bad_request_not_a_crash() {
    let r = start_relay(|_| {}).await;
    let d = FakeDevice::dial(&r).await;
    assert_eq!(d.enroll(&r.key).await["ok"], true);
    let mut big = vec![b'x'; 9000];
    big.push(b'\n');
    let lines: [&[u8]; 6] = [
        &big,
        b"hello\n",
        b"{\"op\":\"nope\"}\n",
        b"{\"op\":\"enroll\",\"join\":\"00\",\"extra\":1}\n",
        b"[1,2]\n",
        b"{\"op\":", // finished before the line ends
    ];
    for line in lines {
        let v = d.raw(line).await.expect("a reply");
        let shown = String::from_utf8_lossy(&line[..20.min(line.len())]).into_owned();
        assert_eq!(v, json!({"ok": false, "error": "bad request"}), "{shown}");
    }

    // Still serving, on this connection and new ones.
    assert!(d.conn.close_reason().is_none());
    assert_eq!(d.enroll(&r.key).await["ok"], true);
    let e = FakeDevice::dial(&r).await;
    assert_eq!(e.enroll(&r.key).await["ok"], true);
}
