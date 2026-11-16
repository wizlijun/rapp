//! 规格 §5.3：分享方的 relay 连接上同时有一条大转发和一个会话时，会话的往返变慢多少；
//! 以及同一条通道里，一条大转发旁边的一条小转发的往返变慢多少。
//! 手动跑：cargo test -p rapp-testkit --release --test session_priority -- --ignored --nocapture --test-threads 1
//!
//! VERDICT RULE (fixed before running), `session_latency_under_a_big_forward`:
//!   在 "wan" 配置下，转发优先级为 FORWARD_PRIORITY、pacing 为 true 的那一组，和同组没有转发时
//!   相比，会话往返的 p50 增加 ≤ 20 ms，且 p95 增加 ≤ 40 ms，算达标。
//!   不达标：照转发让路计划"计划定的"第 8 条处理——允许一轮调参（只改 pace.rs 的常数和规则），
//!   重跑三遍，两轮的数字都写进测量文档；还不达标就如实记下，交给用户。不改阈值。
//!   四组的优先级都是 FORWARD_PRIORITY：1b 已经量过，优先级 0 和 -1 没有差别，所以不再跑优先级 0。
//!
//! VERDICT RULE (fixed before running), `forward_alone_keeps_its_speed`:
//!   "wan"、pacing true、不开会话，只跑大转发：10 s 的下载速率 ≥ 18 Mbit/s 算达标
//!   （1b 量到约 19.5）。没有会话时让路不能拖慢转发。
//!
//! `small_forward_beside_a_bulk_one`: recorded, not judged (written before running). 规格没给
//!   同一通道里两条转发之间的要求；只记数，和会话那一项一起交给用户定（限速或拥塞控制）。
//!
//! `session_latency_after_the_ramp`: recorded, not judged (written before running). 和
//!   `session_latency_under_a_big_forward` 一样，但只跑 "wan"，等 30 s 让转发爬升到瓶颈以后
//!   再量 10 s：看让路在稳定状态下（减半规则真正起作用时）会话往返和转发速率是多少。
//!
//! `session_joins_a_running_forward`: recorded, not judged (written before running). "wan"，
//!   pacing true 和 false 各一组：会话单独跑 10 s 当基线，关掉；大转发先全速跑约 5 s，
//!   再开会话，量 10 s 的会话往返和转发速率：看会话后到时让路从全速降下来要多久、代价多少。

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
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};

const PHASE: Duration = Duration::from_secs(10);

struct Row {
    net: &'static str,
    pacing: bool,
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
        if self.net != "wan" || !self.pacing {
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
async fn rtts<S: AsyncRead + AsyncWrite + Unpin>(s: &mut S) -> Vec<Duration> {
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

/// p50 and p95 in ms.
fn q(v: &[Duration]) -> (f64, f64) {
    (rapp_testkit::quantile_ms(v, 0.5), rapp_testkit::quantile_ms(v, 0.95))
}

/// A relay, A sharing `ports` on it (behind the weak-network proxy for `wan`, its forwards at
/// `prio`, forward pacing as given), and B on it directly; both connected.
struct Pair {
    rig: RelayRig,
    a: TestService,
    b: TestService,
}

async fn pair(net: &str, prio: i32, pacing: bool, ports: &[u16]) -> Pair {
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
    let a = service_on_relay_with(&a_addr, &rig.key, Some(vec![]), |o| {
        o.forward_priority = prio;
        o.pacing = pacing;
    })
    .await;
    wait_status(&mut Ipc::open(&a.svc, a.home.path()).await, |s| s["relay"] == "connected").await;
    assert_eq!(ipc_once(&a.svc, a.home.path(), json!({"cmd":"share","ports":ports})).await["ok"], true);
    let b = service_on_relay_with(&rig.addr, &rig.key, Some(vec![]), |_| {}).await;
    wait_status(&mut Ipc::open(&b.svc, b.home.path()).await, |s| s["relay"] == "connected").await;
    Pair { rig, a, b }
}

impl Pair {
    /// B's `pipe` to A's `port`: the TCP connection, past the reply line.
    async fn pipe(&self, port: u16) -> TcpStream {
        let token = std::fs::read_to_string(self.b.home.path().join("ipc.token")).unwrap().trim().to_string();
        let mut tcp = TcpStream::connect(("127.0.0.1", self.b.svc.ipc_port)).await.unwrap();
        tcp.set_nodelay(true).unwrap();
        let cmd = json!({"cmd":"pipe","to":format!("{}.rapp", self.a.id),"port":port});
        tcp.write_all(format!("{}\n{cmd}\n", json!({"token": token})).as_bytes()).await.unwrap();
        let mut line = Vec::new();
        while !line.ends_with(b"\n") {
            let mut one = [0u8; 1];
            assert_eq!(tokio::time::timeout(WAIT, tcp.read(&mut one)).await.unwrap().unwrap(), 1);
            line.push(one[0]);
        }
        let reply: serde_json::Value = serde_json::from_slice(&line).unwrap();
        assert_eq!(reply, json!({"ok":true,"path":"relay"}));
        tcp
    }
}

/// A forward to the firehose, read on a task of its own until dropped.
struct Download {
    got: Arc<AtomicU64>,
    reader: tokio::task::JoinHandle<()>,
}

impl Download {
    fn start(mut tcp: TcpStream) -> Download {
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
        Download { got, reader }
    }

    /// Runs `f`; its output and the download rate meanwhile (Mbit/s).
    async fn during<T>(&self, f: impl std::future::Future<Output = T>) -> (T, f64) {
        let (bytes0, t0) = (self.got.load(Relaxed), Instant::now());
        let out = f.await;
        (out, (self.got.load(Relaxed) - bytes0) as f64 * 8.0 / t0.elapsed().as_secs_f64() / 1e6)
    }
}

impl Drop for Download {
    fn drop(&mut self) {
        self.reader.abort();
    }
}

/// Starts `tcp` (a forward to the firehose); once it has ramped up for `ramp`, the round trips of
/// `s` meanwhile, and the download rate over them (Mbit/s).
async fn beside_a_download<S: AsyncRead + AsyncWrite + Unpin>(tcp: TcpStream, s: &mut S, ramp: Duration) -> (Vec<Duration>, f64) {
    let dl = Download::start(tcp);
    tokio::time::sleep(ramp).await; // let the download ramp up before measuring
    dl.during(rtts(s)).await
}

/// A session on A from its own device identity over its own relay connection, past `ok\n`.
struct Session {
    s: rapp_conn::Pipe,
    _conn: rapp_conn::relay::RelayConn,
    _ep: quinn::Endpoint,
    _v: Visitor,
}

impl Pair {
    async fn session(&self) -> Session {
        let v = visitor();
        let (ep, conn) = relay_conn(&self.rig, &v.id, &self.rig.key).await;
        let mut s = relayed_request(&conn, &v.id, &self.a.id, &self.rig.key, json!({"op":"open","app":"com.example.echo"})).await;
        let r = tokio::time::timeout(WAIT, read_json(&mut s)).await.unwrap().unwrap();
        assert_eq!(r["ok"], true, "{r}");
        s.write_all(format!("{}\n", r["token"].as_str().unwrap()).as_bytes()).await.unwrap();
        let mut ok = [0u8; 3];
        tokio::time::timeout(WAIT, s.read_exact(&mut ok)).await.unwrap().unwrap();
        assert_eq!(&ok, b"ok\n");
        Session { s, _conn: conn, _ep: ep, _v: v }
    }
}

/// Session alone for `PHASE` (the base), then beside a big forward that has ramped for `ramp`.
async fn one(net: &'static str, pacing: bool, ramp: Duration) -> Row {
    let port = firehose().await;
    let t = pair(net, FORWARD_PRIORITY, pacing, &[port]).await;
    let mut s = t.session().await;
    let base = rtts(&mut s.s).await;
    // The forward: B pulls from A's firehose through the relay.
    let (load, mbps) = beside_a_download(t.pipe(port).await, &mut s.s, ramp).await;
    Row { net, pacing, base: q(&base), load: q(&load), mbps }
}

fn print_rows(rows: &[Row]) {
    eprintln!("{:<5}{:>6} | {:>14} | {:>14} | {:>14} | {:>9} | 判定", "网络", "让路", "基线 p50/p95", "有转发 p50/p95", "增加 p50/p95", "转发Mbps");
    for r in rows {
        eprintln!(
            "{:<5}{:>6} | {:>6.1}/{:>6.1} | {:>6.1}/{:>6.1} | {:>6.1}/{:>6.1} | {:>9.1} | {}",
            r.net, r.pacing, r.base.0, r.base.1, r.load.0, r.load.1, r.d50(), r.d95(), r.mbps, r.verdict()
        );
    }
}

#[tokio::test]
#[ignore = "manual measurement, about 86 s in release"]
async fn session_latency_under_a_big_forward() {
    let mut rows = Vec::new();
    // All four at FORWARD_PRIORITY: 1b showed priority 0 and -1 make no difference.
    for net in ["lan", "wan"] {
        for pacing in [true, false] {
            rows.push(one(net, pacing, Duration::from_secs(1)).await);
        }
    }
    print_rows(&rows);
}

#[tokio::test]
#[ignore = "manual measurement, record only, about 100 s in release"]
async fn session_latency_after_the_ramp() {
    let mut rows = Vec::new();
    for pacing in [true, false] {
        rows.push(one("wan", pacing, Duration::from_secs(30)).await);
    }
    // Record only: the 判定 column is the rule of the 1 s test, printed for comparison.
    print_rows(&rows);
}

#[tokio::test]
#[ignore = "manual measurement, record only, about 55 s in release"]
async fn session_joins_a_running_forward() {
    eprintln!("{:<5}{:>6} | {:>14} | {:>9} | {:>14} | {:>14} | {:>9}", "网络", "让路", "基线 p50/p95", "会话前Mbps", "有转发 p50/p95", "增加 p50/p95", "转发Mbps");
    for pacing in [true, false] {
        let port = firehose().await;
        let t = pair("wan", FORWARD_PRIORITY, pacing, &[port]).await;
        // The base: a session alone, then closed.
        let mut s = t.session().await;
        let base = q(&rtts(&mut s.s).await);
        drop(s);
        if pacing {
            wait_log(t.a.home.path(), "pace", |v| v["on"] == false).await;
        }
        // The forward runs at full speed (no session) for about 5 s before the session joins.
        let dl = Download::start(t.pipe(port).await);
        tokio::time::sleep(Duration::from_secs(1)).await;
        let ((), before) = dl.during(tokio::time::sleep(Duration::from_secs(4))).await;
        let mut s = t.session().await;
        let (load, mbps) = dl.during(rtts(&mut s.s)).await;
        let load = q(&load);
        eprintln!(
            "{:<5}{:>6} | {:>6.1}/{:>6.1} | {:>9.1} | {:>6.1}/{:>6.1} | {:>6.1}/{:>6.1} | {:>9.1}",
            "wan", pacing, base.0, base.1, before, load.0, load.1, load.0 - base.0, load.1 - base.1, mbps
        );
    }
}

#[tokio::test]
#[ignore = "manual measurement, about 25 s in release"]
async fn small_forward_beside_a_bulk_one() {
    // `wan`, as above; both forwards from B to A on one channel, the small one an echo.
    let (echo_port, _echo) = echo().await;
    let bulk_port = firehose().await;
    let t = pair("wan", FORWARD_PRIORITY, true, &[echo_port, bulk_port]).await;
    let mut small = t.pipe(echo_port).await;
    let alone = rtts(&mut small).await;
    let (load, mbps) = beside_a_download(t.pipe(bulk_port).await, &mut small, Duration::from_secs(1)).await;
    let home = t.a.home.path();
    let channels = log_events(home).iter().filter(|v| v["ev"] == "channel").count();
    assert_eq!(channels, 1, "both forwards on one channel");
    let (alone, load) = (q(&alone), q(&load));
    eprintln!("{:<5} | {:>14} | {:>14} | {:>14} | {:>9}", "网络", "单独 p50/p95", "有大转发 p50/p95", "增加 p50/p95", "大转发Mbps");
    eprintln!(
        "{:<5} | {:>6.1}/{:>6.1} | {:>6.1}/{:>6.1} | {:>6.1}/{:>6.1} | {:>9.1}",
        "wan", alone.0, alone.1, load.0, load.1, load.0 - alone.0, load.1 - alone.1, mbps
    );
}

#[tokio::test]
#[ignore = "manual measurement, about 12 s in release"]
async fn forward_alone_keeps_its_speed() {
    // `wan`, pacing on, no session: only the bulk forward. Pacing must not cost it speed.
    let port = firehose().await;
    let t = pair("wan", FORWARD_PRIORITY, true, &[port]).await;
    let mut tcp = t.pipe(port).await;
    read_for(&mut tcp, Duration::from_secs(1)).await; // let the download ramp up before measuring
    let mbps = read_for(&mut tcp, PHASE).await;
    let verdict = if mbps >= 18.0 { "达标" } else { "不达标" };
    eprintln!("{:<5} | {:>9} | 判定", "网络", "转发Mbps");
    eprintln!("{:<5} | {:>9.1} | {}", "wan", mbps, verdict);
}

/// Reads `tcp` for `d`; the rate over it in Mbit/s.
async fn read_for(tcp: &mut TcpStream, d: Duration) -> f64 {
    let mut buf = vec![0u8; 64 * 1024];
    let (mut bytes, t0) = (0u64, Instant::now());
    while t0.elapsed() < d {
        let n = tcp.read(&mut buf).await.unwrap();
        assert!(n > 0, "the firehose does not end");
        bytes += n as u64;
    }
    bytes as f64 * 8.0 / t0.elapsed().as_secs_f64() / 1e6
}
