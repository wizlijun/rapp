//! rapp-service (spec §3): A side. Authenticates B, runs `rapp-host` workers, serves local IPC.

mod cm;
pub mod config;
mod data;
mod ipc;
mod peer;
mod relay_link;
mod state;
mod update;
mod workers;

use anyhow::{Context, Result};
use serde_json::json;
use config::{Config, DEFAULT_IPC_PORT, DEFAULT_PORT};
use rapp_net::log::{Log, Lvl};
use rapp_net::quic::ALPN_PEER;
use rapp_wire::tls::{device_server_config, ALPN_DEVICE};
use rapp_wire::Identity;
use state::State;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::task::JoinHandle;

pub use data::{DataOpts, SyncStatus};
pub use rapp_update::{Runner, SystemRunner};

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
    /// Runs every external program of the updater (`SystemRunner` in the real service).
    pub runner: Arc<dyn Runner>,
    /// None turns the updater off (not running from a `.app`).
    pub update: Option<UpdateOpts>,
    /// None: no `device.json`, no git (the testkit).
    pub data: Option<DataOpts>,
    /// The LAN addresses registered on the relay; None: this machine's own (`rapp_net::addr::lan_addrs`).
    pub advertise_lan: Option<Vec<String>>,
}

/// Where the running app is and the updater's timings (online-update plan Task 4).
#[derive(Clone, Debug)]
pub struct UpdateOpts {
    /// The `.app` this service runs from; it is what gets replaced.
    pub bundle: PathBuf,
    /// Started by launchd (parent pid 1): only then does an exit come back as the new version.
    pub launchd: bool,
    pub cache_dir: PathBuf,
    pub first_check: Duration,
    pub tick: Duration,
    /// How often a downloaded version tries to install by itself.
    pub idle_poll: Duration,
    /// How long a new version must run before its marker and zip are removed.
    pub healthy_after: Duration,
    /// How long a manual install waits for the GUI to go, and then for nobody to be using rapp.
    pub gui_wait: Duration,
}

impl UpdateOpts {
    pub fn system(bundle: PathBuf) -> Self {
        let home = std::env::var_os("HOME").map(PathBuf::from).unwrap_or_else(std::env::temp_dir);
        UpdateOpts {
            bundle,
            launchd: std::os::unix::process::parent_id() == 1,
            cache_dir: home.join("Library/Caches/rapp/update"),
            first_check: Duration::from_secs(30),
            tick: Duration::from_secs(3600),
            idle_poll: Duration::from_secs(60),
            healthy_after: Duration::from_secs(30),
            gui_wait: Duration::from_secs(10),
        }
    }
}

pub struct Service {
    /// UDP port of the peer endpoint.
    pub port: u16,
    pub ipc_port: u16,
    state: Arc<State>,
    tasks: Vec<JoinHandle<()>>,
    stopped: std::sync::atomic::AtomicBool,
}

impl Service {
    pub async fn start(opts: Opts) -> Result<Service> {
        let launchd = opts.log_dir.join("launchd.log");
        empty_if_over(&launchd, LAUNCHD_LOG_MAX);
        make_private(&launchd);
        let log = Log::file(&opts.log_dir, LOG_FILE);
        let cfg = Config::load_or_init(&opts.home)?;
        if cfg.legacy_dropped {
            log.event(Lvl::Info, "relay_legacy_dropped", json!({}));
        }
        let (port, ipc_port) = (cfg.port.unwrap_or(DEFAULT_PORT), cfg.ipc_port.unwrap_or(DEFAULT_IPC_PORT));
        let identity = Identity::load_or_create(&opts.home, "device")?;
        let paired = rapp_conn::Paired::load(&opts.home).unwrap_or_else(|e| {
            log.event(Lvl::Warn, "paired_error", json!({"err": format!("{e:#}")}));
            rapp_conn::Paired::empty(&opts.home)
        });
        let server = device_server_config(&identity, &[ALPN_DEVICE, ALPN_PEER])?;
        let endpoint = quinn::Endpoint::server(server, ([0, 0, 0, 0], port).into()).with_context(|| format!("bind udp port {port}"))?;
        let port = endpoint.local_addr()?.port();
        let listener = tokio::net::TcpListener::bind(("127.0.0.1", ipc_port)).await.with_context(|| format!("bind ipc 127.0.0.1:{ipc_port}"))?;
        let ipc_port = listener.local_addr()?.port();
        let ipc_token = rapp_net::crypto::random_hex(16);
        rapp_net::config::write_private(&opts.home.join("ipc.token"), ipc_token.as_bytes())?;

        let state = State {
            home: opts.home,
            bin_dir: opts.bin_dir,
            gui: opts.gui,
            endpoint: endpoint.clone(),
            port,
            cfg: Mutex::new(cfg),
            sessions: Mutex::default(),
            permissions: Mutex::new(serde_json::Value::Null),
            perms_lost: Mutex::new(false),
            workers: workers::Workers::new(opts.worker_idle),
            changed: tokio::sync::watch::channel(0).0,
            cm: Mutex::new(None),
            log,
            log_dir: opts.log_dir,
            runner: opts.runner,
            update: Mutex::default(),
            update_opts: opts.update,
            restart: tokio::sync::watch::channel(false).0,
            identity,
            paired,
            relay: Mutex::new(("off", None)),
            relay_settings: tokio::sync::watch::channel(0).0,
        };
        let id = state.cfg.lock().unwrap().id.clone();
        let version = env!("CARGO_PKG_VERSION");
        state.log.event(Lvl::Info, "service_start", json!({"version": version, "id": id, "port": port, "ipc_port": ipc_port}));
        let checked = workers::check(&state, false).await.unwrap_or(serde_json::json!({"screen_recording": false, "accessibility": false}));
        state.set_permissions(checked);
        let state = Arc::new(state);
        update::on_start(&state).await;
        let mut tasks = vec![
            tokio::spawn(peer::accept_loop(state.clone(), endpoint)),
            tokio::spawn(ipc::serve(state.clone(), listener, ipc_token)),
            update::spawn(state.clone()),
            relay_link::spawn(state.clone(), opts.advertise_lan),
        ];
        if let Some(data) = opts.data {
            let name = state.cfg.lock().unwrap().name.clone();
            if let Some(id) = id.as_deref() {
                if let Err(e) = data::write_device_json(&data.root, id, &name) {
                    state.log.event(Lvl::Warn, "data_error", json!({"step": "device.json", "err": format!("{e:#}")}));
                }
            }
            tasks.push(data::spawn(data, name, state.log.clone()));
        }
        Ok(Service { port, ipc_port, state, tasks, stopped: Default::default() })
    }

    /// Resolves once a new version has been put in place and this service should exit.
    pub fn restart_wanted(&self) -> impl std::future::Future<Output = ()> + Send + 'static {
        let mut rx = self.state.restart.subscribe();
        async move {
            if rx.wait_for(|r| *r).await.is_err() {
                std::future::pending::<()>().await;
            }
        }
    }

    /// Ends open sessions in the log first, so a stop (SIGTERM, ^C) leaves no session unclosed.
    pub fn stop(&self) {
        if self.stopped.swap(true, std::sync::atomic::Ordering::SeqCst) {
            return;
        }
        let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0, |d| d.as_secs());
        for (sid, s) in self.state.end_all() {
            let mut f = s.peer.session_fields(&s.app, s.side, sid);
            (f["secs"], f["reason"]) = (json!(now.saturating_sub(s.since)), json!("service stopped"));
            self.state.log.event(Lvl::Info, "session_end", f);
        }
        self.state.log.event(Lvl::Info, "service_stop", json!({}));
        self.state.log.flush();
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

/// launchd creates its log 0644; it can hold panic text, so keep it owner-only.
fn make_private(path: &std::path::Path) {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        if path.exists() {
            let _ = std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600));
        }
    }
    #[cfg(not(unix))]
    let _ = path;
}

impl Drop for Service {
    fn drop(&mut self) {
        self.stop();
    }
}
