//! The admin socket, the subcommands and the graceful stop (spec §6.5, §7.4, §9.3, §10.1).
mod common;

use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};
use std::time::{Duration, Instant};

use common::*;
use rapp_net::log::Log;
use rapp_relay::admin;
use rapp_relay::config;
use rapp_relay::server::{Opts, Relay};
use rapp_wire::msg::Push;
use rapp_wire::{join_hash, Fp, Key};
use serde_json::{json, Value};
use tokio::time::timeout;

const A_ID: &str = "123456789";

async fn call(r: &TestRelay, req: Value) -> Value {
    timeout(WAIT, admin::call(r.data.path(), req)).await.expect("admin reply within WAIT").expect("admin call")
}

fn hash_of(k: &Key) -> String {
    join_hash(&k.join())
}

fn app_close_code(e: &quinn::ConnectionError) -> Option<u64> {
    match e {
        quinn::ConnectionError::ApplicationClosed(c) => Some(c.error_code.into_inner()),
        _ => None,
    }
}

async fn closed(d: &FakeDevice) -> quinn::ConnectionError {
    timeout(WAIT, d.conn.closed()).await.expect("connection closed within WAIT")
}

/// A relay on `data` started the way `main` does it: the config comes from `config.json`.
async fn start_from_file(data: tempfile::TempDir, enroll_from_env: bool) -> TestRelay {
    let mut config = config::load(data.path(), &|_| None).expect("config loads");
    config.listen = "127.0.0.1:0".parse().unwrap();
    let opts = Opts {
        data: data.path().to_path_buf(),
        config: config.clone(),
        log: Log::file(data.path(), "relay.log"),
        enroll_from_env,
    };
    let relay = Relay::start(opts).await.expect("relay starts");
    let key = Key::new_for_relay(&relay.fp);
    relay.registry().set_join_hash(&hash_of(&key)).unwrap();
    TestRelay { relay, data, key, config }
}

/// Polls until `f` holds (at most WAIT).
async fn eventually(what: &str, mut f: impl AsyncFnMut() -> bool) {
    let until = Instant::now() + WAIT;
    while !f().await {
        assert!(Instant::now() < until, "timed out waiting for {what}");
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
}

fn device_row<'a>(v: &'a Value, fp: &Fp) -> &'a Value {
    v["devices"].as_array().unwrap().iter().find(|d| d["fp"] == fp.to_string()).expect("device listed")
}

#[tokio::test]
async fn info_reports_state() {
    let r = start_relay_without_key(|_| {}).await;
    let v = call(&r, json!({"cmd": "info"})).await;
    assert_eq!(v["ok"], true, "{v}");
    assert_eq!(v["version"], env!("CARGO_PKG_VERSION"));
    assert_eq!(v["fp"], r.relay.fp.to_string());
    assert_eq!(v["listen"], r.relay.addr.to_string());
    assert_ne!(r.relay.addr.port(), 0);
    assert_eq!(v["has_key"], false);
    assert_eq!(v["enroll"], "open");
    assert_eq!(v["devices"], 0);
    assert_eq!(v["online"], 0);

    r.relay.registry().set_join_hash(&hash_of(&r.key)).unwrap();
    let _d = FakeDevice::enrolled(&r).await;
    let v = call(&r, json!({"cmd": "info"})).await;
    assert_eq!(v["has_key"], true);
    assert_eq!(v["devices"], 1);
    assert_eq!(v["online"], 1);
}

#[tokio::test]
async fn bad_requests_get_bad_request() {
    let r = start_relay(|_| {}).await;
    for req in [json!({"cmd": "nope"}), json!({"x": 1}), json!("info"), json!({"cmd": "revoke"})] {
        assert_eq!(call(&r, req).await, json!({"ok": false, "error": "bad request"}));
    }
}

#[tokio::test]
async fn key_can_be_set_once_and_rotated() {
    let r = start_relay_without_key(|_| {}).await;
    let (k1, k2) = (Key::new_for_relay(&r.relay.fp), Key::new_for_relay(&r.relay.fp));
    for bad in ["", "abc", &"A".repeat(64), &"0".repeat(63), &"g".repeat(64)] {
        let v = call(&r, json!({"cmd": "set_join", "hash": bad, "rotate": false})).await;
        assert_eq!(v, json!({"ok": false, "error": "bad hash"}), "{bad:?}");
    }
    assert_eq!(call(&r, json!({"cmd": "set_join", "hash": hash_of(&k1), "rotate": false})).await, json!({"ok": true}));
    let enrolled = FakeDevice::dial(&r).await;
    assert_eq!(enrolled.enroll(&k1).await["ok"], true);

    let v = call(&r, json!({"cmd": "set_join", "hash": hash_of(&k2), "rotate": false})).await;
    assert_eq!(v, json!({"ok": false, "error": "key exists"}));
    assert_eq!(r.relay.registry().join_hash(), Some(hash_of(&k1)));
    assert_eq!(call(&r, json!({"cmd": "set_join", "hash": hash_of(&k2), "rotate": true})).await, json!({"ok": true}));
    assert_eq!(r.relay.registry().join_hash(), Some(hash_of(&k2)));

    let evs: Vec<String> = {
        r.relay.audit().flush();
        let all = rapp_relay::audit::read(r.data.path(), None, None, None).unwrap();
        all.iter().map(|l| l["ev"].as_str().unwrap().to_string()).filter(|e| e == "key" || e == "rotate_key").collect()
    };
    assert_eq!(evs, ["key", "rotate_key"]);
    for l in audit_lines(&r, "key").iter().chain(&audit_lines(&r, "rotate_key")) {
        assert!(!l.to_string().contains(&hash_of(&k1)) && !l.to_string().contains(&hash_of(&k2)), "{l}");
    }

    let old = FakeDevice::dial(&r).await;
    assert_eq!(old.enroll(&k1).await, json!({"ok": false, "error": "bad key"}));
    let new = FakeDevice::dial(&r).await;
    assert_eq!(new.enroll(&k2).await["ok"], true);
    assert_eq!(audit_lines(&r, "key")[0]["stale"], Value::Null);
    assert_eq!(audit_lines(&r, "rotate_key")[0]["stale"], 1);
    // The device that enrolled with the old key was cut off and has to enter the new one.
    assert_eq!(app_close_code(&closed(&enrolled).await), Some(4));
    let again = FakeDevice::dial_as(&r, same_identity(&enrolled.id)).await.unwrap();
    assert_eq!(again.register(A_ID, &[]).await["error"], "not enrolled");
    assert_eq!(again.enroll(&k2).await["ok"], true);
    assert_eq!(again.register(A_ID, &[]).await, json!({"ok": true, "id": A_ID}));
}

/// `rotate-key` the way the subcommand does it; the new key.
async fn rotate(r: &TestRelay) -> Key {
    timeout(WAIT, admin::issue_key(r.data.path(), true)).await.expect("rotated within WAIT").unwrap().expect("a key")
}

#[tokio::test]
async fn a_stale_device_with_the_old_key_gets_key_changed_and_is_never_locked() {
    // Rate limiting still applies; room for the 11 attempts below.
    let r = start_relay(|c| c.limits.enroll_per_ip_per_min = 100).await;
    let a = FakeDevice::enrolled(&r).await;
    let new = rotate(&r).await;
    assert_eq!(app_close_code(&closed(&a).await), Some(4));
    for i in 0..10 {
        let again = FakeDevice::dial_as(&r, same_identity(&a.id)).await.unwrap();
        assert_eq!(again.enroll(&r.key).await, json!({"ok": false, "error": "key changed"}), "attempt {i}");
    }
    assert!(audit_lines(&r, "lockout").is_empty());
    let results: Vec<Value> = audit_lines(&r, "enroll").iter().map(|l| l["result"].clone()).collect();
    assert_eq!(results.iter().filter(|x| **x == "key changed").count(), 10, "{results:?}");
    // Another device from the same source is not locked out either.
    let other = FakeDevice::dial(&r).await;
    assert_eq!(other.enroll(&new).await["ok"], true);
}

#[tokio::test]
async fn the_new_key_brings_the_old_id_back() {
    let r = start_relay(|_| {}).await;
    let a = FakeDevice::enrolled(&r).await;
    assert_eq!(a.register(A_ID, &[]).await["ok"], true);
    let new = rotate(&r).await;
    assert_eq!(app_close_code(&closed(&a).await), Some(4));

    let mut back = FakeDevice::dial_as(&r, same_identity(&a.id)).await.unwrap();
    assert_eq!(back.enroll(&new).await["ok"], true);
    assert_eq!(back.register(A_ID, &[]).await, json!({"ok": true, "id": A_ID}));
    assert_eq!(audit_lines(&r, "register").last().unwrap()["result"], "ok");
    assert!(!r.relay.registry().get(&a.id.fp).unwrap().stale);

    let b = FakeDevice::dial(&r).await;
    assert_eq!(b.enroll(&new).await["ok"], true);
    assert_eq!(b.connect_to(A_ID).await["ok"], true);
    assert_eq!(back.next_incoming().await.1, b.id.fp);
}

#[tokio::test]
async fn a_stale_device_is_offline_to_others() {
    let r = start_relay(|_| {}).await;
    let a = FakeDevice::enrolled(&r).await;
    assert_eq!(a.register(A_ID, &[]).await["ok"], true);
    let new = rotate(&r).await;
    assert_eq!(app_close_code(&closed(&a).await), Some(4));

    // Back without the new key: it may only enroll, and it keeps its ID.
    let back = FakeDevice::dial_as(&r, same_identity(&a.id)).await.unwrap();
    assert_eq!(back.register(A_ID, &[]).await, json!({"ok": false, "error": "not enrolled"}));
    let b = FakeDevice::dial(&r).await;
    assert_eq!(b.enroll(&new).await["ok"], true);
    assert_eq!(b.connect_to(A_ID).await, json!({"ok": false, "error": "offline"}));
    assert_eq!(b.register(A_ID, &[]).await, json!({"ok": false, "error": "id taken"}));

    let v = call(&r, json!({"cmd": "devices"})).await;
    let row = device_row(&v, &a.id.fp);
    assert_eq!((&row["stale"], &row["online"], &row["id"]), (&json!(true), &json!(false), &json!(A_ID)), "{row}");
    assert_eq!(device_row(&v, &b.id.fp)["stale"], false);
    assert_eq!(call(&r, json!({"cmd": "info"})).await["devices"], 2);
}

#[tokio::test]
async fn rotate_key_fails_without_showing_a_key_when_devices_json_cannot_be_written() {
    let r = start_relay(|_| {}).await;
    let a = FakeDevice::enrolled(&r).await;
    // devices.json is replaced through `devices.tmp` next to it: a directory there blocks the save
    // (even as root, unlike a read-only file or dir) and leaves the `join` file writable.
    let blocker = r.data.path().join("devices.tmp");
    std::fs::create_dir(&blocker).unwrap();
    let res = timeout(WAIT, admin::issue_key(r.data.path(), true)).await.expect("reply within WAIT");
    std::fs::remove_dir(&blocker).unwrap();

    let e = format!("{:#}", res.err().expect("rotate-key fails: no key to show"));
    assert!(e.contains("devices"), "{e}");
    assert_eq!(r.relay.registry().join_hash(), Some(hash_of(&r.key)));
    assert!(!r.relay.registry().get(&a.id.fp).unwrap().stale);
    assert!(audit_lines(&r, "rotate_key").is_empty());
    // Nothing changed: the device is still in with the old key.
    assert!(a.conn.close_reason().is_none());
    assert_eq!(a.register(A_ID, &[]).await, json!({"ok": true, "id": A_ID}));
    let b = FakeDevice::dial(&r).await;
    assert_eq!(b.enroll(&r.key).await["ok"], true);
}

#[tokio::test]
async fn the_root_never_reaches_the_server_side() {
    let r = start_relay_without_key(|_| {}).await;
    let key = admin::issue_key(r.data.path(), false).await.unwrap().expect("a new key");
    assert_eq!(key.to_string().len(), 56);
    assert!(key.matches_relay(&r.relay.fp));
    assert!(admin::issue_key(r.data.path(), false).await.unwrap().is_none(), "the key is shown once");
    let d = FakeDevice::dial(&r).await;
    assert_eq!(d.enroll(&key).await["ok"], true);

    let join = std::fs::read_to_string(r.data.path().join("join")).unwrap();
    assert_eq!(join.trim(), hash_of(&key));

    let TestRelay { relay, data, .. } = r;
    relay.stop().await;
    let hex = data_encoding::HEXLOWER;
    let b32 = data_encoding::BASE32_NOPAD;
    let secrets = [
        hex.encode(&key.root),
        b32.encode(&key.root),
        b32.encode(&key.root).to_ascii_lowercase(),
        key.to_string(),
        key.to_string().to_ascii_uppercase(),
        key.to_string()["rapp".len()..].to_string(),
        hex.encode(&key.trust()),
        hex.encode(&key.join()),
    ];
    let mut files = Vec::new();
    walk(data.path(), &mut files);
    assert!(files.iter().any(|f| f.ends_with("relay.log")), "{files:?}");
    for f in &files {
        let text = String::from_utf8_lossy(&std::fs::read(f).unwrap()).into_owned();
        for s in &secrets {
            assert!(!text.contains(s.as_str()), "a secret is in {f:?}");
        }
    }
    for raw in [&key.root[..], &key.trust()[..], &key.join()[..]] {
        for f in &files {
            let bytes = std::fs::read(f).unwrap();
            assert!(!bytes.windows(raw.len()).any(|w| w == raw), "raw secret bytes in {f:?}");
        }
    }
}

#[tokio::test]
async fn revoke_by_id_fp_and_unique_prefix() {
    let r = start_relay(|_| {}).await;
    let by_id = FakeDevice::enrolled(&r).await;
    assert_eq!(by_id.register(A_ID, &[]).await["ok"], true);
    let by_fp = FakeDevice::enrolled(&r).await;
    let by_prefix = FakeDevice::enrolled(&r).await;

    let v = call(&r, json!({"cmd": "revoke", "target": A_ID})).await;
    assert_eq!(v, json!({"ok": true, "fp": by_id.id.fp.to_string()}));
    assert_eq!(app_close_code(&closed(&by_id).await), Some(2));

    let v = call(&r, json!({"cmd": "revoke", "target": by_fp.id.fp.to_string()})).await;
    assert_eq!(v, json!({"ok": true, "fp": by_fp.id.fp.to_string()}));
    assert_eq!(app_close_code(&closed(&by_fp).await), Some(2));

    let prefix = by_prefix.id.fp.to_string()[..10].to_ascii_uppercase();
    let v = call(&r, json!({"cmd": "revoke", "target": prefix})).await;
    assert_eq!(v, json!({"ok": true, "fp": by_prefix.id.fp.to_string()}));
    assert_eq!(app_close_code(&closed(&by_prefix).await), Some(2));

    // Idempotent: revoking again still names the device.
    let v = call(&r, json!({"cmd": "revoke", "target": by_fp.id.fp.to_string()})).await;
    assert_eq!(v, json!({"ok": true, "fp": by_fp.id.fp.to_string()}));
    assert_eq!(audit_lines(&r, "revoke").len(), 3);

    let mut twin = [0x11u8; 32];
    r.relay.registry().enroll(Fp(twin), "default").unwrap();
    twin[31] = 0x12;
    r.relay.registry().enroll(Fp(twin), "default").unwrap();
    let v = call(&r, json!({"cmd": "revoke", "target": "11111111"})).await;
    assert_eq!(v, json!({"ok": false, "error": "ambiguous"}));
    for target in ["2222222222", "987654321", &"3".repeat(64)] {
        let v = call(&r, json!({"cmd": "revoke", "target": target})).await;
        assert_eq!(v, json!({"ok": false, "error": "not found"}), "{target}");
    }
    // Not an ID, not a fingerprint, not a long enough hex prefix: nothing it could name.
    for target in ["1111111", "", "hello world", "12345678x"] {
        let v = call(&r, json!({"cmd": "revoke", "target": target})).await;
        assert_eq!(v, json!({"ok": false, "error": "not found"}), "{target}");
    }
}

#[tokio::test]
async fn revoke_applies_even_when_it_cannot_be_saved() {
    let r = start_relay(|_| {}).await;
    let d = FakeDevice::enrolled(&r).await;
    let dir = r.data.path().to_path_buf();
    // devices.json is replaced through a temp file next to it, so a read-only dir blocks the save.
    std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o500)).unwrap();
    let writable_anyway = std::fs::write(dir.join("probe"), b"x").is_ok(); // running as root
    let v = call(&r, json!({"cmd": "revoke", "target": d.id.fp.to_string()})).await;
    let code = app_close_code(&closed(&d).await);
    std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700)).unwrap();
    let _ = std::fs::remove_file(dir.join("probe"));
    if writable_anyway {
        return;
    }
    assert_eq!(v["ok"], false, "{v}");
    assert!(v["error"].as_str().unwrap().starts_with("applied but not saved: "), "{v}");
    assert_eq!(code, Some(2));
    assert!(r.relay.registry().get(&d.id.fp).unwrap().revoked);
    let lines = audit_lines(&r, "revoke");
    assert_eq!((lines.len(), lines[0]["saved"].as_bool()), (1, Some(false)));
    // Saved at the next successful write: revoking again is a no-op, the flush at stop persists it.
    let TestRelay { relay, data, .. } = r;
    relay.stop().await;
    let reopened = rapp_relay::store::FileRegistry::open(data.path()).unwrap();
    assert!(rapp_relay::store::Registry::get(&reopened, &d.id.fp).unwrap().revoked);
}

#[tokio::test]
async fn enroll_switch_applies_even_when_it_cannot_be_saved() {
    let data = tempfile::tempdir().unwrap();
    std::fs::write(data.path().join("config.json"), r#"{"log":"debug"}"#).unwrap();
    let r = start_from_file(data, false).await;
    let dir = r.data.path().to_path_buf();
    // config.json is replaced through a temp file next to it, so a read-only dir blocks the save.
    std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o500)).unwrap();
    let v = call(&r, json!({"cmd": "enroll", "state": "closed"})).await;
    std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700)).unwrap();

    assert_eq!(v["ok"], false, "{v}");
    let error = v["error"].as_str().unwrap();
    assert!(error.starts_with("applied but not saved: "), "{error}");
    let d = FakeDevice::dial(&r).await;
    assert_eq!(d.enroll(&r.key).await, json!({"ok": false, "error": "closed"}));
    assert_eq!(call(&r, json!({"cmd": "info"})).await["enroll"], "closed");
    assert_eq!(audit_lines(&r, "enroll_close").len(), 1);
    let file: Value = serde_json::from_slice(&std::fs::read(dir.join("config.json")).unwrap()).unwrap();
    assert_eq!(file, json!({"log": "debug"}));
}

#[tokio::test]
async fn enroll_switch_takes_effect_and_persists() {
    let data = tempfile::tempdir().unwrap();
    std::fs::write(data.path().join("config.json"), r#"{"log":"debug"}"#).unwrap();
    let r = start_from_file(data, false).await;
    let v = call(&r, json!({"cmd": "enroll", "state": "closed"})).await;
    assert_eq!(v, json!({"ok": true, "env_overrides": false}));
    let d = FakeDevice::dial(&r).await;
    assert_eq!(d.enroll(&r.key).await, json!({"ok": false, "error": "closed"}));
    assert_eq!(call(&r, json!({"cmd": "info"})).await["enroll"], "closed");

    let file: Value = serde_json::from_slice(&std::fs::read(r.data.path().join("config.json")).unwrap()).unwrap();
    assert_eq!(file, json!({"log": "debug", "enroll": "closed"}));
    assert_eq!(audit_lines(&r, "enroll_close").len(), 1);

    let TestRelay { relay, data, .. } = r;
    relay.stop().await;
    let r = start_from_file(data, false).await;
    assert_eq!(call(&r, json!({"cmd": "info"})).await["enroll"], "closed");
    let d = FakeDevice::dial(&r).await;
    assert_eq!(d.enroll(&r.key).await, json!({"ok": false, "error": "closed"}));

    assert_eq!(call(&r, json!({"cmd": "enroll", "state": "open"})).await["ok"], true);
    // The refused enroll ended that connection.
    assert!(app_close_code(&closed(&d).await).is_some());
    let d = FakeDevice::dial(&r).await;
    assert_eq!(d.enroll(&r.key).await["ok"], true);
    assert_eq!(audit_lines(&r, "enroll_open").len(), 1);
    assert_eq!(call(&r, json!({"cmd": "enroll", "state": "maybe"})).await["error"], "bad request");
}

#[tokio::test]
async fn enroll_switch_warns_when_env_will_override_it() {
    let r = start_from_file(tempfile::tempdir().unwrap(), true).await;
    let v = call(&r, json!({"cmd": "enroll", "state": "closed"})).await;
    assert_eq!(v, json!({"ok": true, "env_overrides": true}));
    let file: Value = serde_json::from_slice(&std::fs::read(r.data.path().join("config.json")).unwrap()).unwrap();
    assert_eq!(file, json!({"enroll": "closed"}));
    let mode = std::fs::metadata(r.data.path().join("config.json")).unwrap().permissions().mode();
    assert_eq!(mode & 0o777, 0o600);
}

#[tokio::test]
async fn devices_shows_last_seen() {
    let r = start_relay(|_| {}).await;
    let a = FakeDevice::enrolled(&r).await;
    assert_eq!(a.register(A_ID, &[]).await["ok"], true);
    let b = FakeDevice::enrolled(&r).await;
    let fp = a.id.fp;
    let v = call(&r, json!({"cmd": "devices"})).await;
    assert_eq!(v["ok"], true, "{v}");
    let row = device_row(&v, &fp);
    assert_eq!(row["online"], true);
    assert_eq!(row["id"], A_ID);
    assert_eq!(row["revoked"], false);
    assert!(row["enrolled_at"].is_string(), "{row}");
    assert_eq!(device_row(&v, &b.id.fp)["id"], Value::Null);

    a.close().await;
    eventually("A offline", async || device_row(&call(&r, json!({"cmd": "devices"})).await, &fp)["online"] == false)
        .await;
    let v = call(&r, json!({"cmd": "devices"})).await;
    let row = device_row(&v, &fp);
    assert!(row["last_seen"].as_str().is_some_and(|s| s.ends_with('Z')), "{row}");
    assert_eq!(call(&r, json!({"cmd": "info"})).await["online"], 1);
}

#[tokio::test]
async fn unbind_frees_the_id() {
    let r = start_relay(|_| {}).await;
    let a = FakeDevice::enrolled(&r).await;
    assert_eq!(a.register(A_ID, &[]).await["ok"], true);
    let b = FakeDevice::enrolled(&r).await;
    assert_eq!(b.register(A_ID, &[]).await, json!({"ok": false, "error": "id taken"}));

    assert_eq!(call(&r, json!({"cmd": "unbind", "id": A_ID})).await, json!({"ok": true}));
    assert_eq!(call(&r, json!({"cmd": "unbind", "id": A_ID})).await, json!({"ok": false, "error": "not found"}));
    let lines = audit_lines(&r, "unbind");
    assert_eq!(lines.len(), 1, "{lines:?}");
    assert_eq!(lines[0]["id"], A_ID);
    assert_eq!(lines[0]["fp"], a.id.fp.to_string());

    assert_eq!(b.register(A_ID, &[]).await, json!({"ok": true, "id": A_ID}));
    assert_eq!(r.relay.registry().by_id(A_ID).unwrap().fp, b.id.fp);
    // A was not cut off, and its ID now reaches B.
    assert!(a.conn.close_reason().is_none());
    let mut b = b;
    assert_eq!(a.connect_to(A_ID).await["ok"], true);
    assert_eq!(b.next_incoming().await.1, a.id.fp);
}

#[tokio::test]
async fn admin_socket_is_private() {
    let r = start_relay(|_| {}).await;
    let sock = r.data.path().join("admin.sock");
    let mode = std::fs::metadata(&sock).unwrap().permissions().mode();
    assert_eq!(mode & 0o777, 0o600);
    let TestRelay { relay, data, .. } = r;
    relay.stop().await;
    assert!(!sock.exists(), "stop removes the socket");
    drop(data);
}

#[tokio::test]
async fn a_second_relay_on_the_same_data_dir_is_refused() {
    let r = start_relay(|_| {}).await;
    let opts =
        Opts { data: r.data.path().to_path_buf(), config: r.config.clone(), log: Log::none(), enroll_from_env: false };
    let e = Relay::start(opts).await.err().expect("second relay refused");
    assert!(format!("{e:#}").contains(&r.data.path().join("admin.sock").display().to_string()), "{e:#}");
    // The first one still answers.
    assert_eq!(call(&r, json!({"cmd": "info"})).await["ok"], true);

    // A socket file left behind by a relay that is gone is replaced.
    let TestRelay { relay, data, config, .. } = r;
    relay.stop().await;
    let stale = std::os::unix::net::UnixListener::bind(data.path().join("admin.sock")).unwrap();
    drop(stale);
    let opts = Opts { data: data.path().to_path_buf(), config, log: Log::none(), enroll_from_env: false };
    let relay = Relay::start(opts).await.expect("starts over a stale socket");
    assert_eq!(timeout(WAIT, admin::call(data.path(), json!({"cmd": "info"}))).await.unwrap().unwrap()["ok"], true);
    relay.stop().await;
}

#[tokio::test]
async fn stop_tells_devices_before_closing() {
    let r = start_relay(|_| {}).await;
    let mut d = FakeDevice::enrolled(&r).await;
    let TestRelay { relay, data, .. } = r;
    let started = Instant::now();
    relay.stop().await;
    assert!(started.elapsed() < Duration::from_millis(2500), "stop took {:?}", started.elapsed());
    loop {
        match d.next_push().await {
            Push::GoingAway { after_ms } => {
                assert_eq!(after_ms, 3000);
                break;
            }
            Push::Revoked { .. } => continue,
            other => panic!("unexpected push {other:?}"),
        }
    }
    let e = timeout(WAIT, d.conn.closed()).await.expect("closed after going_away");
    assert_eq!(app_close_code(&e), Some(0), "{e:?}");
    let all = rapp_relay::audit::read(data.path(), None, None, None).unwrap();
    let last = all.last().unwrap();
    assert_eq!(last["ev"], "relay_stop", "{all:?}");
    assert_eq!(last["reason"], "stop");
}

fn walk(dir: &Path, out: &mut Vec<PathBuf>) {
    for e in std::fs::read_dir(dir).unwrap().flatten() {
        let p = e.path();
        if p.is_dir() {
            walk(&p, out);
        } else if p.is_file() {
            out.push(p);
        }
    }
}

// --- The binary, as a process. ---

const BIN: &str = env!("CARGO_BIN_EXE_rapp-relay");

/// A temp dir holding the data dir (`data/`) and the server's stderr (`stderr.log`).
struct Dirs {
    root: tempfile::TempDir,
}

impl Dirs {
    fn new() -> Dirs {
        let d = Dirs { root: tempfile::tempdir().unwrap() };
        assert!(d.data().join("admin.sock").as_os_str().len() < 100, "socket path too long for macOS");
        d
    }
    fn data(&self) -> PathBuf {
        self.root.path().join("data")
    }
    fn stderr(&self) -> String {
        std::fs::read_to_string(self.root.path().join("stderr.log")).unwrap_or_default()
    }
}

/// A child relay; killed (SIGKILL) and reaped on drop unless `stop` already ended it.
struct Server {
    child: Option<std::process::Child>,
}

impl Server {
    fn start(dirs: &Dirs) -> Server {
        let log = std::fs::File::create(dirs.root.path().join("stderr.log")).unwrap();
        let child = Command::new(BIN)
            .arg("--data")
            .arg(dirs.data())
            .env("RAPP_RELAY_LISTEN", "127.0.0.1:0")
            .env_remove("RAPP_RELAY_ENROLL")
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(log)
            .spawn()
            .unwrap();
        let s = Server { child: Some(child) };
        let rt = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
        let until = Instant::now() + WAIT;
        loop {
            let got = rt.block_on(async {
                timeout(Duration::from_millis(500), admin::call(&dirs.data(), json!({"cmd": "info"}))).await
            });
            if matches!(got, Ok(Ok(ref v)) if v["ok"] == true) {
                return s;
            }
            assert!(Instant::now() < until, "relay did not answer info: {}", dirs.stderr());
            std::thread::sleep(Duration::from_millis(50));
        }
    }

    fn pid(&self) -> i32 {
        self.child.as_ref().unwrap().id() as i32
    }

    fn signal(&self, sig: i32) {
        assert_eq!(unsafe { libc::kill(self.pid(), sig) }, 0);
    }

    /// SIGTERM, then waits (at most WAIT) and returns the exit status.
    fn stop(mut self) -> std::process::ExitStatus {
        self.signal(libc::SIGTERM);
        let mut child = self.child.take().unwrap();
        let until = Instant::now() + WAIT;
        loop {
            if let Some(st) = child.try_wait().unwrap() {
                return st;
            }
            if Instant::now() > until {
                let _ = child.kill();
                let _ = child.wait();
                panic!("relay did not stop on SIGTERM");
            }
            std::thread::sleep(Duration::from_millis(20));
        }
    }
}

impl Drop for Server {
    fn drop(&mut self) {
        if let Some(mut c) = self.child.take() {
            let _ = c.kill();
            let _ = c.wait();
        }
    }
}

fn cli(data: &Path, args: &[&str]) -> Output {
    Command::new(BIN).arg("--data").arg(data).args(args).stdin(Stdio::null()).output().unwrap()
}

fn text(b: &[u8]) -> String {
    String::from_utf8_lossy(b).into_owned()
}

#[test]
fn cli_key_prints_once_then_refuses() {
    let dirs = Dirs::new();
    let server = Server::start(&dirs);
    let out = cli(&dirs.data(), &["key"]);
    assert!(out.status.success(), "{}", text(&out.stderr));
    let key = text(&out.stdout);
    assert!(key.ends_with('\n'));
    let key = key.trim_end().to_string();
    assert_eq!(key.len(), 56, "{key:?}");
    assert!(key.starts_with("rapp"), "{key:?}");
    let parsed: Key = key.parse().unwrap();
    let info: Value = {
        let rt = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
        rt.block_on(admin::call(&dirs.data(), json!({"cmd": "info"}))).unwrap()
    };
    assert!(parsed.matches_relay(&info["fp"].as_str().unwrap().parse().unwrap()));
    assert_eq!(info["has_key"], true);

    let again = cli(&dirs.data(), &["key"]);
    assert_eq!(again.status.code(), Some(1));
    assert!(!text(&again.stdout).contains(&key) && !text(&again.stderr).contains(&key));
    assert!(text(&again.stderr).contains("rotate-key"), "{}", text(&again.stderr));

    let rotated = cli(&dirs.data(), &["rotate-key"]);
    assert!(rotated.status.success(), "{}", text(&rotated.stderr));
    let new_key = text(&rotated.stdout).trim_end().to_string();
    assert_eq!(new_key.len(), 56);
    assert_ne!(new_key, key);

    let devices = cli(&dirs.data(), &["devices"]);
    assert!(devices.status.success());
    assert_eq!(text(&devices.stdout).lines().count(), 1, "only the header: {}", text(&devices.stdout));

    let enroll = cli(&dirs.data(), &["enroll", "closed"]);
    assert!(enroll.status.success(), "{}", text(&enroll.stderr));
    assert!(!text(&enroll.stdout).contains("RAPP_RELAY_ENROLL"));

    assert!(server.stop().success(), "{}", dirs.stderr());
    assert!(!dirs.stderr().contains(&key) && !dirs.stderr().contains(&new_key), "a key reached the server's log");
    let audit = cli(&dirs.data(), &["audit", "--event", "relay_stop"]);
    assert!(audit.status.success());
    let lines: Vec<Value> = text(&audit.stdout).lines().map(|l| serde_json::from_str(l).unwrap()).collect();
    assert_eq!(lines.len(), 1, "{lines:?}");
    assert_eq!(lines[0]["reason"], "signal");
    let since = cli(&dirs.data(), &["audit", "--since", "1h", "--event", "rotate_key"]);
    assert_eq!(text(&since.stdout).lines().count(), 1, "{}", text(&since.stdout));
    assert!(!dirs.data().join("admin.sock").exists());
}

#[test]
fn cli_check_exits_zero_when_serving_and_one_when_not() {
    let dirs = Dirs::new();
    let server = Server::start(&dirs);
    let out = cli(&dirs.data(), &["check"]);
    assert_eq!(out.status.code(), Some(0), "{}", text(&out.stderr));

    server.signal(libc::SIGSTOP);
    let started = Instant::now();
    let out = cli(&dirs.data(), &["check"]);
    let took = started.elapsed();
    server.signal(libc::SIGCONT);
    assert_eq!(out.status.code(), Some(1), "{}", text(&out.stderr));
    assert!(took >= Duration::from_secs(3) && took < Duration::from_secs(5), "check took {took:?}");

    assert!(server.stop().success(), "{}", dirs.stderr());
    let out = cli(&dirs.data(), &["check"]);
    assert_eq!(out.status.code(), Some(1));
}

#[test]
fn cli_admin_commands_say_when_the_relay_is_not_running() {
    let dirs = Dirs::new();
    std::fs::create_dir(dirs.data()).unwrap();
    for args in [&["devices"][..], &["key"], &["revoke", A_ID], &["unbind", A_ID], &["enroll", "open"], &["check"]] {
        let out = cli(&dirs.data(), args);
        assert_eq!(out.status.code(), Some(1), "{args:?}");
        let want = format!("relay 没在运行（{}/admin.sock 连不上）", dirs.data().display());
        assert!(text(&out.stderr).contains(&want), "{args:?}: {}", text(&out.stderr));
    }
}

#[test]
fn cli_refuses_to_start_on_bad_config_and_names_the_item() {
    let dirs = Dirs::new();
    let out = Command::new(BIN)
        .arg("--data")
        .arg(dirs.data())
        .env("RAPP_RELAY_LISTEN", "127.0.0.1:0")
        .env("RAPP_RELAY_ENROLL", "maybe")
        .stdin(Stdio::null())
        .output()
        .unwrap();
    assert!(!out.status.success());
    assert!(text(&out.stderr).contains("RAPP_RELAY_ENROLL"), "{}", text(&out.stderr));
}

#[test]
fn cli_refuses_to_start_when_data_dir_is_unusable() {
    let dirs = Dirs::new();
    let file = dirs.root.path().join("plain-file");
    std::fs::write(&file, b"x").unwrap();
    let out = Command::new(BIN)
        .arg("--data")
        .arg(&file)
        .env("RAPP_RELAY_LISTEN", "127.0.0.1:0")
        .env_remove("RAPP_RELAY_ENROLL")
        .stdin(Stdio::null())
        .output()
        .unwrap();
    assert!(!out.status.success());
    assert!(text(&out.stderr).contains(&file.display().to_string()), "{}", text(&out.stderr));
}

#[test]
fn cli_version_and_usage() {
    let out = Command::new(BIN).arg("--version").output().unwrap();
    assert!(out.status.success());
    assert_eq!(text(&out.stdout), format!("rapp-relay {}\n", env!("CARGO_PKG_VERSION")));
    for args in [&["frobnicate"][..], &["--nope"], &["enroll", "maybe"], &["audit", "--since", "7x"], &["revoke"]] {
        let out = Command::new(BIN).args(args).output().unwrap();
        assert_eq!(out.status.code(), Some(2), "{args:?}");
        assert!(text(&out.stderr).contains("usage"), "{args:?}: {}", text(&out.stderr));
    }
}
