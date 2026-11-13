//! Register, connect and the revocation list (spec §5.1, §6.3, §7.4, §8).
mod common;

use std::time::{Duration, Instant};

use common::*;
use rapp_wire::Identity;
use serde_json::json;
use tokio::time::timeout;

const A_ID: &str = "123456789";
const OTHER_ID: &str = "987654321";
const LAN: &str = "192.168.1.5:21118";

fn app_close(e: &quinn::ConnectionError) -> Option<(u64, String)> {
    match e {
        quinn::ConnectionError::ApplicationClosed(c) => {
            Some((c.error_code.into_inner(), String::from_utf8_lossy(&c.reason).into_owned()))
        }
        _ => None,
    }
}

async fn closed(d: &FakeDevice) -> quinn::ConnectionError {
    timeout(WAIT, d.conn.closed()).await.expect("connection closed within WAIT")
}

/// An enrolled device that has registered `id`.
async fn host(r: &TestRelay, id: &str) -> FakeDevice {
    let d = FakeDevice::enrolled(r).await;
    assert_eq!(d.register(id, &[LAN]).await, json!({"ok": true, "id": id}));
    d
}

#[tokio::test]
async fn connect_returns_addresses_and_notifies_the_target() {
    let r = start_relay(|_| {}).await;
    let mut a = host(&r, A_ID).await;
    let b = FakeDevice::enrolled(&r).await;
    let v = timeout(WAIT, b.connect_to(A_ID)).await.unwrap();
    assert_eq!(v["ok"], true, "{v}");
    assert_eq!(v["lan"], json!([LAN]));
    assert_eq!(v["public"], a.local_addr().to_string());
    assert!(v["public"].as_str().unwrap().starts_with("127.0.0.1:"), "{v}");

    let (peer, fp) = a.next_incoming().await;
    assert_eq!(fp, b.id.fp);
    assert_eq!(peer, b.local_addr().to_string());
}

#[tokio::test]
async fn unknown_and_offline_are_told_apart() {
    let r = start_relay(|_| {}).await;
    let b = FakeDevice::enrolled(&r).await;
    assert_eq!(b.connect_to(A_ID).await, json!({"ok": false, "error": "unknown id"}));
    let a = host(&r, A_ID).await;
    a.close().await;
    let v = timeout(WAIT, b.connect_to(A_ID)).await.unwrap();
    assert_eq!(v, json!({"ok": false, "error": "offline"}));
}

#[tokio::test]
async fn an_id_cannot_be_taken_by_another_key() {
    let r = start_relay(|_| {}).await;
    let a = host(&r, A_ID).await;
    let c = FakeDevice::enrolled(&r).await;
    assert_eq!(c.register(A_ID, &[]).await, json!({"ok": false, "error": "id taken"}));
    assert_eq!(r.relay.registry().by_id(A_ID).unwrap().fp, a.id.fp);
    // The holder is still the one that is introduced.
    let v = timeout(WAIT, c.connect_to(A_ID)).await.unwrap();
    assert_eq!(v["ok"], true, "{v}");

    let lines = audit_lines(&r, "register");
    let results: Vec<_> = lines.iter().map(|l| l["result"].as_str().unwrap()).collect();
    assert_eq!(results, ["new", "id taken"], "{lines:?}");
    let taken = &lines[1];
    assert_eq!(taken["fp"], c.id.fp.to_string());
    assert_eq!(taken["id"], A_ID);
    assert_eq!(taken["from"], c.local_addr().to_string());
}

#[tokio::test]
async fn a_new_registration_replaces_the_old_connection() {
    let r = start_relay(|_| {}).await;
    let id = Identity::generate().unwrap();
    let first = FakeDevice::enrolled_as(&r, same_identity(&id)).await;
    assert_eq!(first.register(A_ID, &[]).await["ok"], true);
    let mut second = FakeDevice::enrolled_as(&r, same_identity(&id)).await;
    assert_eq!(second.register(A_ID, &[LAN]).await, json!({"ok": true, "id": A_ID}));

    let e = closed(&first).await;
    assert_eq!(app_close(&e), Some((0, "replaced".into())), "{e:?}");

    let b = FakeDevice::enrolled(&r).await;
    let v = timeout(WAIT, b.connect_to(A_ID)).await.unwrap();
    assert_eq!(v["ok"], true, "{v}");
    assert_eq!(v["public"], second.local_addr().to_string());
    assert_eq!(second.next_incoming().await.1, b.id.fp);

    let results: Vec<_> =
        audit_lines(&r, "register").iter().map(|l| l["result"].as_str().unwrap().to_string()).collect();
    assert_eq!(results, ["new", "replaced"]);
}

#[tokio::test]
async fn two_devices_racing_for_one_id_have_one_winner() {
    // Few rounds: every device here enrolls from 127.0.0.1, and that is limited per minute.
    let r = start_relay(|_| {}).await;
    let b = FakeDevice::enrolled(&r).await;
    for round in 0..3 {
        let id = format!("{}", 200_000_000 + round);
        let x = FakeDevice::enrolled(&r).await;
        let y = FakeDevice::enrolled(&r).await;
        let (vx, vy) = tokio::join!(x.register(&id, &[]), y.register(&id, &[]));
        let oks = [&vx, &vy].iter().filter(|v| v["ok"] == true).count();
        assert_eq!(oks, 1, "{vx} {vy}");
        let loser = if vx["ok"] == true { &vy } else { &vx };
        assert_eq!(loser["error"], "id taken");

        let winner = if vx["ok"] == true { &x } else { &y };
        let v = timeout(WAIT, b.connect_to(&id)).await.unwrap();
        assert_eq!(v["public"], winner.local_addr().to_string(), "{v}");
    }
}

#[tokio::test]
async fn target_that_does_not_answer_incoming_is_offline() {
    let r = start_relay(|_| {}).await;
    let mut a = FakeDevice::enrolled_silent(&r).await;
    assert_eq!(a.register(A_ID, &[]).await["ok"], true);
    let b = FakeDevice::enrolled(&r).await;
    let t = Instant::now();
    let v = timeout(WAIT, b.connect_to(A_ID)).await.unwrap();
    assert_eq!(v, json!({"ok": false, "error": "offline"}));
    let took = t.elapsed();
    assert!(took >= Duration::from_millis(1900) && took < Duration::from_secs(4), "{took:?}");
    // It was asked, it just did not answer.
    assert_eq!(a.next_incoming().await.1, b.id.fp);
}

#[tokio::test]
async fn connect_is_audited() {
    let r = start_relay(|_| {}).await;
    let _a = host(&r, A_ID).await;
    let b = FakeDevice::enrolled(&r).await;
    assert_eq!(timeout(WAIT, b.connect_to(A_ID)).await.unwrap()["ok"], true);
    let lines = audit_lines(&r, "connect");
    assert_eq!(lines.len(), 1, "{lines:?}");
    let l = &lines[0];
    assert_eq!(l["fp"], b.id.fp.to_string());
    assert_eq!(l["fp"].as_str().unwrap().len(), 64);
    assert_eq!(l["from"], b.local_addr().to_string());
    assert_eq!(l["to"], A_ID);
    assert_eq!(l["result"], "ok");
    assert_eq!(l["tenant"], "default");
}

#[tokio::test]
async fn revoked_list_is_pushed_on_admission() {
    let r = start_relay(|_| {}).await;
    let x = Identity::generate().unwrap().fp;
    r.relay.registry().enroll(x, "default").unwrap();
    assert!(r.relay.registry().revoke(&x).unwrap());

    let id = Identity::generate().unwrap();
    FakeDevice::enrolled_as(&r, same_identity(&id)).await.close().await;
    // Known now: admitted at the handshake, no enroll, no register.
    let mut a = FakeDevice::dial_as(&r, same_identity(&id)).await.unwrap();
    assert_eq!(a.next_revoked().await, vec![x]);
}

#[tokio::test]
async fn a_device_that_never_registers_still_gets_list_changes() {
    let r = start_relay(|_| {}).await;
    let mut b = FakeDevice::enrolled(&r).await;
    // Pushed once on enrolling, even though the list is empty.
    assert_eq!(b.next_revoked().await, vec![]);

    let x = FakeDevice::enrolled(&r).await;
    assert!(r.relay.revoke(&x.id.fp).await.unwrap());
    assert_eq!(b.next_revoked().await, vec![x.id.fp]);
}

#[tokio::test]
async fn a_revoked_device_is_cut_off_and_cannot_come_back() {
    let r = start_relay(|_| {}).await;
    let id = Identity::generate().unwrap();
    let a = FakeDevice::enrolled_as(&r, same_identity(&id)).await;
    assert_eq!(a.register(A_ID, &[]).await["ok"], true);
    let mut b = FakeDevice::enrolled(&r).await;
    assert_eq!(b.next_revoked().await, vec![]);

    assert!(r.relay.revoke(&id.fp).await.unwrap());
    let e = closed(&a).await;
    assert_eq!(app_close(&e), Some((2, "revoked".into())), "{e:?}");
    assert_eq!(b.next_revoked().await, vec![id.fp]);

    let e = match FakeDevice::dial_as(&r, same_identity(&id)).await {
        Ok(d) => closed(&d).await,
        Err(e) => e.downcast::<quinn::ConnectionError>().expect("a connection error"),
    };
    assert_eq!(app_close(&e).map(|c| c.0), Some(2), "{e:?}");
    assert_eq!(b.connect_to(A_ID).await["error"], "unknown id");
    // A second revoke changes nothing.
    assert!(!r.relay.revoke(&id.fp).await.unwrap());

    let lines = audit_lines(&r, "revoke");
    assert_eq!(lines.len(), 1, "{lines:?}");
    assert_eq!(lines[0]["fp"], id.fp.to_string());
}

#[tokio::test]
async fn hammering_connect_backs_off() {
    let r = start_relay(|_| {}).await;
    let b = FakeDevice::enrolled(&r).await;
    for _ in 0..5 {
        assert_eq!(b.connect_to(A_ID).await["error"], "unknown id");
    }
    let v = b.connect_to(A_ID).await;
    let e = v["error"].as_str().unwrap();
    assert!(e.starts_with("locked, retry in ") && e.ends_with('s'), "{v}");

    let lockouts = audit_lines(&r, "lockout");
    let mut keys: Vec<_> = lockouts.iter().map(|l| l["key"].as_str().unwrap().to_string()).collect();
    keys.sort();
    assert_eq!(keys, [format!("fp:{}", b.id.fp), "ip:127.0.0.1".to_string()], "{lockouts:?}");
    assert!(lockouts.iter().all(|l| l["secs"] == 1), "{lockouts:?}");
    let results: Vec<_> =
        audit_lines(&r, "connect").iter().map(|l| l["result"].as_str().unwrap().to_string()).collect();
    assert_eq!(results[..5], ["unknown id"; 5]);
    assert!(results[5].starts_with("locked, retry in "), "{results:?}");
}

#[tokio::test]
async fn a_locked_client_does_not_flood_lockout_lines() {
    let r = start_relay(|_| {}).await;
    let b = FakeDevice::enrolled(&r).await;
    for _ in 0..5 {
        assert_eq!(b.connect_to(A_ID).await["error"], "unknown id");
    }
    let before = audit_lines(&r, "lockout").len();
    assert_eq!(before, 2);
    for _ in 0..5 {
        // Locked comes before the ID format: a locked client cannot make the relay fsync.
        let v = b.connect_to("12").await;
        assert!(v["error"].as_str().unwrap().starts_with("locked, retry in "), "{v}");
    }
    assert_eq!(audit_lines(&r, "lockout").len(), before);
}

#[tokio::test]
async fn polling_an_offline_host_does_not_lock_the_poller_out() {
    let r = start_relay(|_| {}).await;
    let id = Identity::generate().unwrap();
    let a = FakeDevice::enrolled_as(&r, same_identity(&id)).await;
    assert_eq!(a.register(A_ID, &[]).await["ok"], true);
    a.close().await;

    let b = FakeDevice::enrolled(&r).await;
    for _ in 0..10 {
        let v = timeout(WAIT, b.connect_to(A_ID)).await.unwrap();
        assert_eq!(v, json!({"ok": false, "error": "offline"}));
    }
    let a = FakeDevice::enrolled_as(&r, same_identity(&id)).await;
    assert_eq!(a.register(A_ID, &[]).await["ok"], true);
    let v = timeout(WAIT, b.connect_to(A_ID)).await.unwrap();
    assert_eq!(v["ok"], true, "{v}");
}

#[tokio::test]
async fn connects_to_one_target_are_capped_per_minute() {
    let r = start_relay(|c| c.limits.connect_per_target_per_min = 3).await;
    let _a = host(&r, A_ID).await;
    let _d = host(&r, OTHER_ID).await;
    let b = FakeDevice::enrolled(&r).await;
    let c = FakeDevice::enrolled(&r).await;
    for d in [&b, &b, &c] {
        let v = timeout(WAIT, d.connect_to(A_ID)).await.unwrap();
        assert_eq!(v["ok"], true, "{v}");
    }
    assert_eq!(c.connect_to(A_ID).await, json!({"ok": false, "error": "limit"}));
    assert_eq!(b.connect_to(A_ID).await, json!({"ok": false, "error": "limit"}));
    let v = timeout(WAIT, b.connect_to(OTHER_ID)).await.unwrap();
    assert_eq!(v["ok"], true, "{v}");

    let limits = audit_lines(&r, "limit");
    assert_eq!(limits.len(), 2, "{limits:?}");
    assert_eq!(limits[0]["what"], "connect_per_target_per_min");
    assert_eq!(limits[0]["fp"], c.id.fp.to_string());
    // `limit` is not a failure: nobody is locked out.
    assert!(audit_lines(&r, "lockout").is_empty());
}

#[tokio::test]
async fn bad_id_and_oversized_lan_are_rejected() {
    let r = start_relay(|_| {}).await;
    let d = FakeDevice::enrolled(&r).await;
    assert_eq!(d.register("12", &[]).await, json!({"ok": false, "error": "bad id"}));
    assert_eq!(d.register("012345678", &[]).await, json!({"ok": false, "error": "bad id"}));
    let seventeen = vec![LAN; 17];
    assert_eq!(d.register(A_ID, &seventeen).await, json!({"ok": false, "error": "bad request"}));
    let long = "x".repeat(65);
    assert_eq!(d.register(A_ID, &[&long]).await, json!({"ok": false, "error": "bad request"}));
    assert!(r.relay.registry().by_id(A_ID).is_none());
    assert_eq!(d.connect_to("12").await, json!({"ok": false, "error": "bad id"}));

    // The limits themselves are allowed.
    let edge = "x".repeat(64);
    let sixteen = vec![edge.as_str(); 16];
    assert_eq!(d.register(A_ID, &sixteen).await, json!({"ok": true, "id": A_ID}));
}
