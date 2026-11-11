use anyhow::{bail, Context, Result};
use rapp_net::log::Log;
use rapp_relay::{Opts, Relay, DEFAULT_LISTEN, TOKEN_TTL};

const USAGE: &str = "usage: rapp-relay --key <relay key> [--listen 0.0.0.0:21116] [--db relay.json]";

fn parse(args: &[String]) -> Result<Opts> {
    let (mut key, mut listen, mut db) = (None, DEFAULT_LISTEN.to_string(), "relay.json".to_string());
    let mut it = args.iter();
    while let Some(a) = it.next() {
        let mut val = || it.next().cloned().with_context(|| format!("{a} needs a value"));
        match a.as_str() {
            "--key" => key = Some(val()?),
            "--listen" => listen = val()?,
            "--db" => db = val()?,
            _ => bail!("unknown argument {a}"),
        }
    }
    Ok(Opts {
        key: key.context("--key is required")?,
        listen: listen.parse().with_context(|| format!("bad --listen {listen}"))?,
        db: db.into(),
        token_ttl: TOKEN_TTL,
        log: Log::stderr(),
    })
}

#[tokio::main]
async fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let opts = match parse(&args) {
        Ok(o) => o,
        Err(e) => {
            eprintln!("rapp-relay: {e:#}\n{USAGE}");
            std::process::exit(2);
        }
    };
    match Relay::start(opts) {
        Ok(_relay) => {
            let _ = tokio::signal::ctrl_c().await;
        }
        Err(e) => {
            eprintln!("rapp-relay: {e:#}");
            std::process::exit(1);
        }
    }
}
