//! 规格 §5.3：分享方的 relay 连接上同时有一条大转发和一个会话时，会话的往返变慢多少。
//! 手动跑：cargo test -p rapp-testkit --test session_priority -- --ignored --nocapture
//!
//! VERDICT RULE (fixed before running):
//!   在 "wan" 配置下，转发优先级为 FORWARD_PRIORITY 的那一组，和同组没有转发时相比，
//!   会话往返的 p50 增加 ≤ 20 ms，且 p95 增加 ≤ 40 ms，算达标。
//!   不达标：如实写进测量文档，限速（或换拥塞控制）作为下一件交给用户定。不改阈值。

mod common;
use common::sharing::*;
use common::*;

use rapp_conn::relay::FORWARD_PRIORITY;
use rapp_net::line::read_json;
use rapp_testkit::weaknet::{self, Profile};
use serde_json::json;
use std::path::Path;
use std::sync::atomic::{AtomicU64, Ordering::Relaxed};
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;

const PHASE: Duration = Duration::from_secs(10);

struct Row {
    net: &'static str,
    prio: i32,
    base: (f64, f64),
    load: (f64, f64),
    mbps: f64,
}

impl Row {
    fn d50(&self) -> f64 {
        self.load.0 - self.base.0
    }
    fn d95(&self) -> f64 {
        self.load.1 - self.base.1
    }
    fn verdict(&self) -> &'static str {
        if self.net != "wan" || self.prio != FORWARD_PRIORITY {
            "-"
        } else if self.d50() <= 20.0 && self.d95() <= 40.0 {
            "达标"
        } else {
            "不达标"
        }
    }
}

/// A TCP server that writes to whoever connects, for as long as they read.
async fn firehose() -> u16 {
    let l = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = l.local_addr().unwrap().port();
    tokio::spawn(async move {
        while let Ok((mut c, _)) = l.accept().await {
            tokio::spawn(async move {
                let buf = vec![0x5au8; 64 * 1024];
                while c.write_all(&buf).await.is_ok() {}
            });
        }
    });
    port
}

/// 16-byte round trips every 20 ms for `PHASE`.
async fn rtts(s: &mut rapp_conn::Pipe) -> Vec<Duration> {
    let mut out = Vec::new();
    let end = Instant::now() + PHASE;
    let mut tick = tokio::time::interval(Duration::from_millis(20));
    tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    while Instant::now() < end {
        tick.tick().await;
        let t = Instant::now();
        s.write_all(&[7u8; 16]).await.unwrap();
        let mut got = [0u8; 16];
        tokio::time::timeout(Duration::from_secs(30), s.read_exact(&mut got)).await.expect("echo in time").unwrap();
        out.push(t.elapsed());
    }
    out
}

async fn one(net: &'static str, prio: i32) -> Row {
    let port = firehose().await;
    let rig = RelayRig::start_with_connect_limit(1000).await;
    let a_addr = if net == "wan" {
        let mut p = Profile::load(&Path::new(env!("CARGO_MANIFEST_DIR")).join("profiles/lan.json")).unwrap();
        p.rate_kbps = (20_000, 20_000);
        p.delay_ms = (15, 15);
        p.queue_ms = 100;
        p.seed = 7;
        weaknet::spawn_proxy(rig.addr.parse().unwrap(), p).await.to_string()
    } else {
        rig.addr.clone()
    };
    let a = service_on_relay_with(&a_addr, &rig.key, Some(vec![]), |o| o.forward_priority = prio).await;
    wait_status(&mut Ipc::open(&a.svc, a.home.path()).await, |s| s["relay"] == "connected").await;
    assert_eq!(ipc_once(&a.svc, a.home.path(), json!({"cmd":"share","ports":[port]})).await["ok"], true);
    let b = service_on_relay_with(&rig.addr, &rig.key, Some(vec![]), |_| {}).await;
    wait_status(&mut Ipc::open(&b.svc, b.home.path()).await, |s| s["relay"] == "connected").await;

    // The session: its own device identity, its own relay connection, to A.
    let v = visitor();
    let (_ep, conn) = relay_conn(&rig, &v.id, &rig.key).await;
    let mut s = relayed_request(&conn, &v.id, &a.id, &rig.key, json!({"op":"open","app":"com.example.echo"})).await;
    let r = tokio::time::timeout(WAIT, read_json(&mut s)).await.unwrap().unwrap();
    assert_eq!(r["ok"], true, "{r}");
    s.write_all(format!("{}\n", r["token"].as_str().unwrap()).as_bytes()).await.unwrap();
    let mut ok = [0u8; 3];
    tokio::time::timeout(WAIT, s.read_exact(&mut ok)).await.unwrap().unwrap();
    assert_eq!(&ok, b"ok\n");

    let base = rtts(&mut s).await;

    // The forward: B pulls from A's firehose through the relay.
    let token = std::fs::read_to_string(b.home.path().join("ipc.token")).unwrap().trim().to_string();
    let mut tcp = tokio::net::TcpStream::connect(("127.0.0.1", b.svc.ipc_port)).await.unwrap();
    let cmd = json!({"cmd":"pipe","to":format!("{}.rapp", a.id),"port":port});
    tcp.write_all(format!("{}\n{cmd}\n", json!({"token": token})).as_bytes()).await.unwrap();
    let mut line = Vec::new();
    while !line.ends_with(b"\n") {
        let mut one = [0u8; 1];
        assert_eq!(tokio::time::timeout(WAIT, tcp.read(&mut one)).await.unwrap().unwrap(), 1);
        line.push(one[0]);
    }
    let reply: serde_json::Value = serde_json::from_slice(&line).unwrap();
    assert_eq!(reply["ok"], true, "{reply}");
    let got = Arc::new(AtomicU64::new(0));
    let g = got.clone();
    let reader = tokio::spawn(async move {
        let mut buf = vec![0u8; 64 * 1024];
        while let Ok(n) = tcp.read(&mut buf).await {
            if n == 0 {
                break;
            }
            g.fetch_add(n as u64, Relaxed);
        }
    });
    tokio::time::sleep(Duration::from_secs(1)).await; // let the download ramp up before measuring
    let (bytes0, t0) = (got.load(Relaxed), Instant::now());
    let load = rtts(&mut s).await;
    let mbps = (got.load(Relaxed) - bytes0) as f64 * 8.0 / t0.elapsed().as_secs_f64() / 1e6;
    reader.abort();

    let q = |v: &[Duration]| (rapp_testkit::quantile_ms(v, 0.5), rapp_testkit::quantile_ms(v, 0.95));
    Row { net, prio, base: q(&base), load: q(&load), mbps }
}

#[tokio::test]
#[ignore = "manual measurement, about 90 s"]
async fn session_latency_under_a_big_forward() {
    let mut rows = Vec::new();
    for net in ["lan", "wan"] {
        for prio in [FORWARD_PRIORITY, 0] {
            rows.push(one(net, prio).await);
        }
    }
    eprintln!("{:<5}{:>5} | {:>14} | {:>14} | {:>14} | {:>9} | 判定", "网络", "优先", "基线 p50/p95", "有转发 p50/p95", "增加 p50/p95", "转发Mbps");
    for r in &rows {
        eprintln!(
            "{:<5}{:>5} | {:>6.1}/{:>6.1} | {:>6.1}/{:>6.1} | {:>6.1}/{:>6.1} | {:>9.1} | {}",
            r.net, r.prio, r.base.0, r.base.1, r.load.0, r.load.1, r.d50(), r.d95(), r.mbps, r.verdict()
        );
    }
}
