//! A socket whose every receive fails while it stays readable (what iOS leaves behind when it
//! takes a suspended app's socket away) must not stop the endpoint: after a rebind to a good
//! socket, connections get through again.
//!
//! quinn's own tokio socket retries such a receive at once, forever, so its endpoint driver never
//! comes back to read the new socket and every dial times out until the process restarts.
#![cfg(unix)]

use rapp_net::log::{forward_lib_warnings, Log};
use rapp_net::quic::{client_endpoint, connect, server_endpoint, ALPN_PEER};
use std::os::fd::{FromRawFd, IntoRawFd};
use std::time::Duration;

/// A listening TCP socket with a connection waiting: readable, and every `recvmsg` on it fails
/// with ENOTCONN, as on a socket iOS has defuncted.
fn always_failing_socket() -> (std::net::UdpSocket, std::net::TcpStream) {
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let waiting = std::net::TcpStream::connect(listener.local_addr().unwrap()).unwrap();
    listener.set_nonblocking(true).unwrap();
    // SAFETY: the fd comes straight from into_raw_fd and is owned by the new socket alone.
    let sock = unsafe { std::net::UdpSocket::from_raw_fd(listener.into_raw_fd()) };
    (sock, waiting)
}

#[test]
fn a_socket_that_always_fails_to_receive_does_not_stop_the_endpoint() {
    let dir = tempfile::tempdir().unwrap();
    forward_lib_warnings(Log::file(dir.path(), "hub.log"));
    // A spinning driver would hold its worker for good: run on our own runtime and leave it
    // behind instead of waiting for it.
    let rt = tokio::runtime::Builder::new_multi_thread().worker_threads(4).enable_all().build().unwrap();
    let r = rt.block_on(async {
        let server = server_endpoint("127.0.0.1:0".parse().unwrap(), ALPN_PEER).unwrap();
        let addr = server.local_addr().unwrap();
        tokio::spawn(async move {
            while let Some(inc) = server.accept().await {
                tokio::spawn(async move {
                    if let Ok(conn) = inc.await {
                        conn.closed().await;
                    }
                });
            }
        });
        let ep = client_endpoint("127.0.0.1:0".parse().unwrap()).unwrap();
        let (bad, _waiting) = always_failing_socket();
        ep.rebind(bad).unwrap();
        tokio::time::sleep(Duration::from_millis(200)).await;
        ep.rebind(std::net::UdpSocket::bind("127.0.0.1:0").unwrap()).unwrap();
        connect(&ep, addr, ALPN_PEER, Duration::from_secs(3)).await.map(|_| ())
    });
    rt.shutdown_background();
    r.unwrap();
    let text = std::fs::read_to_string(dir.path().join("hub.log")).unwrap_or_default();
    assert!(text.lines().any(|l| l.contains(r#""ev":"lib""#) && l.contains("recvmsg error")), "{text}");
}
