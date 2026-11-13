//! Malformed input and floods: the relay stays up, bounded, and keeps serving others (spec §8, §9.2).
mod common;

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

use common::*;
use rapp_wire::Identity;
use serde_json::json;
use tokio::task::JoinSet;
use tokio::time::{sleep, timeout};

const A_ID: &str = "123456789";

/// A small fixed-seed generator (xorshift64*), so a failing run can be replayed.
struct Rng(u64);

impl Rng {
    fn next(&mut self) -> u64 {
        self.0 ^= self.0 >> 12;
        self.0 ^= self.0 << 25;
        self.0 ^= self.0 >> 27;
        self.0.wrapping_mul(0x2545_f491_4f6c_dd1d)
    }

    fn below(&mut self, n: usize) -> usize {
        (self.next() % n as u64) as usize
    }
}

/// One random blob: raw noise, or a valid request cut short, with bytes flipped, or both.
fn blob(rng: &mut Rng) -> Vec<u8> {
    let valid = [
        json!({"op": "enroll", "join": "ab".repeat(32)}),
        json!({"op": "register", "id": A_ID, "lan": ["192.168.1.5:47800"]}),
        json!({"op": "connect", "id": A_ID}),
        json!({"op": "relay", "id": A_ID}),
    ];
    match rng.below(3) {
        0 => {
            let len = rng.below(12_000);
            let mut v: Vec<u8> = (0..len).map(|_| rng.next() as u8).collect();
            if rng.below(2) == 0 && !v.is_empty() {
                let at = rng.below(v.len());
                v[at] = b'\n';
            }
            v
        }
        _ => {
            let mut v = valid[rng.below(valid.len())].to_string().into_bytes();
            if rng.below(2) == 0 {
                v.truncate(rng.below(v.len() + 1));
            }
            for _ in 0..rng.below(4) {
                if !v.is_empty() {
                    let at = rng.below(v.len());
                    v[at] = rng.next() as u8;
                }
            }
            if rng.below(2) == 0 {
                v.push(b'\n');
            }
            v
        }
    }
}

#[tokio::test]
async fn random_bytes_on_request_streams_never_take_the_relay_down() {
    // Garbage must not lock the address out of the checks at the end.
    let r = start_relay(|c| {
        c.limits.lock_after = 1_000_000;
        c.limits.enroll_per_ip_per_min = 1_000_000;
        c.limits.connect_per_target_per_min = 1_000_000;
    })
    .await;
    let mut abuser = FakeDevice::enrolled(&r).await;
    let mut rng = Rng(0x5eed_1234_abcd_ef01);
    let t = Instant::now();
    for _ in 0..2000 {
        if abuser.conn.close_reason().is_some() {
            abuser = FakeDevice::enrolled_as(&r, same_identity(&abuser.id)).await;
        }
        let bytes = blob(&mut rng);
        let Ok((mut send, mut recv)) = abuser.conn.open_bi().await else { continue };
        let _ = send.write_all(&bytes).await;
        let _ = send.finish();
        // Whatever the relay answers (or resets) is fine; it must just not hang the loop.
        let _ = timeout(Duration::from_millis(100), recv.read_to_end(64 * 1024)).await;
        let _ = recv.stop(0u32.into());
    }
    assert!(t.elapsed() < Duration::from_secs(60), "too slow: {:?}", t.elapsed());

    // The garbage may have registered A_ID for the abuser; use another id.
    const OTHER: &str = "987654321";
    let a = FakeDevice::enrolled(&r).await;
    assert_eq!(a.register(OTHER, &[]).await, json!({"ok": true, "id": OTHER}));
    let b = FakeDevice::enrolled(&r).await;
    let v = b.connect_to(OTHER).await;
    assert_eq!(v["ok"], true, "{v}");
}

#[tokio::test]
async fn many_idle_unenrolled_connections_are_shed() {
    let r = start_relay(|c| c.limits.unenrolled_idle_secs = 1).await;
    let mut set = JoinSet::new();
    for _ in 0..40 {
        let addr = r.relay.addr;
        let pin = rapp_wire::tls::Expect::Pin(r.relay.fp.prefix16());
        set.spawn(async move {
            let id = Identity::generate().unwrap();
            timeout(Duration::from_secs(3), FakeDevice::dial_to(addr, id, pin)).await
        });
    }
    let mut devices = Vec::new();
    while let Some(res) = set.join_next().await {
        if let Ok(Ok(Ok(d))) = res {
            devices.push(d);
        }
    }
    let alive = |ds: &[FakeDevice]| ds.iter().filter(|d| d.conn.close_reason().is_none()).count();
    let until = Instant::now() + Duration::from_millis(900);
    while alive(&devices) > 16 && Instant::now() < until {
        sleep(Duration::from_millis(20)).await;
    }
    let n = alive(&devices);
    assert!(n <= 16, "{n} connections from one address alive");

    let until = Instant::now() + Duration::from_secs(4);
    while alive(&devices) > 0 && Instant::now() < until {
        sleep(Duration::from_millis(50)).await;
    }
    assert_eq!(alive(&devices), 0, "idle unenrolled connections were not all closed");
}

#[tokio::test]
async fn stream_flood_is_bounded() {
    let r = start_relay(|c| c.limits.request_timeout_secs = 1).await;
    let a = FakeDevice::enrolled(&r).await;
    assert_eq!(a.register(A_ID, &[]).await["ok"], true);
    let flooder = FakeDevice::enrolled(&r).await;
    let b = FakeDevice::enrolled(&r).await;

    let opened = Arc::new(AtomicUsize::new(0));
    let first = Arc::new(tokio::sync::Mutex::new(Vec::new()));
    let (conn, count, keep) = (flooder.conn.clone(), opened.clone(), first.clone());
    let task = tokio::spawn(async move {
        for _ in 0..500 {
            let Ok((mut send, recv)) = conn.open_bi().await else { return };
            if send.write_all(br#"{"op":"conn"#).await.is_err() {
                return;
            }
            let n = count.fetch_add(1, Ordering::SeqCst) + 1;
            if n <= 128 {
                keep.lock().await.push((send, recv));
            } else {
                // Beyond the first batch: only possible once the relay has freed credit.
                std::mem::forget((send, recv));
            }
        }
    });

    sleep(Duration::from_millis(600)).await;
    let n = opened.load(Ordering::SeqCst);
    assert!(n <= 128, "{n} streams open at once on one connection");
    assert!(n >= 100, "the flood did not get going: {n}");

    // Another device is served while the flood is on.
    let t = Instant::now();
    let v = timeout(Duration::from_secs(1), b.connect_to(A_ID)).await.expect("connect answered within 1 s");
    assert_eq!(v["ok"], true, "{v}");
    assert!(t.elapsed() < Duration::from_secs(1));

    // The half lines are reset after the timeout.
    sleep(Duration::from_millis(1800)).await;
    let mut streams = std::mem::take(&mut *first.lock().await);
    for (_, recv) in streams.iter_mut() {
        let res = timeout(Duration::from_secs(2), recv.read_to_end(1024)).await.expect("stream reset in time");
        assert!(matches!(res, Err(quinn::ReadToEndError::Read(quinn::ReadError::Reset(_)))), "{res:?}");
    }
    task.abort();
}
