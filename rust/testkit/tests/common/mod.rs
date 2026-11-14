//! Shared fixtures: service (with fake rapp-host), raw B client, IPC and hub drivers.
#![allow(dead_code)]

use quinn::{Connection, Endpoint};
use rapp_conn::{quic_facts, read_welcome, send_hello, Me, Pipe, Role};
use rapp_net::line::{read_json, write_json};
use rapp_net::quic::{bi, client_endpoint, connect, ALPN_PEER};
use rapp_service::{Runner, Service, UpdateOpts};
use rapp_update::fake::FakeRunner;
use serde_json::{json, Value};
use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;
use tempfile::TempDir;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader, DuplexStream, Lines};
use tokio::net::TcpStream;

pub const PASSWORD: &str = "a-pass-1";
pub const WAIT: Duration = Duration::from_secs(10);

/// A temp dir with `rapp-host` / `rapp-client` symlinked to the fake workers.
pub fn bins() -> TempDir {
    let dir = tempfile::tempdir().unwrap();
    for (name, target) in
        [("rapp-host", env!("CARGO_BIN_EXE_fake-rapp-host")), ("rapp-client", env!("CARGO_BIN_EXE_fake-rapp-client"))]
    {
        std::os::unix::fs::symlink(target, dir.path().join(name)).unwrap();
    }
    dir
}

pub fn host_log(bins: &Path) -> String {
    std::fs::read_to_string(bins.join("host.log")).unwrap_or_default()
}

pub struct TestService {
    pub svc: Service,
    pub home: TempDir,
    pub bins: TempDir,
    pub id: String,
}

pub fn service_json(home: &Path) {
    let cfg = json!({
        "id": null, "name": "test-a", "password": PASSWORD, "port": 0, "ipc_port": 0,
    });
    rapp_net::config::write_json(&home.join("service.json"), &cfg).unwrap();
}

pub async fn start_service(home: &Path, bins: &Path, idle: Duration) -> Service {
    Service::start(rapp_service::Opts {
        home: home.to_path_buf(),
        bin_dir: Some(bins.to_path_buf()),
        gui: None,
        worker_idle: idle,
        log_dir: home.join("logs"),
        runner: Arc::new(FakeRunner::new()),
        update: None,
        data: None,
        advertise_lan: None,
    })
    .await
    .unwrap()
}

/// A service with its external programs scripted by `runner` and the updater set up by `update`.
pub async fn start_service_with(
    home: &Path,
    bins: &Path,
    runner: Arc<dyn Runner>,
    update: Option<UpdateOpts>,
) -> Service {
    Service::start(rapp_service::Opts {
        home: home.to_path_buf(),
        bin_dir: Some(bins.to_path_buf()),
        gui: None,
        worker_idle: Duration::from_secs(60),
        log_dir: home.join("logs"),
        runner,
        update,
        data: None,
        advertise_lan: None,
    })
    .await
    .unwrap()
}

/// A service on a fresh home dir with the fake workers.
pub async fn service() -> TestService {
    service_with_idle(Duration::from_secs(60)).await
}

pub async fn service_with_idle(idle: Duration) -> TestService {
    let (home, bins) = (tempfile::tempdir().unwrap(), bins());
    service_json(home.path());
    let svc = start_service(home.path(), bins.path(), idle).await;
    let id = ipc_once(&svc, home.path(), json!({"cmd":"status"})).await["id"].as_str().unwrap().to_string();
    TestService { svc, home, bins, id }
}

/// Every line of `<home>/logs/<file>` so far.
pub fn read_log(home: &Path, file: &str) -> Vec<Value> {
    let text = std::fs::read_to_string(home.join("logs").join(file)).unwrap_or_default();
    text.lines().map(|l| serde_json::from_str(l).unwrap()).collect()
}

/// Every line of the service's `service.log` so far.
pub fn log_events(home: &Path) -> Vec<Value> {
    read_log(home, "service.log")
}

/// Waits for an `ev` line in `service.log` that `pred` accepts.
pub async fn wait_log(home: &Path, ev: &str, pred: impl Fn(&Value) -> bool) -> Value {
    wait_log_in(home, "service.log", ev, pred).await
}

/// Waits for an `ev` line in `<home>/logs/<file>` that `pred` accepts.
pub async fn wait_log_in(home: &Path, file: &str, ev: &str, pred: impl Fn(&Value) -> bool) -> Value {
    let deadline = tokio::time::Instant::now() + WAIT;
    loop {
        if let Some(v) = read_log(home, file).into_iter().find(|v| v["ev"] == ev && pred(v)) {
            return v;
        }
        assert!(tokio::time::Instant::now() < deadline, "no {ev} in {file}: {:?}", read_log(home, file));
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
}

// ---- IPC ----

pub struct Ipc {
    lines: Lines<BufReader<tokio::net::tcp::OwnedReadHalf>>,
    w: tokio::net::tcp::OwnedWriteHalf,
}

impl Ipc {
    pub async fn open(svc: &Service, home: &Path) -> Ipc {
        let token = std::fs::read_to_string(home.join("ipc.token")).unwrap();
        Ipc::open_with(svc, token.trim()).await
    }

    pub async fn open_with(svc: &Service, token: &str) -> Ipc {
        let tcp = TcpStream::connect(("127.0.0.1", svc.ipc_port)).await.unwrap();
        let (r, w) = tcp.into_split();
        let mut ipc = Ipc { lines: BufReader::new(r).lines(), w };
        ipc.send(json!({"token": token})).await;
        ipc
    }

    pub async fn send(&mut self, v: Value) {
        self.w.write_all(format!("{v}\n").as_bytes()).await.unwrap();
    }

    /// Next line, or Null on EOF.
    pub async fn next(&mut self) -> Value {
        let line = tokio::time::timeout(WAIT, self.lines.next_line()).await.expect("ipc reply").unwrap();
        line.map(|l| serde_json::from_str(&l).unwrap()).unwrap_or(Value::Null)
    }

    /// Sends a command and returns its reply, skipping pushed `changed` events.
    pub async fn call(&mut self, v: Value) -> Value {
        self.send(v).await;
        loop {
            let r = self.next().await;
            if r.get("event").is_none() {
                return r;
            }
        }
    }
}

pub async fn ipc_once(svc: &Service, home: &Path, cmd: Value) -> Value {
    Ipc::open(svc, home).await.call(cmd).await
}

// ---- raw B side ----

pub fn b_endpoint() -> Endpoint {
    client_endpoint("127.0.0.1:0".parse().unwrap()).unwrap()
}

pub async fn dial(ep: &Endpoint, addr: SocketAddr, alpn: &[u8]) -> Connection {
    connect(ep, addr, alpn, Duration::from_secs(2)).await.unwrap()
}

pub async fn req(conn: &Connection, v: Value) -> Value {
    let mut s = bi(conn.open_bi().await.unwrap());
    write_json(&mut s, &v).await.unwrap();
    read_json(&mut s).await.unwrap()
}

/// Direct QUIC connection to A authenticated with `auth`.
pub async fn direct(ep: &Endpoint, a: SocketAddr, auth: Value) -> (Connection, Value) {
    let conn = dial(ep, a, ALPN_PEER).await;
    let r = req(&conn, auth).await;
    (conn, r)
}

pub fn a_addr(svc: &Service) -> SocketAddr {
    SocketAddr::from(([127, 0, 0, 1], svc.port))
}

// ---- rapp/2 B side ----

/// A `rapp/2` connection to A showing `id`'s certificate.
pub async fn dial2(a: SocketAddr, id: &rapp_wire::Identity) -> Connection {
    let ep = b_endpoint();
    let cfg = rapp_wire::tls::device_client_config(id, rapp_wire::tls::ALPN_DEVICE).unwrap();
    let connecting = ep.connect_with(cfg, a, "rapp").unwrap();
    tokio::time::timeout(Duration::from_secs(5), connecting).await.expect("connect in time").unwrap()
}

/// The hello and one request on a fresh stream, written together as B does; the welcome is
/// checked through `quic_facts` and `read_welcome`. Returns the pipe positioned at the reply.
pub async fn hello_and_send(
    conn: &Connection,
    id: &rapp_wire::Identity,
    a_id: &str,
    key: Option<&rapp_wire::Key>,
    request: Value,
) -> anyhow::Result<Pipe> {
    let facts = quic_facts(conn, &id.fp, Role::Client)?;
    let mut pipe: Pipe = Box::new(bi(conn.open_bi().await?));
    send_hello(&mut pipe, &facts, &Me { id: "", name: "test-b", key }).await?;
    write_json(&mut pipe, &request).await?;
    tokio::time::timeout(WAIT, read_welcome(&mut pipe, &facts, key, a_id, None)).await??;
    Ok(pipe)
}

/// `hello_and_send` and the reply to the request.
pub async fn req2(
    conn: &Connection,
    id: &rapp_wire::Identity,
    a_id: &str,
    key: Option<&rapp_wire::Key>,
    request: Value,
) -> anyhow::Result<Value> {
    let mut pipe = hello_and_send(conn, id, a_id, key, request).await?;
    tokio::time::timeout(WAIT, read_json(&mut pipe)).await?
}

// ---- hub driver ----

/// The hub on stdin/stdout. `path` events (one per link the hub caches) come at any time, so `next`
/// sets them aside; `wait_path` and `take_paths` read them.
pub struct Hub {
    w: DuplexStream,
    lines: Lines<BufReader<DuplexStream>>,
    pub task: tokio::task::JoinHandle<anyhow::Result<()>>,
    pub home: PathBuf,
    paths: Vec<Value>,
}

impl Hub {
    pub fn start(home: &Path, bins: &Path) -> Hub {
        Hub::start_with(home, bins, None, Default::default())
    }

    /// Like `start`, with the presence probe running every `every`.
    pub fn start_with_presence(home: &Path, bins: &Path, every: Duration) -> Hub {
        Hub::start_with(home, bins, Some(every), Default::default())
    }

    /// Like `start`, with the LAN upgrade on `times` instead of the real ones.
    pub fn start_with_upgrade(home: &Path, bins: &Path, times: rapp_hub::UpgradeTimes) -> Hub {
        Hub::start_with(home, bins, None, times)
    }

    fn start_with(home: &Path, bins: &Path, every: Option<Duration>, upgrade: rapp_hub::UpgradeTimes) -> Hub {
        let (cmd_r, cmd_w) = tokio::io::duplex(1 << 16);
        let (out_r, out_w) = tokio::io::duplex(1 << 16);
        let opts = rapp_hub::Opts {
            home: home.to_path_buf(),
            bin_dir: Some(bins.to_path_buf()),
            log: rapp_net::log::Log::file(&home.join("logs"), "hub.log"),
            presence_every: every,
            upgrade,
        };
        let task = tokio::spawn(rapp_hub::run(opts, cmd_r, out_w));
        Hub { w: cmd_w, lines: BufReader::new(out_r).lines(), task, home: home.to_path_buf(), paths: Vec::new() }
    }

    pub async fn send(&mut self, v: Value) {
        self.w.write_all(format!("{v}\n").as_bytes()).await.unwrap();
    }

    /// The next event line, whatever it is.
    async fn next_any(&mut self) -> Value {
        let line = tokio::time::timeout(Duration::from_secs(15), self.lines.next_line())
            .await
            .expect("hub event in time")
            .unwrap()
            .expect("hub output open");
        serde_json::from_str(&line).unwrap()
    }

    /// The next event that is not a `path` event (those are kept for `wait_path` / `take_paths`).
    pub async fn next(&mut self) -> Value {
        loop {
            let v = self.next_any().await;
            if v["event"] != "path" {
                return v;
            }
            self.paths.push(v);
        }
    }

    /// Waits (within `WAIT`) for the `path` event `id` → `path`, dropping the `path` events before it
    /// and any other event read meanwhile (none may be an error).
    pub async fn wait_path(&mut self, id: &str, path: &str) {
        let want = json!({"event":"path","id":id,"path":path});
        if let Some(i) = self.paths.iter().position(|p| *p == want) {
            self.paths.drain(..=i);
            return;
        }
        self.paths.clear();
        let deadline = tokio::time::Instant::now() + WAIT;
        loop {
            let v = tokio::time::timeout_at(deadline, self.next_any()).await.expect("path event in time");
            assert_ne!(v["event"], "error", "{v}");
            if v == want {
                return;
            }
        }
    }

    /// The `path` events set aside so far, oldest first; clears them.
    pub fn take_paths(&mut self) -> Vec<Value> {
        std::mem::take(&mut self.paths)
    }

    pub async fn call(&mut self, v: Value) -> Value {
        self.send(v).await;
        self.next().await
    }

    /// Closes stdin and waits for the hub to exit; returns remaining events (`path` events left out).
    pub async fn finish(mut self) -> Vec<Value> {
        self.w.shutdown().await.unwrap();
        drop(self.w);
        let mut rest = Vec::new();
        while let Ok(Some(l)) = tokio::time::timeout(Duration::from_secs(10), self.lines.next_line()).await.unwrap() {
            let v: Value = serde_json::from_str(&l).unwrap();
            if v["event"] != "path" {
                rest.push(v);
            }
        }
        self.task.await.unwrap().unwrap();
        rest
    }
}

// ---- in-process relay ----

/// A relay on an ephemeral UDP port with its own data dir. `restart` brings it back on the same
/// port and data (so the key and the relay's fingerprint stay valid).
pub struct RelayRig {
    pub relay: Option<rapp_relay::server::Relay>,
    pub data: TempDir,
    pub key: rapp_wire::Key,
    pub addr: String,
}

impl RelayRig {
    pub async fn start() -> RelayRig {
        let data = tempfile::tempdir().unwrap();
        let relay = Self::boot(data.path(), "127.0.0.1:0".parse().unwrap()).await;
        let key = rapp_wire::Key::new_for_relay(&relay.fp);
        relay.registry().set_join_hash(&rapp_wire::join_hash(&key.join())).unwrap();
        let addr = relay.addr.to_string();
        RelayRig { relay: Some(relay), data, key, addr }
    }

    async fn boot(data: &Path, listen: SocketAddr) -> rapp_relay::server::Relay {
        let config = rapp_relay::config::Config { listen, ..Default::default() };
        let opts = rapp_relay::server::Opts {
            data: data.to_path_buf(),
            config,
            log: rapp_net::log::Log::file(data, "relay.log"),
            enroll_from_env: false,
        };
        rapp_relay::server::Relay::start(opts).await.expect("relay starts")
    }

    /// Streams the relay was asked to relay so far (audited ones, failures, and the short ones it only counts).
    pub fn streams(&self) -> u64 {
        let relay = self.relay.as_ref().expect("relay running");
        relay.audit().flush();
        let lines = rapp_relay::audit::read(self.data.path(), None, None, None).unwrap_or_default();
        lines
            .iter()
            .map(|v| match v["ev"].as_str() {
                Some("relayed") => 1,
                Some("probes") => v["n"].as_u64().unwrap_or(0),
                _ => 0,
            })
            .sum()
    }

    pub async fn stop(&mut self) {
        if let Some(r) = self.relay.take() {
            r.stop().await;
        }
    }

    pub async fn restart(&mut self) {
        self.stop().await;
        // The old socket is released a moment after `stop` returns.
        let listen: SocketAddr = self.addr.parse().unwrap();
        for _ in 0..50 {
            if std::net::UdpSocket::bind(listen).is_ok() {
                break;
            }
            tokio::time::sleep(Duration::from_millis(100)).await;
        }
        self.relay = Some(Self::boot(self.data.path(), listen).await);
    }
}

/// B's side of the relay: its own endpoint and identity, dialed in with `key`.
pub async fn relay_conn(
    rig: &RelayRig,
    id: &rapp_wire::Identity,
    key: &rapp_wire::Key,
) -> (Endpoint, rapp_conn::relay::RelayConn) {
    let ep = b_endpoint();
    let conn = tokio::time::timeout(WAIT, rapp_conn::relay::RelayConn::dial(&ep, &rig.addr, key, id))
        .await
        .expect("dial in time")
        .expect("dial");
    (ep, conn)
}

/// The service's status once `pred` accepts it (within `WAIT`).
pub async fn wait_status(ipc: &mut Ipc, pred: impl Fn(&Value) -> bool) -> Value {
    let deadline = tokio::time::Instant::now() + WAIT;
    loop {
        let st = ipc.call(json!({"cmd":"status"})).await;
        if pred(&st) {
            return st;
        }
        assert!(tokio::time::Instant::now() < deadline, "status never matched: {st}");
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
}

/// A service whose `service.json` already names `relay` and `key`; its LAN address is a dummy.
pub async fn service_on_relay(addr: &str, key: &rapp_wire::Key) -> TestService {
    service_on_relay_lan(addr, key, Some(vec!["127.0.0.1:1".into()])).await
}

/// Like `service_on_relay`, registering `lan` (None: the service's own addresses).
pub async fn service_on_relay_lan(addr: &str, key: &rapp_wire::Key, lan: Option<Vec<String>>) -> TestService {
    let (home, bins) = (tempfile::tempdir().unwrap(), bins());
    let cfg = json!({
        "id": null, "name": "test-a", "password": PASSWORD, "port": 0, "ipc_port": 0,
        "relay": addr, "key": key.to_string(),
    });
    rapp_net::config::write_json(&home.path().join("service.json"), &cfg).unwrap();
    let svc = Service::start(rapp_service::Opts {
        home: home.path().to_path_buf(),
        bin_dir: Some(bins.path().to_path_buf()),
        gui: None,
        worker_idle: Duration::from_secs(60),
        log_dir: home.path().join("logs"),
        runner: Arc::new(FakeRunner::new()),
        update: None,
        data: None,
        advertise_lan: lan,
    })
    .await
    .unwrap();
    let id = ipc_once(&svc, home.path(), json!({"cmd":"status"})).await["id"].as_str().unwrap().to_string();
    TestService { svc, home, bins, id }
}

/// A hub home whose `service.json` names the relay and the key.
pub fn hub_relay(home: &Path, addr: &str, key: &rapp_wire::Key) {
    rapp_net::config::write_json(&home.join("service.json"), &json!({"relay": addr, "key": key.to_string()})).unwrap();
}

/// A service on `rig` (registering `lan`; None: its own addresses), once it is connected there.
pub async fn a_on_relay(rig: &RelayRig, lan: Option<Vec<String>>) -> TestService {
    let a = service_on_relay_lan(&rig.addr, &rig.key, lan).await;
    let mut ipc = Ipc::open(&a.svc, a.home.path()).await;
    wait_status(&mut ipc, |s| s["relay"] == "connected").await;
    a
}

/// The hub's `hosts.json` as saved.
pub fn saved_hosts(home: &Path) -> Value {
    serde_json::from_slice(&std::fs::read(home.join("hosts.json")).unwrap()).unwrap()
}

/// The next hub event that is not a presence line (nor a `path` event).
pub async fn reply(hub: &mut Hub) -> Value {
    loop {
        let r = hub.next().await;
        if r["event"] != "presence" {
            return r;
        }
    }
}

/// Waits (within `WAIT`) for `presence` of `id` with `online`: offline says why, online says nothing more.
pub async fn next_presence(hub: &mut Hub, id: &str, online: bool) {
    let deadline = tokio::time::Instant::now() + WAIT;
    loop {
        let r = tokio::time::timeout_at(deadline, hub.next()).await.expect("presence in time");
        assert_ne!(r["event"], "error", "{r}");
        if (&r["event"], &r["id"], &r["online"]) == (&json!("presence"), &json!(id), &json!(online)) {
            // Offline says why; online says nothing more.
            assert_eq!(r["error"].as_str().is_some_and(|e| !e.is_empty()), !online, "{r}");
            return;
        }
    }
}

/// How many `connect` lookups the relay answered with `result`.
pub fn relay_connects(rig: &RelayRig, result: &str) -> usize {
    rig.relay.as_ref().expect("relay running").audit().flush();
    let lines = rapp_relay::audit::read(rig.data.path(), None, None, None).unwrap_or_default();
    lines.iter().filter(|v| v["ev"] == "connect" && v["result"] == result).count()
}

// ---- a LAN that can be cut ----

/// A UDP forwarder on `127.0.0.1:0` standing in for a host's LAN address: while open, what reaches it
/// goes on to the target (one upstream socket per sender, so replies find their way back); while
/// closed (the start), everything is dropped.
pub struct LanGate {
    addr: SocketAddr,
    open: Arc<std::sync::atomic::AtomicBool>,
    to: Arc<std::sync::Mutex<Option<SocketAddr>>>,
    task: tokio::task::JoinHandle<()>,
}

impl LanGate {
    pub async fn start() -> LanGate {
        let front = Arc::new(tokio::net::UdpSocket::bind("127.0.0.1:0").await.unwrap());
        let addr = front.local_addr().unwrap();
        let (open, to) = (Arc::new(std::sync::atomic::AtomicBool::new(false)), Arc::new(std::sync::Mutex::new(None)));
        let task = tokio::spawn(gate_forward(front, open.clone(), to.clone()));
        LanGate { addr, open, to, task }
    }

    pub fn addr(&self) -> String {
        self.addr.to_string()
    }

    /// Where packets go (for senders seen from now on).
    pub fn forward_to(&self, to: SocketAddr) {
        *self.to.lock().unwrap() = Some(to);
    }

    pub fn open(&self) {
        self.open.store(true, std::sync::atomic::Ordering::SeqCst);
    }

    pub fn close(&self) {
        self.open.store(false, std::sync::atomic::Ordering::SeqCst);
    }
}

impl Drop for LanGate {
    fn drop(&mut self) {
        self.task.abort();
    }
}

async fn gate_forward(
    front: Arc<tokio::net::UdpSocket>,
    open: Arc<std::sync::atomic::AtomicBool>,
    to: Arc<std::sync::Mutex<Option<SocketAddr>>>,
) {
    let is_open = |o: &std::sync::atomic::AtomicBool| o.load(std::sync::atomic::Ordering::SeqCst);
    let mut ups: std::collections::HashMap<SocketAddr, Arc<tokio::net::UdpSocket>> = Default::default();
    // The reply pumps end with this task (dropping the set aborts them).
    let mut pumps = tokio::task::JoinSet::new();
    let mut buf = vec![0u8; 65536];
    while let Ok((n, from)) = front.recv_from(&mut buf).await {
        let target = *to.lock().unwrap();
        let Some(target) = target.filter(|_| is_open(&open)) else { continue };
        let up = match ups.get(&from) {
            Some(up) => up.clone(),
            None => {
                let up = Arc::new(tokio::net::UdpSocket::bind("127.0.0.1:0").await.unwrap());
                up.connect(target).await.unwrap();
                let (back, front, open) = (up.clone(), front.clone(), open.clone());
                pumps.spawn(async move {
                    let mut buf = vec![0u8; 65536];
                    while let Ok(n) = back.recv(&mut buf).await {
                        if is_open(&open) {
                            let _ = front.send_to(&buf[..n], from).await;
                        }
                    }
                });
                ups.insert(from, up.clone());
                up
            }
        };
        let _ = up.send(&buf[..n]).await;
    }
}
