//! `kind` of a share: another device sees it in `hosts` and `shares`.

mod common;
use common::sharing::*;
use common::*;

use serde_json::json;
use std::time::Duration;

#[tokio::test]
async fn another_device_sees_the_kind() {
    let (a, key) = sharing(json!([{"port": 8102, "local": 29400, "kind": "state"}, {"port": 8103, "local": 29401}])).await;
    let (home, bins) = (tempfile::tempdir().unwrap(), bins());
    service_json(home.path());
    let svc = start_service_ports(home.path(), bins.path(), Duration::from_secs(60), (29410, 10)).await;
    let r = ipc_once(&svc, home.path(), json!({"cmd":"set_relay","relay":"","key":key.to_string()})).await;
    assert_eq!(r["ok"], true, "{r}");
    let hosts = json!([{"id": a.id, "name": "a", "lan": [a_addr(&a.svc).to_string()]}]);
    std::fs::write(home.path().join("hosts.json"), hosts.to_string()).unwrap();

    let r = ipc_once(&svc, home.path(), json!({"cmd":"hosts"})).await;
    let shares = r["hosts"][0]["shares"].as_array().unwrap_or_else(|| panic!("{r}"));
    let find = |p: u64| shares.iter().find(|s| s["port"] == p).unwrap_or_else(|| panic!("{r}"));
    assert_eq!(find(8102)["kind"], "state", "{r}");
    assert!(find(8103).get("kind").is_none(), "{r}");

    let r = ipc_once(&svc, home.path(), json!({"cmd":"shares","to":a.id})).await;
    let kinds: Vec<_> = r["shares"].as_array().unwrap().iter().map(|s| (s["port"].clone(), s.get("kind").cloned())).collect();
    assert_eq!(kinds, [(json!(8102), Some(json!("state"))), (json!(8103), None)], "{r}");

    // A's own `shares` says it too.
    let r = ipc_once(&a.svc, a.home.path(), json!({"cmd":"shares"})).await;
    assert_eq!(r["shares"][0]["kind"], "state", "{r}");
}
