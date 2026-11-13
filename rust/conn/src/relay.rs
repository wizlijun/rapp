//! The client side of the relay: dial it (pinning its fingerprint), enroll, register, look up and
//! relay to other devices, and receive what the relay pushes.

use std::io;
use std::pin::Pin;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::task::{ready, Context, Poll};
use std::time::Duration;

use anyhow::{anyhow, bail, Result};
use rapp_wire::line::read_json;
use rapp_wire::msg::{Push, Req};
use rapp_wire::tls::{self, BiStream, Expect};
use rapp_wire::{Fp, Identity, Key};
use serde_json::Value;
use tokio::io::{AsyncBufRead, AsyncRead, AsyncWrite, BufReader, ReadBuf};
use tokio::sync::{mpsc, Mutex};

use crate::Pipe;

/// Lines the relay pushes (`revoked` is the whole list on one line) may be this long; with 8 KiB
/// the list would be cut at about 120 fingerprints and a device would go on trusting revoked ones.
const MAX_PUSH: usize = 1024 * 1024;
/// A reply to a request is a short line.
const MAX_REPLY: usize = 8192;
/// A pushed stream whose first line does not arrive within this long is dropped.
const PUSH_LINE_WAIT: Duration = Duration::from_secs(10);
const DIAL_WAIT: Duration = Duration::from_secs(10);

/// What `connect` returns about a registered device.
#[derive(Debug, Clone, PartialEq)]
pub struct Found {
    pub lan: Vec<String>,
    pub public: String,
}

pub enum Pushed {
    /// Someone looked this device up; the caller writes `{"ok":true}` on `reply`.
    Incoming {
        peer: String,
        reply: Pipe,
    },
    /// Someone relays to this device: `stream` starts right after the `relayed` line.
    Relayed {
        peer: String,
        stream: Pipe,
    },
    /// The relay's whole list of revoked fingerprints.
    Revoked(Vec<Fp>),
    GoingAway {
        after_ms: u64,
    },
    /// The connection to the relay ended.
    Closed {
        code: u32,
        reason: String,
    },
}

/// A connection to the relay. Cloning shares it.
#[derive(Clone)]
pub struct RelayConn {
    conn: quinn::Connection,
    join: String,
    enrolled: Arc<AtomicBool>,
    pushes: Arc<Mutex<mpsc::UnboundedReceiver<Pushed>>>,
}

impl RelayConn {
    /// Connects to the relay at `addr`, which must have the fingerprint `key.relay`. Does not enroll.
    pub async fn dial(ep: &quinn::Endpoint, addr: &str, key: &Key, id: &Identity) -> Result<RelayConn> {
        let Some(pin) = key.relay else { bail!("relay not set: add the host as id@ip") };
        let unreachable = |e: &dyn std::fmt::Display| anyhow!("relay unreachable: {e}");
        let addr = rapp_net::quic::resolve(addr).await.map_err(|e| unreachable(&e))?;
        let cc = tls::client_config(id, tls::ALPN_RELAY, Expect::Pin(pin))?;
        let connecting = ep.connect_with(cc, addr, tls::SNI).map_err(|e| unreachable(&e))?;
        let conn = match tokio::time::timeout(DIAL_WAIT, connecting).await {
            Err(_) => return Err(unreachable(&"timed out")),
            Ok(Err(quinn::ConnectionError::TransportError(e))) if e.to_string().contains("crypto") => {
                bail!("relay identity mismatch")
            }
            Ok(Err(e)) => return Err(unreachable(&e)),
            Ok(Ok(c)) => c,
        };
        let (tx, pushes) = mpsc::unbounded_channel();
        tokio::spawn(pump(conn.clone(), tx));
        let join = data_encoding::HEXLOWER.encode(&key.join());
        Ok(RelayConn { conn, join, enrolled: Arc::new(AtomicBool::new(false)), pushes: Arc::new(Mutex::new(pushes)) })
    }

    pub async fn register(&self, id: &str, lan: &[String]) -> Result<()> {
        self.request_enrolling(&Req::Register { id: id.into(), lan: lan.to_vec() }).await?;
        Ok(())
    }

    pub async fn connect_to(&self, id: &str) -> Result<Found> {
        let v = self.request_enrolling(&Req::Connect { id: id.into() }).await?;
        let strings = |k: &str| -> Vec<String> {
            v[k].as_array().map(|a| a.iter().filter_map(|s| s.as_str().map(String::from)).collect()).unwrap_or_default()
        };
        let public = v["public"].as_str().unwrap_or_default().to_string();
        Ok(Found { lan: strings("lan"), public })
    }

    /// Opens a byte stream to device `id` through the relay. The relay answers only a failure, with
    /// one line: it comes out as the error of the first read.
    pub async fn relay_to(&self, id: &str) -> Result<Pipe> {
        // A success has no reply to tell "not enrolled" from, so make sure first (a no-op for a
        // device the relay already knows).
        if !self.enrolled.load(Ordering::Acquire) {
            self.enroll().await?;
        }
        let (mut send, recv) = self.conn.open_bi().await?;
        let mut line = serde_json::to_vec(&Req::Relay { id: id.into() })?;
        line.push(b'\n');
        send.write_all(&line).await?;
        Ok(Box::new(Relaying::new(BufReader::new(tls::bi((send, recv))))))
    }

    /// The next push from the relay; `Closed` when the connection ends (and from then on).
    pub async fn next_push(&self) -> Result<Pushed> {
        match self.pushes.lock().await.recv().await {
            Some(p) => Ok(p),
            None => Ok(Pushed::Closed { code: 0, reason: "closed".into() }),
        }
    }

    pub fn close(&self) {
        self.conn.close(0u32.into(), b"bye");
    }

    async fn enroll(&self) -> Result<()> {
        self.request(&Req::Enroll { join: self.join.clone() }).await?;
        self.enrolled.store(true, Ordering::Release);
        Ok(())
    }

    /// `req`; on `not enrolled`, enroll and try once more.
    async fn request_enrolling(&self, req: &Req) -> Result<Value> {
        match self.request(req).await {
            Err(e) if e.to_string() == "not enrolled" => {
                self.enroll().await?;
                self.request(req).await
            }
            Ok(v) => {
                self.enrolled.store(true, Ordering::Release);
                Ok(v)
            }
            e => e,
        }
    }

    /// One request, one reply line; `{"ok":false,"error":e}` is the error `e`.
    async fn request(&self, req: &Req) -> Result<Value> {
        let (mut send, recv) = self.conn.open_bi().await?;
        let mut line = serde_json::to_vec(req)?;
        line.push(b'\n');
        send.write_all(&line).await?;
        let _ = send.finish();
        let v = read_json(&mut BufReader::new(recv), MAX_REPLY).await?;
        if v["ok"] == true {
            return Ok(v);
        }
        bail!("{}", v["error"].as_str().unwrap_or("bad reply"))
    }
}

/// Hands every stream the relay opens on to the channel, each on its own task; ends with `Closed`.
async fn pump(conn: quinn::Connection, tx: mpsc::UnboundedSender<Pushed>) {
    let end = loop {
        tokio::select! {
            bi = conn.accept_bi() => match bi {
                Ok((send, recv)) => { tokio::spawn(bi_push(send, recv, tx.clone())); }
                Err(e) => break e,
            },
            uni = conn.accept_uni() => match uni {
                Ok(recv) => { tokio::spawn(uni_push(recv, tx.clone())); }
                Err(e) => break e,
            },
        }
    };
    let (code, reason) = match end {
        quinn::ConnectionError::ApplicationClosed(c) => (
            u32::try_from(u64::from(c.error_code)).unwrap_or(u32::MAX),
            String::from_utf8_lossy(&c.reason).into_owned(),
        ),
        e => (0, e.to_string()),
    };
    let _ = tx.send(Pushed::Closed { code, reason });
}

async fn uni_push(mut recv: quinn::RecvStream, tx: mpsc::UnboundedSender<Pushed>) {
    let Ok(Ok(bytes)) = tokio::time::timeout(PUSH_LINE_WAIT, recv.read_to_end(MAX_PUSH)).await else { return };
    let pushed = match serde_json::from_slice::<Push>(bytes.trim_ascii()) {
        Ok(Push::Revoked { fps }) => Pushed::Revoked(fps),
        Ok(Push::GoingAway { after_ms }) => Pushed::GoingAway { after_ms },
        _ => return,
    };
    let _ = tx.send(pushed);
}

async fn bi_push(send: quinn::SendStream, mut recv: quinn::RecvStream, tx: mpsc::UnboundedSender<Pushed>) {
    let Ok(Ok(line)) = tokio::time::timeout(PUSH_LINE_WAIT, read_line_exact(&mut recv)).await else { return };
    let stream = BufReader::new(tls::bi((send, recv)));
    let pushed = match serde_json::from_slice::<Push>(&line) {
        Ok(Push::Incoming { peer, .. }) => Pushed::Incoming { peer, reply: Box::new(stream) },
        Ok(Push::Relayed { peer, .. }) => {
            // The initiator speaks first (it is the TLS client): a stream that ends before any byte
            // is a request the relay gave up on, not a connection.
            let mut stream = stream;
            match std::future::poll_fn(|cx| Pin::new(&mut stream).poll_fill_buf(cx).map_ok(|b| b.is_empty())).await {
                Ok(false) => Pushed::Relayed { peer, stream: Box::new(stream) },
                _ => return,
            }
        }
        _ => return,
    };
    let _ = tx.send(pushed);
}

/// One line a byte at a time, so the bytes after it stay in the stream.
async fn read_line_exact(recv: &mut quinn::RecvStream) -> Result<Vec<u8>> {
    let mut line = Vec::new();
    loop {
        let mut b = [0u8; 1];
        recv.read_exact(&mut b).await?;
        if b[0] == b'\n' {
            return Ok(line);
        }
        line.push(b[0]);
        if line.len() > MAX_PUSH {
            bail!("push line too long");
        }
    }
}

/// The stream of a `relay` request. Until the first byte arrives it may turn out to be the relay's
/// one-line failure (`{"ok":false,...}`; the target's bytes are TLS and never start with `{`):
/// then reads fail with the relay's error text.
struct Relaying {
    io: BufReader<BiStream>,
    state: Peek,
}

enum Peek {
    First,
    Failure(Vec<u8>),
    Data,
}

impl Relaying {
    fn new(io: BufReader<BiStream>) -> Relaying {
        Relaying { io, state: Peek::First }
    }
}

impl AsyncRead for Relaying {
    fn poll_read(mut self: Pin<&mut Self>, cx: &mut Context<'_>, out: &mut ReadBuf<'_>) -> Poll<io::Result<()>> {
        loop {
            let me = &mut *self;
            match &mut me.state {
                Peek::Data => return Pin::new(&mut me.io).poll_read(cx, out),
                Peek::First => {
                    let buf = ready!(Pin::new(&mut me.io).poll_fill_buf(cx))?;
                    me.state = if buf.first() == Some(&b'{') { Peek::Failure(Vec::new()) } else { Peek::Data };
                }
                Peek::Failure(line) => {
                    let buf = ready!(Pin::new(&mut me.io).poll_fill_buf(cx))?;
                    let (used, done) = match buf.iter().position(|&b| b == b'\n') {
                        Some(i) => (i, true),
                        None => (buf.len(), buf.is_empty()),
                    };
                    line.extend_from_slice(&buf[..used]);
                    let n = if done && !buf.is_empty() { used + 1 } else { used };
                    Pin::new(&mut me.io).consume(n);
                    if done || line.len() > MAX_REPLY {
                        let text = serde_json::from_slice::<Value>(line)
                            .ok()
                            .and_then(|v| v["error"].as_str().map(String::from))
                            .unwrap_or_else(|| "bad reply".into());
                        return Poll::Ready(Err(io::Error::other(text)));
                    }
                }
            }
        }
    }
}

impl AsyncWrite for Relaying {
    fn poll_write(mut self: Pin<&mut Self>, cx: &mut Context<'_>, b: &[u8]) -> Poll<io::Result<usize>> {
        Pin::new(&mut self.io).poll_write(cx, b)
    }
    fn poll_flush(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut self.io).poll_flush(cx)
    }
    fn poll_shutdown(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut self.io).poll_shutdown(cx)
    }
}
