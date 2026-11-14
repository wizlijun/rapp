//! The hub's network monitor (spec 2026-11-14-rapp-network-status §3.2, §5.1, §7): `net` events
//! about the link to the relay.

mod common;

use common::*;
use serde_json::json;
use std::time::{Duration, Instant};

fn level(l: &'static str) -> impl Fn(&serde_json::Value) -> bool {
    move |v| v["level"] == l
}

#[tokio::test]
async fn net_follows_the_relay() {
    let mut rig = RelayRig::start().await;
    let home = tempfile::tempdir().unwrap();
    hub_relay(home.path(), &rig.addr, &rig.key);
    let bins = bins();
    let mut hub = Hub::start(home.path(), bins.path());
    let v = hub.wait_net(Duration::from_secs(10), level("strong")).await;
    assert!(v["rtt_ms"].as_u64().is_some(), "{v}");
    assert_eq!(v["loss"], 0.0, "{v}");
    // `net` answers with the value as it stands.
    hub.send(json!({"cmd":"net","req":1})).await;
    let v = hub.wait_net(Duration::from_secs(5), |v| v["req"] == 1).await;
    assert_eq!(v["level"], "strong", "{v}");

    rig.stop().await;
    let t = Instant::now();
    hub.wait_net(Duration::from_secs(20), level("down")).await;
    eprintln!("down after {:?}", t.elapsed());

    rig.restart().await;
    let t = Instant::now();
    let v = hub.wait_net(Duration::from_secs(5), |v| v["level"] != "down").await;
    eprintln!("back after {:?}: {v}", t.elapsed());
    assert!(["strong", "ok"].contains(&v["level"].as_str().unwrap()), "{v}");
    hub.finish().await;
}

#[tokio::test]
async fn no_relay_no_net_event() {
    let home = tempfile::tempdir().unwrap();
    let bins = bins();
    let mut hub = Hub::start(home.path(), bins.path());
    tokio::time::sleep(Duration::from_secs(3)).await;
    assert_eq!(hub.call(json!({"cmd":"hosts"})).await["event"], "hosts");
    assert_eq!(hub.take_nets(), Vec::<serde_json::Value>::new());
    hub.send(json!({"cmd":"net","req":2})).await;
    let v = hub.wait_net(Duration::from_secs(5), |v| v["req"] == 2).await;
    assert_eq!(v, json!({"event":"net","level":"none","req":2}));
    hub.finish().await;
}

#[tokio::test]
async fn taking_the_relay_out_says_none() {
    let rig = RelayRig::start().await;
    let home = tempfile::tempdir().unwrap();
    hub_relay(home.path(), &rig.addr, &rig.key);
    let bins = bins();
    let mut hub = Hub::start(home.path(), bins.path());
    hub.wait_net(Duration::from_secs(10), level("strong")).await;
    rapp_net::config::write_json(&home.path().join("service.json"), &json!({})).unwrap();
    hub.wait_net(Duration::from_secs(5), level("none")).await;
    hub.finish().await;
}

#[tokio::test]
async fn a_refused_key_is_not_dialed_again() {
    let rig = RelayRig::start().await;
    let home = tempfile::tempdir().unwrap();
    let bad = rapp_wire::Key { relay: rig.key.relay, root: [9u8; 16] };
    hub_relay(home.path(), &rig.addr, &bad);
    let bins = bins();
    let mut hub = Hub::start(home.path(), bins.path());
    hub.wait_net(Duration::from_secs(10), level("down")).await;
    tokio::time::sleep(Duration::from_secs(8)).await;
    let relay = rig.relay.as_ref().unwrap();
    relay.audit().flush();
    let enrolls = rapp_relay::audit::read(rig.data.path(), None, None, Some("enroll")).unwrap();
    assert_eq!(enrolls.len(), 1, "{enrolls:?}");
    assert_eq!(enrolls[0]["result"], "bad key", "{enrolls:?}");
    let lockouts = rapp_relay::audit::read(rig.data.path(), None, None, Some("lockout")).unwrap();
    assert!(lockouts.is_empty(), "{lockouts:?}");
    hub.finish().await;
}

/// An enroll the relay turns down for another reason than the key (enrollment closed, a limit,
/// a lockout) must not be retried every second: the monitor waits a minute.
#[tokio::test]
async fn a_closed_enrollment_is_not_hammered() {
    let rig = RelayRig::start_enroll(rapp_relay::config::Enroll::Closed).await;
    let home = tempfile::tempdir().unwrap();
    hub_relay(home.path(), &rig.addr, &rig.key);
    let bins = bins();
    let mut hub = Hub::start(home.path(), bins.path());
    hub.wait_net(Duration::from_secs(10), level("down")).await;
    tokio::time::sleep(Duration::from_secs(10)).await;
    let relay = rig.relay.as_ref().unwrap();
    relay.audit().flush();
    let enrolls = rapp_relay::audit::read(rig.data.path(), None, None, Some("enroll")).unwrap();
    assert!(!enrolls.is_empty(), "the relay must have been asked once");
    assert!(enrolls.iter().all(|e| e["result"] == "closed"), "{enrolls:?}");
    // One from the monitor; the hub's 30 s presence round may add one.
    assert!(enrolls.len() <= 2, "{} enrolls in ~12 s: {enrolls:?}", enrolls.len());
    hub.finish().await;
}
