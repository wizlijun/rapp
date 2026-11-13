//! The `relay` request: splicing two device streams, metering and the relayed audit (spec §5.1,
//! §5.3, §8, §9.2, §11.1).
mod common;

use std::path::Path;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use common::*;
use rapp_wire::line::read_json;
use rapp_wire::tls::BiStream;
use serde_json::{json, Value};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt, BufReader};
use tokio::time::timeout;

const A_ID: &str = "123456789";
const MIB: usize = 1024 * 1024;

/// An enrolled device that has registered `id`.
async fn host(r: &TestRelay, id: &str) -> FakeDevice {
    let d = FakeDevice::enrolled(r).await;
    assert_eq!(d.register(id, &[]).await, json!({"ok": true, "id": id}));
    d
}

/// `len` pseudo-random bytes (splitmix64 from `seed`).
fn noise(len: usize, seed: u64) -> Vec<u8> {
    let mut x = seed;
    let mut out = Vec::with_capacity(len + 8);
    while out.len() < len {
        x = x.wrapping_add(0x9e37_79b9_7f4a_7c15);
        let mut z = x;
        z = (z ^ (z >> 30)).wrapping_mul(0xbf58_476d_1ce4_e5b9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94d0_49bb_1331_11eb);
        out.extend_from_slice(&(z ^ (z >> 31)).to_le_bytes());
    }
    out.truncate(len);
    out
}

fn seed() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos() as u64
}

/// B relays to A; returns B's end and A's end.
async fn spliced(a: &mut FakeDevice, b: &FakeDevice) -> (BufReader<BiStream>, BiStream) {
    let on_b = b.relay_to(A_ID).await.unwrap();
    let (peer, fp, on_a) = a.next_relayed().await;
    assert_eq!(fp, b.id.fp);
    assert_eq!(peer, b.local_addr().to_string());
    (on_b, on_a)
}

/// Writes `data` and finishes on `w` while `r` reads to the end; returns what `r` read.
async fn send_over<W, R>(w: &mut W, r: &mut R, data: &[u8]) -> Vec<u8>
where
    W: AsyncWrite + Unpin,
    R: AsyncRead + Unpin,
{
    let write = async {
        w.write_all(data).await.unwrap();
        w.shutdown().await.unwrap();
    };
    let read = async {
        let mut got = Vec::new();
        r.read_to_end(&mut got).await.unwrap();
        got
    };
    let ((), got) = timeout(WAIT * 2, async { tokio::join!(write, read) }).await.expect("transfer within WAIT");
    got
}

/// 1 MiB from B to A, then 300 KiB back; both arrive unchanged and both ends close cleanly.
async fn both_ways(on_b: &mut BufReader<BiStream>, on_a: &mut BiStream) {
    let up = noise(MIB, seed());
    assert!(send_over(on_b, on_a, &up).await == up, "B → A bytes changed");
    let down = noise(300 * 1024, seed());
    assert!(send_over(on_a, on_b, &down).await == down, "A → B bytes changed");
}

/// The audit records of `ev`, waiting (within WAIT) until there is at least one.
async fn wait_audit(r: &TestRelay, ev: &str) -> Vec<Value> {
    let t = Instant::now();
    loop {
        let lines = audit_lines(r, ev);
        if !lines.is_empty() || t.elapsed() > WAIT {
            return lines;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
}

async fn reply(st: &mut BufReader<BiStream>) -> Value {
    timeout(WAIT, read_json(st, 8192)).await.expect("a reply within WAIT").expect("a reply line")
}

#[tokio::test]
async fn bytes_cross_unchanged_both_ways() {
    let r = start_relay(|_| {}).await;
    let mut a = host(&r, A_ID).await;
    let b = FakeDevice::enrolled(&r).await;
    let (mut on_b, mut on_a) = spliced(&mut a, &b).await;
    both_ways(&mut on_b, &mut on_a).await;
}

#[tokio::test]
async fn bytes_written_with_the_request_line_are_not_lost() {
    let r = start_relay(|_| {}).await;
    let mut a = host(&r, A_ID).await;
    let b = FakeDevice::enrolled(&r).await;
    let _on_b = b.relay_to_with(A_ID, b"\x16\x03\x01hello").await.unwrap();
    let (_, _, mut on_a) = a.next_relayed().await;
    let mut first = [0u8; 8];
    timeout(WAIT, on_a.read_exact(&mut first)).await.unwrap().unwrap();
    assert_eq!(&first, b"\x16\x03\x01hello");
}

#[tokio::test]
async fn a_real_stream_is_audited_with_sizes() {
    let r = start_relay(|_| {}).await;
    let mut a = host(&r, A_ID).await;
    let b = FakeDevice::enrolled(&r).await;
    let (mut on_b, mut on_a) = spliced(&mut a, &b).await;
    both_ways(&mut on_b, &mut on_a).await;

    let lines = wait_audit(&r, "relayed").await;
    assert_eq!(lines.len(), 1, "{lines:?}");
    let l = &lines[0];
    assert!(l["up"].as_u64().unwrap() >= 1_048_576, "{l}");
    assert!(l["down"].as_u64().unwrap() >= 307_200, "{l}");
    assert_eq!(l["to"], A_ID);
    assert_eq!(l["fp"], b.id.fp.to_string());
    assert_eq!(l["from"], b.local_addr().to_string());
    assert!(l["secs"].as_f64().unwrap() >= 0.0, "{l}");
    assert_eq!(l["tenant"], "default");
    assert!(audit_lines(&r, "probes").is_empty());
}

#[tokio::test]
async fn a_short_small_stream_is_a_probe_not_a_relayed_line() {
    let r = start_relay(|_| {}).await;
    let mut a = host(&r, A_ID).await;
    let b = FakeDevice::enrolled(&r).await;
    let (mut on_b, mut on_a) = spliced(&mut a, &b).await;
    assert_eq!(send_over(&mut on_b, &mut on_a, &[7u8; 100]).await, [7u8; 100]);
    assert!(send_over(&mut on_a, &mut on_b, &[]).await.is_empty());

    let probes = wait_audit(&r, "probes").await;
    assert_eq!(probes.len(), 1, "{probes:?}");
    assert_eq!(probes[0]["n"], 1);
    assert_eq!(probes[0]["from"], b.id.fp.to_string());
    assert_eq!(probes[0]["to"], A_ID);
    assert!(audit_lines(&r, "relayed").is_empty());
}

#[tokio::test]
async fn relay_to_offline_or_unknown_answers_in_json() {
    let r = start_relay(|_| {}).await;
    let b = FakeDevice::enrolled(&r).await;
    let mut st = b.relay_to(A_ID).await.unwrap();
    assert_eq!(reply(&mut st).await, json!({"ok": false, "error": "unknown id"}));
    let a = host(&r, A_ID).await;
    a.close().await;
    let mut st = b.relay_to(A_ID).await.unwrap();
    assert_eq!(reply(&mut st).await, json!({"ok": false, "error": "offline"}));
    let mut st = b.relay_to("12").await.unwrap();
    assert_eq!(reply(&mut st).await, json!({"ok": false, "error": "bad id"}));
}

#[tokio::test]
async fn an_unenrolled_device_cannot_relay() {
    let r = start_relay(|_| {}).await;
    let _a = host(&r, A_ID).await;
    let c = FakeDevice::dial(&r).await;
    let mut st = c.relay_to(A_ID).await.unwrap();
    assert_eq!(reply(&mut st).await, json!({"ok": false, "error": "not enrolled"}));
}

#[tokio::test]
async fn per_device_stream_cap() {
    let r = start_relay(|c| c.limits.max_relayed_per_device = 1).await;
    let mut a = host(&r, A_ID).await;
    let b = FakeDevice::enrolled(&r).await;
    let (mut on_b, mut on_a) = spliced(&mut a, &b).await;
    let mut second = b.relay_to(A_ID).await.unwrap();
    assert_eq!(reply(&mut second).await, json!({"ok": false, "error": "limit"}));

    let limits = audit_lines(&r, "limit");
    assert_eq!(limits.len(), 1, "{limits:?}");
    assert_eq!(limits[0]["what"], "max_relayed_per_device");
    assert_eq!(limits[0]["fp"], b.id.fp.to_string());
    assert_eq!(limits[0]["from"], b.local_addr().to_string());

    // The slot comes back when the first stream ends.
    send_over(&mut on_b, &mut on_a, b"x").await;
    send_over(&mut on_a, &mut on_b, b"y").await;
    wait_audit(&r, "probes").await;
    let _third = b.relay_to(A_ID).await.unwrap();
    assert_eq!(a.next_relayed().await.1, b.id.fp);
}

#[tokio::test]
async fn one_side_closing_closes_the_other() {
    let r = start_relay(|_| {}).await;
    let mut a = host(&r, A_ID).await;
    let b = FakeDevice::enrolled(&r).await;
    let (_on_b, mut on_a) = spliced(&mut a, &b).await;
    b.close().await;
    let mut rest = Vec::new();
    // An end or an error: either way A sees the stream is over.
    let _ = timeout(WAIT, on_a.read_to_end(&mut rest)).await.expect("A's stream ends within WAIT");
}

#[tokio::test]
async fn relayed_content_never_reaches_logs_or_disk() {
    let r = start_relay(|_| {}).await;
    let mut a = host(&r, A_ID).await;
    let b = FakeDevice::enrolled(&r).await;
    let marker = noise(32, seed());
    let hex = data_encoding::HEXLOWER.encode(&marker);
    let mut on_b = b.relay_to_with(A_ID, &marker).await.unwrap();
    let (_, _, mut on_a) = a.next_relayed().await;
    let mut more = marker.clone();
    more.extend_from_slice(&marker);
    assert_eq!(send_over(&mut on_b, &mut on_a, &marker).await, more);
    assert_eq!(send_over(&mut on_a, &mut on_b, &marker).await, marker);
    wait_audit(&r, "probes").await;

    let TestRelay { relay, data, .. } = r;
    relay.stop().await;
    let mut files = Vec::new();
    walk(data.path(), &mut files);
    assert!(files.iter().any(|f| f.ends_with("relay.log")), "{files:?}");
    for f in &files {
        let bytes = std::fs::read(f).unwrap();
        assert!(!bytes.windows(marker.len()).any(|w| w == marker), "marker in {f:?}");
        assert!(!bytes.windows(hex.len()).any(|w| w == hex.as_bytes()), "marker hex in {f:?}");
    }
}

fn walk(dir: &Path, out: &mut Vec<std::path::PathBuf>) {
    for e in std::fs::read_dir(dir).unwrap() {
        let p = e.unwrap().path();
        if p.is_dir() {
            walk(&p, out);
        } else {
            out.push(p);
        }
    }
}

#[tokio::test]
async fn bandwidth_cap_paces_the_stream() {
    let r = start_relay(|c| c.limits.relay_bps_per_stream = 100_000).await;
    let mut a = host(&r, A_ID).await;
    let b = FakeDevice::enrolled(&r).await;
    let t = Instant::now();
    // The metered path keeps the bytes sent with the request line too.
    let mut on_b = b.relay_to_with(A_ID, b"\x16\x03\x01hello").await.unwrap();
    let (_, _, mut on_a) = a.next_relayed().await;
    let data = noise(300_000, seed());
    let got = send_over(&mut on_b, &mut on_a, &data).await;
    let took = t.elapsed();
    assert_eq!(&got[..8], b"\x16\x03\x01hello");
    assert!(got[8..] == data, "bytes changed");
    assert!(took >= Duration::from_secs(2), "{took:?}");
    // The other direction still works on the metered path.
    assert_eq!(send_over(&mut on_a, &mut on_b, b"back").await, b"back");
}

#[tokio::test]
async fn relay_failures_share_the_connect_backoff() {
    let r = start_relay(|_| {}).await;
    let b = FakeDevice::enrolled(&r).await;
    for _ in 0..5 {
        let mut st = b.relay_to(A_ID).await.unwrap();
        assert_eq!(reply(&mut st).await["error"], "unknown id");
    }
    for _ in 0..3 {
        let mut st = b.relay_to("12").await.unwrap();
        let v = reply(&mut st).await;
        assert!(v["error"].as_str().unwrap().starts_with("locked, retry in "), "{v}");
    }
    let v = b.connect_to(A_ID).await;
    assert!(v["error"].as_str().unwrap().starts_with("locked, retry in "), "{v}");
    // One lockout per key, from the fail that locked it.
    assert_eq!(audit_lines(&r, "lockout").len(), 2);
}
