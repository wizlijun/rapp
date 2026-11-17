//! `{"cmd":"net_changed"}`: the app came back, or Wi-Fi/cellular changed. The hub takes a new UDP
//! socket and asks every host again at once, instead of at the next 30 s round.

use rapp_hub::{Opts, UpgradeTimes};
use serde_json::{json, Value};
use std::path::Path;
use std::time::{Duration, Instant};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader, DuplexStream, Lines};

struct H {
    w: DuplexStream,
    lines: Lines<BufReader<DuplexStream>>,
}

fn opts(home: &Path, log: rapp_net::log::Log, presence_every: Option<Duration>) -> Opts {
    Opts {
        home: home.to_path_buf(),
        bin_dir: None,
        log,
        presence_every,
        upgrade: UpgradeTimes::default(),
        name: Some("Duo".into()),
        owns_access: true,
        embed_only: false,
        dual_stack: true,
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
    /// The next event named `name`, waiting at most `wait`.
    async fn next_named(&mut self, name: &str, wait: Duration) -> Option<Value> {
        let end = Instant::now() + wait;
        loop {
            let left = end.checked_duration_since(Instant::now())?;
            let l = tokio::time::timeout(left, self.lines.next_line()).await.ok()?.unwrap()?;
            let v: Value = serde_json::from_str(&l).unwrap();
            if v["event"] == name {
                return Some(v);
            }
        }
    }
}

/// The `rebind` lines in hub.log, waiting up to 5 s for `n` of them.
async fn rebinds(log: &Path, n: usize) -> Vec<Value> {
    let end = Instant::now() + Duration::from_secs(5);
    loop {
        let found: Vec<Value> = std::fs::read_to_string(log)
            .unwrap_or_default()
            .lines()
            .filter_map(|l| serde_json::from_str::<Value>(l).ok())
            .filter(|v| v["ev"] == "rebind")
            .collect();
        if found.len() >= n || Instant::now() > end {
            return found;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
}

#[tokio::test]
async fn net_changed_gives_the_hub_a_new_socket() {
    let dir = tempfile::tempdir().unwrap();
    let logs = dir.path().join("logs");
    let mut h = start(opts(dir.path(), rapp_net::log::Log::file(&logs, "hub.log"), None));
    h.send(json!({"cmd":"net_changed"})).await;
    h.send(json!({"cmd":"net_changed"})).await;
    let got = rebinds(&logs.join("hub.log"), 2).await;
    assert_eq!(got.len(), 2, "{got:?}");
    let ports: Vec<String> = got.iter().map(|v| v["local"].as_str().unwrap_or_default().to_string()).collect();
    assert!(ports.iter().all(|p| p.starts_with("[::]:")), "dual-stack stays dual: {ports:?}");
    assert_ne!(ports[0], ports[1], "each change takes a socket of its own");
}

#[tokio::test]
async fn net_changed_asks_every_host_again_at_once() {
    // A host that turns this device down at once (wrong ALPN), so a probe ends fast.
    let server = rapp_net::quic::server_endpoint("127.0.0.1:0".parse().unwrap(), b"other/1").unwrap();
    let port = server.local_addr().unwrap().port();
    tokio::spawn(async move {
        while let Some(inc) = server.accept().await {
            let _ = inc.await;
        }
    });
    let dir = tempfile::tempdir().unwrap();
    std::fs::write(
        dir.path().join("hosts.json"),
        json!([{"id":"h1","name":"Mac","password":"","lan":[format!("127.0.0.1:{port}")]}]).to_string(),
    )
    .unwrap();
    // A round an hour apart: only the first one comes by itself within this test.
    let mut h = start(opts(dir.path(), rapp_net::log::Log::none(), Some(Duration::from_secs(3600))));
    let first = h.next_named("presence", Duration::from_secs(15)).await.expect("the first round");
    assert_eq!(first["id"], "h1");
    h.send(json!({"cmd":"net_changed"})).await;
    let again = h.next_named("presence", Duration::from_secs(15)).await.expect("a round right after the change");
    assert_eq!(again["id"], "h1");
}
