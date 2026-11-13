//! `rapp-hub` — no arguments. JSON-line commands on stdin, events on stdout (spec §4).
//! Env: `RAPP_HOME` (data root: `$RAPP_HOME`, the `data-root` pointer or `~/rapp`; relay/key read from local/service.json),
//! `RAPP_BIN_DIR` (where rapp-client lives), `RAPP_FORCE_PATH=relay|direct|lan`,
//! `RAPP_LOG_DIR` (where `hub.log` goes; see `rapp_net::log::log_dir`).

use rapp_net::log::{Log, Lvl};

#[tokio::main]
async fn main() {
    if std::env::args().len() > 1 {
        eprintln!("usage: rapp-hub   (JSON lines on stdin/stdout; data root: $RAPP_HOME, data-root pointer or ~/rapp)");
        std::process::exit(2);
    }
    let log = Log::file(&rapp_net::log::log_dir(), "hub.log");
    let opts = rapp_hub::Opts {
        home: rapp_net::config::home(),
        bin_dir: rapp_net::bins::bin_dir_from_env(),
        force_path: std::env::var("RAPP_FORCE_PATH").ok(),
        log: log.clone(),
        presence_every: Some(std::time::Duration::from_secs(30)),
    };
    if let Err(e) = rapp_hub::run(opts, tokio::io::stdin(), tokio::io::stdout()).await {
        log.msg(Lvl::Error, format_args!("{e:#}"));
        log.flush();
        eprintln!("rapp-hub: {e:#}");
        std::process::exit(1);
    }
}
