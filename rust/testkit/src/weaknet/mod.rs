pub mod link;
pub mod profile;
pub mod proxy;

pub use link::Link;
pub use profile::{Outage, Profile};
pub use proxy::{run, serve, ProxyStats};

/// Starts a weak-link proxy in front of the UDP `upstream` on a free local port and returns that port's address.
pub async fn spawn_proxy(upstream: std::net::SocketAddr, p: Profile) -> std::net::SocketAddr {
    let probe = tokio::net::UdpSocket::bind("127.0.0.1:0").await.unwrap();
    let listen = probe.local_addr().unwrap();
    drop(probe);
    tokio::spawn(async move {
        let _ = run(listen, upstream, p, std::sync::Arc::new(ProxyStats::default())).await;
    });
    tokio::time::sleep(std::time::Duration::from_millis(100)).await;
    listen
}
