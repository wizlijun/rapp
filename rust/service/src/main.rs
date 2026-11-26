//! `rapp-service` — no arguments. Data root: `$RAPP_HOME`, the `data-root` pointer file, or `~/rapp`.
//! Env: `RAPP_BIN_DIR` (where rapp-host lives), `RAPP_GUI` (the `rapp` GUI for `--cm`),
//! `RAPP_LOG_DIR` (where `service.log` goes; see `rapp_net::log::log_dir`).

use rapp_service::{autolock, DataOpts, LoadOpts, Opts, Service, SystemRunner, UpdateOpts, WORKER_IDLE};
use std::sync::Arc;

#[cfg(target_os = "linux")]
mod instance;

#[tokio::main]
async fn main() {
    if std::env::args().len() > 1 {
        eprintln!("usage: rapp-service   (data root: $RAPP_HOME, data-root pointer or ~/rapp)");
        std::process::exit(2);
    }
    // Claim ownership before migration, identity/token writes, or worker startup.
    // Keep it until process exit, including service shutdown and child cleanup.
    #[cfg(target_os = "linux")]
    let _instance = match instance::acquire() {
        Ok(Some(guard)) => guard,
        Ok(None) => {
            eprintln!("rapp-service: already running for this user");
            return;
        }
        Err(e) => {
            eprintln!("rapp-service: single-instance guard: {e}");
            std::process::exit(1);
        }
    };
    let root = rapp_net::config::home();
    if let Err(e) = rapp_net::datadir::prepare(&root, &rapp_net::config::legacy_dir()) {
        eprintln!("rapp-service: 数据目录 {}: {e:#}", root.display());
        std::process::exit(1);
    }
    let home = rapp_net::config::local(&root);
    let data = Some(DataOpts::system(root));
    let opts = Opts {
        home,
        bin_dir: rapp_net::bins::bin_dir_from_env(),
        gui: std::env::var_os("RAPP_GUI").map(Into::into),
        worker_idle: WORKER_IDLE,
        lock_grace: autolock::GRACE,
        log_dir: rapp_net::log::log_dir(),
        runner: Arc::new(SystemRunner),
        // Only a service running from a `.app` updates itself.
        data,
        advertise_lan: None,
        forward_sum_every: rapp_service::forward_log::SUM_EVERY,
        forward_priority: rapp_conn::relay::FORWARD_PRIORITY,
        channels: true,
        pacing: true,
        map_ports: rapp_service::MAP_PORTS,
        own_ports: true,
        load: Some(LoadOpts::system()),
        update: std::env::current_exe().ok().and_then(|e| rapp_update::bundle_of(&e)).map(UpdateOpts::system),
    };
    match Service::start(opts).await {
        Ok(svc) => {
            // Ports and id are in service.log (`service_start`).
            let restart = tokio::select! {
                _ = stopped() => false,
                _ = svc.restart_wanted() => true,
            };
            svc.stop();
            if restart {
                // A new version is in place: exit 0 and launchd's KeepAlive starts it.
                std::process::exit(0);
            }
        }
        Err(e) => {
            eprintln!("rapp-service: {e:#}");
            std::process::exit(1);
        }
    }
}

/// ^C, or SIGTERM (launchd/systemd stopping the service).
async fn stopped() {
    #[cfg(unix)]
    {
        use tokio::signal::unix::{signal, SignalKind};
        if let Ok(mut term) = signal(SignalKind::terminate()) {
            tokio::select! {
                _ = tokio::signal::ctrl_c() => {}
                _ = term.recv() => {}
            }
            return;
        }
    }
    let _ = tokio::signal::ctrl_c().await;
}
