//! The client side of the relay: dial it (pinning its fingerprint), enroll, register, look up and
//! relay to other devices, and receive what the relay pushes.

use std::io;
use std::pin::Pin;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, OnceLock};
use std::task::{ready, Context, Poll};
use std::time::{Duration, Instant};

use anyhow::{anyhow, bail, Result};
use rapp_wire::line::read_json;
use rapp_wire::msg::{Push, Req};
use rapp_wire::tls::{self, BiStream, Expect};
use rapp_wire::{Fp, Identity, Key};
use serde_json::Value;
use tokio::io::{AsyncBufRead, AsyncBufReadExt, AsyncRead, AsyncReadExt, AsyncWrite, BufReader, ReadBuf};
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
/// The relay closes every device's connection with this code when its key is changed (`rotate-key`).
pub const CLOSE_KEY_CHANGED: u32 = 4;
/// What the relay answers a device that enrolled before the key changed and has not got the new one,
/// and the error of a request on a connection that ended because the key changed.
pub const KEY_CHANGED: &str = "key changed";

/// The relay closes a connection whose `enroll` had a wrong key with this code.
pub const CLOSE_BAD_KEY: u32 = 5;
/// What the relay answers an `enroll` with a wrong key (a device it does not know, or one whose
/// key was not changed).
pub const BAD_KEY: &str = "bad key";

/// The relay refused this device's key: `key changed` or `bad key`, else `None`. A client stops
/// on either until its key changes; dialing again would only be locked out.
///
/// Every error of this module that means a refused key is exactly one of the two texts (a link of
/// `e`'s chain); one error that merely mentions them is not one.
pub fn refused_key(e: &anyhow::Error) -> Option<&'static str> {
    e.chain().find_map(|c| refusal_of(&c.to_string()))
}

/// The relay changed its key since this device enrolled: it needs the new one.
pub fn is_key_changed(e: &anyhow::Error) -> bool {
    refused_key(e) == Some(KEY_CHANGED)
}

/// The relay does not take this device's key.
pub fn is_bad_key(e: &anyhow::Error) -> bool {
    refused_key(e) == Some(BAD_KEY)
}

fn refusal_of(text: &str) -> Option<&'static str> {
    [KEY_CHANGED, BAD_KEY].into_iter().find(|t| *t == text)
}

/// The refusal a close code means.
fn refusal_by_code(code: u64) -> Option<&'static str> {
    match code {
        c if c == u64::from(CLOSE_KEY_CHANGED) => Some(KEY_CHANGED),
        c if c == u64::from(CLOSE_BAD_KEY) => Some(BAD_KEY),
        _ => None,
    }
}

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

/// Counters of the connection to the relay (see `RelayConn::stats`).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct LinkStats {
    pub rtt: Duration,
    pub rx_datagrams: u64,
    pub lost: u64,
    pub sent: u64,
}

/// A connection to the relay. Cloning shares it.
#[derive(Clone)]
pub struct RelayConn {
    conn: quinn::Connection,
    join: String,
    enrolled: Arc<AtomicBool>,
    /// The relay answered `key changed` or `bad key` to an `enroll` (and then closes the connection).
    enroll_refused: Arc<OnceLock<&'static str>>,
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
        Ok(RelayConn {
            conn,
            join,
            enrolled: Arc::new(AtomicBool::new(false)),
            enroll_refused: Arc::new(OnceLock::new()),
            pushes: Arc::new(Mutex::new(pushes)),
        })
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

    /// Opens a byte stream to device `id` through the relay, for TLS only: the initiator must speak
    /// first (the target is not told of the stream before its first byte).
    ///
    /// The relay sends no line on success, only on failure, so a failure (`unknown id`, `offline`,
    /// `not enrolled`, `limit`, ...) comes as an io error on the first read whose text is exactly
    /// the relay's.
    ///
    /// The relay answers a `relay` request of an unenrolled connection with a reply line at once, so
    /// enrolling after seeing it would mean reading that line here. Instead this enrolls first when
    /// the connection is not yet known to be enrolled: an enrolled connection only loses its
    /// enrollment through revocation, which closes the connection.
    pub async fn relay_to(&self, id: &str) -> Result<Pipe> {
        // A success has no reply to tell "not enrolled" from, so make sure first (a no-op for a
        // device the relay already knows).
        if !self.enrolled.load(Ordering::Acquire) {
            self.enroll().await?;
        }
        let open = async {
            let (mut send, recv) = self.conn.open_bi().await?;
            let mut line = serde_json::to_vec(&Req::Relay { id: id.into() })?;
            line.push(b'\n');
            send.write_all(&line).await?;
            anyhow::Ok(tls::bi((send, recv)))
        };
        let io = open.await.map_err(|e| self.why(e))?;
        Ok(Box::new(Relaying::new(BufReader::new(io), self.clone())))
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

    /// Enrolls this connection unless it already is: a connection kept open must, or the relay's
    /// idle deadline for unenrolled connections closes it.
    pub async fn ensure_enrolled(&self) -> Result<()> {
        if self.enrolled.load(Ordering::Acquire) {
            return Ok(());
        }
        self.enroll().await
    }

    /// One round trip to the relay: a `{"op":"ping"}` line on a fresh stream. Relay 0.7.0 does
    /// not know the op and answers `bad request` (not audited, not rate-limited, not counted by
    /// `connect_backoff`); any reply line within `wait` means the relay is there.
    pub async fn probe(&self, wait: Duration) -> Result<Duration> {
        let start = Instant::now();
        let once = async {
            let (mut send, recv) = self.conn.open_bi().await?;
            send.write_all(b"{\"op\":\"ping\"}\n").await?;
            let _ = send.finish();
            let mut line = Vec::new();
            let mut r = BufReader::new(recv).take(MAX_REPLY as u64);
            r.read_until(b'\n', &mut line).await?;
            if line.is_empty() {
                bail!("no reply");
            }
            anyhow::Ok(())
        };
        match tokio::time::timeout(wait, once).await {
            Err(_) => bail!("timed out"),
            Ok(r) => r.map(|()| start.elapsed()),
        }
    }

    /// The QUIC connection's own counters: no packet is sent to read them.
    pub fn stats(&self) -> LinkStats {
        let s = self.conn.stats();
        LinkStats { rtt: self.conn.rtt(), rx_datagrams: s.udp_rx.datagrams, lost: s.path.lost_packets, sent: s.path.sent_packets }
    }

    /// The connection has ended (by either side); a closed one is dialed anew, not reused.
    pub fn is_closed(&self) -> bool {
        self.conn.close_reason().is_some()
    }

    /// `key changed` / `bad key` when this connection ended (or is ending) because the relay
    /// refused the key: closed with `CLOSE_KEY_CHANGED` / `CLOSE_BAD_KEY`, or its `enroll` was
    /// answered so. A client does not dial again with the same key.
    pub fn refused(&self) -> Option<&'static str> {
        let by_code = match self.conn.close_reason() {
            Some(quinn::ConnectionError::ApplicationClosed(c)) => refusal_by_code(c.error_code.into_inner()),
            _ => None,
        };
        by_code.or_else(|| self.enroll_refused.get().copied())
    }

    /// `e`, or `key changed` / `bad key` when the connection ended for that: a request cut off by
    /// the close would otherwise say `connection lost`.
    fn why(&self, e: anyhow::Error) -> anyhow::Error {
        match self.refused() {
            Some(text) => anyhow!(text),
            None => e,
        }
    }

    /// `e` of a relayed stream, or the refusal its connection ended for.
    fn why_io(&self, e: io::Error) -> io::Error {
        match self.refused() {
            Some(text) => io::Error::other(text),
            None => e,
        }
    }

    async fn enroll(&self) -> Result<()> {
        if let Err(e) = self.request(&Req::Enroll { join: self.join.clone() }).await {
            if let Some(text) = refused_key(&e) {
                let _ = self.enroll_refused.set(text);
            }
            return Err(e);
        }
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
        self.request_once(req).await.map_err(|e| self.why(e))
    }

    async fn request_once(&self, req: &Req) -> Result<Value> {
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
                Ok(recv) => { tokio::spawn(uni_push(conn.clone(), recv, tx.clone())); }
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

/// A `revoked` or `going_away` push that cannot be read is not dropped quietly: a lost revocation
/// list would leave the device trusting revoked devices. The connection is closed instead; the
/// caller reconnects and is sent the whole list again when it is admitted.
async fn uni_push(conn: quinn::Connection, mut recv: quinn::RecvStream, tx: mpsc::UnboundedSender<Pushed>) {
    let read = tokio::time::timeout(PUSH_LINE_WAIT, recv.read_to_end(MAX_PUSH)).await;
    let pushed = match read.ok().and_then(|r| r.ok()).map(|b| serde_json::from_slice::<Push>(b.trim_ascii())) {
        Some(Ok(Push::Revoked { fps })) => Pushed::Revoked(fps),
        Some(Ok(Push::GoingAway { after_ms })) => Pushed::GoingAway { after_ms },
        _ => {
            // Said here: the pump only sees its own close as `LocallyClosed`.
            let _ = tx.send(Pushed::Closed { code: 0, reason: "bad push".into() });
            return conn.close(0u32.into(), b"bad push");
        }
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
async fn read_line_exact<R: AsyncRead + Unpin>(recv: &mut R) -> Result<Vec<u8>> {
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
    /// The connection it is on, to tell a read or write cut off by a refused key (`why_io`).
    relay: RelayConn,
}

enum Peek {
    First,
    Failure(Vec<u8>),
    Data,
}

impl Relaying {
    fn new(io: BufReader<BiStream>, relay: RelayConn) -> Relaying {
        Relaying { io, state: Peek::First, relay }
    }

    fn poll_read_inner(mut self: Pin<&mut Self>, cx: &mut Context<'_>, out: &mut ReadBuf<'_>) -> Poll<io::Result<()>> {
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

impl AsyncRead for Relaying {
    fn poll_read(mut self: Pin<&mut Self>, cx: &mut Context<'_>, out: &mut ReadBuf<'_>) -> Poll<io::Result<()>> {
        let r = ready!(self.as_mut().poll_read_inner(cx, out));
        Poll::Ready(r.map_err(|e| self.relay.why_io(e)))
    }
}

impl AsyncWrite for Relaying {
    fn poll_write(mut self: Pin<&mut Self>, cx: &mut Context<'_>, b: &[u8]) -> Poll<io::Result<usize>> {
        let r = ready!(Pin::new(&mut self.io).poll_write(cx, b));
        Poll::Ready(r.map_err(|e| self.relay.why_io(e)))
    }
    fn poll_flush(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        let r = ready!(Pin::new(&mut self.io).poll_flush(cx));
        Poll::Ready(r.map_err(|e| self.relay.why_io(e)))
    }
    fn poll_shutdown(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        let r = ready!(Pin::new(&mut self.io).poll_shutdown(cx));
        Poll::Ready(r.map_err(|e| self.relay.why_io(e)))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::AsyncWriteExt;

    async fn line_of(len: usize) -> Result<Vec<u8>> {
        let (mut w, mut r) = tokio::io::duplex(64 * 1024);
        let write = tokio::spawn(async move {
            let mut bytes = vec![b' '; len];
            bytes.push(b'\n');
            let _ = w.write_all(&bytes).await;
        });
        let got = read_line_exact(&mut r).await;
        write.abort();
        got
    }

    #[tokio::test]
    async fn push_line_of_1_mib_is_read_one_byte_more_is_not() {
        assert_eq!(line_of(MAX_PUSH).await.unwrap().len(), MAX_PUSH);
        assert!(line_of(MAX_PUSH + 1).await.is_err());
    }
}
