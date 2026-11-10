//! Shared fixtures: relay, service (with fake rapp-host), raw B client, IPC and hub drivers.
#![allow(dead_code)]

use quinn::{Connection, Endpoint};
use rapp_net::line::{read_json, write_json};
use rapp_net::quic::{bi, client_endpoint, connect, ALPN_PEER, ALPN_RELAY};
use rapp_relay::Relay;
use rapp_service::Service;
use serde_json::{json, Value};
use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::time::Duration;
use tempfile::TempDir;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader, DuplexStream, Lines};
use tokio::net::TcpStream;

pub const KEY: &str = "test-relay-key";
pub const PASSWORD: &str = "a-pass-1";
pub const WAIT: Duration = Duration::from_secs(10);

/// A temp dir with `rapp-host` / `rapp-client` symlinked to the fake workers.
pub fn bins() -> TempDir {
    let dir = tempfile::tempdir().unwrap();
    for (name, target) in [
        ("rapp-host", env!("CARGO_BIN_EXE_fake-rapp-host")),
        ("rapp-client", env!("CARGO_BIN_EXE_fake-rapp-client")),
    ] {
        std::os::unix::fs::symlink(target, dir.path().join(name)).unwrap();
    }
    dir
}

pub fn host_log(bins: &Path) -> String {
    std::fs::read_to_string(bins.join("host.log")).unwrap_or_default()
}

pub struct TestRelay {
    pub relay: Relay,
    _dir: TempDir,
}

pub fn relay(ttl: Duration) -> TestRelay {
    let dir = tempfile::tempdir().unwrap();
    let relay = Relay::start(rapp_relay::Opts {
        listen: "127.0.0.1:0".parse().unwrap(),
        key: KEY.into(),
        db: dir.path().join("relay.json"),
        token_ttl: ttl,
    })
    .unwrap();
    TestRelay { relay, _dir: dir }
}

pub struct TestService {
    pub svc: Service,
    pub home: TempDir,
    pub bins: TempDir,
    pub id: String,
}

pub fn service_json(home: &Path, relay: Option<SocketAddr>) {
    let cfg = json!({
        "relay": relay.map(|a| a.to_string()), "key": KEY, "id": null, "secret": "",
        "name": "test-a", "password": PASSWORD, "port": 0, "ipc_port": 0,
    });
    rapp_net::config::write_json(&home.join("service.json"), &cfg).unwrap();
}

pub async fn start_service(home: &Path, bins: &Path, idle: Duration) -> Service {
    Service::start(rapp_service::Opts {
        home: home.to_path_buf(),
        bin_dir: Some(bins.to_path_buf()),
        gui: None,
        worker_idle: idle,
    })
    .await
    .unwrap()
}

/// A service registered with `relay` (or relay-less when None); waits until registered.
pub async fn service(relay: Option<SocketAddr>) -> TestService {
    service_with_idle(relay, Duration::from_secs(60)).await
}

pub async fn service_with_idle(relay: Option<SocketAddr>, idle: Duration) -> TestService {
    let (home, bins) = (tempfile::tempdir().unwrap(), bins());
    service_json(home.path(), relay);
    let svc = start_service(home.path(), bins.path(), idle).await;
    let id = if relay.is_some() { wait_registered(&svc, home.path()).await } else { String::new() };
    TestService { svc, home, bins, id }
}

pub async fn wait_registered(svc: &Service, home: &Path) -> String {
    let deadline = tokio::time::Instant::now() + WAIT;
    loop {
        let st = ipc_once(svc, home, json!({"cmd":"status"})).await;
        if st["relay"] == "connected" {
            return st["id"].as_str().unwrap().to_string();
        }
        assert!(tokio::time::Instant::now() < deadline, "service never registered: {st}");
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

/// B's `connect` through the relay.
pub async fn relay_connect(ep: &Endpoint, relay: SocketAddr, id: &str, password: &str) -> (Connection, Value) {
    let conn = dial(ep, relay, ALPN_RELAY).await;
    let r = req(&conn, json!({"op":"connect","key":KEY,"id":id,"password":password})).await;
    (conn, r)
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

// ---- hub driver ----

pub struct Hub {
    w: DuplexStream,
    lines: Lines<BufReader<DuplexStream>>,
    pub task: tokio::task::JoinHandle<anyhow::Result<()>>,
    pub home: PathBuf,
}

impl Hub {
    /// Starts a hub whose config dir holds a service.json pointing at `relay`.
    pub fn start(home: &Path, bins: &Path, relay: Option<SocketAddr>, force: Option<&str>) -> Hub {
        if !home.join("service.json").exists() {
            service_json(home, relay);
        }
        let (cmd_r, cmd_w) = tokio::io::duplex(1 << 16);
        let (out_r, out_w) = tokio::io::duplex(1 << 16);
        let opts = rapp_hub::Opts {
            home: home.to_path_buf(),
            bin_dir: Some(bins.to_path_buf()),
            force_path: force.map(str::to_string),
        };
        let task = tokio::spawn(rapp_hub::run(opts, cmd_r, out_w));
        Hub { w: cmd_w, lines: BufReader::new(out_r).lines(), task, home: home.to_path_buf() }
    }

    pub async fn send(&mut self, v: Value) {
        self.w.write_all(format!("{v}\n").as_bytes()).await.unwrap();
    }

    pub async fn next(&mut self) -> Value {
        let line = tokio::time::timeout(Duration::from_secs(15), self.lines.next_line())
            .await
            .expect("hub event in time")
            .unwrap()
            .expect("hub output open");
        serde_json::from_str(&line).unwrap()
    }

    pub async fn call(&mut self, v: Value) -> Value {
        self.send(v).await;
        self.next().await
    }

    /// Closes stdin and waits for the hub to exit; returns remaining events.
    pub async fn finish(mut self) -> Vec<Value> {
        self.w.shutdown().await.unwrap();
        drop(self.w);
        let mut rest = Vec::new();
        while let Ok(Some(l)) = tokio::time::timeout(Duration::from_secs(10), self.lines.next_line()).await.unwrap() {
            rest.push(serde_json::from_str(&l).unwrap());
        }
        self.task.await.unwrap().unwrap();
        rest
    }
}
