//! A full life of a relay, then a search of everything it wrote for secrets; and the same life
//! checked against the audit event table (spec §11.1).
mod common;

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use common::*;
use rapp_relay2::admin;
use rapp_wire::Key;
use serde_json::{json, Value};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::time::timeout;

const A_ID: &str = "123456789";

async fn call(r: &TestRelay, req: Value) -> Value {
    timeout(WAIT, admin::call(r.data.path(), req)).await.expect("admin reply within WAIT").expect("admin call")
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

async fn wait_audit(r: &TestRelay, ev: &str) {
    let t = Instant::now();
    while audit_lines(r, ev).is_empty() {
        assert!(t.elapsed() < WAIT, "no {ev} audit line");
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
}

async fn enrolled_with(r: &TestRelay, key: &Key) -> FakeDevice {
    let d = FakeDevice::dial(r).await;
    assert_eq!(d.enroll(key).await["ok"], true);
    d
}

/// Moves `len` bytes from `on_b` to `on_a` and finishes both ends.
async fn exchange(
    on_b: &mut (impl AsyncReadExt + AsyncWriteExt + Unpin),
    on_a: &mut (impl AsyncReadExt + AsyncWriteExt + Unpin),
    len: usize,
) {
    let data = vec![0x5au8; len];
    let w = async {
        on_b.write_all(&data).await.unwrap();
        on_b.shutdown().await.unwrap();
    };
    let r = async {
        let mut got = Vec::new();
        on_a.read_to_end(&mut got).await.unwrap();
        assert_eq!(got.len(), len);
    };
    timeout(WAIT * 2, async { tokio::join!(w, r) }).await.expect("transfer within WAIT");
    on_a.shutdown().await.unwrap();
}

/// Runs everything the relay does and returns it (still running) with every key that existed.
async fn life() -> (TestRelay, Vec<Key>) {
    let r = start_relay_without_key(|c| c.limits.max_relayed_per_device = 1).await;
    let key1 = admin::issue_key(r.data.path(), false).await.unwrap().expect("a new key");

    // Three devices enroll, one registers, one connects.
    let mut a = enrolled_with(&r, &key1).await;
    let b = enrolled_with(&r, &key1).await;
    let c = enrolled_with(&r, &key1).await;
    assert_eq!(a.register(A_ID, &["192.168.1.5:47800"]).await["ok"], true);
    assert_eq!(b.connect_to(A_ID).await["ok"], true);

    // A stream, a second one that hits max_relayed_per_device, then the first one carries data.
    let mut on_b = b.relay_to(A_ID).await.unwrap();
    let (_, _, mut on_a) = a.next_relayed().await;
    let mut over = c.relay_to(A_ID).await.unwrap();
    let mut buf = [0u8; 256];
    let n = timeout(WAIT, over.read(&mut buf)).await.unwrap().unwrap();
    let line = String::from_utf8_lossy(&buf[..n]).into_owned();
    assert!(line.contains("limit"), "{line}");
    exchange(&mut on_b, &mut on_a, 20_000).await;
    wait_audit(&r, "relayed").await;

    // A short probe stream.
    let mut on_b = b.relay_to(A_ID).await.unwrap();
    let (_, _, mut on_a) = a.next_relayed().await;
    exchange(&mut on_b, &mut on_a, 10).await;
    wait_audit(&r, "probes").await;

    // A wrong key until locked (last: the lock covers this address).
    // (A failed enroll ends its connection, so each attempt dials again.)
    let wrong = Key::new_for_relay(&r.relay.fp);
    for _ in 0..5 {
        assert_eq!(FakeDevice::dial(&r).await.enroll(&wrong).await["ok"], false);
    }
    assert_eq!(FakeDevice::dial(&r).await.enroll(&key1).await["ok"], false, "locked");

    // Enrollment closed and open again, unbind, revoke, a new key.
    assert_eq!(call(&r, json!({"cmd": "enroll", "state": "closed"})).await["ok"], true);
    assert_eq!(call(&r, json!({"cmd": "enroll", "state": "open"})).await["ok"], true);
    assert_eq!(call(&r, json!({"cmd": "unbind", "id": A_ID})).await["ok"], true);
    assert_eq!(call(&r, json!({"cmd": "revoke", "target": c.id.fp.to_string()})).await["ok"], true);
    let key2 = admin::issue_key(r.data.path(), true).await.unwrap().expect("a rotated key");
    (r, vec![key1, key2, wrong])
}

#[tokio::test]
async fn nothing_secret_is_written_anywhere() {
    let (r, keys) = life().await;
    let TestRelay { relay, data, .. } = r;
    relay.stop().await;

    let hex = data_encoding::HEXLOWER;
    let b32 = data_encoding::BASE32_NOPAD;
    let mut secrets: Vec<String> = Vec::new();
    let mut raw: Vec<Vec<u8>> = Vec::new();
    for k in &keys {
        secrets.extend([
            hex.encode(&k.root),
            b32.encode(&k.root),
            b32.encode(&k.root).to_ascii_lowercase(),
            k.to_string(),
            k.to_string().to_ascii_uppercase(),
            hex.encode(&k.trust()),
            hex.encode(&k.join()),
        ]);
        raw.extend([k.root.to_vec(), k.trust().to_vec(), k.join().to_vec()]);
    }
    let mut files = Vec::new();
    walk(data.path(), &mut files);
    let log = files.iter().find(|f| f.ends_with("relay.log")).unwrap_or_else(|| panic!("no relay.log in {files:?}"));
    // Positive control: the scan reads real output, so a vacuous pass would show here.
    let log_text = std::fs::read_to_string(log).unwrap();
    assert!(log_text.contains("relay_start"), "relay.log has no relay_start event");
    let key_file = files.iter().find(|f| f.file_name().unwrap() == "relay.key").expect("relay.key exists").clone();
    let key_bytes = std::fs::read(&key_file).unwrap();
    assert!(key_bytes.len() > 16);
    for f in &files {
        let bytes = std::fs::read(f).unwrap();
        let text = String::from_utf8_lossy(&bytes).into_owned();
        for s in &secrets {
            assert!(!text.contains(s.as_str()), "a secret is in {f:?}");
        }
        for w in &raw {
            assert!(!bytes.windows(w.len()).any(|x| x == &w[..]), "raw secret bytes in {f:?}");
        }
        if *f != key_file {
            assert!(!bytes.windows(key_bytes.len()).any(|x| x == &key_bytes[..]), "relay.key bytes in {f:?}");
        }
    }
}

#[tokio::test]
async fn every_audit_event_appears() {
    let (r, _) = life().await;
    let TestRelay { relay, data, .. } = r;
    relay.stop().await;
    let lines = rapp_relay2::audit::read(data.path(), None, None, None).unwrap();
    let seen: BTreeSet<String> = lines.iter().map(|l| l["ev"].as_str().unwrap().to_string()).collect();
    let want = [
        "relay_start",
        "relay_stop",
        "enroll",
        "register",
        "connect",
        "relayed",
        "lockout",
        "limit",
        "key",
        "rotate_key",
        "revoke",
        "unbind",
        "enroll_open",
        "enroll_close",
        "probes",
    ];
    for ev in want {
        assert!(seen.contains(ev), "no {ev} event in {seen:?}");
    }
    for l in &lines {
        for f in ["t", "ev", "tenant"] {
            assert!(l[f].is_string(), "{f} missing in {l}");
        }
    }
}
