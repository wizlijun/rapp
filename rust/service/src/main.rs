//! `rapp-service` — no arguments. Data root: `$RAPP_HOME`, the `data-root` pointer file, or `~/rapp`.
//! Env: `RAPP_BIN_DIR` (where rapp-host lives), `RAPP_GUI` (the `rapp` GUI for `--cm`),
//! `RAPP_LOG_DIR` (where `service.log` goes; see `rapp_net::log::log_dir`).

use rapp_service::{Opts, Service, SystemRunner, UpdateOpts, WORKER_IDLE};
use std::sync::Arc;

#[tokio::main]
async fn main() {
    if std::env::args().len() > 1 {
        eprintln!("usage: rapp-service   (data root: $RAPP_HOME, data-root pointer or ~/rapp)");
        std::process::exit(2);
    }
    let home = rapp_net::config::home();
    let opts = Opts {
        home,
        bin_dir: rapp_net::bins::bin_dir_from_env(),
        gui: std::env::var_os("RAPP_GUI").map(Into::into),
        worker_idle: WORKER_IDLE,
        log_dir: rapp_net::log::log_dir(),
        runner: Arc::new(SystemRunner),
        // Only a service running from a `.app` updates itself.
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
