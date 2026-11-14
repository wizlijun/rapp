//! Mutual TLS 1.3 over QUIC. Each side shows its self-signed certificate; nobody checks a CA,
//! a name or an expiry date. What counts is the key behind the certificate: both verifiers
//! check the handshake signature, so a peer's `Fp` proves it holds the private key.

use std::sync::Arc;
use std::time::Duration;

use anyhow::{anyhow, Result};
use quinn::crypto::rustls::{QuicClientConfig, QuicServerConfig};
use rustls::client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier};
use rustls::crypto::{CryptoProvider, WebPkiSupportedAlgorithms};
use rustls::pki_types::{CertificateDer, PrivateKeyDer, ServerName, UnixTime};
use rustls::server::danger::{ClientCertVerified, ClientCertVerifier};
use rustls::{CertificateError, DigitallySignedStruct, DistinguishedName, PeerIncompatible, SignatureScheme};

use crate::{Fp, Identity};

pub const ALPN_RELAY: &[u8] = b"rapp-relay/2";
/// Device to device, direct or through the relay.
pub const ALPN_DEVICE: &[u8] = b"rapp/2";
/// The end-to-end TLS inside a relayed stream.
pub const ALPN_E2E: &[u8] = b"rapp-e2e/1";
pub const SNI: &str = "rapp";

/// What the client accepts from the server.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Expect {
    /// The first 16 bytes of the server's fingerprint must equal these.
    Pin([u8; 16]),
    /// Any server; for tests and self-checks only.
    Any,
}

/// Per-stream receive window on the relay: bounds what one stream of an unenrolled
/// connection can make the relay buffer.
pub const SERVER_STREAM_WINDOW: u32 = 1024 * 1024;
/// Per-connection receive window on the relay: bounded memory per connection, while still
/// about 40 MB/s per connection at 100 ms RTT (4 MiB / 0.1 s) for relayed streams. One stream
/// is bound by `SERVER_STREAM_WINDOW` instead: about 10 MB/s at 100 ms (1 MiB / 0.1 s).
pub const SERVER_CONN_WINDOW: u32 = 4 * 1024 * 1024;

pub type BiStream = tokio::io::Join<quinn::RecvStream, quinn::SendStream>;

pub fn bi((send, recv): (quinn::SendStream, quinn::RecvStream)) -> BiStream {
    tokio::io::join(recv, send)
}

/// TLS 1.3 only; the client must show a certificate and prove it holds its key.
/// Devices never open unidirectional streams toward the relay, so none are allowed.
pub fn server_config(id: &Identity, alpn: &[u8], max_streams: u32) -> Result<quinn::ServerConfig> {
    let p = provider();
    let tls = server_tls(id, p, true, vec![alpn.to_vec()])?;
    let mut sc = quinn::ServerConfig::with_crypto(Arc::new(QuicServerConfig::try_from(tls)?));
    let mut t = transport();
    t.max_concurrent_bidi_streams(max_streams.into())
        .max_concurrent_uni_streams(0u32.into())
        .stream_receive_window(SERVER_STREAM_WINDOW.into())
        .receive_window(SERVER_CONN_WINDOW.into());
    sc.transport_config(Arc::new(t));
    Ok(sc)
}

/// A device accepting other devices: TLS 1.3 only; a client certificate is optional (a `rapp/1`
/// peer shows none), but one that is shown must be backed by its key.
pub fn device_server_config(id: &Identity, alpns: &[&[u8]]) -> Result<quinn::ServerConfig> {
    let tls = server_tls(id, provider(), false, alpns.iter().map(|a| a.to_vec()).collect())?;
    let mut sc = quinn::ServerConfig::with_crypto(Arc::new(QuicServerConfig::try_from(tls)?));
    let mut t = transport();
    t.max_concurrent_bidi_streams(1024u32.into());
    sc.transport_config(Arc::new(t));
    Ok(sc)
}

/// A device dialing another device: shows its certificate; the caller compares the server's
/// fingerprint after the handshake.
pub fn device_client_config(id: &Identity, alpn: &[u8]) -> Result<quinn::ClientConfig> {
    client_config(id, alpn, Expect::Any)
}

/// TLS inside a relayed stream, server side: the client must show a certificate.
pub fn e2e_server(id: &Identity) -> Result<Arc<rustls::ServerConfig>> {
    Ok(Arc::new(server_tls(id, provider(), true, vec![ALPN_E2E.to_vec()])?))
}

/// TLS inside a relayed stream, client side; the caller compares the server's fingerprint.
pub fn e2e_client(id: &Identity) -> Result<Arc<rustls::ClientConfig>> {
    Ok(Arc::new(client_tls(id, Expect::Any, ALPN_E2E)?))
}

/// The ALPN the connection negotiated.
pub fn alpn(conn: &quinn::Connection) -> Option<Vec<u8>> {
    conn.handshake_data()?.downcast::<quinn::crypto::rustls::HandshakeData>().ok()?.protocol
}

fn server_tls(
    id: &Identity,
    p: Arc<CryptoProvider>,
    mandatory: bool,
    alpns: Vec<Vec<u8>>,
) -> Result<rustls::ServerConfig> {
    let verifier = ClientVerifier { algs: p.signature_verification_algorithms, mandatory };
    let mut tls = rustls::ServerConfig::builder_with_provider(p)
        .with_protocol_versions(&[&rustls::version::TLS13])?
        .with_client_cert_verifier(Arc::new(verifier))
        .with_single_cert(vec![id.cert.clone()], PrivateKeyDer::Pkcs8(id.key.clone_key()))?;
    tls.alpn_protocols = alpns;
    Ok(tls)
}

fn client_tls(id: &Identity, expect: Expect, alpn: &[u8]) -> Result<rustls::ClientConfig> {
    let p = provider();
    let verifier = ServerVerifier { algs: p.signature_verification_algorithms, expect };
    let mut tls = rustls::ClientConfig::builder_with_provider(p)
        .with_protocol_versions(&[&rustls::version::TLS13])?
        .dangerous()
        .with_custom_certificate_verifier(Arc::new(verifier))
        .with_client_auth_cert(vec![id.cert.clone()], PrivateKeyDer::Pkcs8(id.key.clone_key()))?;
    tls.alpn_protocols = vec![alpn.to_vec()];
    Ok(tls)
}

/// TLS 1.3 only; shows this device's certificate and checks the server against `expect`.
pub fn client_config(id: &Identity, alpn: &[u8], expect: Expect) -> Result<quinn::ClientConfig> {
    let tls = client_tls(id, expect, alpn)?;
    let mut cc = quinn::ClientConfig::new(Arc::new(QuicClientConfig::try_from(tls)?));
    cc.transport_config(Arc::new(transport()));
    Ok(cc)
}

/// The fingerprint of the certificate the peer showed in the handshake.
pub fn peer_fp(conn: &quinn::Connection) -> Result<Fp> {
    let certs = conn
        .peer_identity()
        .and_then(|i| i.downcast::<Vec<CertificateDer<'static>>>().ok())
        .ok_or_else(|| anyhow!("peer showed no certificate"))?;
    Fp::of_cert(certs.first().ok_or_else(|| anyhow!("peer showed no certificate"))?)
}

fn provider() -> Arc<CryptoProvider> {
    Arc::new(rustls::crypto::ring::default_provider())
}

/// Keep-alive 10 s, idle 30 s: both sides.
fn transport() -> quinn::TransportConfig {
    let mut t = quinn::TransportConfig::default();
    t.keep_alive_interval(Some(Duration::from_secs(10)));
    t.max_idle_timeout(Some(Duration::from_secs(30).try_into().expect("idle timeout fits")));
    t
}

fn parse_fp(cert: &CertificateDer<'_>) -> Result<Fp, rustls::Error> {
    Fp::of_cert(cert).map_err(|_| rustls::Error::InvalidCertificate(CertificateError::BadEncoding))
}

fn no_tls12() -> rustls::Error {
    rustls::Error::PeerIncompatible(PeerIncompatible::Tls12NotOffered)
}

/// Server side: any client certificate x509-parser can read, as long as the client signs with its key.
/// With `mandatory` false a client may also show no certificate at all.
#[derive(Debug)]
struct ClientVerifier {
    algs: WebPkiSupportedAlgorithms,
    mandatory: bool,
}

impl ClientCertVerifier for ClientVerifier {
    fn client_auth_mandatory(&self) -> bool {
        self.mandatory
    }

    fn root_hint_subjects(&self) -> &[DistinguishedName] {
        &[]
    }

    fn verify_client_cert(
        &self,
        end_entity: &CertificateDer<'_>,
        _intermediates: &[CertificateDer<'_>],
        _now: UnixTime,
    ) -> Result<ClientCertVerified, rustls::Error> {
        parse_fp(end_entity)?;
        Ok(ClientCertVerified::assertion())
    }

    fn verify_tls12_signature(
        &self,
        _: &[u8],
        _: &CertificateDer<'_>,
        _: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        Err(no_tls12())
    }

    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls13_signature(message, cert, dss, &self.algs)
    }

    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        self.algs.supported_schemes()
    }
}

/// Client side: the server's certificate is judged by `expect`, and the server must sign with its key.
#[derive(Debug)]
struct ServerVerifier {
    algs: WebPkiSupportedAlgorithms,
    expect: Expect,
}

impl ServerCertVerifier for ServerVerifier {
    fn verify_server_cert(
        &self,
        end_entity: &CertificateDer<'_>,
        _intermediates: &[CertificateDer<'_>],
        _server_name: &ServerName<'_>,
        _ocsp_response: &[u8],
        _now: UnixTime,
    ) -> Result<ServerCertVerified, rustls::Error> {
        let fp = parse_fp(end_entity)?;
        match self.expect {
            Expect::Pin(p) if fp.prefix16() != p => {
                Err(rustls::Error::InvalidCertificate(CertificateError::ApplicationVerificationFailure))
            }
            _ => Ok(ServerCertVerified::assertion()),
        }
    }

    fn verify_tls12_signature(
        &self,
        _: &[u8],
        _: &CertificateDer<'_>,
        _: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        Err(no_tls12())
    }

    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls13_signature(message, cert, dss, &self.algs)
    }

    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        self.algs.supported_schemes()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::SocketAddr;

    fn local() -> SocketAddr {
        "127.0.0.1:0".parse().unwrap()
    }

    fn server(id: &Identity) -> quinn::Endpoint {
        quinn::Endpoint::server(server_config(id, ALPN_RELAY, 128).unwrap(), local()).unwrap()
    }

    /// Connects with `cc`; returns the client's result and the server's.
    async fn handshake(
        srv: &quinn::Endpoint,
        cc: quinn::ClientConfig,
    ) -> (Result<quinn::Connection>, Result<quinn::Connection>) {
        let cli = quinn::Endpoint::client(local()).unwrap();
        let addr = srv.local_addr().unwrap();
        let s = srv.clone();
        let accept = tokio::spawn(async move {
            let inc = s.accept().await.ok_or_else(|| anyhow!("endpoint closed"))?;
            Ok::<_, anyhow::Error>(inc.await?)
        });
        let c = async { Ok::<_, anyhow::Error>(cli.connect_with(cc, addr, SNI)?.await?) }.await;
        let s = tokio::time::timeout(Duration::from_secs(5), accept).await.expect("server side timed out").unwrap();
        (c, s)
    }

    /// The client may finish its side of the handshake before the server's refusal lands;
    /// then the connection must close with an error rather than live on.
    async fn refused(c: Result<quinn::Connection>) -> bool {
        match c {
            Err(_) => true,
            Ok(conn) => {
                let e = tokio::time::timeout(Duration::from_secs(5), conn.closed()).await.expect("never closed");
                !matches!(e, quinn::ConnectionError::LocallyClosed)
            }
        }
    }

    #[tokio::test]
    async fn mutual_tls_gives_each_side_the_others_fp() {
        let (sid, cid) = (Identity::generate().unwrap(), Identity::generate().unwrap());
        let srv = server(&sid);
        let cc = client_config(&cid, ALPN_RELAY, Expect::Pin(sid.fp.prefix16())).unwrap();
        let (c, s) = handshake(&srv, cc).await;
        let (c, s) = (c.unwrap(), s.unwrap());
        assert_eq!(peer_fp(&c).unwrap(), sid.fp);
        assert_eq!(peer_fp(&s).unwrap(), cid.fp);

        // A stream works end to end through `bi`.
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        let echo = tokio::spawn(async move {
            let mut st = bi(s.accept_bi().await.unwrap());
            let mut b = [0u8; 4];
            st.read_exact(&mut b).await.unwrap();
            st.write_all(&b).await.unwrap();
            st.shutdown().await.unwrap();
            s
        });
        let mut st = bi(c.open_bi().await.unwrap());
        st.write_all(b"ping").await.unwrap();
        let mut b = Vec::new();
        st.read_to_end(&mut b).await.unwrap();
        assert_eq!(b, b"ping");
        drop(echo.await.unwrap());
    }

    #[tokio::test]
    async fn any_accepts_whatever_server() {
        let (sid, cid) = (Identity::generate().unwrap(), Identity::generate().unwrap());
        let srv = server(&sid);
        let (c, s) = handshake(&srv, client_config(&cid, ALPN_RELAY, Expect::Any).unwrap()).await;
        assert_eq!(peer_fp(&c.unwrap()).unwrap(), sid.fp);
        assert_eq!(peer_fp(&s.unwrap()).unwrap(), cid.fp);
    }

    #[tokio::test]
    async fn client_rejects_a_server_whose_fp_does_not_match_the_pin() {
        let (sid, cid, other) =
            (Identity::generate().unwrap(), Identity::generate().unwrap(), Identity::generate().unwrap());
        let srv = server(&sid);
        let cc = client_config(&cid, ALPN_RELAY, Expect::Pin(other.fp.prefix16())).unwrap();
        let (c, s) = handshake(&srv, cc).await;
        assert!(c.is_err());
        assert!(s.is_err());
    }

    /// A client built by hand: `cert` is what it shows (None: no certificate at all).
    fn hand_built_client(cert: Option<Arc<rustls::sign::CertifiedKey>>) -> quinn::ClientConfig {
        let provider = Arc::new(rustls::crypto::ring::default_provider());
        let b = rustls::ClientConfig::builder_with_provider(provider.clone())
            .with_protocol_versions(&[&rustls::version::TLS13])
            .unwrap()
            .dangerous()
            .with_custom_certificate_verifier(Arc::new(ServerVerifier {
                algs: provider.signature_verification_algorithms,
                expect: Expect::Any,
            }));
        let mut tls = match cert {
            None => b.with_no_client_auth(),
            Some(ck) => b.with_client_cert_resolver(Arc::new(rustls::sign::SingleCertAndKey::from(ck))),
        };
        tls.alpn_protocols = vec![ALPN_RELAY.to_vec()];
        quinn::ClientConfig::new(Arc::new(QuicClientConfig::try_from(tls).unwrap()))
    }

    #[tokio::test]
    async fn server_refuses_a_client_without_a_certificate() {
        let srv = server(&Identity::generate().unwrap());
        let (c, s) = handshake(&srv, hand_built_client(None)).await;
        assert!(s.is_err());
        assert!(refused(c).await);
    }

    /// `victim`'s certificate, but signatures made with `thief`'s key.
    fn stolen_cert(victim: &Identity, thief: &Identity) -> Arc<rustls::sign::CertifiedKey> {
        let wrong_key = rustls::crypto::ring::default_provider()
            .key_provider
            .load_private_key(PrivateKeyDer::Pkcs8(thief.key.clone_key()))
            .unwrap();
        Arc::new(rustls::sign::CertifiedKey::new(vec![victim.cert.clone()], wrong_key))
    }

    #[tokio::test]
    async fn server_refuses_a_certificate_signed_for_with_another_key() {
        let srv = server(&Identity::generate().unwrap());
        let (victim, thief) = (Identity::generate().unwrap(), Identity::generate().unwrap());
        let (c, s) = handshake(&srv, hand_built_client(Some(stolen_cert(&victim, &thief)))).await;
        assert!(s.is_err());
        assert!(refused(c).await);
    }

    #[tokio::test]
    async fn client_refuses_a_server_that_shows_a_certificate_without_its_key() {
        let (victim, thief, cid) =
            (Identity::generate().unwrap(), Identity::generate().unwrap(), Identity::generate().unwrap());
        let provider = Arc::new(rustls::crypto::ring::default_provider());
        let verifier = ClientVerifier { algs: provider.signature_verification_algorithms, mandatory: true };
        let mut tls = rustls::ServerConfig::builder_with_provider(provider)
            .with_protocol_versions(&[&rustls::version::TLS13])
            .unwrap()
            .with_client_cert_verifier(Arc::new(verifier))
            .with_cert_resolver(Arc::new(rustls::sign::SingleCertAndKey::from(stolen_cert(&victim, &thief))));
        tls.alpn_protocols = vec![ALPN_RELAY.to_vec()];
        let sc = quinn::ServerConfig::with_crypto(Arc::new(QuicServerConfig::try_from(tls).unwrap()));
        let srv = quinn::Endpoint::server(sc, local()).unwrap();
        let cc = client_config(&cid, ALPN_RELAY, Expect::Pin(victim.fp.prefix16())).unwrap();
        let (c, s) = handshake(&srv, cc).await;
        assert!(c.is_err());
        assert!(s.is_err());
    }

    #[tokio::test]
    async fn server_allows_no_uni_streams() {
        let (sid, cid) = (Identity::generate().unwrap(), Identity::generate().unwrap());
        let srv = server(&sid);
        let (c, _s) = handshake(&srv, client_config(&cid, ALPN_RELAY, Expect::Any).unwrap()).await;
        let c = c.unwrap();
        assert!(tokio::time::timeout(Duration::from_millis(200), c.open_uni()).await.is_err());
        // Bidi streams are still allowed.
        assert!(tokio::time::timeout(Duration::from_secs(5), c.open_bi()).await.is_ok());
    }

    #[tokio::test]
    async fn wrong_alpn_is_refused() {
        let (sid, cid) = (Identity::generate().unwrap(), Identity::generate().unwrap());
        let srv = server(&sid);
        let cc = client_config(&cid, b"rapp-relay/1", Expect::Pin(sid.fp.prefix16())).unwrap();
        let (c, s) = handshake(&srv, cc).await;
        assert!(s.is_err());
        assert!(refused(c).await);
    }
}
