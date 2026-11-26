//! The service's local IPC: JSON lines over TCP 127.0.0.1, the token line first. The token and
//! the port are read again on every connect: the service changes the token each time it starts.

use serde_json::{json, Value};
use std::path::{Path, PathBuf};
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::tcp::{OwnedReadHalf, OwnedWriteHalf};
use tokio::net::TcpStream;

const DEFAULT_IPC_PORT: u16 = 22029;

/// The service cannot be reached, or did not answer in time.
#[derive(Debug)]
pub struct Gone;

fn local_dir() -> PathBuf {
    match std::env::var_os("RAPP_LOCAL").filter(|v| !v.is_empty()) {
        Some(dir) => dir.into(),
        None => rapp_net::config::local(&rapp_net::config::home()),
    }
}

fn ipc_port(local: &Path) -> u16 {
    std::fs::read(local.join("service.json"))
        .ok()
        .and_then(|b| serde_json::from_slice::<Value>(&b).ok())
        .and_then(|v| v["ipc_port"].as_u64())
        .and_then(|p| u16::try_from(p).ok())
        .filter(|&p| p != 0)
        .unwrap_or(DEFAULT_IPC_PORT)
}

/// A connection with the token line already sent.
async fn connect() -> Option<TcpStream> {
    let local = local_dir();
    let token = std::fs::read_to_string(local.join("ipc.token")).ok()?;
    let mut tcp = TcpStream::connect(("127.0.0.1", ipc_port(&local))).await.ok()?;
    tcp.write_all(format!("{}\n", json!({"token": token.trim()})).as_bytes()).await.ok()?;
    Some(tcp)
}

/// Sends `cmd` and reads its one reply line; the stream stays open for what follows (`pipe`).
pub async fn open(cmd: Value) -> Result<(Value, BufReader<OwnedReadHalf>, OwnedWriteHalf), Gone> {
    let tcp = connect().await.ok_or(Gone)?;
    let (r, mut w) = tcp.into_split();
    w.write_all(format!("{cmd}\n").as_bytes()).await.map_err(|_| Gone)?;
    let mut r = BufReader::new(r);
    let mut line = String::new();
    match r.read_line(&mut line).await {
        Ok(n) if n > 0 => {}
        _ => return Err(Gone),
    }
    let v = serde_json::from_str(&line).map_err(|_| Gone)?;
    Ok((v, r, w))
}

/// One command on its own connection, which is closed as soon as the reply is in (the service
/// starts an install once the asking connection is gone). Gone after `wait`.
pub async fn call(cmd: Value, wait: Duration) -> Result<Value, Gone> {
    match tokio::time::timeout(wait, open(cmd)).await {
        Ok(Ok((v, ..))) => Ok(v),
        _ => Err(Gone),
    }
}
