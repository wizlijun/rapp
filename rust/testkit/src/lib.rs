//! Test kit. `weaknet` is the lossy-network proxy. The rest of this file is the core of `measure-forward`: how long it takes to open a port forward through the local
//! service's IPC (`pipe`), and how long a first byte takes to come back from an echo port.
//! The program in `src/bin/measure_forward.rs` only parses arguments and prints.

pub mod weaknet;

use anyhow::{anyhow, bail, Result};
use serde_json::{json, Value};
use std::collections::BTreeMap;
use std::time::{Duration, Instant};
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::net::tcp::{OwnedReadHalf, OwnedWriteHalf};
use tokio::net::TcpStream;

/// Longest wait for any one reply or echoed byte.
const WAIT: Duration = Duration::from_secs(30);

/// Where to measure from, and what to open.
#[derive(Clone)]
pub struct Plan {
    /// The local service's IPC port and token (`local/ipc.token`).
    pub ipc_port: u16,
    pub token: String,
    /// The device to open to, as `pipe` takes it (`<ID>` or `<ID>.rapp`).
    pub to: String,
    /// The shared port; for `first_byte` it must be an echo service.
    pub port: u16,
    /// Forwards opened one after the other, and again in `open_par`.
    pub n: usize,
    /// Forwards opened at the same time in `open_par`.
    pub parallel: usize,
}

/// Samples of each kind, in the order they were taken.
#[derive(Debug, Default)]
pub struct Report {
    /// `pipe` sent until `{"ok":true}` received, one forward at a time.
    pub open_seq: Vec<Duration>,
    /// The same, with `parallel` forwards opening at once.
    pub open_par: Vec<Duration>,
    /// One byte written after `ok` until one byte read back.
    pub first_byte: Vec<Duration>,
    /// How many forwards (of both open kinds) went by each path the service reported.
    pub path: BTreeMap<String, usize>,
}

/// An open forward: the IPC connection after the `ok` reply, and how long the reply took.
struct Opened {
    reader: BufReader<OwnedReadHalf>,
    writer: OwnedWriteHalf,
    took: Duration,
    path: String,
}

async fn open_owned(plan: Plan) -> Result<Opened> {
    open(&plan).await
}

async fn open(plan: &Plan) -> Result<Opened> {
    let tcp = TcpStream::connect(("127.0.0.1", plan.ipc_port)).await?;
    let (r, mut writer) = tcp.into_split();
    writer.write_all(format!("{}\n", json!({"token": &plan.token})).as_bytes()).await?;
    let cmd = json!({"cmd":"pipe","to":&plan.to,"port":plan.port});
    let started = Instant::now();
    writer.write_all(format!("{cmd}\n").as_bytes()).await?;
    let mut reader = BufReader::new(r);
    let mut line = String::new();
    let n = tokio::time::timeout(WAIT, reader.read_line(&mut line)).await.map_err(|_| anyhow!("no reply to pipe"))??;
    let took = started.elapsed();
    if n == 0 {
        bail!("the service closed the connection without a reply");
    }
    let reply: Value = serde_json::from_str(&line)?;
    if reply["ok"] != true {
        bail!("pipe was refused: {}", line.trim());
    }
    let path = reply["path"].as_str().unwrap_or("unknown").to_string();
    Ok(Opened { reader, writer, took, path })
}

impl Opened {
    /// Writes one byte and waits for it to come back.
    async fn first_byte(&mut self) -> Result<Duration> {
        let started = Instant::now();
        self.writer.write_all(b"x").await?;
        let mut back = [0u8; 1];
        tokio::time::timeout(WAIT, self.reader.read_exact(&mut back)).await.map_err(|_| anyhow!("no byte came back"))??;
        if back != *b"x" {
            bail!("the port did not echo");
        }
        Ok(started.elapsed())
    }
}

pub async fn measure(plan: &Plan) -> Result<Report> {
    if plan.n == 0 || plan.parallel == 0 {
        bail!("n and parallel must be at least 1");
    }
    let mut report = Report::default();
    // One at a time. Each is closed before the next opens, and tells its first byte time first.
    for _ in 0..plan.n {
        let mut one = open(plan).await?;
        report.open_seq.push(one.took);
        *report.path.entry(one.path.clone()).or_default() += 1;
        report.first_byte.push(one.first_byte().await?);
    }
    // `parallel` at a time; all of a round stay open until the round is over.
    let mut left = plan.n;
    while left > 0 {
        let round = left.min(plan.parallel);
        left -= round;
        let opening = (0..round).map(|_| open_owned(plan.clone()));
        let mut held = Vec::new();
        for opened in futures_all(opening).await {
            let opened = opened?;
            report.open_par.push(opened.took);
            *report.path.entry(opened.path.clone()).or_default() += 1;
            held.push(opened);
        }
    }
    Ok(report)
}

/// Runs the futures at the same time and returns what they returned, in order.
async fn futures_all<F, T>(futures: impl Iterator<Item = F>) -> Vec<T>
where
    F: std::future::Future<Output = T> + Send + 'static,
    T: Send + 'static,
{
    let tasks: Vec<_> = futures.map(tokio::spawn).collect();
    let mut out = Vec::new();
    for t in tasks {
        out.push(t.await.expect("a measuring task does not panic"));
    }
    out
}

/// The `p` quantile (0..=1) of `samples` by nearest rank, in milliseconds; 0 for no samples.
pub fn quantile_ms(samples: &[Duration], p: f64) -> f64 {
    if samples.is_empty() {
        return 0.0;
    }
    let mut sorted = samples.to_vec();
    sorted.sort();
    let rank = ((p * sorted.len() as f64).ceil() as usize).clamp(1, sorted.len());
    sorted[rank - 1].as_secs_f64() * 1000.0
}

impl Report {
    /// The four lines `measure-forward` prints.
    pub fn lines(&self) -> Vec<String> {
        let timing = |name: &str, s: &[Duration]| {
            format!("{name:<11} n={:<4} median {:>8.2} ms   p95 {:>8.2} ms", s.len(), quantile_ms(s, 0.5), quantile_ms(s, 0.95))
        };
        let paths: Vec<String> = self.path.iter().map(|(k, v)| format!("{k}={v}")).collect();
        vec![
            timing("open_seq", &self.open_seq),
            timing("open_par", &self.open_par),
            timing("first_byte", &self.first_byte),
            format!("{:<11} {}", "path", paths.join(" ")),
        ]
    }
}
