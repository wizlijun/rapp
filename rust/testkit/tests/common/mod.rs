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

pub struct Hub {
    w: DuplexStream,
    lines: Lines<BufReader<DuplexStream>>,
    pub task: tokio::task::JoinHandle<anyhow::Result<()>>,
    pub home: PathBuf,
}

impl Hub {
    pub fn start(home: &Path, bins: &Path) -> Hub {
        Hub::start_with(home, bins, None)
    }

    /// Like `start`, with the presence probe running every `every`.
    pub fn start_with_presence(home: &Path, bins: &Path, every: Duration) -> Hub {
        Hub::start_with(home, bins, Some(every))
    }

    fn start_with(home: &Path, bins: &Path, every: Option<Duration>) -> Hub {
        let (cmd_r, cmd_w) = tokio::io::duplex(1 << 16);
        let (out_r, out_w) = tokio::io::duplex(1 << 16);
        let opts = rapp_hub::Opts {
            home: home.to_path_buf(),
            bin_dir: Some(bins.to_path_buf()),
            log: rapp_net::log::Log::file(&home.join("logs"), "hub.log"),
            presence_every: every,
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
