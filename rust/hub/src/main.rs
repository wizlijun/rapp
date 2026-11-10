//! `rapp-hub` — no arguments. JSON-line commands on stdin, events on stdout (spec §4).
//! Env: `RAPP_HOME` (config dir; relay/key read from its service.json),
//! `RAPP_BIN_DIR` (where rapp-client lives), `RAPP_FORCE_PATH=relay|direct|lan`.

#[tokio::main]
async fn main() {
    if std::env::args().len() > 1 {
        eprintln!("usage: rapp-hub   (JSON lines on stdin/stdout; config: $RAPP_HOME)");
        std::process::exit(2);
    }
    let opts = rapp_hub::Opts {
        home: rapp_net::config::home(),
        bin_dir: rapp_net::bins::bin_dir_from_env(),
        force_path: std::env::var("RAPP_FORCE_PATH").ok(),
    };
    if let Err(e) = rapp_hub::run(opts, tokio::io::stdin(), tokio::io::stdout()).await {
        eprintln!("rapp-hub: {e:#}");
        std::process::exit(1);
    }
}
