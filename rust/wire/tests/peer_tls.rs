use std::net::SocketAddr;
use std::time::Duration;

use rapp_wire::tls::*;
use rapp_wire::Identity;
use tokio_rustls::{TlsAcceptor, TlsConnector};

fn local() -> SocketAddr {
    "127.0.0.1:0".parse().unwrap()
}

async fn connect(srv: &quinn::Endpoint, cc: quinn::ClientConfig) -> (quinn::Connection, quinn::Connection) {
    let cli = quinn::Endpoint::client(local()).unwrap();
    let addr = srv.local_addr().unwrap();
    let s = srv.clone();
    let accept = tokio::spawn(async move { s.accept().await.unwrap().await.unwrap() });
    let c = cli.connect_with(cc, addr, SNI).unwrap().await.unwrap();
    let s = tokio::time::timeout(Duration::from_secs(5), accept).await.unwrap().unwrap();
    (c, s)
}

#[tokio::test]
async fn device_quic_mutual() {
    let (a, b) = (Identity::generate().unwrap(), Identity::generate().unwrap());
    let srv = quinn::Endpoint::server(device_server_config(&a, &[ALPN_DEVICE, b"rapp/1"]).unwrap(), local()).unwrap();
    let (c, s) = connect(&srv, device_client_config(&b, ALPN_DEVICE).unwrap()).await;
    assert_eq!(peer_fp(&c).unwrap(), a.fp);
    assert_eq!(peer_fp(&s).unwrap(), b.fp);
    assert_eq!(alpn(&c), Some(b"rapp/2".to_vec()));
    assert_eq!(alpn(&s), Some(b"rapp/2".to_vec()));
}

#[tokio::test]
async fn device_quic_old_client_without_cert() {
    let a = Identity::generate().unwrap();
    let srv = quinn::Endpoint::server(device_server_config(&a, &[ALPN_DEVICE, b"rapp/1"]).unwrap(), local()).unwrap();
    let (c, s) = connect(&srv, rapp_net::quic::client_config(b"rapp/1").unwrap()).await;
    assert!(peer_fp(&s).is_err());
    assert_eq!(alpn(&s), Some(b"rapp/1".to_vec()));
    assert_eq!(alpn(&c), Some(b"rapp/1".to_vec()));
}

#[tokio::test]
async fn e2e_over_duplex() {
    let (a, b) = (Identity::generate().unwrap(), Identity::generate().unwrap());
    let (x, y) = tokio::io::duplex(64 * 1024);
    let acc = TlsAcceptor::from(e2e_server(&a).unwrap());
    let con = TlsConnector::from(e2e_client(&b).unwrap());
    let name = rustls::pki_types::ServerName::try_from(SNI).unwrap();
    let (s, c) = tokio::join!(acc.accept(x), con.connect(name, y));
    let (s, c) = (s.unwrap(), c.unwrap());
    let fp_of = |certs: Option<&[rustls::pki_types::CertificateDer<'static>]>| {
        rapp_wire::Fp::of_cert(&certs.unwrap()[0]).unwrap()
    };
    assert_eq!(fp_of(c.get_ref().1.peer_certificates()), a.fp);
    assert_eq!(fp_of(s.get_ref().1.peer_certificates()), b.fp);
    assert_eq!(c.get_ref().1.alpn_protocol(), Some(ALPN_E2E));
}

#[tokio::test]
async fn e2e_server_requires_a_client_certificate() {
    let a = Identity::generate().unwrap();
    let (x, y) = tokio::io::duplex(64 * 1024);
    let acc = TlsAcceptor::from(e2e_server(&a).unwrap());
    let provider = std::sync::Arc::new(rustls::crypto::ring::default_provider());
    let mut cfg = rustls::ClientConfig::builder_with_provider(provider)
        .with_protocol_versions(&[&rustls::version::TLS13])
        .unwrap()
        .dangerous()
        .with_custom_certificate_verifier(std::sync::Arc::new(AnyServer))
        .with_no_client_auth();
    cfg.alpn_protocols = vec![ALPN_E2E.to_vec()];
    let con = TlsConnector::from(std::sync::Arc::new(cfg));
    let name = rustls::pki_types::ServerName::try_from(SNI).unwrap();
    let (s, c) = tokio::join!(acc.accept(x), async {
        let mut c = con.connect(name, y).await?;
        // TLS 1.3: the client finishes first; the refusal shows on the first read.
        use tokio::io::AsyncReadExt;
        c.read_u8().await.map(|_| ())
    });
    assert!(s.is_err());
    assert!(c.is_err());
}

#[derive(Debug)]
struct AnyServer;

impl rustls::client::danger::ServerCertVerifier for AnyServer {
    fn verify_server_cert(
        &self,
        _: &rustls::pki_types::CertificateDer<'_>,
        _: &[rustls::pki_types::CertificateDer<'_>],
        _: &rustls::pki_types::ServerName<'_>,
        _: &[u8],
        _: rustls::pki_types::UnixTime,
    ) -> Result<rustls::client::danger::ServerCertVerified, rustls::Error> {
        Ok(rustls::client::danger::ServerCertVerified::assertion())
    }
    fn verify_tls12_signature(
        &self,
        _: &[u8],
        _: &rustls::pki_types::CertificateDer<'_>,
        _: &rustls::DigitallySignedStruct,
    ) -> Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
        Err(rustls::Error::General("no tls12".into()))
    }
    fn verify_tls13_signature(
        &self,
        m: &[u8],
        c: &rustls::pki_types::CertificateDer<'_>,
        d: &rustls::DigitallySignedStruct,
    ) -> Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
        let p = rustls::crypto::ring::default_provider();
        rustls::crypto::verify_tls13_signature(m, c, d, &p.signature_verification_algorithms)
    }
    fn supported_verify_schemes(&self) -> Vec<rustls::SignatureScheme> {
        rustls::crypto::ring::default_provider().signature_verification_algorithms.supported_schemes()
    }
}
