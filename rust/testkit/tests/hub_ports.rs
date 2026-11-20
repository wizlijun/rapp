//! The embedded hub of an app with no service (iOS) listens on `localhost:<share number>` itself
//! and carries each connection to the share, as the service does on a PC.

mod common;
use common::sharing::*;
use common::*;

use serde_json::{json, Value};
use std::path::Path;
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;

/// A device that is in `hosts.json` but never answers: nothing listens on its LAN address.
const GONE: &str = "987654321";

/// A sharing an echo port, with share numbers from `first` on and nothing listening on them on
/// this machine (`own_ports` off), so that the hub of the same test can take the number.
async fn a_sharing_echo(first: u16) -> (TestService, rapp_wire::Key, u16, tokio::task::JoinHandle<()>) {
    let (port, echo) = echo().await;
    let (a, key) = start_sharing_opts(|h| share_file(h, json!([{"port": port}])), (first, 10), false, None).await;
    (a, key, port, echo)
}

/// A hub home that knows `a` (its id and LAN address) and has its key.
fn hub_home_knowing(a: &TestService, key: &rapp_wire::Key) -> tempfile::TempDir {
    let home = tempfile::tempdir().unwrap();
    let hosts = json!([{"id": a.id, "name": "a", "lan": [a_addr(&a.svc).to_string()]}]);
    std::fs::write(home.path().join("hosts.json"), hosts.to_string()).unwrap();
    hub_relay(home.path(), "", key);
    home
}

/// A hub home that knows only `GONE`, with a map to it in `maps.json` on `local`.
fn hub_home_with_a_map(local: u16, key: Option<&rapp_wire::Key>) -> tempfile::TempDir {
    let home = tempfile::tempdir().unwrap();
    let hosts = json!([{"id": GONE, "name": "gone", "lan": ["127.0.0.1:1"]}]);
    std::fs::write(home.path().join("hosts.json"), hosts.to_string()).unwrap();
    let maps = json!([{"id": GONE, "port": 7, "local": local}]);
    std::fs::write(home.path().join("maps.json"), maps.to_string()).unwrap();
    if let Some(key) = key {
        hub_relay(home.path(), "", key);
    }
    home
}

fn saved_maps(home: &Path) -> Vec<Value> {
    match std::fs::read(home.join("maps.json")) {
        Ok(b) => serde_json::from_slice(&b).unwrap(),
        Err(_) => Vec::new(),
    }
}

/// Writes `data` to `127.0.0.1:<local>`, finishes writing, and reads to the end.
async fn through(local: u16, data: &[u8]) -> Vec<u8> {
    let mut c = TcpStream::connect(("127.0.0.1", local)).await.expect("the local port accepts");
    c.write_all(data).await.unwrap();
    c.shutdown().await.unwrap();
    let mut got = Vec::new();
    tokio::time::timeout(WAIT, c.read_to_end(&mut got)).await.expect("ends in time").unwrap();
    got
}

fn log_lines(home: &Path) -> Vec<Value> {
    let text = std::fs::read_to_string(home.join("logs").join("hub.log")).unwrap_or_default();
    text.lines().filter_map(|l| serde_json::from_str(l).ok()).collect()
}

/// Waits (within `WAIT`) until `hub.log` has at least `n` lines that `pred` accepts.
async fn wait_log(home: &Path, n: usize, pred: impl Fn(&Value) -> bool) {
    let deadline = tokio::time::Instant::now() + WAIT;
    while log_lines(home).iter().filter(|l| pred(l)).count() < n {
        assert!(tokio::time::Instant::now() < deadline, "hub.log: {:?}", log_lines(home));
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
}

fn the_map(id: &str, port: u16, local: u16) -> Value {
    json!([{"id": id, "port": port, "local": local}])
}

#[tokio::test]
async fn a_hub_with_map_ports_reaches_a_share_on_its_number() {
    let (a, key, port, _echo) = a_sharing_echo(29410).await;
    let home = hub_home_knowing(&a, &key);
    let mut hub = Hub::start_with_ports(home.path(), a.bins.path(), (29410, 10));
    hub.wait_event("ports", WAIT, |v| v["maps"] == the_map(&a.id, port, 29410)).await;
    assert_eq!(through(29410, b"hello").await, b"hello");
    let saved = saved_maps(home.path());
    assert_eq!(saved.len(), 1, "{saved:?}");
    assert_eq!((&saved[0]["id"], &saved[0]["port"], &saved[0]["local"]), (&json!(a.id), &json!(port), &json!(29410)));
}

#[tokio::test]
async fn a_desktop_hub_opens_no_ports() {
    let (a, key, _port, _echo) = a_sharing_echo(29420).await;
    let home = hub_home_knowing(&a, &key);
    let mut hub = Hub::start(home.path(), a.bins.path());
    hub.send(json!({"cmd":"hosts"})).await;
    let deadline = tokio::time::Instant::now() + Duration::from_secs(3);
    while let Ok(v) = tokio::time::timeout_at(deadline, hub.next()).await {
        assert_ne!(v["event"], "ports", "{v}");
    }
    assert!(TcpStream::connect(("127.0.0.1", 29420)).await.is_err(), "29420 is listened on");
    assert!(!home.path().join("maps.json").exists());
}

#[tokio::test]
async fn net_changed_relistens_and_still_carries() {
    let (a, key, port, _echo) = a_sharing_echo(29440).await;
    let home = hub_home_knowing(&a, &key);
    let mut hub = Hub::start_with_ports(home.path(), a.bins.path(), (29440, 10));
    hub.wait_event("ports", WAIT, |v| v["maps"] == the_map(&a.id, port, 29440)).await;
    assert_eq!(through(29440, b"hello").await, b"hello");
    hub.send(json!({"cmd":"net_changed"})).await;
    // The listeners are closed and opened again, then logged.
    wait_log(home.path(), 1, |l| l["ev"] == "ports_relisten").await;
    assert_eq!(through(29440, b"again").await, b"again");
}

#[tokio::test]
async fn the_file_listens_before_anyone_is_asked() {
    let home = hub_home_with_a_map(29430, Some(&rapp_wire::Key::new_local()));
    let bins = bins();
    let mut hub = Hub::start_with_ports(home.path(), bins.path(), (29430, 10));
    let first = hub.wait_event("ports", WAIT, |_| true).await;
    assert_eq!(first["maps"], the_map(GONE, 7, 29430));
    // It accepts, and closes (an end or a reset: what was written is not read): the device does
    // not answer.
    let mut c = TcpStream::connect(("127.0.0.1", 29430)).await.expect("the local port accepts");
    c.write_all(b"hi").await.unwrap();
    let mut got = Vec::new();
    match tokio::time::timeout(WAIT, c.read_to_end(&mut got)).await.expect("closed in time") {
        Ok(_) => assert_eq!(got, b""),
        Err(e) => assert_eq!(e.kind(), std::io::ErrorKind::ConnectionReset, "{e}"),
    }
    wait_log(home.path(), 1, |l| l["ev"] == "map_refused" && l["local"] == 29430).await;
}

#[tokio::test]
async fn an_offline_device_keeps_its_maps() {
    let home = hub_home_with_a_map(29450, Some(&rapp_wire::Key::new_local()));
    let bins = bins();
    let mut hub = Hub::start_with_ports(home.path(), bins.path(), (29450, 10));
    hub.wait_event("ports", WAIT, |_| true).await;
    wait_log(home.path(), 1, |l| l["ev"] == "ports_asked").await;
    hub.send(json!({"cmd":"net_changed"})).await;
    wait_log(home.path(), 2, |l| l["ev"] == "ports_asked").await;
    let saved = saved_maps(home.path());
    assert_eq!(saved.len(), 1, "{saved:?}");
    assert_eq!((&saved[0]["id"], &saved[0]["local"]), (&json!(GONE), &json!(29450)));
    assert!(TcpStream::connect(("127.0.0.1", 29450)).await.is_ok(), "29450 still listened on");
}

#[tokio::test]
async fn no_key_still_listens_from_the_file() {
    let home = hub_home_with_a_map(29460, None);
    let bins = bins();
    let mut hub = Hub::start_with_ports(home.path(), bins.path(), (29460, 10));
    hub.wait_event("ports", WAIT, |v| v["maps"] == the_map(GONE, 7, 29460)).await;
    wait_log(home.path(), 1, |l| l["ev"] == "ports_asked").await;
    assert!(TcpStream::connect(("127.0.0.1", 29460)).await.is_ok(), "29460 listened on");
    // The hub is still there and answers.
    assert_eq!(hub.call(json!({"cmd":"hosts"})).await["event"], "hosts");
    let errors: Vec<Value> = log_lines(home.path()).into_iter().filter(|l| l["lvl"] == "error").collect();
    assert!(errors.is_empty(), "{errors:?}");
}
