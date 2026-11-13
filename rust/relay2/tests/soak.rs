//! A long run with many devices: memory must not grow. Not part of the normal run:
//! `RAPP_SOAK_SECS=600 cargo test -p rapp-relay2 --release --test soak -- --ignored --nocapture`
mod common;

use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

use common::*;
use rapp_wire::msg::{Push, Req};
use rapp_wire::tls::BiStream;
use rapp_wire::Identity;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::sync::mpsc;
use tokio::time::{sleep, timeout};

const DEVICES: usize = 50;
const SAMPLE_EVERY: Duration = Duration::from_secs(30);
/// The sample the others are compared with.
const BASELINE_AT: Duration = Duration::from_secs(120);

/// This process's resident memory in KiB (the relay runs in-process).
fn rss_kib() -> u64 {
    let out = std::process::Command::new("ps")
        .args(["-o", "rss=", "-p", &std::process::id().to_string()])
        .output()
        .expect("ps runs");
    String::from_utf8_lossy(&out.stdout).trim().parse().expect("ps prints a number")
}

fn id_of(i: usize) -> String {
    format!("{:09}", 100_000_000 + i)
}

struct Rng(u64);

impl Rng {
    fn below(&mut self, n: u64) -> u64 {
        self.0 ^= self.0 >> 12;
        self.0 ^= self.0 << 25;
        self.0 ^= self.0 >> 27;
        self.0.wrapping_mul(0x2545_f491_4f6c_dd1d) % n
    }
}

/// The target's end of a relayed stream: echoes what arrives, then finishes.
async fn echo(mut st: BiStream) {
    let _ = timeout(Duration::from_secs(5), async {
        let mut got = Vec::new();
        st.read_to_end(&mut got).await?;
        st.write_all(&got).await?;
        st.shutdown().await
    })
    .await;
}

/// Takes the pushes of `d` and echoes every relayed stream, until the connection ends.
fn serve(mut pushes: mpsc::UnboundedReceiver<(Push, Option<BiStream>)>) {
    tokio::spawn(async move {
        while let Some((p, st)) = pushes.recv().await {
            if let (Push::Relayed { .. }, Some(st)) = (p, st) {
                tokio::spawn(echo(st));
            }
        }
    });
}

async fn request(d: &FakeDevice, req: &Req) {
    let mut line = serde_json::to_vec(req).unwrap();
    line.push(b'\n');
    let _ = d.raw(&line).await;
}

/// One device's life: connect, register, then connect/relay to others and now and then drop the
/// connection and start again, until `stop`.
async fn device(r: Arc<TestRelayHandle>, i: usize, stop: Arc<AtomicBool>, done: Arc<AtomicU64>, ready: Arc<AtomicU64>) {
    let id = Identity::generate().unwrap();
    let mut rng = Rng(0x9e37_79b9_7f4a_7c15 ^ (i as u64 + 1).wrapping_mul(0x1234_5678_9abc_def1));
    let mut first = true;
    while !stop.load(Ordering::Relaxed) {
        let mut d = FakeDevice::enrolled_as(&r.0, same_identity(&id)).await;
        let v = d.register(&id_of(i), &[]).await;
        assert_eq!(v["ok"], true, "{v}");
        serve(std::mem::replace(&mut d.pushes, mpsc::unbounded_channel().1));
        if first {
            first = false;
            ready.fetch_add(1, Ordering::SeqCst);
            while ready.load(Ordering::SeqCst) < DEVICES as u64 && !stop.load(Ordering::Relaxed) {
                sleep(Duration::from_millis(50)).await;
            }
        }
        for _ in 0..(200 + rng.below(200)) {
            if stop.load(Ordering::Relaxed) || d.conn.close_reason().is_some() {
                break;
            }
            let mut j = rng.below(DEVICES as u64 - 1) as usize;
            if j >= i {
                j += 1;
            }
            let target = id_of(j);
            request(&d, &Req::Connect { id: target.clone() }).await;
            let payload = vec![0xa5u8; 20_000];
            if let Ok(mut st) = d.relay_to_with(&target, &payload).await {
                let _ = timeout(Duration::from_secs(5), async {
                    st.shutdown().await?;
                    let mut got = Vec::new();
                    st.read_to_end(&mut got).await
                })
                .await;
            }
            done.fetch_add(1, Ordering::Relaxed);
            sleep(Duration::from_millis(50 + rng.below(150))).await;
        }
        d.close().await;
    }
}

/// `TestRelay` is not Clone; the device tasks share one behind an `Arc`.
struct TestRelayHandle(TestRelay);

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore]
async fn soak() {
    let secs: u64 = std::env::var("RAPP_SOAK_SECS").ok().and_then(|v| v.parse().ok()).unwrap_or(600);
    let r = start_relay(|c| {
        c.limits.max_conns_per_ip = 1000;
        c.limits.enroll_per_ip_per_min = 1000;
        c.limits.connect_per_target_per_min = 100_000;
    })
    .await;
    let r = Arc::new(TestRelayHandle(r));
    let stop = Arc::new(AtomicBool::new(false));
    let done = Arc::new(AtomicU64::new(0));
    let ready = Arc::new(AtomicU64::new(0));
    let tasks: Vec<_> =
        (0..DEVICES).map(|i| tokio::spawn(device(r.clone(), i, stop.clone(), done.clone(), ready.clone()))).collect();

    let start = Instant::now();
    let mut samples: Vec<(Duration, u64)> = Vec::new();
    let mut baseline: Option<u64> = None;
    let end = start + Duration::from_secs(secs);
    loop {
        let next = (start + SAMPLE_EVERY * (samples.len() as u32 + 1)).min(end);
        sleep(next.saturating_duration_since(Instant::now())).await;
        let (t, kib) = (start.elapsed(), rss_kib());
        println!("soak: t={:>5.0}s rss={} KiB streams_done={}", t.as_secs_f64(), kib, done.load(Ordering::Relaxed));
        if baseline.is_none() && t >= BASELINE_AT {
            baseline = Some(kib);
        }
        samples.push((t, kib));
        if Instant::now() >= end {
            break;
        }
    }
    stop.store(true, Ordering::Relaxed);
    for t in tasks {
        t.await.expect("device task did not panic");
    }
    let r = Arc::try_unwrap(r).ok().expect("device tasks are gone").0;
    r.relay.stop().await;

    let last = samples.last().unwrap().1;
    match baseline {
        Some(b) => {
            let ratio = last as f64 / b as f64;
            println!("soak: baseline={b} KiB final={last} KiB ratio={ratio:.3}");
            assert!(last as f64 <= b as f64 * 1.2, "rss grew from {b} KiB to {last} KiB");
        }
        None => println!("soak: run shorter than {BASELINE_AT:?}, no baseline; final={last} KiB"),
    }
}
