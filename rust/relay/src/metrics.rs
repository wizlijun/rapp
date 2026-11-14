//! Counters for the five-minute `stats` log line and the optional loopback Prometheus endpoint
//! (spec §11.3). Counters are atomics bumped on the request paths; the two gauges (`online`,
//! `relayed_streams`) are set from the live tables just before a snapshot, so they cannot drift.

use std::net::SocketAddr;
use std::sync::atomic::{AtomicU64, Ordering::Relaxed};
use std::sync::Arc;
use std::time::Duration;

use anyhow::{Context, Result};
use serde_json::{json, Value};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};

/// How long a scraper has to send its request headers.
const REQUEST_WAIT: Duration = Duration::from_secs(2);
/// How much of the request is read before replying.
const REQUEST_CAP: usize = 4096;

#[derive(Default)]
pub struct Stats {
    /// Distinct devices with a live enrolled connection (gauge).
    pub online: AtomicU64,
    /// Live splices (gauge).
    pub relayed_streams: AtomicU64,
    /// Up plus down of every finished splice.
    pub relayed_bytes: AtomicU64,
    pub handshake_failures: AtomicU64,
    /// Requests refused with `limit` / `locked`, and connections closed with code 3.
    pub limited: AtomicU64,
    /// Requests refused because `audit.required` is set and the audit cannot be written.
    pub audit_failures: AtomicU64,
}

impl Stats {
    pub fn add(counter: &AtomicU64, n: u64) {
        counter.fetch_add(n, Relaxed);
    }

    pub fn snapshot(&self) -> Value {
        json!({
            "online": self.online.load(Relaxed),
            "relayed_streams": self.relayed_streams.load(Relaxed),
            "relayed_bytes": self.relayed_bytes.load(Relaxed),
            "handshake_failures": self.handshake_failures.load(Relaxed),
            "limited": self.limited.load(Relaxed),
            "audit_failures": self.audit_failures.load(Relaxed),
        })
    }

    /// Prometheus text exposition format 0.0.4.
    pub fn prometheus(&self) -> String {
        let rows = [
            ("rapp_relay_online_devices", "gauge", &self.online),
            ("rapp_relay_relayed_streams", "gauge", &self.relayed_streams),
            ("rapp_relay_relayed_bytes_total", "counter", &self.relayed_bytes),
            ("rapp_relay_handshake_failures_total", "counter", &self.handshake_failures),
            ("rapp_relay_limited_total", "counter", &self.limited),
            ("rapp_relay_audit_failures_total", "counter", &self.audit_failures),
        ];
        let mut out = String::new();
        for (name, kind, v) in rows {
            out.push_str(&format!("# TYPE {name} {kind}\n{name} {}\n", v.load(Relaxed)));
        }
        out
    }
}

pub type Render = Arc<dyn Fn() -> String + Send + Sync>;

/// The metrics listener: replies to any request with `render()`. Stops when dropped.
pub struct MetricsServer {
    pub addr: SocketAddr,
    task: tokio::task::JoinHandle<()>,
}

impl MetricsServer {
    pub async fn bind(addr: SocketAddr, render: Render) -> Result<MetricsServer> {
        let listener = TcpListener::bind(addr).await.with_context(|| format!("metrics listen on {addr}"))?;
        let addr = listener.local_addr()?;
        let task = tokio::spawn(async move {
            while let Ok((sock, _)) = listener.accept().await {
                tokio::spawn(serve(sock, render.clone()));
            }
        });
        Ok(MetricsServer { addr, task })
    }
}

impl Drop for MetricsServer {
    fn drop(&mut self) {
        self.task.abort();
    }
}

async fn serve(mut sock: TcpStream, render: Render) {
    let headers = async {
        let mut buf = Vec::with_capacity(512);
        let mut chunk = [0u8; 512];
        while !buf.windows(4).any(|w| w == b"\r\n\r\n") && !buf.windows(2).any(|w| w == b"\n\n") {
            let n = sock.read(&mut chunk).await.ok().filter(|&n| n > 0)?;
            buf.extend_from_slice(&chunk[..n]);
            if buf.len() > REQUEST_CAP {
                return None;
            }
        }
        Some(())
    };
    if !matches!(tokio::time::timeout(REQUEST_WAIT, headers).await, Ok(Some(()))) {
        return;
    }
    let body = render();
    let head = format!(
        "HTTP/1.1 200 OK\r\nContent-Type: text/plain; version=0.0.4\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
        body.len()
    );
    let _ = sock.write_all(head.as_bytes()).await;
    let _ = sock.write_all(body.as_bytes()).await;
    let _ = sock.shutdown().await;
}
