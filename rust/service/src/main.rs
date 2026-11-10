//! `rapp-service` — no arguments. Config dir: `RAPP_HOME` or the platform default.
//! Env: `RAPP_BIN_DIR` (where rapp-host lives), `RAPP_GUI` (the `rapp` GUI for `--cm`).

use rapp_service::{Opts, Service, WORKER_IDLE};

#[tokio::main]
async fn main() {
    if std::env::args().len() > 1 {
        eprintln!("usage: rapp-service   (config: $RAPP_HOME/service.json)");
        std::process::exit(2);
    }
    let home = rapp_net::config::home();
    let opts = Opts {
        home: home.clone(),
        bin_dir: rapp_net::bins::bin_dir_from_env(),
        gui: std::env::var_os("RAPP_GUI").map(Into::into),
        worker_idle: WORKER_IDLE,
    };
    match Service::start(opts).await {
        Ok(svc) => {
            eprintln!(
                "rapp-service: config {}, udp port {}, ipc 127.0.0.1:{}",
                home.display(),
                svc.port,
                svc.ipc_port
            );
            let _ = tokio::signal::ctrl_c().await;
            svc.stop();
        }
        Err(e) => {
            eprintln!("rapp-service: {e:#}");
            std::process::exit(1);
        }
    }
}
