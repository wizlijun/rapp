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
use config::{Config, DEFAULT_IPC_PORT, DEFAULT_PORT};
use rapp_net::quic::{server_endpoint, ALPN_PEER};
use state::State;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::task::JoinHandle;

pub const WORKER_IDLE: Duration = Duration::from_secs(60);

pub struct Opts {
    pub home: PathBuf,
    pub bin_dir: Option<PathBuf>,
    pub gui: Option<PathBuf>,
    pub worker_idle: Duration,
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
        let cfg = Config::load_or_init(&opts.home)?;
        let (port, ipc_port) = (cfg.port.unwrap_or(DEFAULT_PORT), cfg.ipc_port.unwrap_or(DEFAULT_IPC_PORT));
        let endpoint = server_endpoint(([0, 0, 0, 0], port).into(), ALPN_PEER)?;
        let port = endpoint.local_addr()?.port();
        let listener = tokio::net::TcpListener::bind(("127.0.0.1", ipc_port)).await.with_context(|| format!("bind ipc 127.0.0.1:{ipc_port}"))?;
        let ipc_port = listener.local_addr()?.port();
        let ipc_token = rapp_net::crypto::random_hex(16);
        rapp_net::config::write_private(&opts.home.join("ipc.token"), ipc_token.as_bytes())?;

        let (relay_tx, relay_rx) = tokio::sync::mpsc::unbounded_channel();
        let mut state = State {
            home: opts.home,
            bin_dir: opts.bin_dir,
            gui: opts.gui,
            endpoint: endpoint.clone(),
            port,
            cfg: Mutex::new(cfg),
            tokens: Mutex::default(),
            sessions: Mutex::default(),
            relay: Mutex::new(("off", None)),
            permissions: serde_json::Value::Null,
            workers: workers::Workers::new(opts.worker_idle),
            changed: tokio::sync::watch::channel(0).0,
            relay_cmd: relay_tx,
            cm: Mutex::new(None),
        };
        state.permissions = workers::check(&state).await;
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

impl Drop for Service {
    fn drop(&mut self) {
        self.stop();
    }
}
