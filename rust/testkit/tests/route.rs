//! A host's `route` (relay device plan 2b, Task 1): `set_route relay` keeps the host on the relay
//! even with its LAN working, and every link the hub caches is announced with a `path` event.
//! The LAN upgrade (Task 2): a link on the relay moves to the LAN once the LAN answers as this host.

mod common;

use common::*;
use serde_json::{json, Value};
use std::time::Duration;

/// A on the relay, its own addresses registered (its LAN works); a hub on the same relay, with
/// presence every `presence` when given, and A added by bare ID.
async fn on_relay(presence: Option<Duration>) -> (RelayRig, TestService, tempfile::TempDir, Hub) {
    let rig = RelayRig::start().await;
    let a = a_on_relay(&rig, None).await;
    let home = tempfile::tempdir().unwrap();
    hub_relay(home.path(), &rig.addr, &rig.key);
    let mut hub = match presence {
        Some(every) => Hub::start_with_presence(home.path(), a.bins.path(), every),
        None => Hub::start(home.path(), a.bins.path()),
    };
    hub.send(json!({"cmd":"add_host","id":a.id})).await;
    let r = reply(&mut hub).await;
    assert_eq!(r["event"], "host_added", "{r}");
    (rig, a, home, hub)
}

/// `set_route`, and its reply.
async fn set_route(hub: &mut Hub, id: &str, route: &str) -> Value {
    hub.send(json!({"cmd":"set_route","id":id,"route":route,"req":"r"})).await;
    reply(hub).await
}

/// Forces `a` onto the relay: the reply lists the host forced, then the relay link is announced.
async fn force(hub: &mut Hub, a: &TestService) {
    let r = set_route(hub, &a.id, "relay").await;
    assert_eq!((&r["event"], &r["req"]), (&json!("hosts"), &json!("r")), "{r}");
    assert_eq!(r["hosts"][0]["route"], "relay", "{r}");
    hub.wait_path(&a.id, "relay").await;
}

fn is_relay_unreachable(r: &Value) -> bool {
    r["error"].as_str().is_some_and(|e| e.starts_with("relay unreachable: "))
}

#[tokio::test]
async fn forced_relay_ignores_a_working_lan() {
    let (rig, a, home, mut hub) = on_relay(None).await;
    force(&mut hub, &a).await;
    let r = hub.call(json!({"cmd":"apps","id":a.id})).await;
    assert_eq!((&r["event"], &r["path"]), (&json!("apps"), &json!("relay")), "{r}");
    assert!(rig.streams() > 0, "nothing went through the relay");
    assert_eq!(saved_hosts(home.path())[0]["route"], "relay");
    let said = format!("{}: route relay", a.id);
    wait_log_in(home.path(), "hub.log", "log", |v| v["msg"] == said.as_str()).await;
    assert!(hub.take_paths().iter().all(|p| p["path"] != "lan"), "a LAN link was cached");
    hub.finish().await;
}

#[tokio::test]
async fn forcing_moves_new_requests_off_the_lan() {
    let (_rig, a, _home, mut hub) = on_relay(None).await;
    let r = hub.call(json!({"cmd":"apps","id":a.id})).await;
    assert_eq!((&r["event"], &r["path"]), (&json!("apps"), &json!("lan")), "{r}");
    hub.wait_path(&a.id, "lan").await;
    let first = hub.call(json!({"cmd":"open","id":a.id,"app":"com.example.echo"})).await;
    assert_eq!((&first["event"], &first["path"]), (&json!("opened"), &json!("lan")), "{first}");
    force(&mut hub, &a).await;
    // Another app: a second session of the same app would take the first over on A.
    let second = hub.call(json!({"cmd":"open","id":a.id,"app":"com.apple.Safari"})).await;
    assert_eq!((&second["event"], &second["path"]), (&json!("opened"), &json!("relay")), "{second}");
    // Give the fake clients time to finish their ping/echo before closing their stdin.
    tokio::time::sleep(Duration::from_millis(300)).await;
    // The session on the LAN link lived on after the link left the cache.
    for s in [&first, &second] {
        hub.send(json!({"cmd":"close","sid":s["sid"]})).await;
        assert_eq!(hub.next().await, json!({"event":"closed","sid":s["sid"],"reason":"echo ok"}));
    }
    hub.finish().await;
}

#[tokio::test]
async fn forced_relay_down_does_not_fall_back() {
    let (mut rig, a, _home, mut hub) = on_relay(None).await;
    force(&mut hub, &a).await;
    let r = hub.call(json!({"cmd":"apps","id":a.id})).await;
    assert_eq!(r["path"], "relay", "{r}");
    rig.stop().await;
    // A link cached before the stop may fail some other way first; then the relay is redialed.
    let deadline = tokio::time::Instant::now() + WAIT;
    loop {
        let r = hub.call(json!({"cmd":"apps","id":a.id})).await;
        assert_ne!(r["path"], "lan", "fell back to the LAN: {r}");
        if r["event"] == "error" && is_relay_unreachable(&r) {
            break;
        }
        assert!(tokio::time::Instant::now() < deadline, "{r}");
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    assert!(hub.take_paths().iter().all(|p| p["path"] != "lan"), "a LAN link was cached");
    hub.finish().await;
}

#[tokio::test]
async fn bad_route_is_refused() {
    let home = tempfile::tempdir().unwrap();
    let bins = bins();
    let saved = json!([{"id":"100000001","name":"a","password":"","lan":[]}]);
    rapp_net::config::write_json(&home.path().join("hosts.json"), &saved).unwrap();
    let mut hub = Hub::start(home.path(), bins.path());
    let r = hub.call(json!({"cmd":"set_route","id":"100000001","route":"lan"})).await;
    assert_eq!(r, json!({"event":"error","error":"bad route"}));
    let r = hub.call(json!({"cmd":"set_route","id":"999999999","route":"relay"})).await;
    assert_eq!(r, json!({"event":"error","error":"unknown host"}));
    assert_eq!(saved_hosts(home.path()), saved);
    hub.finish().await;
}

#[tokio::test]
async fn presence_says_why_offline() {
    let (mut rig, a, _home, mut hub) = on_relay(Some(Duration::from_millis(100))).await;
    force(&mut hub, &a).await;
    // Online is said without an error.
    let deadline = tokio::time::Instant::now() + WAIT;
    loop {
        let r = tokio::time::timeout_at(deadline, hub.next()).await.expect("online in time");
        if r["event"] == "presence" && r["id"] == a.id.as_str() && r["online"] == true {
            assert!(r.get("error").is_none(), "{r}");
            break;
        }
    }
    rig.stop().await;
    // The probe redials the relay, which waits out its 10 s dial timeout.
    let deadline = tokio::time::Instant::now() + 2 * WAIT;
    loop {
        let r = tokio::time::timeout_at(deadline, hub.next()).await.expect("offline in time");
        if r["event"] != "presence" || r["online"] != false {
            continue;
        }
        assert!(r["error"].as_str().is_some_and(|e| !e.is_empty()), "offline without a reason: {r}");
        if is_relay_unreachable(&r) {
            break;
        }
    }
    hub.finish().await;
}

/// The relay counts every `unknown id` against B and locks it out after five: a forced host the relay
/// does not know costs one lookup per run, not one per probe; the user acting on it asks again.
#[tokio::test]
async fn probes_of_a_forced_unknown_host_ask_the_relay_once() {
    let rig = RelayRig::start().await;
    let a = a_on_relay(&rig, None).await;
    let home = tempfile::tempdir().unwrap();
    hub_relay(home.path(), &rig.addr, &rig.key);
    let saved = json!([{"id":"100000009","name":"gone","password":"pw","lan":[],"route":"relay"}]);
    rapp_net::config::write_json(&home.path().join("hosts.json"), &saved).unwrap();
    let mut hub = Hub::start_with_presence(home.path(), a.bins.path(), Duration::from_millis(100));
    for _ in 0..6 {
        next_presence(&mut hub, "100000009", false).await;
    }
    assert_eq!(relay_connects(&rig, "unknown id"), 1, "lookups the relay counted as failures");
    hub.send(json!({"cmd":"apps","id":"100000009","req":2})).await;
    assert_eq!(reply(&mut hub).await, json!({"event":"error","error":"unknown id","req":2}));
    assert_eq!(relay_connects(&rig, "unknown id"), 2);
    // A known host is still reached: the hub was not locked out.
    hub.send(json!({"cmd":"add_host","id":a.id,"req":3})).await;
    assert_eq!(reply(&mut hub).await["event"], "host_added");
    hub.finish().await;
}

// ---- the LAN upgrade ----

/// Upgrade times short enough for tests.
fn quick() -> rapp_hub::UpgradeTimes {
    let ms = Duration::from_millis;
    rapp_hub::UpgradeTimes { first: ms(200), every: ms(300), hold: ms(2000), tick: ms(50) }
}

/// A on the relay registering only `gate` as its LAN address (the gate forwards to A); a hub on the
/// same relay with `quick` upgrades, and A added by bare ID while the gate is as `open` says.
async fn behind_gate(open: bool) -> (RelayRig, TestService, LanGate, tempfile::TempDir, Hub) {
    let rig = RelayRig::start().await;
    let gate = LanGate::start().await;
    let a = a_on_relay(&rig, Some(vec![gate.addr()])).await;
    gate.forward_to(a_addr(&a.svc));
    if open {
        gate.open();
    }
    let home = tempfile::tempdir().unwrap();
    hub_relay(home.path(), &rig.addr, &rig.key);
    let mut hub = Hub::start_with_upgrade(home.path(), a.bins.path(), quick());
    hub.send(json!({"cmd":"add_host","id":a.id})).await;
    let r = reply(&mut hub).await;
    assert_eq!(r["event"], "host_added", "{r}");
    (rig, a, gate, home, hub)
}

/// `apps` of `a` goes by `path`.
async fn apps_via(hub: &mut Hub, a: &TestService, path: &str) {
    let r = hub.call(json!({"cmd":"apps","id":a.id})).await;
    assert_eq!((&r["event"], &r["path"]), (&json!("apps"), &json!(path)), "{r}");
}

/// The `path` events of `id` in the next `wait` (events already read are dropped first).
async fn paths_within(hub: &mut Hub, id: &str, wait: Duration) -> Vec<Value> {
    hub.take_paths();
    tokio::time::sleep(wait).await;
    // Every event written before this reply is read (and `path` ones set aside) on the way to it.
    assert_eq!(hub.call(json!({"cmd":"hosts"})).await["event"], "hosts");
    hub.take_paths().into_iter().filter(|p| p["id"] == id).collect()
}

const WINDOW: Duration = Duration::from_millis(1500);

#[tokio::test]
async fn relay_link_moves_to_lan_when_the_lan_opens() {
    let (_rig, a, gate, home, mut hub) = behind_gate(false).await;
    apps_via(&mut hub, &a, "relay").await;
    hub.wait_path(&a.id, "relay").await;
    let first = hub.call(json!({"cmd":"open","id":a.id,"app":"com.example.echo"})).await;
    assert_eq!((&first["event"], &first["path"]), (&json!("opened"), &json!("relay")), "{first}");
    gate.open();
    hub.wait_path(&a.id, "lan").await;
    let said = format!("{}: path relay→lan", a.id);
    wait_log_in(home.path(), "hub.log", "log", |v| v["msg"] == said.as_str()).await;
    // Another app: a second session of the same app would take the first over on A.
    let second = hub.call(json!({"cmd":"open","id":a.id,"app":"com.apple.Safari"})).await;
    assert_eq!((&second["event"], &second["path"]), (&json!("opened"), &json!("lan")), "{second}");
    tokio::time::sleep(Duration::from_millis(300)).await;
    // The session on the relay lived on after its link left the cache.
    for s in [&first, &second] {
        hub.send(json!({"cmd":"close","sid":s["sid"]})).await;
        assert_eq!(hub.next().await, json!({"event":"closed","sid":s["sid"],"reason":"echo ok"}));
    }
    hub.finish().await;
}

#[tokio::test]
async fn another_device_on_the_lan_address_is_not_taken() {
    let (rig, a, gate, _home, mut hub) = behind_gate(false).await;
    // Another device of the same relay (same key) answers on A's LAN address.
    let other = a_on_relay(&rig, None).await;
    gate.forward_to(a_addr(&other.svc));
    apps_via(&mut hub, &a, "relay").await;
    gate.open();
    let paths = paths_within(&mut hub, &a.id, WINDOW).await;
    assert!(paths.iter().all(|p| p["path"] != "lan"), "{paths:?}");
    apps_via(&mut hub, &a, "relay").await;
    hub.finish().await;
}

#[tokio::test]
async fn route_failed_holds_the_host() {
    let (_rig, a, gate, _home, mut hub) = behind_gate(false).await;
    apps_via(&mut hub, &a, "relay").await;
    hub.send(json!({"cmd":"route_failed","id":a.id})).await;
    gate.open();
    let paths = paths_within(&mut hub, &a.id, WINDOW).await;
    assert!(paths.iter().all(|p| p["path"] != "lan"), "moved while held: {paths:?}");
    hub.wait_path(&a.id, "lan").await;
    hub.finish().await;
}

#[tokio::test]
async fn forced_host_is_never_tried_and_auto_tries_at_once() {
    let (_rig, a, _gate, _home, mut hub) = behind_gate(true).await;
    force(&mut hub, &a).await;
    let paths = paths_within(&mut hub, &a.id, Duration::from_secs(1)).await;
    assert!(paths.is_empty(), "{paths:?}");
    let r = set_route(&mut hub, &a.id, "auto").await;
    assert_eq!(r["event"], "hosts", "{r}");
    tokio::time::timeout(Duration::from_secs(1), hub.wait_path(&a.id, "lan")).await.expect("moved at once");
    hub.finish().await;
}

#[tokio::test]
async fn lan_from_the_start_never_touches_the_relay() {
    let (rig, a, _gate, _home, mut hub) = behind_gate(true).await;
    apps_via(&mut hub, &a, "lan").await;
    hub.wait_path(&a.id, "lan").await;
    let s = hub.call(json!({"cmd":"open","id":a.id,"app":"com.example.echo"})).await;
    assert_eq!((&s["event"], &s["path"]), (&json!("opened"), &json!("lan")), "{s}");
    assert_eq!(rig.streams(), 0);
    tokio::time::sleep(Duration::from_millis(300)).await;
    hub.send(json!({"cmd":"close","sid":s["sid"]})).await;
    assert_eq!(hub.next().await, json!({"event":"closed","sid":s["sid"],"reason":"echo ok"}));
    hub.finish().await;
}

#[tokio::test]
async fn a_removed_host_is_not_moved() {
    let (_rig, a, gate, _home, mut hub) = behind_gate(false).await;
    apps_via(&mut hub, &a, "relay").await;
    assert_eq!(hub.call(json!({"cmd":"remove_host","id":a.id})).await["event"], "hosts");
    gate.open();
    let paths = paths_within(&mut hub, &a.id, WINDOW).await;
    assert!(paths.is_empty(), "{paths:?}");
    // Added again, it connects as any new link does: LAN first.
    assert_eq!(hub.call(json!({"cmd":"add_host","id":a.id})).await["event"], "host_added");
    apps_via(&mut hub, &a, "lan").await;
    hub.finish().await;
}

#[tokio::test]
async fn set_home_drops_pending_moves() {
    let (_rig, a, gate, _home, mut hub) = behind_gate(false).await;
    apps_via(&mut hub, &a, "relay").await;
    let other = tempfile::tempdir().unwrap();
    let r = hub.call(json!({"cmd":"set_home","dir":other.path()})).await;
    assert_eq!(r["event"], "home_set", "{r}");
    gate.open();
    let paths = paths_within(&mut hub, &a.id, WINDOW).await;
    assert!(paths.is_empty(), "{paths:?}");
    hub.finish().await;
}
