//! QUIC endpoints: self-signed server cert, client accepts any cert (D8), SNI `rapp`,
//! keep-alive 10 s, idle timeout 30 s (spec §2.1).

use anyhow::{anyhow, Context, Result};
use quinn::crypto::rustls::{QuicClientConfig, QuicServerConfig};
use quinn::{ClientConfig, Connection, Endpoint, RecvStream, SendStream, ServerConfig, TransportConfig};
use rustls::client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier};
use rustls::crypto::CryptoProvider;
use rustls::pki_types::{CertificateDer, PrivateKeyDer, PrivatePkcs8KeyDer, ServerName, UnixTime};
use rustls::{DigitallySignedStruct, SignatureScheme};
use std::net::SocketAddr;
use std::sync::Arc;
use std::time::Duration;
use tokio::io::{AsyncRead, AsyncWrite, Join};

pub const ALPN_RELAY: &[u8] = b"rapp-relay/1";
pub const ALPN_PEER: &[u8] = b"rapp/1";
pub const SNI: &str = "rapp";

/// A bidirectional QUIC stream as one `AsyncRead + AsyncWrite`.
pub type BiStream = Join<RecvStream, SendStream>;

pub fn bi((send, recv): (SendStream, RecvStream)) -> BiStream {
    tokio::io::join(recv, send)
}

/// Copies both ways until both sides are done (64 KiB buffers).
pub async fn splice<A, B>(a: &mut A, b: &mut B) -> std::io::Result<()>
where
    A: AsyncRead + AsyncWrite + Unpin + ?Sized,
    B: AsyncRead + AsyncWrite + Unpin + ?Sized,
{
    tokio::io::copy_bidirectional_with_sizes(a, b, 64 * 1024, 64 * 1024).await.map(|_| ())
}

fn provider() -> Arc<CryptoProvider> {
    Arc::new(rustls::crypto::ring::default_provider())
}

fn transport() -> Arc<TransportConfig> {
    let mut t = TransportConfig::default();
    t.keep_alive_interval(Some(Duration::from_secs(10)));
    t.max_idle_timeout(Some(Duration::from_secs(30).try_into().expect("idle timeout")));
    t.max_concurrent_bidi_streams(1024u32.into());
    Arc::new(t)
}

fn server_config(alpn: &[u8]) -> Result<ServerConfig> {
    let ck = rcgen::generate_simple_self_signed(vec![SNI.to_string()])?;
    let cert = ck.cert.der().clone();
    let key = PrivateKeyDer::Pkcs8(PrivatePkcs8KeyDer::from(ck.signing_key.serialize_der()));
    let mut tls = rustls::ServerConfig::builder_with_provider(provider())
        .with_protocol_versions(&[&rustls::version::TLS13])?
        .with_no_client_auth()
        .with_single_cert(vec![cert], key)?;
    tls.alpn_protocols = vec![alpn.to_vec()];
    let mut sc = ServerConfig::with_crypto(Arc::new(QuicServerConfig::try_from(tls)?));
    sc.transport_config(transport());
    Ok(sc)
}

pub fn client_config(alpn: &[u8]) -> Result<ClientConfig> {
    let mut tls = rustls::ClientConfig::builder_with_provider(provider())
        .with_protocol_versions(&[&rustls::version::TLS13])?
        .dangerous()
        .with_custom_certificate_verifier(Arc::new(AcceptAny(provider())))
        .with_no_client_auth();
    tls.alpn_protocols = vec![alpn.to_vec()];
    let mut cc = ClientConfig::new(Arc::new(QuicClientConfig::try_from(tls)?));
    cc.transport_config(transport());
    Ok(cc)
}

/// An endpoint that accepts connections with `alpn` and can also dial out.
pub fn server_endpoint(addr: SocketAddr, alpn: &[u8]) -> Result<Endpoint> {
    Endpoint::server(server_config(alpn)?, addr).with_context(|| format!("bind udp {addr}"))
}

pub fn client_endpoint(addr: SocketAddr) -> Result<Endpoint> {
    Endpoint::client(addr).with_context(|| format!("bind udp {addr}"))
}

pub async fn connect(ep: &Endpoint, addr: SocketAddr, alpn: &[u8], wait: Duration) -> Result<Connection> {
    let connecting = ep.connect_with(client_config(alpn)?, addr, SNI)?;
    tokio::time::timeout(wait, connecting)
        .await
        .map_err(|_| anyhow!("connect {addr}: timed out"))?
        .with_context(|| format!("connect {addr}"))
}

/// Resolves `host:port` (first address, IPv4 preferred).
pub async fn resolve(hostport: &str) -> Result<SocketAddr> {
    let addrs: Vec<SocketAddr> = tokio::net::lookup_host(hostport).await?.collect();
    addrs
        .iter()
        .find(|a| a.is_ipv4())
        .or(addrs.first())
        .copied()
        .ok_or_else(|| anyhow!("cannot resolve {hostport}"))
}

/// D8: no certificate verification. The relay's key + ID/password check is the gate.
#[derive(Debug)]
struct AcceptAny(Arc<CryptoProvider>);

impl ServerCertVerifier for AcceptAny {
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
        Ok(HandshakeSignatureValid::assertion())
    }

    fn verify_tls13_signature(
        &self,
        _: &[u8],
        _: &CertificateDer<'_>,
        _: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        Ok(HandshakeSignatureValid::assertion())
    }

    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        self.0.signature_verification_algorithms.supported_schemes()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::line::{read_json, write_json};
    use serde_json::json;

    #[tokio::test]
    async fn roundtrip_over_self_signed_quic() {
        let server = server_endpoint("127.0.0.1:0".parse().unwrap(), ALPN_PEER).unwrap();
        let addr = server.local_addr().unwrap();
        let srv = tokio::spawn(async move {
            let conn = server.accept().await.unwrap().await.unwrap();
            let mut s = bi(conn.accept_bi().await.unwrap());
            let v = read_json(&mut s).await.unwrap();
            write_json(&mut s, &json!({"echo": v})).await.unwrap();
            s.writer_mut().finish().unwrap();
            conn.closed().await;
        });
        let client = client_endpoint("127.0.0.1:0".parse().unwrap()).unwrap();
        let conn = connect(&client, addr, ALPN_PEER, Duration::from_secs(2)).await.unwrap();
        let mut s = bi(conn.open_bi().await.unwrap());
        write_json(&mut s, &json!(1)).await.unwrap();
        assert_eq!(read_json(&mut s).await.unwrap(), json!({"echo":1}));
        conn.close(0u32.into(), b"");
        srv.await.unwrap();
    }

    #[tokio::test]
    async fn wrong_alpn_is_refused() {
        let server = server_endpoint("127.0.0.1:0".parse().unwrap(), ALPN_RELAY).unwrap();
        let addr = server.local_addr().unwrap();
        tokio::spawn(async move {
            while let Some(inc) = server.accept().await {
                let _ = inc.await;
            }
        });
        let client = client_endpoint("127.0.0.1:0".parse().unwrap()).unwrap();
        assert!(connect(&client, addr, ALPN_PEER, Duration::from_secs(2)).await.is_err());
    }
}
