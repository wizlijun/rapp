//! `rapp-weaknet --listen ADDR --to HOST:PORT --profile NAME|PATH [--seed N]`
//! UDP proxy that simulates a weak network. Prints `{"event":"listening","port":P}`, then a `stats` line every second.

use anyhow::{anyhow, bail, Context, Result};
use rapp_testkit::weaknet::{serve, Link, Profile, ProxyStats};
use std::net::SocketAddr;
use std::path::Path;
use std::sync::atomic::Ordering::Relaxed;
use std::sync::Arc;
use std::time::{Duration, Instant};

fn arg(args: &[String], name: &str) -> Option<String> {
    args.iter().position(|a| a == name).and_then(|i| args.get(i + 1)).cloned()
}

#[tokio::main]
async fn main() -> Result<()> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let (Some(listen), Some(to), Some(prof)) = (arg(&args, "--listen"), arg(&args, "--to"), arg(&args, "--profile"))
    else {
        bail!("usage: rapp-weaknet --listen ADDR --to HOST:PORT --profile NAME|PATH [--seed N]");
    };
    let listen: SocketAddr = listen.parse().context("--listen")?;
    let upstream = tokio::net::lookup_host(&to).await?.next().ok_or_else(|| anyhow!("cannot resolve {to}"))?;
    let mut p = if Path::new(&prof).exists() { Profile::load(Path::new(&prof))? } else { Profile::named(&prof)? };
    if let Some(seed) = arg(&args, "--seed") {
        p.seed = seed.parse().context("--seed")?;
    }

    let sock = tokio::net::UdpSocket::bind(listen).await.with_context(|| format!("bind {listen}"))?;
    let port = sock.local_addr()?.port();

    let stats = Arc::new(ProxyStats::default());
    let clock = Link::new(&p, 0);
    let start = Instant::now();
    let st = stats.clone();
    let mut task = tokio::spawn(serve(sock, upstream, p, st));
    println!(r#"{{"event":"listening","port":{port}}}"#);
    let mut tick = tokio::time::interval(Duration::from_secs(1));
    loop {
        tokio::select! {
            r = &mut task => return r?,
            _ = tick.tick() => {
                println!(
                    r#"{{"event":"stats","up_pkts":{},"up_dropped":{},"down_pkts":{},"down_dropped":{},"down":{}}}"#,
                    stats.up_pkts.load(Relaxed), stats.up_dropped.load(Relaxed),
                    stats.down_pkts.load(Relaxed), stats.down_dropped.load(Relaxed),
                    clock.down(start.elapsed()),
                );
            }
        }
    }
}
