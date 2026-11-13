//! Test harness shared by the server tests: a relay on a temporary data dir and port, and fake
//! devices that dial it with their own identity.
#![allow(dead_code)]

use std::net::SocketAddr;
use std::time::Duration;

use anyhow::{bail, Result};
use rapp_net::log::Log;
use rapp_relay2::config::Config;
use rapp_relay2::server::{Opts, Relay};
use rapp_wire::line::read_json;
use rapp_wire::msg::{Push, Req};
use rapp_wire::tls::{self, BiStream, Expect};
use rapp_wire::{join_hash, Identity, Key};
use serde_json::Value;
use tempfile::TempDir;
use tokio::io::BufReader;
use tokio::sync::mpsc;

/// Upper bound for any single wait in a test, so a failure cannot hang the run.
pub const WAIT: Duration = Duration::from_secs(5);

pub struct TestRelay {
    pub relay: Relay,
    pub data: TempDir,
    pub key: Key,
    /// The configuration the relay was started with (reused by `restart`).
    pub config: Config,
}

fn opts(data: &TempDir, config: &Config) -> Opts {
    Opts {
        data: data.path().to_path_buf(),
        config: config.clone(),
        log: Log::file(data.path(), "relay.log"),
        enroll_from_env: false,
    }
}

/// A relay on `127.0.0.1:0` with a fresh data dir and no join hash: `key` is not set on it.
pub async fn start_relay_without_key(tweak: impl FnOnce(&mut Config)) -> TestRelay {
    let data = tempfile::tempdir().unwrap();
    let mut config = Config { listen: "127.0.0.1:0".parse().unwrap(), ..Config::default() };
    tweak(&mut config);
    let relay = Relay::start(opts(&data, &config)).await.expect("relay starts");
    let key = Key::new_for_relay(&relay.fp);
    TestRelay { relay, data, key, config }
}

/// A relay on `127.0.0.1:0` with a fresh data dir whose join hash is `key`'s.
pub async fn start_relay(tweak: impl FnOnce(&mut Config)) -> TestRelay {
    let r = start_relay_without_key(tweak).await;
    r.relay.registry().set_join_hash(&join_hash(&r.key.join())).unwrap();
    r
}

impl TestRelay {
    /// Stops the relay and starts a new one on the same data dir and config (new port).
    pub async fn restart(self) -> TestRelay {
        let TestRelay { relay, data, key, config } = self;
        relay.stop().await;
        let relay = Relay::start(opts(&data, &config)).await.expect("relay restarts");
        TestRelay { relay, data, key, config }
    }

    /// The relay's run log so far.
    pub fn log_text(&self) -> String {
        std::fs::read_to_string(self.data.path().join("relay.log")).unwrap_or_default()
    }
}

/// Audit records of event `ev`, after flushing what is pending.
pub fn audit_lines(r: &TestRelay, ev: &str) -> Vec<Value> {
    r.relay.audit().flush();
    rapp_relay2::audit::read(r.data.path(), None, None, Some(ev)).unwrap()
}

/// Another handle on the same key pair (Identity is not Clone).
pub fn same_identity(id: &Identity) -> Identity {
    Identity { cert: id.cert.clone(), key: id.key.clone_key(), fp: id.fp }
}

pub fn client_endpoint() -> quinn::Endpoint {
    quinn::Endpoint::client("127.0.0.1:0".parse().unwrap()).unwrap()
}

pub fn join_hex(key: &Key) -> String {
    data_encoding::HEXLOWER.encode(&key.join())
}

pub struct FakeDevice {
    pub id: Identity,
    pub conn: quinn::Connection,
    pub pushes: mpsc::UnboundedReceiver<(Push, Option<BiStream>)>,
    _endpoint: quinn::Endpoint,
}

impl FakeDevice {
    /// A new identity, pinning the relay's fingerprint.
    pub async fn dial(r: &TestRelay) -> FakeDevice {
        FakeDevice::dial_as(r, Identity::generate().unwrap()).await.expect("dial relay")
    }

    pub async fn dial_as(r: &TestRelay, id: Identity) -> Result<FakeDevice> {
        FakeDevice::dial_to(r.relay.addr, id, Expect::Pin(r.relay.fp.prefix16())).await
    }

    /// Dials `addr` from a fresh client endpoint; errors carry the `quinn::ConnectionError`.
    pub async fn dial_to(addr: SocketAddr, id: Identity, expect: Expect) -> Result<FakeDevice> {
        let endpoint = client_endpoint();
        let cc = tls::client_config(&id, tls::ALPN_RELAY, expect)?;
        let conn = tokio::time::timeout(WAIT, endpoint.connect_with(cc, addr, tls::SNI)?).await??;
        let (tx, pushes) = mpsc::unbounded_channel();
        tokio::spawn(pump(conn.clone(), tx));
        Ok(FakeDevice { id, conn, pushes, _endpoint: endpoint })
    }

    /// Opens a stream, writes `bytes` as they are, finishes, and reads one reply line.
    pub async fn raw(&self, bytes: &[u8]) -> Result<Value> {
        let (mut send, recv) = self.conn.open_bi().await?;
        send.write_all(bytes).await?;
        let _ = send.finish();
        let mut r = BufReader::new(recv);
        tokio::time::timeout(WAIT, read_json(&mut r, 64 * 1024)).await?
    }

    /// One request, one reply line.
    pub async fn req(&self, req: &Req) -> Value {
        let mut line = serde_json::to_vec(req).unwrap();
        line.push(b'\n');
        self.raw(&line).await.expect("request got a reply")
    }

    pub async fn enroll(&self, key: &Key) -> Value {
        self.req(&Req::Enroll { join: join_hex(key) }).await
    }
}

/// Hands every stream the relay opens to `tx`: bi streams with their first line read,
/// uni streams read whole. Ends quietly when the connection does.
async fn pump(conn: quinn::Connection, tx: mpsc::UnboundedSender<(Push, Option<BiStream>)>) {
    loop {
        tokio::select! {
            bi = conn.accept_bi() => {
                let Ok((send, mut recv)) = bi else { return };
                let tx = tx.clone();
                tokio::spawn(async move {
                    if let Ok(p) = read_push(&mut recv).await {
                        let _ = tx.send((p, Some(tls::bi((send, recv)))));
                    }
                });
            }
            uni = conn.accept_uni() => {
                let Ok(mut recv) = uni else { return };
                let tx = tx.clone();
                tokio::spawn(async move {
                    if let Ok(b) = recv.read_to_end(8192).await {
                        if let Ok(p) = serde_json::from_slice::<Push>(b.trim_ascii()) {
                            let _ = tx.send((p, None));
                        }
                    }
                });
            }
        }
    }
}

/// One line read a byte at a time, so the bytes after it stay in the stream.
async fn read_push(recv: &mut quinn::RecvStream) -> Result<Push> {
    let mut line = Vec::new();
    loop {
        let mut b = [0u8; 1];
        recv.read_exact(&mut b).await?;
        if b[0] == b'\n' {
            return Ok(serde_json::from_slice(&line)?);
        }
        line.push(b[0]);
        if line.len() > 8192 {
            bail!("push line too long");
        }
    }
}
