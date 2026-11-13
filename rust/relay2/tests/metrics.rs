//! Stats line, Prometheus endpoint and the `audit.required` gate (spec §11.1, §11.3).
mod common;

use std::os::unix::fs::PermissionsExt;

use common::*;
use rapp_relay2::metrics::Stats;
use rapp_wire::line::read_json;
use serde_json::json;
use tokio::io::{AsyncReadExt, AsyncWriteExt};

async fn scrape(addr: std::net::SocketAddr) -> String {
    let mut s = tokio::net::TcpStream::connect(addr).await.unwrap();
    s.write_all(b"GET / HTTP/1.1\r\nHost: x\r\n\r\n").await.unwrap();
    let mut out = String::new();
    tokio::time::timeout(WAIT, s.read_to_string(&mut out)).await.unwrap().unwrap();
    out
}

fn metrics_on(c: &mut rapp_relay2::config::Config) {
    c.metrics = Some("127.0.0.1:0".parse().unwrap());
}

#[tokio::test]
async fn metrics_are_off_by_default() {
    let r = start_relay(|_| {}).await;
    assert_eq!(r.relay.metrics_addr(), None);
}

#[tokio::test]
async fn metrics_endpoint_serves_the_fixed_names() {
    let r = start_relay(metrics_on).await;
    let _d = FakeDevice::enrolled(&r).await;
    let addr = r.relay.metrics_addr().expect("bound");
    assert!(addr.ip().is_loopback());
    let text = scrape(addr).await;
    assert!(text.starts_with("HTTP/1.1 200 OK\r\n"), "{text}");
    assert!(text.contains("Content-Type: text/plain; version=0.0.4\r\n"), "{text}");
    assert!(text.contains("# TYPE rapp_relay_online_devices gauge\n"), "{text}");
    assert!(text.contains("# TYPE rapp_relay_limited_total counter\n"), "{text}");
    for line in [
        "rapp_relay_online_devices 1\n",
        "rapp_relay_relayed_streams 0\n",
        "rapp_relay_relayed_bytes_total 0\n",
        "rapp_relay_handshake_failures_total 0\n",
        "rapp_relay_limited_total 0\n",
        "rapp_relay_audit_failures_total 0\n",
    ] {
        assert!(text.contains(line), "{line:?} in {text}");
    }
    r.relay.stop().await;
}

#[tokio::test]
async fn stats_line_has_the_counters() {
    let v = Stats::default().snapshot();
    for k in ["online", "relayed_streams", "relayed_bytes", "handshake_failures", "limited", "audit_failures"] {
        assert_eq!(v[k], json!(0), "{k} in {v}");
    }
}

#[tokio::test]
async fn limited_counts_refusals() {
    let r = start_relay(|c| {
        metrics_on(c);
        c.limits.enroll_per_ip_per_min = 1;
    })
    .await;
    let d1 = FakeDevice::dial(&r).await;
    assert_eq!(d1.enroll(&r.key).await["ok"], true);
    let d2 = FakeDevice::dial(&r).await;
    assert_eq!(d2.enroll(&r.key).await, json!({"ok": false, "error": "limit"}));
    let text = scrape(r.relay.metrics_addr().unwrap()).await;
    assert!(text.contains("rapp_relay_limited_total 1\n"), "{text}");
}

#[tokio::test]
async fn relayed_bytes_and_streams_are_counted() {
    let r = start_relay(metrics_on).await;
    let mut a = FakeDevice::enrolled(&r).await;
    assert_eq!(a.register("123456789", &[]).await["ok"], true);
    let b = FakeDevice::enrolled(&r).await;
    let init = b.relay_to_with("123456789", b"hello").await.unwrap();
    let (_, _, mut target) = a.next_relayed().await;
    let mut buf = [0u8; 5];
    tokio::time::timeout(WAIT, target.read_exact(&mut buf)).await.unwrap().unwrap();
    let addr = r.relay.metrics_addr().unwrap();
    assert!(scrape(addr).await.contains("rapp_relay_relayed_streams 1\n"));
    target.shutdown().await.unwrap();
    drop(target);
    drop(init);
    let mut text = String::new();
    for _ in 0..100 {
        text = scrape(addr).await;
        if text.contains("rapp_relay_relayed_streams 0\n") && text.contains("rapp_relay_relayed_bytes_total 5\n") {
            return;
        }
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;
    }
    panic!("{text}");
}

#[tokio::test]
async fn audit_required_refuses_when_audit_cannot_be_written() {
    for required in [true, false] {
        let r = start_relay(|c| {
            c.audit.required = required;
            metrics_on(c);
        })
        .await;
        let a = FakeDevice::enrolled(&r).await;
        assert_eq!(a.register("123456789", &[]).await["ok"], true);
        let b = FakeDevice::enrolled(&r).await;
        let c = FakeDevice::dial(&r).await;
        let dir = r.data.path().join("audit");
        let set = |dir_mode: u32, file_mode: u32| {
            for e in std::fs::read_dir(&dir).unwrap() {
                std::fs::set_permissions(e.unwrap().path(), std::fs::Permissions::from_mode(file_mode)).unwrap();
            }
            std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(dir_mode)).unwrap();
        };
        set(0o500, 0o400);
        if std::fs::write(dir.join("probe"), "x").is_ok() {
            eprintln!("skip: permissions do not block writes (root?)");
            std::fs::remove_file(dir.join("probe")).unwrap();
            set(0o700, 0o600);
            continue;
        }
        // One failing urgent write makes the audit unhealthy.
        assert!(!r.relay.audit().event("test", json!({}), true));
        let enroll = c.enroll(&r.key).await;
        let connect = b.connect_to("123456789").await;
        let mut relay = b.relay_to("123456789").await.unwrap();
        let relay = tokio::time::timeout(std::time::Duration::from_millis(500), read_json(&mut relay, 4096)).await;
        let text = scrape(r.relay.metrics_addr().unwrap()).await;
        if required {
            let refused = json!({"ok": false, "error": "limit"});
            assert_eq!(enroll, refused);
            assert_eq!(connect, refused);
            assert_eq!(relay.unwrap().unwrap(), refused);
            assert!(text.contains("rapp_relay_audit_failures_total 3\n"), "{text}");
            assert!(text.contains("rapp_relay_limited_total 0\n"), "{text}");
        } else {
            assert_eq!(enroll["ok"], true, "{enroll}");
            assert_eq!(connect["ok"], true, "{connect}");
            assert!(text.contains("rapp_relay_audit_failures_total 0\n"), "{text}");
        }
        set(0o700, 0o600);
    }
}

#[tokio::test(start_paused = true)]
async fn stats_line_is_logged_after_five_minutes() {
    let r = start_relay(|_| {}).await;
    for _ in 0..20 {
        tokio::task::yield_now().await;
    }
    tokio::time::advance(std::time::Duration::from_secs(299)).await;
    for _ in 0..20 {
        tokio::task::yield_now().await;
    }
    assert!(!r.log_text().contains("\"ev\":\"stats\""), "{}", r.log_text());
    tokio::time::advance(std::time::Duration::from_secs(2)).await;
    for _ in 0..20 {
        tokio::task::yield_now().await;
    }
    r.relay.stop().await;
    let text = std::fs::read_to_string(r.data.path().join("relay.log")).unwrap();
    assert!(text.contains("\"ev\":\"stats\""), "{text}");
    assert!(text.contains("\"handshake_failures\""), "{text}");
}
