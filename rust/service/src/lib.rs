//! rapp-service (spec §3): A side. Registers with the relay, authenticates peers,
//! lists apps, runs `rapp-host` workers and splices sessions, serves local IPC.

mod cm;
pub mod config;
mod ipc;
mod peer;
mod relay_link;
mod state;
mod workers;

use anyhow::{Context, Result};
use serde_json::json;
use config::{Config, DEFAULT_IPC_PORT, DEFAULT_PORT};
use rapp_net::log::{Log, Lvl};
use rapp_net::quic::{server_endpoint, ALPN_PEER};
use state::State;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::task::JoinHandle;

pub const WORKER_IDLE: Duration = Duration::from_secs(60);
/// The service's log in `Opts::log_dir` (observability spec §3).
pub const LOG_FILE: &str = "service.log";
/// launchd's catch-all for panics and pre-log output; emptied at start once past this.
const LAUNCHD_LOG_MAX: u64 = 5 * 1024 * 1024;

pub struct Opts {
    pub home: PathBuf,
    pub bin_dir: Option<PathBuf>,
    pub gui: Option<PathBuf>,
    pub worker_idle: Duration,
    /// Where `service.log` goes (`rapp_net::log::log_dir()` in the real service).
    pub log_dir: PathBuf,
}

pub struct Service {
    /// UDP port of the peer endpoint.
    pub port: u16,
    pub ipc_port: u16,
    state: Arc<State>,
    tasks: Vec<JoinHandle<()>>,
}

impl Service {
    pub async fn start(opts: Opts) -> Result<Service> {
        empty_if_over(&opts.log_dir.join("launchd.log"), LAUNCHD_LOG_MAX);
        let log = Log::file(&opts.log_dir, LOG_FILE);
        let cfg = Config::load_or_init(&opts.home)?;
        let (port, ipc_port) = (cfg.port.unwrap_or(DEFAULT_PORT), cfg.ipc_port.unwrap_or(DEFAULT_IPC_PORT));
        let endpoint = server_endpoint(([0, 0, 0, 0], port).into(), ALPN_PEER)?;
        let port = endpoint.local_addr()?.port();
        let listener = tokio::net::TcpListener::bind(("127.0.0.1", ipc_port)).await.with_context(|| format!("bind ipc 127.0.0.1:{ipc_port}"))?;
        let ipc_port = listener.local_addr()?.port();
        let ipc_token = rapp_net::crypto::random_hex(16);
        rapp_net::config::write_private(&opts.home.join("ipc.token"), ipc_token.as_bytes())?;

        let (relay_tx, relay_rx) = tokio::sync::mpsc::unbounded_channel();
        let state = State {
            home: opts.home,
            bin_dir: opts.bin_dir,
            gui: opts.gui,
            endpoint: endpoint.clone(),
            port,
            cfg: Mutex::new(cfg),
            tokens: Mutex::default(),
            sessions: Mutex::default(),
            relay: Mutex::new(("off", None)),
            permissions: Mutex::new(serde_json::Value::Null),
            workers: workers::Workers::new(opts.worker_idle),
            changed: tokio::sync::watch::channel(0).0,
            relay_cmd: relay_tx,
            cm: Mutex::new(None),
            log,
            log_dir: opts.log_dir,
        };
        let id = state.cfg.lock().unwrap().id.clone();
        let version = env!("CARGO_PKG_VERSION");
        state.log.event(Lvl::Info, "service_start", json!({"version": version, "id": id, "port": port, "ipc_port": ipc_port}));
        let checked = workers::check(&state, false).await.unwrap_or(serde_json::json!({"screen_recording": false, "accessibility": false}));
        state.set_permissions(checked);
        let state = Arc::new(state);
        let tasks = vec![
            tokio::spawn(peer::accept_loop(state.clone(), endpoint)),
            tokio::spawn(relay_link::run(state.clone(), relay_rx)),
            tokio::spawn(ipc::serve(state.clone(), listener, ipc_token)),
        ];
        Ok(Service { port, ipc_port, state, tasks })
    }

    pub fn stop(&self) {
        for t in &self.tasks {
            t.abort();
        }
        self.state.endpoint.close(0u32.into(), b"service stopped");
        self.state.workers.close_all();
    }
}

/// Truncates `path` once it is bigger than `max` (launchd keeps appending to the same file).
fn empty_if_over(path: &std::path::Path, max: u64) {
    if std::fs::metadata(path).is_ok_and(|m| m.len() > max) {
        let _ = std::fs::OpenOptions::new().write(true).open(path).and_then(|f| f.set_len(0));
    }
}

impl Drop for Service {
    fn drop(&mut self) {
        self.stop();
    }
}
