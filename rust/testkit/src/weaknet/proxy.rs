//! UDP proxy that runs every datagram through a `Link` per direction. One session per client source
//! address; time zero is the moment `run` starts. Packets are queued per direction with their delivery
//! time and sent by one task per direction. When the rebind epoch changes the session gets a fresh
//! upstream socket (the peer sees a new source port, like a NAT remap) and replies to the old one are dropped.

use super::{Link, Profile};
use anyhow::{Context, Result};
use std::collections::HashMap;
use std::net::SocketAddr;
use std::sync::atomic::{AtomicU64, Ordering::Relaxed};
use std::sync::{Arc, Mutex};
use tokio::net::UdpSocket;
use tokio::sync::mpsc::{unbounded_channel, UnboundedSender};
use tokio::task::JoinHandle;
use tokio::time::{sleep_until, Instant};

#[derive(Default)]
pub struct ProxyStats {
    pub up_pkts: AtomicU64,
    pub up_dropped: AtomicU64,
    pub down_pkts: AtomicU64,
    pub down_dropped: AtomicU64,
}

/// A datagram waiting for its delivery time, and the socket to send it from.
struct Queued {
    at: Instant,
    data: Vec<u8>,
    via: Arc<UdpSocket>,
    to: SocketAddr,
}

fn sender() -> UnboundedSender<Queued> {
    let (tx, mut rx) = unbounded_channel::<Queued>();
    tokio::spawn(async move {
        while let Some(q) = rx.recv().await {
            sleep_until(q.at).await;
            let _ = q.via.send_to(&q.data, q.to).await;
        }
    });
    tx
}

struct Session {
    up: Link,
    down: Arc<Mutex<Link>>,
    epoch: u64,
    upstream: Arc<UdpSocket>,
    reader: JoinHandle<()>,
    up_tx: UnboundedSender<Queued>,
    down_tx: UnboundedSender<Queued>,
}

struct Ctx {
    main: Arc<UdpSocket>,
    start: Instant,
    stats: Arc<ProxyStats>,
}

async fn bind_upstream(upstream: SocketAddr) -> Result<Arc<UdpSocket>> {
    let any: SocketAddr = if upstream.is_ipv4() { "0.0.0.0:0" } else { "[::]:0" }.parse()?;
    Ok(Arc::new(UdpSocket::bind(any).await.context("bind upstream socket")?))
}

/// Reads replies on one upstream socket and feeds them to the downlink. Aborted on rebind.
fn spawn_reader(
    ctx: &Ctx,
    sock: Arc<UdpSocket>,
    client: SocketAddr,
    down: Arc<Mutex<Link>>,
    tx: UnboundedSender<Queued>,
) -> JoinHandle<()> {
    let (main, start, stats) = (ctx.main.clone(), ctx.start, ctx.stats.clone());
    tokio::spawn(async move {
        let mut buf = vec![0u8; 65536];
        while let Ok((n, _)) = sock.recv_from(&mut buf).await {
            stats.down_pkts.fetch_add(1, Relaxed);
            let verdict = down.lock().unwrap().admit(start.elapsed(), n);
            match verdict {
                Some(d) => {
                    let _ = tx.send(Queued { at: start + d, data: buf[..n].to_vec(), via: main.clone(), to: client });
                }
                None => {
                    stats.down_dropped.fetch_add(1, Relaxed);
                }
            }
        }
    })
}

pub async fn run(listen: SocketAddr, upstream: SocketAddr, p: Profile, stats: Arc<ProxyStats>) -> Result<()> {
    let sock = UdpSocket::bind(listen).await.with_context(|| format!("bind {listen}"))?;
    serve(sock, upstream, p, stats).await
}

/// Like `run`, on an already bound socket (lets a caller learn the port of `:0` before serving).
pub async fn serve(sock: UdpSocket, upstream: SocketAddr, p: Profile, stats: Arc<ProxyStats>) -> Result<()> {
    let main = Arc::new(sock);
    let ctx = Ctx { main: main.clone(), start: Instant::now(), stats };
    let mut sessions: HashMap<SocketAddr, Session> = HashMap::new();
    let mut buf = vec![0u8; 65536];
    loop {
        let (n, client) = main.recv_from(&mut buf).await?;
        let now = ctx.start.elapsed();
        if let std::collections::hash_map::Entry::Vacant(e) = sessions.entry(client) {
            let upstream_sock = bind_upstream(upstream).await?;
            let down = Arc::new(Mutex::new(Link::new(&p, 1)));
            let down_tx = sender();
            let up = Link::new(&p, 0);
            let reader = spawn_reader(&ctx, upstream_sock.clone(), client, down.clone(), down_tx.clone());
            let epoch = up.rebind_epoch(now);
            e.insert(Session { up, down, epoch, upstream: upstream_sock, reader, up_tx: sender(), down_tx });
        }
        let s = sessions.get_mut(&client).unwrap();
        let epoch = s.up.rebind_epoch(now);
        if epoch != s.epoch {
            s.epoch = epoch;
            s.reader.abort();
            s.upstream = bind_upstream(upstream).await?;
            s.reader = spawn_reader(&ctx, s.upstream.clone(), client, s.down.clone(), s.down_tx.clone());
        }
        ctx.stats.up_pkts.fetch_add(1, Relaxed);
        match s.up.admit(now, n) {
            Some(d) => {
                let _ = s.up_tx.send(Queued {
                    at: ctx.start + d,
                    data: buf[..n].to_vec(),
                    via: s.upstream.clone(),
                    to: upstream,
                });
            }
            None => {
                ctx.stats.up_dropped.fetch_add(1, Relaxed);
            }
        }
    }
}
