//! The iOS options and access commands of the hub, driven over in-memory pipes.

use rapp_hub::{Opts, UpgradeTimes};
use serde_json::{json, Value};
use std::path::Path;
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader, DuplexStream, Lines};

struct H {
    w: DuplexStream,
    lines: Lines<BufReader<DuplexStream>>,
}

fn opts(home: &Path) -> Opts {
    Opts {
        home: home.to_path_buf(),
        bin_dir: None,
        log: rapp_net::log::Log::none(),
        presence_every: None,
        upgrade: UpgradeTimes::default(),
        name: Some("Bruce 的 iPad".into()),
        owns_access: true,
        embed_only: false,
        dual_stack: false,
    }
}

fn start(o: Opts) -> H {
    let (cmd_r, w) = tokio::io::duplex(1 << 16);
    let (out_r, out_w) = tokio::io::duplex(1 << 16);
    tokio::spawn(rapp_hub::run(o, cmd_r, out_w));
    H { w, lines: BufReader::new(out_r).lines() }
}

impl H {
    async fn send(&mut self, v: Value) {
        self.w.write_all(format!("{v}\n").as_bytes()).await.unwrap();
    }
    async fn next(&mut self) -> Value {
        let l = tokio::time::timeout(Duration::from_secs(10), self.lines.next_line()).await.unwrap().unwrap().unwrap();
        serde_json::from_str(&l).unwrap()
    }
    async fn ask(&mut self, v: Value) -> Value {
        self.send(v).await;
        self.next().await
    }
}

#[tokio::test]
async fn access_reports_unset_then_set() {
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("service.json");
    std::fs::write(&file, r#"{"id":"x"}"#).unwrap();
    let mut h = start(opts(dir.path()));
    let ev = h.ask(json!({"cmd":"access","req":1})).await;
    assert_eq!(ev["event"], "access");
    assert_eq!(ev["req"], 1);
    assert!(ev["relay"].is_null());
    assert_eq!(ev["has_key"], false);
    assert_eq!(ev["name"], "Bruce 的 iPad");

    let key = rapp_wire::Key::new_local().to_string();
    let ev = h.ask(json!({"cmd":"set_access","relay":"r.example:7000","key":key,"req":2})).await;
    assert_eq!(ev["event"], "access", "{ev}");
    assert_eq!(ev["relay"], "r.example:7000");
    assert_eq!(ev["has_key"], true);
    assert!(!ev.to_string().contains(&key), "the key must not be echoed");
    let v: Value = serde_json::from_slice(&std::fs::read(&file).unwrap()).unwrap();
    assert_eq!(v["relay"], "r.example:7000");
    assert_eq!(v["key"], key.as_str());
    assert_eq!(v["id"], "x");
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(std::fs::metadata(&file).unwrap().permissions().mode() & 0o777, 0o600);
    }
    let ev = h.ask(json!({"cmd":"access"})).await;
    assert_eq!(ev["relay"], "r.example:7000");
    assert_eq!(ev["has_key"], true);
}

#[tokio::test]
async fn set_access_rejects_bad_key_and_keeps_file() {
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("service.json");
    let before = r#"{"id":"x","relay":"old:1"}"#;
    std::fs::write(&file, before).unwrap();
    let mut h = start(opts(dir.path()));
    let ev = h.ask(json!({"cmd":"set_access","relay":"r.example:7000","key":"nope"})).await;
    assert_eq!(ev["event"], "error");
    assert!(ev["error"].as_str().unwrap().contains("bad key"), "{ev}");
    assert_eq!(std::fs::read_to_string(&file).unwrap(), before);

    let key = rapp_wire::Key::new_local().to_string();
    let ev = h.ask(json!({"cmd":"set_access","relay":"  ","key":key})).await;
    assert_eq!(ev["event"], "error");
    assert_eq!(std::fs::read_to_string(&file).unwrap(), before);
}

#[tokio::test]
async fn access_cmds_refused_without_owns_access() {
    let dir = tempfile::tempdir().unwrap();
    let mut o = opts(dir.path());
    o.owns_access = false;
    let mut h = start(o);
    let key = rapp_wire::Key::new_local().to_string();
    for cmd in [json!({"cmd":"access"}), json!({"cmd":"set_access","relay":"r:1","key":key})] {
        let ev = h.ask(cmd).await;
        assert_eq!(ev["event"], "error");
        assert!(ev["error"].as_str().unwrap().contains("service owns access"), "{ev}");
    }
    assert!(!dir.path().join("service.json").exists());
}

#[tokio::test]
async fn close_accepts_background() {
    let dir = tempfile::tempdir().unwrap();
    let mut h = start(opts(dir.path()));
    // The reason is accepted; the sid is what is unknown.
    let ev = h.ask(json!({"cmd":"close","sid":1,"reason":"background"})).await;
    assert_eq!(ev["error"], "unknown sid");
    let ev = h.ask(json!({"cmd":"close","sid":1,"reason":"x"})).await;
    assert_eq!(ev["error"], "bad reason");
}

#[tokio::test]
async fn embed_only_refuses_window_open() {
    let dir = tempfile::tempdir().unwrap();
    let mut o = opts(dir.path());
    o.embed_only = true;
    let mut h = start(o);
    let ev = h.ask(json!({"cmd":"open","id":"h","app":"com.example.app"})).await;
    assert_eq!(ev["event"], "error");
    assert!(ev["error"].as_str().unwrap().contains("embedded only"), "{ev}");
}

#[tokio::test]
async fn presence_pause_skips_ticks() {
    let dir = tempfile::tempdir().unwrap();
    // No address, no password, no relay: the probe fails at once and the host shows offline.
    std::fs::write(dir.path().join("hosts.json"), r#"[{"id":"h1","name":"h1"}]"#).unwrap();
    let mut o = opts(dir.path());
    o.presence_every = Some(Duration::from_millis(50));
    let mut h = start(o);
    assert_eq!(h.next().await["event"], "presence");

    h.send(json!({"cmd":"presence","paused":true})).await;
    // Let a tick in flight finish, then drain what was already sent.
    tokio::time::sleep(Duration::from_millis(200)).await;
    while tokio::time::timeout(Duration::from_millis(100), h.lines.next_line()).await.is_ok() {}
    let quiet = tokio::time::timeout(Duration::from_millis(300), h.lines.next_line()).await;
    assert!(quiet.is_err(), "presence while paused: {quiet:?}");

    h.send(json!({"cmd":"presence","paused":false})).await;
    assert_eq!(h.next().await["event"], "presence");
}
