//! rapp-relay (spec §2.2): device registry, ID/password check with rate limiting,
//! tokens, hole-punch hints and stream relaying. The single gate of the system (D8).

mod db;
mod limit;
mod server;

use anyhow::Result;
use rapp_net::log::{Lvl, Log};
use serde_json::json;
use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

pub const DEFAULT_LISTEN: &str = "0.0.0.0:22026";
pub const TOKEN_TTL: Duration = Duration::from_secs(24 * 3600);

pub struct Opts {
    pub listen: SocketAddr,
    pub key: String,
    pub db: PathBuf,
    pub token_ttl: Duration,
    /// Events of observability spec §4.2 (`Log::stderr()` in production: journald).
    pub log: Log,
}

pub struct Relay {
    pub addr: SocketAddr,
    endpoint: quinn::Endpoint,
    task: tokio::task::JoinHandle<()>,
}

impl Relay {
    /// Binds and starts serving on the current tokio runtime.
    pub fn start(opts: Opts) -> Result<Relay> {
        let endpoint = rapp_net::quic::server_endpoint(opts.listen, rapp_net::quic::ALPN_RELAY)?;
        let addr = endpoint.local_addr()?;
        let state = Arc::new(server::State::load(opts)?);
        state.log.event(Lvl::Info, "relay_start", json!({"listen": addr.to_string(), "devices": state.devices()}));
        let task = tokio::spawn(server::accept_loop(endpoint.clone(), state));
        Ok(Relay { addr, endpoint, task })
    }

    pub fn stop(&self) {
        self.endpoint.close(0u32.into(), b"relay stopped");
        self.task.abort();
    }
}

impl Drop for Relay {
    fn drop(&mut self) {
        self.stop();
    }
}
