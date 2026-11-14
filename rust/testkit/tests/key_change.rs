//! The relay changes its key (relay device plan 2c, Task 2): `rotate-key` drops every device, the
//! service stops and says `key changed` until the user enters the new key, and the hub reports it.

mod common;

use common::*;
use serde_json::{json, Value};
use std::time::Duration;

/// `rotate-key` the way the subcommand does it; the new key.
async fn rotate(rig: &RelayRig) -> rapp_wire::Key {
    let rotated = tokio::time::timeout(WAIT, rapp_relay::admin::issue_key(rig.data.path(), true)).await;
    rotated.expect("rotated in time").unwrap().expect("a new key")
}

/// The relay's audit lines of `fp` that say it came back: an enroll or a register.
fn comebacks(rig: &RelayRig, fp: &str) -> Vec<Value> {
    rig.relay.as_ref().expect("relay running").audit().flush();
    let lines = rapp_relay::audit::read(rig.data.path(), None, None, None).unwrap_or_default();
    lines.into_iter().filter(|v| (v["ev"] == "enroll" || v["ev"] == "register") && v["fp"] == fp).collect()
}

/// Waits (within `within`) for the service's status to say `relay: "error"` with `error`.
async fn wait_relay_error(ipc: &mut Ipc, error: &str, within: Duration) -> Value {
    let deadline = tokio::time::Instant::now() + within;
    loop {
        let st = ipc.call(json!({"cmd":"status"})).await;
        if st["relay"] == "error" && st["relay_error"] == error {
            return st;
        }
        assert!(tokio::time::Instant::now() < deadline, "status never said {error}: {st}");
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
}

/// The relay's audit lines of event `ev`.
fn audit_events(rig: &RelayRig, ev: &str) -> Vec<Value> {
    rig.relay.as_ref().expect("relay running").audit().flush();
    let lines = rapp_relay::audit::read(rig.data.path(), None, None, None).unwrap_or_default();
    lines.into_iter().filter(|v| v["ev"] == ev).collect()
}

fn hex(b: [u8; 32]) -> String {
    b.iter().map(|b| format!("{b:02x}")).collect()
}

#[tokio::test]
async fn service_stops_and_says_key_changed_after_rotate() {
    let rig = RelayRig::start().await;
    let a = a_on_relay(&rig, Some(vec!["127.0.0.1:1".into()])).await;
    let mut ipc = Ipc::open(&a.svc, a.home.path()).await;
    let fp = ipc.call(json!({"cmd":"status"})).await["fp"].as_str().unwrap().to_string();
    let new = rotate(&rig).await;
    wait_relay_error(&mut ipc, "key changed", Duration::from_secs(2)).await;
    wait_log(a.home.path(), "relay_key_changed", |_| true).await;
    // It stays down: no enroll or register of this device on the relay from now on.
    let before = comebacks(&rig, &fp).len();
    tokio::time::sleep(Duration::from_secs(5)).await;
    assert_eq!(comebacks(&rig, &fp).len(), before, "the service tried the relay again");
    let st = ipc.call(json!({"cmd":"status"})).await;
    assert_eq!((&st["relay"], &st["relay_error"]), (&json!("error"), &json!("key changed")), "{st}");
    let log = std::fs::read_to_string(a.home.path().join("logs/service.log")).unwrap();
    for key in [&rig.key, &new] {
        for secret in [key.to_string(), hex(key.trust()), hex(key.join())] {
            assert!(!log.contains(&secret), "service.log has a secret of a key");
        }
    }
}

#[tokio::test]
async fn a_new_key_reconnects_with_the_same_id() {
    let rig = RelayRig::start().await;
    let a = a_on_relay(&rig, Some(vec!["127.0.0.1:1".into()])).await;
    let mut ipc = Ipc::open(&a.svc, a.home.path()).await;
    let new = rotate(&rig).await;
    wait_relay_error(&mut ipc, "key changed", WAIT).await;
    let r = ipc.call(json!({"cmd":"set_relay","relay":rig.addr,"key":new.to_string()})).await;
    assert_eq!(r["ok"], true, "{r}");
    let st = wait_status(&mut ipc, |s| s["relay"] == "connected").await;
    assert_eq!((&st["id"], &st["relay_error"]), (&json!(a.id), &Value::Null), "{st}");
    // Another device on the new key reaches it through the relay under the same ID.
    let home = tempfile::tempdir().unwrap();
    hub_relay(home.path(), &rig.addr, &new);
    let mut hub = Hub::start(home.path(), a.bins.path());
    let r = hub.call(json!({"cmd":"add_host","id":a.id})).await;
    assert_eq!(r["event"], "host_added", "{r}");
    let r = hub.call(json!({"cmd":"apps","id":a.id})).await;
    assert_eq!(r["path"], "relay", "{r}");
    hub.finish().await;
    // Registered on the new key, it forgot the old one: the next rotate is a key change again.
    rotate(&rig).await;
    wait_relay_error(&mut ipc, "key changed", WAIT).await;
}

#[tokio::test]
async fn a_wrong_new_key_says_bad_key() {
    let rig = RelayRig::start().await;
    let a = a_on_relay(&rig, Some(vec!["127.0.0.1:1".into()])).await;
    let mut ipc = Ipc::open(&a.svc, a.home.path()).await;
    rotate(&rig).await;
    wait_relay_error(&mut ipc, "key changed", WAIT).await;
    let third = rapp_wire::Key::new_for_relay(&rig.relay.as_ref().unwrap().fp);
    let r = ipc.call(json!({"cmd":"set_relay","relay":rig.addr,"key":third.to_string()})).await;
    assert_eq!(r["ok"], true, "{r}");
    wait_relay_error(&mut ipc, "bad key", WAIT).await;
    // The key it first met the change with is still only a key change.
    let r = ipc.call(json!({"cmd":"set_relay","relay":rig.addr,"key":rig.key.to_string()})).await;
    assert_eq!(r["ok"], true, "{r}");
    wait_relay_error(&mut ipc, "key changed", WAIT).await;
}

#[tokio::test]
async fn a_wrong_key_stops_the_service_with_bad_key() {
    // A device the relay has never seen (not stale), on a key with the wrong root half.
    let rig = RelayRig::start().await;
    let key = rapp_wire::Key { relay: rig.key.relay, root: [9u8; 16] };
    let a = service_on_relay(&rig.addr, &key).await;
    let mut ipc = Ipc::open(&a.svc, a.home.path()).await;
    let fp = ipc.call(json!({"cmd":"status"})).await["fp"].as_str().unwrap().to_string();
    wait_relay_error(&mut ipc, "bad key", WAIT).await;
    let tries = comebacks(&rig, &fp);
    assert_eq!(tries.len(), 1, "{tries:?}");
    assert_eq!(tries[0]["result"], "bad key", "{tries:?}");
    // No more enrolls: one that kept trying would be locked out.
    tokio::time::sleep(Duration::from_secs(5)).await;
    assert_eq!(comebacks(&rig, &fp).len(), 1, "the service tried the relay again");
    let st = ipc.call(json!({"cmd":"status"})).await;
    assert_eq!((&st["relay"], &st["relay_error"]), (&json!("error"), &json!("bad key")), "{st}");
    // The right key: it enrolls and registers.
    let r = ipc.call(json!({"cmd":"set_relay","relay":rig.addr,"key":rig.key.to_string()})).await;
    assert_eq!(r["ok"], true, "{r}");
    wait_status(&mut ipc, |s| s["relay"] == "connected").await;
}

#[tokio::test]
async fn hub_presence_says_key_changed_and_stops_dialing() {
    let every = Duration::from_millis(300);
    let rig = RelayRig::start().await;
    let a = a_on_relay(&rig, Some(vec!["127.0.0.1:1".into()])).await;
    let home = tempfile::tempdir().unwrap();
    hub_relay(home.path(), &rig.addr, &rig.key);
    let mut hub = Hub::start_with_presence(home.path(), a.bins.path(), every);
    let r = hub.call(json!({"cmd":"add_host","id":a.id})).await;
    assert_eq!(r["event"], "host_added", "{r}");
    next_presence(&mut hub, &a.id, true).await;
    let hub_fp = rapp_wire::Identity::load_or_create(home.path(), "device").unwrap().fp.to_string();
    assert!(!comebacks(&rig, &hub_fp).is_empty(), "the hub enrolled");
    rotate(&rig).await;
    // The probe says why A is offline.
    let deadline = tokio::time::Instant::now() + WAIT;
    loop {
        let r = tokio::time::timeout_at(deadline, hub.next()).await.expect("presence says key changed in time");
        if r["event"] == "presence" && r["id"] == a.id && r["online"] == false && r["error"] == "key changed" {
            break;
        }
    }
    // Over the next probes (and a user's request) the hub does not dial the relay with the old key.
    let before = comebacks(&rig, &hub_fp).len();
    let r = hub.call(json!({"cmd":"apps","id":a.id})).await;
    assert_eq!(r["error"], "key changed", "{r}");
    tokio::time::sleep(every * 4).await;
    assert_eq!(comebacks(&rig, &hub_fp).len(), before, "the hub enrolled again with the old key");
    let lockouts = audit_events(&rig, "lockout");
    assert!(lockouts.is_empty(), "{lockouts:?}");
    hub.finish().await;
}

#[tokio::test]
async fn hub_reports_key_changed() {
    let rig = RelayRig::start().await;
    let a = a_on_relay(&rig, Some(vec!["127.0.0.1:1".into()])).await;
    let home = tempfile::tempdir().unwrap();
    hub_relay(home.path(), &rig.addr, &rig.key);
    let mut hub = Hub::start(home.path(), a.bins.path());
    let r = hub.call(json!({"cmd":"add_host","id":a.id})).await;
    assert_eq!(r["event"], "host_added", "{r}");
    let r = hub.call(json!({"cmd":"apps","id":a.id})).await;
    assert_eq!(r["path"], "relay", "{r}");
    let new = rotate(&rig).await;
    let r = hub.call(json!({"cmd":"open","id":a.id,"app":"com.example.echo"})).await;
    assert_eq!(r["event"], "error", "{r}");
    assert!(r["error"].as_str().unwrap_or_default().contains("key changed"), "{r}");
    // The new key in `service.json` (the GUI writes it for both): the hub dials the relay anew.
    let mut ipc = Ipc::open(&a.svc, a.home.path()).await;
    ipc.call(json!({"cmd":"set_relay","relay":rig.addr,"key":new.to_string()})).await;
    wait_status(&mut ipc, |s| s["relay"] == "connected").await;
    hub_relay(home.path(), &rig.addr, &new);
    let r = hub.call(json!({"cmd":"apps","id":a.id})).await;
    assert_eq!(r["path"], "relay", "{r}");
    hub.finish().await;
}
