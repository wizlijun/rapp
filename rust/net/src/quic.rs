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
use std::pin::Pin;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::task::{Context as TaskContext, Poll};
use std::time::Duration;
use tokio::io::{AsyncRead, AsyncWrite, Join, ReadBuf};

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
    splice_metered(a, b, &Meter::default()).await
}

/// Bytes a splice has moved so far, readable even after it was cancelled or failed.
#[derive(Clone, Default, Debug)]
pub struct Meter(Arc<(AtomicU64, AtomicU64)>);

impl Meter {
    /// `(a_to_b, b_to_a)`.
    pub fn get(&self) -> (u64, u64) {
        (self.0 .0.load(Ordering::Relaxed), self.0 .1.load(Ordering::Relaxed))
    }
}

/// `splice`, counting into `meter` as bytes are read from `a` and written to `a`.
pub async fn splice_metered<A, B>(a: &mut A, b: &mut B, meter: &Meter) -> std::io::Result<()>
where
    A: AsyncRead + AsyncWrite + Unpin + ?Sized,
    B: AsyncRead + AsyncWrite + Unpin + ?Sized,
{
    let mut a = Counted { inner: a, meter };
    tokio::io::copy_bidirectional_with_sizes(&mut a, b, 64 * 1024, 64 * 1024).await.map(|_| ())
}

/// `a` with its reads counted as a→b and its writes as b→a.
struct Counted<'a, S: ?Sized> {
    inner: &'a mut S,
    meter: &'a Meter,
}

impl<S: AsyncRead + Unpin + ?Sized> AsyncRead for Counted<'_, S> {
    fn poll_read(self: Pin<&mut Self>, cx: &mut TaskContext<'_>, buf: &mut ReadBuf<'_>) -> Poll<std::io::Result<()>> {
        let this = self.get_mut();
        let before = buf.filled().len();
        let r = Pin::new(&mut *this.inner).poll_read(cx, buf);
        this.meter.0 .0.fetch_add((buf.filled().len() - before) as u64, Ordering::Relaxed);
        r
    }
}

impl<S: AsyncWrite + Unpin + ?Sized> AsyncWrite for Counted<'_, S> {
    fn poll_write(self: Pin<&mut Self>, cx: &mut TaskContext<'_>, buf: &[u8]) -> Poll<std::io::Result<usize>> {
        let this = self.get_mut();
        let r = Pin::new(&mut *this.inner).poll_write(cx, buf);
        if let Poll::Ready(Ok(n)) = r {
            this.meter.0 .1.fetch_add(n as u64, Ordering::Relaxed);
        }
        r
    }
    fn poll_flush(self: Pin<&mut Self>, cx: &mut TaskContext<'_>) -> Poll<std::io::Result<()>> {
        Pin::new(&mut *self.get_mut().inner).poll_flush(cx)
    }
    fn poll_shutdown(self: Pin<&mut Self>, cx: &mut TaskContext<'_>) -> Poll<std::io::Result<()>> {
        Pin::new(&mut *self.get_mut().inner).poll_shutdown(cx)
    }
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

/// D8: no certificate verification. The ID/password check is the gate.
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
    async fn splice_metered_counts_both_ways() {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        let (mut a, mut a_far) = tokio::io::duplex(1024);
        let (mut b, mut b_far) = tokio::io::duplex(1024);
        let meter = Meter::default();
        let m = meter.clone();
        let task = tokio::spawn(async move { splice_metered(&mut a, &mut b, &m).await });
        a_far.write_all(&[1; 300]).await.unwrap();
        a_far.shutdown().await.unwrap();
        b_far.write_all(&[2; 50]).await.unwrap();
        b_far.shutdown().await.unwrap();
        let (mut got_b, mut got_a) = (Vec::new(), Vec::new());
        b_far.read_to_end(&mut got_b).await.unwrap();
        a_far.read_to_end(&mut got_a).await.unwrap();
        task.await.unwrap().unwrap();
        assert_eq!((got_b.len(), got_a.len()), (300, 50));
        assert_eq!(meter.get(), (300, 50));
    }

    #[tokio::test]
    async fn meter_keeps_counts_when_the_splice_is_cancelled() {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        let (mut a, mut a_far) = tokio::io::duplex(1024);
        let (mut b, mut b_far) = tokio::io::duplex(1024);
        let meter = Meter::default();
        let m = meter.clone();
        let task = tokio::spawn(async move { splice_metered(&mut a, &mut b, &m).await });
        a_far.write_all(&[1; 10]).await.unwrap();
        let mut buf = [0; 10];
        b_far.read_exact(&mut buf).await.unwrap();
        task.abort();
        let _ = task.await;
        assert_eq!(meter.get(), (10, 0));
    }

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
        let server = server_endpoint("127.0.0.1:0".parse().unwrap(), b"other/1").unwrap();
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
