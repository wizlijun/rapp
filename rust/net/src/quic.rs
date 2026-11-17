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

/// The TLS client a shared port is probed with, to see whether it answers a ClientHello with a
/// ServerHello (`https`). It never finishes a handshake, so it checks no certificate (`AcceptAny`)
/// and offers no ALPN: any HTTPS server answers, whatever it serves. It offers TLS 1.3 and 1.2
/// (`ALL_VERSIONS`; the workspace enables rustls `tls12` for this alone, every other config
/// pins TLS 1.3), so that a server without TLS 1.3 answers with a ServerHello too. Built once.
pub fn probe_tls_config() -> Arc<rustls::ClientConfig> {
    static TLS: std::sync::OnceLock<Arc<rustls::ClientConfig>> = std::sync::OnceLock::new();
    TLS.get_or_init(|| {
        let tls = rustls::ClientConfig::builder_with_provider(provider())
            .with_protocol_versions(rustls::ALL_VERSIONS)
            .expect("the ring provider supports these versions")
            .dangerous()
            .with_custom_certificate_verifier(Arc::new(AcceptAny(provider())))
            .with_no_client_auth();
        Arc::new(tls)
    })
    .clone()
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

/// A client endpoint on `[::]:0` that also reaches IPv4 peers (as v4-mapped addresses), for the
/// in-process hub on a network that has only IPv6 (NAT64).
pub fn client_endpoint_dual() -> Result<Endpoint> {
    let sock = sys::bind_dual().context("bind udp [::]:0")?;
    Endpoint::new(
        quinn::EndpointConfig::default(),
        None,
        sock,
        Arc::new(quinn::TokioRuntime),
    )
    .context("bind udp [::]:0")
}

/// Gives `ep` a fresh UDP socket of the same kind (`dual`: as `client_endpoint_dual`, else IPv4 on
/// `0.0.0.0:0`) and returns its address. Live connections move to it; quinn tells their peers. iOS
/// takes the sockets of a suspended app away, and a socket bound before a network change can keep
/// sending into the old one: a new socket is what gets through again.
pub fn rebind(ep: &Endpoint, dual: bool) -> Result<SocketAddr> {
    let sock = if dual { sys::bind_dual().context("bind udp [::]:0")? } else { std::net::UdpSocket::bind("0.0.0.0:0").context("bind udp 0.0.0.0:0")? };
    ep.rebind(sock).context("rebind udp")?;
    Ok(ep.local_addr()?)
}

/// `resolve`, or with `dual` for a dual-stack endpoint (`client_endpoint_dual`): an IPv4 address
/// with an IPv4 route comes back v4-mapped; without one the name is resolved again with
/// `getaddrinfo(AI_DEFAULT)`, which synthesizes an IPv6 address on a NAT64 network.
pub async fn resolve_for(hostport: &str, dual: bool) -> Result<SocketAddr> {
    if !dual {
        return resolve(hostport).await;
    }
    let addrs: Vec<SocketAddr> = tokio::net::lookup_host(hostport).await.map(|i| i.collect()).unwrap_or_default();
    if let Some(v4) = addrs.iter().find(|a| a.is_ipv4()) {
        let routed = tokio::net::UdpSocket::bind("0.0.0.0:0").await?.connect(v4).await.is_ok();
        if routed {
            return Ok(mapped(*v4));
        }
    }
    let (host, port) = hostport.rsplit_once(':').ok_or_else(|| anyhow!("cannot resolve {hostport}"))?;
    let (host, port) = (host.trim_start_matches('[').trim_end_matches(']').to_string(), port.to_string());
    let synthesized = tokio::task::spawn_blocking(move || sys::getaddrinfo_v6(&host, &port)).await?;
    if let Some(a) = synthesized {
        return Ok(a);
    }
    // No IPv4 route and nothing synthesized: an IPv6 answer of the first lookup still works.
    addrs.iter().find(|a| matches!(a, SocketAddr::V6(v6) if v6.ip().to_ipv4_mapped().is_none())).copied().ok_or_else(|| anyhow!("cannot resolve {hostport}"))
}

/// An IPv4 address as the IPv6 address a dual-stack socket takes; others unchanged.
pub fn mapped(a: SocketAddr) -> SocketAddr {
    match a {
        SocketAddr::V4(v4) => SocketAddr::new(v4.ip().to_ipv6_mapped().into(), v4.port()),
        v6 => v6,
    }
}

/// The libc calls behind the dual-stack pieces (no `socket2` in the tree). Only the iOS hub uses them.
#[cfg(unix)]
mod sys {
    use std::ffi::CString;
    use std::net::{Ipv6Addr, SocketAddr};
    use std::os::fd::FromRawFd;

    pub fn bind_dual() -> std::io::Result<std::net::UdpSocket> {
        // SAFETY: plain socket/setsockopt/bind calls; the fd is closed on every error path and
        // otherwise owned by the returned socket.
        unsafe {
            let fd = libc::socket(libc::AF_INET6, libc::SOCK_DGRAM, 0);
            if fd < 0 {
                return Err(std::io::Error::last_os_error());
            }
            let off: libc::c_int = 0;
            let mut addr: libc::sockaddr_in6 = std::mem::zeroed();
            addr.sin6_family = libc::AF_INET6 as _;
            #[cfg(any(target_os = "macos", target_os = "ios"))]
            {
                addr.sin6_len = std::mem::size_of::<libc::sockaddr_in6>() as u8;
            }
            if libc::setsockopt(
                fd,
                libc::IPPROTO_IPV6,
                libc::IPV6_V6ONLY,
                &off as *const _ as *const libc::c_void,
                std::mem::size_of::<libc::c_int>() as libc::socklen_t,
            ) < 0
                || libc::bind(fd, &addr as *const _ as *const libc::sockaddr, std::mem::size_of::<libc::sockaddr_in6>() as libc::socklen_t) < 0
            {
                let e = std::io::Error::last_os_error();
                libc::close(fd);
                return Err(e);
            }
            let sock = std::net::UdpSocket::from_raw_fd(fd);
            sock.set_nonblocking(true)?;
            Ok(sock)
        }
    }

    #[cfg(any(target_os = "macos", target_os = "ios"))]
    const AI_FLAGS: libc::c_int = libc::AI_DEFAULT;
    #[cfg(not(any(target_os = "macos", target_os = "ios")))]
    const AI_FLAGS: libc::c_int = libc::AI_V4MAPPED | libc::AI_ADDRCONFIG;

    /// The first IPv6 address `getaddrinfo` gives for `host:port` (Apple's synthesizes one from an
    /// IPv4 literal on a NAT64 network).
    pub fn getaddrinfo_v6(host: &str, port: &str) -> Option<SocketAddr> {
        let (host, port) = (CString::new(host).ok()?, CString::new(port).ok()?);
        // SAFETY: `hints` is zeroed and filled; the result list is read then freed.
        unsafe {
            let mut hints: libc::addrinfo = std::mem::zeroed();
            hints.ai_family = libc::AF_UNSPEC;
            hints.ai_socktype = libc::SOCK_DGRAM;
            hints.ai_flags = AI_FLAGS;
            let mut res: *mut libc::addrinfo = std::ptr::null_mut();
            if libc::getaddrinfo(host.as_ptr(), port.as_ptr(), &hints, &mut res) != 0 {
                return None;
            }
            let mut found = None;
            let mut p = res;
            while !p.is_null() && found.is_none() {
                let ai = &*p;
                if ai.ai_family == libc::AF_INET6 && !ai.ai_addr.is_null() {
                    let sin6 = &*(ai.ai_addr as *const libc::sockaddr_in6);
                    let ip = Ipv6Addr::from(sin6.sin6_addr.s6_addr);
                    // A v4-mapped address is not what NAT64 synthesizes; it cannot be reached there.
                    if ip.to_ipv4_mapped().is_none() {
                        found = Some(SocketAddr::new(ip.into(), u16::from_be(sin6.sin6_port)));
                    }
                }
                p = ai.ai_next;
            }
            libc::freeaddrinfo(res);
            found
        }
    }
}

#[cfg(not(unix))]
mod sys {
    pub fn bind_dual() -> std::io::Result<std::net::UdpSocket> {
        Err(std::io::Error::other("dual-stack endpoint is not supported here"))
    }
    pub fn getaddrinfo_v6(_: &str, _: &str) -> Option<std::net::SocketAddr> {
        None
    }
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

    #[tokio::test]
    async fn dual_endpoint_reaches_ipv4_server() {
        let server = server_endpoint("127.0.0.1:0".parse().unwrap(), ALPN_PEER).unwrap();
        let port = server.local_addr().unwrap().port();
        let srv = tokio::spawn(async move {
            let conn = server.accept().await.unwrap().await.unwrap();
            let seen = conn.remote_address();
            conn.close(0u32.into(), b"");
            seen
        });
        let client = client_endpoint_dual().unwrap();
        let addr = resolve_for(&format!("127.0.0.1:{port}"), true).await.unwrap();
        let conn = connect(&client, addr, ALPN_PEER, Duration::from_secs(2)).await.unwrap();
        let seen = srv.await.unwrap();
        assert_eq!(seen.ip(), std::net::IpAddr::from([127, 0, 0, 1]));
        drop(conn);
    }

    /// What iOS does to a suspended app's sockets, near enough: the endpoint's fd stops reaching
    /// anyone. Swapped for a UDP socket connected to a port nobody listens on.
    #[cfg(unix)]
    fn kill_socket(ep_fd: std::os::fd::RawFd) -> std::net::UdpSocket {
        use std::os::fd::AsRawFd;
        let dead = std::net::UdpSocket::bind("127.0.0.1:0").unwrap();
        dead.connect("127.0.0.1:9").unwrap();
        // SAFETY: both fds are open; dup2 swaps what ep_fd refers to.
        assert!(unsafe { libc::dup2(dead.as_raw_fd(), ep_fd) } >= 0);
        dead
    }

    #[cfg(unix)]
    fn endpoint_with_fd() -> (Endpoint, std::os::fd::RawFd) {
        use std::os::fd::AsRawFd;
        let sock = std::net::UdpSocket::bind("127.0.0.1:0").unwrap();
        let fd = sock.as_raw_fd();
        let ep = Endpoint::new(quinn::EndpointConfig::default(), None, sock, Arc::new(quinn::TokioRuntime)).unwrap();
        (ep, fd)
    }

    fn echo_server() -> SocketAddr {
        let server = server_endpoint("127.0.0.1:0".parse().unwrap(), ALPN_PEER).unwrap();
        let addr = server.local_addr().unwrap();
        tokio::spawn(async move {
            while let Some(inc) = server.accept().await {
                tokio::spawn(async move {
                    let Ok(conn) = inc.await else { return };
                    while let Ok(s) = conn.accept_bi().await {
                        let mut s = bi(s);
                        if let Ok(v) = read_json(&mut s).await {
                            let _ = write_json(&mut s, &json!({"echo": v})).await;
                        }
                    }
                });
            }
        });
        addr
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn rebind_revives_an_endpoint_whose_socket_died() {
        let addr = echo_server();
        let (ep, fd) = endpoint_with_fd();
        let _dead = kill_socket(fd);
        assert!(connect(&ep, addr, ALPN_PEER, Duration::from_millis(800)).await.is_err(), "a dead socket reaches nobody");
        let before = ep.local_addr().unwrap();
        let now = rebind(&ep, false).unwrap();
        assert_ne!(now.port(), before.port());
        let conn = connect(&ep, addr, ALPN_PEER, Duration::from_secs(2)).await.unwrap();
        let mut s = bi(conn.open_bi().await.unwrap());
        write_json(&mut s, &json!(2)).await.unwrap();
        assert_eq!(read_json(&mut s).await.unwrap(), json!({"echo":2}));
    }

    #[tokio::test]
    async fn a_live_connection_moves_to_the_new_socket() {
        let addr = echo_server();
        let ep = client_endpoint("127.0.0.1:0".parse().unwrap()).unwrap();
        let conn = connect(&ep, addr, ALPN_PEER, Duration::from_secs(2)).await.unwrap();
        rebind(&ep, false).unwrap();
        let mut s = bi(conn.open_bi().await.unwrap());
        write_json(&mut s, &json!(3)).await.unwrap();
        let r = tokio::time::timeout(Duration::from_secs(3), read_json(&mut s)).await.unwrap().unwrap();
        assert_eq!(r, json!({"echo":3}));
    }

    #[tokio::test]
    async fn rebind_dual_stays_dual() {
        let addr = echo_server();
        let ep = client_endpoint_dual().unwrap();
        assert!(rebind(&ep, true).unwrap().is_ipv6());
        connect(&ep, mapped(addr), ALPN_PEER, Duration::from_secs(2)).await.unwrap();
    }

    #[tokio::test]
    async fn resolve_for_plain_matches_resolve() {
        assert_eq!(resolve_for("localhost:1", false).await.unwrap(), resolve("localhost:1").await.unwrap());
    }

    #[tokio::test]
    async fn resolve_for_dual_maps_v4() {
        let a = resolve_for("127.0.0.1:9", true).await.unwrap();
        assert_eq!(a.to_string(), "[::ffff:127.0.0.1]:9");
    }

    #[cfg(unix)]
    #[test]
    fn getaddrinfo_v6_never_returns_a_v4_mapped_address() {
        assert_eq!(sys::getaddrinfo_v6("127.0.0.1", "9"), None);
        assert_eq!(sys::getaddrinfo_v6("::1", "9"), Some("[::1]:9".parse().unwrap()));
    }
}
