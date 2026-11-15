//! A small stream multiplexer: many byte streams inside one channel (an end-to-end TLS pipe
//! relayed between two devices), so each forwarded connection costs one round trip instead of
//! its own relay stream and TLS handshake.
//!
//! Frames are `type u8 | id u32 BE | len u16 BE | payload`. Only the client (the visitor) opens
//! streams, with odd increasing ids. Each stream has a credit window per direction; a stream
//! nobody reads only ever holds its own window, so it cannot block the others.
//!
//! One reader task and one writer task per channel. The shared state sits under one
//! `std::sync::Mutex`; no io happens under it. When the channel closes both tasks end.
//!
//! Dropping every `Mux`, `Incoming` and `MuxStream` handle aborts the channel, it does not
//! close it gracefully: output still queued (including FINs) is thrown away and the reason
//! is "closed", the same as `Mux::close()`.

use std::collections::{HashMap, VecDeque};
use std::future::{poll_fn, Future};
use std::io;
use std::pin::Pin;
use std::sync::{Arc, Mutex, MutexGuard};
use std::task::{Context, Poll, Waker};
use std::time::Duration;

use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt, BufReader, ReadBuf};
use tokio::sync::{watch, Notify};
use tokio::time::Instant;

pub const MAX_FRAME: usize = 16 * 1024;
pub const WINDOW: u32 = 1 << 20;
pub const MAX_STREAMS: usize = 1024;
pub const PING_EVERY: Duration = Duration::from_secs(10);
pub const DEAD_AFTER: Duration = Duration::from_secs(30);
pub const CHANNEL_IDLE: Duration = Duration::from_secs(300);

pub type Reader = Box<dyn AsyncRead + Unpin + Send>;
pub type Writer = Box<dyn AsyncWrite + Unpin + Send>;

const OPEN: u8 = 1;
const DATA: u8 = 2;
const FIN: u8 = 3;
const RST: u8 = 4;
const CREDIT: u8 = 5;
const PING: u8 = 6;
const PONG: u8 = 7;

const HEAD: usize = 7;
/// Unsent bytes one stream may hold; a full buffer makes `poll_write` wait.
const SEND_BUF: usize = 64 * 1024;
/// The writer stops adding frames to one write once it holds this much.
const BATCH: usize = 64 * 1024;
/// How long a closing writer tries to shut the lower half down cleanly.
const SHUTDOWN_GRACE: Duration = Duration::from_secs(1);

/// A byte queue: appended at the back, consumed at the front.
#[derive(Default)]
struct Bytes {
    data: Vec<u8>,
    pos: usize,
}

impl Bytes {
    fn len(&self) -> usize {
        self.data.len() - self.pos
    }
    fn is_empty(&self) -> bool {
        self.len() == 0
    }
    fn front(&self, n: usize) -> &[u8] {
        &self.data[self.pos..self.pos + n]
    }
    fn consume(&mut self, n: usize) {
        self.pos += n;
        if self.pos == self.data.len() {
            self.clear();
        }
    }
    fn push(&mut self, b: &[u8]) {
        if self.pos > 0 && self.pos >= self.data.len() / 2 {
            self.data.drain(..self.pos);
            self.pos = 0;
        }
        self.data.extend_from_slice(b);
    }
    fn clear(&mut self) {
        self.data.clear();
        self.pos = 0;
    }
}

#[derive(Default)]
struct Sub {
    /// Received, not yet read by the application.
    recv: Bytes,
    /// Bytes the peer may still send before it needs more credit from us.
    recv_allow: u64,
    /// Bytes the application read and we have not credited back yet.
    unacked: u64,
    recv_fin: bool,
    recv_rst: bool,
    /// Written by the application, not sent yet.
    send: Bytes,
    /// Bytes we may still send.
    credit: u64,
    fin_queued: bool,
    fin_sent: bool,
    /// The handle went away before both FINs: send what credit allows, then RST.
    rst_pending: bool,
    /// No handle exists any more (dropped, or never handed out by a dropped `Incoming`).
    dropped: bool,
    /// In the writer's round-robin queue.
    queued: bool,
    read_waker: Option<Waker>,
    write_waker: Option<Waker>,
}

impl Sub {
    fn new() -> Sub {
        Sub { recv_allow: WINDOW as u64, credit: WINDOW as u64, ..Sub::default() }
    }
}

enum Ctrl {
    Open(u32),
    Credit(u32, u32),
    Rst(u32),
    Ping([u8; 8]),
    Pong([u8; 8]),
}

struct State {
    client: bool,
    closed: Option<String>,
    streams: HashMap<u32, Sub>,
    ctrl: VecDeque<Ctrl>,
    /// Streams that may have DATA, FIN or RST to send, in round-robin order.
    ready: VecDeque<u32>,
    /// Client: the next id to open. Server: the highest id the client opened so far.
    next_id: u32,
    opened: u64,
    /// Client: since when no stream is open.
    idle_since: Option<Instant>,
    incoming: VecDeque<u32>,
    incoming_waker: Option<Waker>,
    incoming_gone: bool,
    ping_seq: u64,
}

impl State {
    fn new(client: bool) -> State {
        State {
            client,
            closed: None,
            streams: HashMap::new(),
            ctrl: VecDeque::new(),
            ready: VecDeque::new(),
            next_id: if client { 1 } else { 0 },
            opened: 0,
            idle_since: client.then(Instant::now),
            incoming: VecDeque::new(),
            incoming_waker: None,
            incoming_gone: false,
            ping_seq: 0,
        }
    }

    fn schedule(&mut self, id: u32) {
        if let Some(s) = self.streams.get_mut(&id) {
            if !s.queued {
                s.queued = true;
                self.ready.push_back(id);
            }
        }
    }

    fn remove(&mut self, id: u32) {
        self.streams.remove(&id);
        if self.client && self.streams.is_empty() {
            self.idle_since = Some(Instant::now());
        }
    }

    /// A stream lost its handle: keep it only while a clean ending is still on its way.
    fn drop_stream(&mut self, id: u32) {
        let closed = self.closed.is_some();
        let Some(s) = self.streams.get_mut(&id) else { return };
        s.dropped = true;
        s.recv.clear();
        s.read_waker = None;
        s.write_waker = None;
        if closed || s.recv_rst {
            self.remove(id);
        } else if s.fin_queued && s.recv_fin {
            if s.fin_sent {
                self.remove(id);
            }
            // else the writer sends the FIN and then removes it
        } else if s.send.is_empty() || s.credit == 0 {
            self.ctrl.push_back(Ctrl::Rst(id));
            self.remove(id);
        } else {
            s.rst_pending = true;
            self.schedule(id);
        }
    }

    /// Moves control frames, then one DATA frame per ready stream per turn, into `out`.
    fn collect(&mut self, out: &mut Vec<u8>, wakers: &mut Vec<Waker>) {
        while let Some(c) = self.ctrl.pop_front() {
            match c {
                Ctrl::Open(id) => put(out, OPEN, id, &[]),
                Ctrl::Credit(id, n) => put(out, CREDIT, id, &n.to_be_bytes()),
                Ctrl::Rst(id) => put(out, RST, id, &[]),
                Ctrl::Ping(p) => put(out, PING, 0, &p),
                Ctrl::Pong(p) => put(out, PONG, 0, &p),
            }
        }
        while out.len() < BATCH {
            let Some(id) = self.ready.pop_front() else { break };
            let Some(s) = self.streams.get_mut(&id) else { continue };
            s.queued = false;
            let n = s.send.len().min(s.credit as usize).min(MAX_FRAME);
            if n > 0 {
                put(out, DATA, id, s.send.front(n));
                s.send.consume(n);
                s.credit -= n as u64;
                if let Some(w) = s.write_waker.take() {
                    wakers.push(w);
                }
            }
            let more = !s.send.is_empty() && s.credit > 0;
            if more {
                s.queued = true;
                self.ready.push_back(id);
            } else if s.rst_pending {
                put(out, RST, id, &[]);
                self.remove(id);
            } else if s.send.is_empty() && s.fin_queued && !s.fin_sent {
                put(out, FIN, id, &[]);
                s.fin_sent = true;
                if s.dropped && s.recv_fin {
                    self.remove(id);
                }
            }
        }
    }

    /// Handles one frame from the peer. `Err` is the reason to close the channel.
    fn on_frame(&mut self, t: u8, id: u32, p: &[u8], wakers: &mut Vec<Waker>) -> Result<(), &'static str> {
        match t {
            OPEN => {
                if self.client || id.is_multiple_of(2) || id <= self.next_id {
                    return Err("protocol: id");
                }
                self.next_id = id;
                if self.incoming_gone || self.streams.len() >= MAX_STREAMS {
                    self.ctrl.push_back(Ctrl::Rst(id));
                    return Ok(());
                }
                self.streams.insert(id, Sub::new());
                self.opened += 1;
                self.incoming.push_back(id);
                if let Some(w) = self.incoming_waker.take() {
                    wakers.push(w);
                }
            }
            DATA => {
                let Some(s) = self.streams.get_mut(&id) else { return Ok(()) };
                if s.dropped || s.recv_fin || s.recv_rst {
                    return Ok(());
                }
                if p.len() as u64 > s.recv_allow {
                    return Err("protocol: credit");
                }
                s.recv_allow -= p.len() as u64;
                s.recv.push(p);
                if let Some(w) = s.read_waker.take() {
                    wakers.push(w);
                }
            }
            FIN => {
                let Some(s) = self.streams.get_mut(&id) else { return Ok(()) };
                s.recv_fin = true;
                if let Some(w) = s.read_waker.take() {
                    wakers.push(w);
                }
                if s.dropped && s.fin_sent {
                    self.remove(id);
                }
            }
            RST => {
                let Some(s) = self.streams.get_mut(&id) else { return Ok(()) };
                s.recv_rst = true;
                s.rst_pending = false;
                s.send.clear();
                // The stream is over: no FIN goes out for it any more.
                s.fin_sent = true;
                wakers.extend(s.read_waker.take());
                wakers.extend(s.write_waker.take());
                if s.dropped {
                    self.remove(id);
                }
            }
            CREDIT => {
                let n: [u8; 4] = p.try_into().map_err(|_| "protocol: len")?;
                if let Some(s) = self.streams.get_mut(&id) {
                    s.credit += u32::from_be_bytes(n) as u64;
                    self.schedule(id);
                }
            }
            PING => {
                let n: [u8; 8] = p.try_into().map_err(|_| "protocol: len")?;
                self.ctrl.push_back(Ctrl::Pong(n));
            }
            PONG => {
                let _: [u8; 8] = p.try_into().map_err(|_| "protocol: len")?;
            }
            _ => return Err("protocol: type"),
        }
        Ok(())
    }
}

fn put(out: &mut Vec<u8>, t: u8, id: u32, payload: &[u8]) {
    out.push(t);
    out.extend_from_slice(&id.to_be_bytes());
    out.extend_from_slice(&(payload.len() as u16).to_be_bytes());
    out.extend_from_slice(payload);
}

fn aborted(reason: &str) -> io::Error {
    io::Error::new(io::ErrorKind::ConnectionAborted, reason.to_string())
}

struct Shared {
    st: Mutex<State>,
    /// Wakes the writer task: something was queued, or a deadline moved.
    wake_writer: Notify,
    closed_tx: watch::Sender<bool>,
}

impl Shared {
    fn lock(&self) -> MutexGuard<'_, State> {
        self.st.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn close(&self, reason: impl Into<String>) {
        let mut wakers = Vec::new();
        {
            let mut st = self.lock();
            if st.closed.is_some() {
                return;
            }
            st.closed = Some(reason.into());
            for s in st.streams.values_mut() {
                s.send.clear();
                wakers.extend(s.read_waker.take());
                wakers.extend(s.write_waker.take());
            }
            st.ctrl.clear();
            st.ready.clear();
            wakers.extend(st.incoming_waker.take());
        }
        self.closed_tx.send_replace(true);
        self.wake_writer.notify_one();
        for w in wakers {
            w.wake();
        }
    }

    async fn wait_closed(&self) {
        let mut rx = self.closed_tx.subscribe();
        let _ = rx.wait_for(|c| *c).await;
    }
}

/// What the application holds. When the last `Mux`, `Incoming` and `MuxStream` is gone the
/// channel closes ("closed"), so the two tasks never outlive their users.
struct Handle(Arc<Shared>);

impl Drop for Handle {
    fn drop(&mut self) {
        self.0.close("closed");
    }
}

#[derive(Clone)]
pub struct Mux {
    h: Arc<Handle>,
}

impl Mux {
    fn start(client: bool) -> Arc<Shared> {
        Arc::new(Shared {
            st: Mutex::new(State::new(client)),
            wake_writer: Notify::new(),
            closed_tx: watch::Sender::new(false),
        })
    }

    /// 访问方。`w` 立刻能写；读端等 `ready` 给出才开始读帧。`ready` 出错时通道带着它的文字关掉。
    pub fn client<F>(ready: F, w: Writer) -> Mux
    where
        F: Future<Output = io::Result<Reader>> + Send + 'static,
    {
        let sh = Mux::start(true);
        tokio::spawn(read_task(sh.clone(), ready));
        tokio::spawn(write_task(sh.clone(), w));
        Mux { h: Arc::new(Handle(sh)) }
    }

    /// 分享方。只收子流，不开。
    pub fn server(r: Reader, w: Writer) -> (Mux, Incoming) {
        let sh = Mux::start(false);
        tokio::spawn(read_task(sh.clone(), async { Ok(r) }));
        tokio::spawn(write_task(sh.clone(), w));
        let h = Arc::new(Handle(sh));
        (Mux { h: h.clone() }, Incoming { h })
    }

    fn sh(&self) -> &Shared {
        &self.h.0
    }

    /// 开一条子流，不等对方（OPEN 和之后写的数据一起排队）。通道关了或满了 MAX_STREAMS 时报错。
    pub fn open(&self) -> io::Result<MuxStream> {
        let id = {
            let mut st = self.sh().lock();
            if let Some(r) = &st.closed {
                return Err(aborted(r));
            }
            if !st.client {
                return Err(io::Error::other("the sharer does not open streams"));
            }
            if st.streams.len() >= MAX_STREAMS {
                return Err(io::Error::other("too many streams"));
            }
            let id = st.next_id;
            st.next_id = id.checked_add(2).ok_or_else(|| io::Error::other("stream ids used up"))?;
            st.streams.insert(id, Sub::new());
            st.opened += 1;
            st.idle_since = None;
            st.ctrl.push_back(Ctrl::Open(id));
            id
        };
        self.sh().wake_writer.notify_one();
        Ok(MuxStream { h: self.h.clone(), id })
    }

    pub fn is_closed(&self) -> bool {
        self.sh().lock().closed.is_some()
    }

    /// 原因 "closed"。
    pub fn close(&self) {
        self.sh().close("closed");
    }

    pub fn reason(&self) -> Option<String> {
        self.sh().lock().closed.clone()
    }

    /// 正开着的子流。
    pub fn live(&self) -> usize {
        self.sh().lock().streams.len()
    }

    /// 一共开过（或收到过）的子流。
    pub fn opened(&self) -> u64 {
        self.sh().lock().opened
    }

    /// 通道关掉时返回。
    pub async fn closed(&self) {
        self.sh().wait_closed().await;
    }
}

pub struct Incoming {
    h: Arc<Handle>,
}

impl Incoming {
    /// 通道关了返回 None。
    pub async fn next(&mut self) -> Option<MuxStream> {
        let sh = &self.h.0;
        let id = poll_fn(|cx| {
            let mut st = sh.lock();
            if st.closed.is_some() {
                return Poll::Ready(None);
            }
            if let Some(id) = st.incoming.pop_front() {
                return Poll::Ready(Some(id));
            }
            st.incoming_waker = Some(cx.waker().clone());
            Poll::Pending
        })
        .await?;
        Some(MuxStream { h: self.h.clone(), id })
    }
}

impl Drop for Incoming {
    fn drop(&mut self) {
        {
            let mut st = self.h.0.lock();
            st.incoming_gone = true;
            st.incoming_waker = None;
            while let Some(id) = st.incoming.pop_front() {
                st.drop_stream(id);
            }
        }
        self.h.0.wake_writer.notify_one();
    }
}

/// One stream inside the channel. `poll_shutdown` sends FIN; dropping it before both FINs
/// sends RST. A peer RST reads as `ConnectionReset`; a closed channel as `ConnectionAborted`
/// with the channel's reason as its text.
pub struct MuxStream {
    h: Arc<Handle>,
    id: u32,
}

impl MuxStream {
    fn sh(&self) -> &Shared {
        &self.h.0
    }
}

impl AsyncRead for MuxStream {
    fn poll_read(self: Pin<&mut Self>, cx: &mut Context<'_>, buf: &mut ReadBuf<'_>) -> Poll<io::Result<()>> {
        let sh = self.sh();
        let mut credit = false;
        let res = {
            let mut guard = sh.lock();
            let st = &mut *guard;
            match st.streams.get_mut(&self.id) {
                None => Poll::Ready(Err(aborted(st.closed.as_deref().unwrap_or("closed")))),
                Some(_) if buf.remaining() == 0 => Poll::Ready(Ok(())),
                Some(s) if !s.recv.is_empty() => {
                    let n = buf.remaining().min(s.recv.len());
                    buf.put_slice(s.recv.front(n));
                    s.recv.consume(n);
                    s.unacked += n as u64;
                    if s.unacked >= (WINDOW / 2) as u64 && st.closed.is_none() && !s.recv_fin && !s.recv_rst {
                        st.ctrl.push_back(Ctrl::Credit(self.id, s.unacked as u32));
                        s.recv_allow += s.unacked;
                        s.unacked = 0;
                        credit = true;
                    }
                    Poll::Ready(Ok(()))
                }
                Some(s) if s.recv_fin => Poll::Ready(Ok(())),
                Some(s) if s.recv_rst => Poll::Ready(Err(io::ErrorKind::ConnectionReset.into())),
                Some(s) => match &st.closed {
                    Some(r) => Poll::Ready(Err(aborted(r))),
                    None => {
                        s.read_waker = Some(cx.waker().clone());
                        Poll::Pending
                    }
                },
            }
        };
        if credit {
            sh.wake_writer.notify_one();
        }
        res
    }
}

impl AsyncWrite for MuxStream {
    fn poll_write(self: Pin<&mut Self>, cx: &mut Context<'_>, buf: &[u8]) -> Poll<io::Result<usize>> {
        let sh = self.sh();
        let res = {
            let mut guard = sh.lock();
            let st = &mut *guard;
            if let Some(r) = &st.closed {
                return Poll::Ready(Err(aborted(r)));
            }
            let Some(s) = st.streams.get_mut(&self.id) else {
                return Poll::Ready(Err(aborted("closed")));
            };
            if s.recv_rst {
                return Poll::Ready(Err(io::ErrorKind::ConnectionReset.into()));
            }
            if s.fin_queued {
                return Poll::Ready(Err(io::ErrorKind::BrokenPipe.into()));
            }
            if buf.is_empty() {
                return Poll::Ready(Ok(0));
            }
            let space = SEND_BUF - s.send.len();
            if space == 0 {
                s.write_waker = Some(cx.waker().clone());
                return Poll::Pending;
            }
            let n = space.min(buf.len());
            s.send.push(&buf[..n]);
            st.schedule(self.id);
            n
        };
        sh.wake_writer.notify_one();
        Poll::Ready(Ok(res))
    }

    fn poll_flush(self: Pin<&mut Self>, _cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Poll::Ready(Ok(()))
    }

    fn poll_shutdown(self: Pin<&mut Self>, _cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        let sh = self.sh();
        {
            let mut guard = sh.lock();
            let st = &mut *guard;
            if let Some(r) = &st.closed {
                return Poll::Ready(Err(aborted(r)));
            }
            let Some(s) = st.streams.get_mut(&self.id) else {
                return Poll::Ready(Err(aborted("closed")));
            };
            if s.recv_rst {
                return Poll::Ready(Err(io::ErrorKind::ConnectionReset.into()));
            }
            if s.fin_queued {
                return Poll::Ready(Ok(()));
            }
            s.fin_queued = true;
            st.schedule(self.id);
        }
        sh.wake_writer.notify_one();
        Poll::Ready(Ok(()))
    }
}

impl Drop for MuxStream {
    fn drop(&mut self) {
        self.sh().lock().drop_stream(self.id);
        self.sh().wake_writer.notify_one();
    }
}

/// Reads one frame header and payload. `Ok(Err(..))` is a protocol violation.
async fn read_frame(
    r: &mut BufReader<Reader>,
    payload: &mut Vec<u8>,
) -> io::Result<Result<(u8, u32), &'static str>> {
    let mut h = [0u8; HEAD];
    r.read_exact(&mut h).await?;
    let t = h[0];
    if !(OPEN..=PONG).contains(&t) {
        return Ok(Err("protocol: type"));
    }
    let id = u32::from_be_bytes([h[1], h[2], h[3], h[4]]);
    let len = u16::from_be_bytes([h[5], h[6]]) as usize;
    if len > MAX_FRAME {
        return Ok(Err("protocol: len"));
    }
    payload.resize(len, 0);
    r.read_exact(payload).await?;
    Ok(Ok((t, id)))
}

async fn read_task<F>(sh: Arc<Shared>, ready: F)
where
    F: Future<Output = io::Result<Reader>>,
{
    let dead = tokio::time::sleep(DEAD_AFTER);
    tokio::pin!(dead);
    let r = tokio::select! {
        r = ready => r,
        _ = &mut dead => return sh.close("dead"),
        _ = sh.wait_closed() => return,
    };
    let r = match r {
        Ok(r) => r,
        Err(e) => return sh.close(e.to_string()),
    };
    dead.as_mut().reset(Instant::now() + DEAD_AFTER);
    let mut r = BufReader::with_capacity(64 * 1024, r);
    let mut payload = Vec::with_capacity(MAX_FRAME);
    let mut wakers = Vec::new();
    loop {
        let frame = tokio::select! {
            f = read_frame(&mut r, &mut payload) => f,
            _ = &mut dead => return sh.close("dead"),
            _ = sh.wait_closed() => return,
        };
        let (t, id) = match frame {
            Ok(Ok(f)) => f,
            Ok(Err(why)) => return sh.close(why),
            Err(e) if e.kind() == io::ErrorKind::UnexpectedEof => return sh.close("eof"),
            Err(e) => return sh.close(e.to_string()),
        };
        dead.as_mut().reset(Instant::now() + DEAD_AFTER);
        let (res, wake) = {
            let mut st = sh.lock();
            if st.closed.is_some() {
                return;
            }
            let res = st.on_frame(t, id, &payload, &mut wakers);
            // The writer has something new to send (PONG, RST, data now credited), or a
            // stream ended and the idle deadline may have moved.
            (res, !st.ctrl.is_empty() || !matches!(t, DATA | PONG))
        };
        if let Err(why) = res {
            return sh.close(why);
        }
        if wake {
            sh.wake_writer.notify_one();
        }
        for w in wakers.drain(..) {
            w.wake();
        }
    }
}

async fn write_task(sh: Arc<Shared>, mut w: Writer) {
    let mut next_ping = Instant::now() + PING_EVERY;
    let mut out = Vec::with_capacity(BATCH + MAX_FRAME + HEAD);
    let mut wakers = Vec::new();
    let mut dirty = false;
    loop {
        if Instant::now() >= next_ping {
            let mut st = sh.lock();
            st.ping_seq += 1;
            let seq = st.ping_seq.to_be_bytes();
            st.ctrl.push_back(Ctrl::Ping(seq));
            next_ping = Instant::now() + PING_EVERY;
        }
        let idle_since = {
            let mut st = sh.lock();
            if st.closed.is_some() {
                break;
            }
            st.collect(&mut out, &mut wakers);
            st.idle_since
        };
        for k in wakers.drain(..) {
            k.wake();
        }
        if !out.is_empty() {
            let res = tokio::select! {
                r = w.write_all(&out) => r,
                _ = sh.wait_closed() => break,
            };
            out.clear();
            if let Err(e) = res {
                sh.close(e.to_string());
                break;
            }
            dirty = true;
            continue;
        }
        if dirty {
            let res = tokio::select! {
                r = w.flush() => r,
                _ = sh.wait_closed() => break,
            };
            if let Err(e) = res {
                sh.close(e.to_string());
                break;
            }
            dirty = false;
            continue;
        }
        let idle_at = idle_since.map(|t| t + CHANNEL_IDLE);
        let deadline = idle_at.map_or(next_ping, |t| t.min(next_ping));
        tokio::select! {
            _ = sh.wake_writer.notified() => {}
            _ = tokio::time::sleep_until(deadline) => {
                let idle = {
                    let st = sh.lock();
                    st.streams.is_empty()
                        && st.idle_since.is_some_and(|t| Instant::now() >= t + CHANNEL_IDLE)
                };
                if idle {
                    sh.close("idle");
                    break;
                }
            }
            _ = sh.wait_closed() => break,
        }
    }
    let _ = tokio::time::timeout(SHUTDOWN_GRACE, w.shutdown()).await;
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::sync::Arc;
    use tokio::io::{duplex, split, AsyncReadExt, AsyncWriteExt, DuplexStream};
    use tokio::time::{sleep, timeout, Instant};

    const PIPE: usize = 64 * 1024;

    fn halves(d: DuplexStream) -> (Reader, Writer) {
        let (r, w) = split(d);
        (Box::new(r), Box::new(w))
    }

    fn pair() -> (Mux, Mux, Incoming) {
        let (a, b) = duplex(PIPE);
        let (ar, aw) = halves(a);
        let (br, bw) = halves(b);
        let c = Mux::client(async { Ok(ar) }, aw);
        let (s, inc) = Mux::server(br, bw);
        (c, s, inc)
    }

    fn raw_server() -> (Mux, DuplexStream) {
        let (a, b) = duplex(PIPE);
        let (ar, aw) = halves(a);
        (Mux::client(async { Ok(ar) }, aw), b)
    }

    fn raw_client() -> (DuplexStream, Mux, Incoming) {
        let (a, b) = duplex(PIPE);
        let (br, bw) = halves(b);
        let (s, inc) = Mux::server(br, bw);
        (a, s, inc)
    }

    fn frame(t: u8, id: u32, payload: &[u8]) -> Vec<u8> {
        let mut v = vec![t];
        v.extend(id.to_be_bytes());
        v.extend((payload.len() as u16).to_be_bytes());
        v.extend(payload);
        v
    }

    /// Reads one frame off the raw side: (type, id, payload).
    async fn read_raw(d: &mut DuplexStream) -> (u8, u32, Vec<u8>) {
        let mut h = [0u8; 7];
        d.read_exact(&mut h).await.unwrap();
        let id = u32::from_be_bytes([h[1], h[2], h[3], h[4]]);
        let len = u16::from_be_bytes([h[5], h[6]]) as usize;
        let mut p = vec![0u8; len];
        d.read_exact(&mut p).await.unwrap();
        (h[0], id, p)
    }

    /// The server echoes each stream it accepts until the client's FIN, then FINs back.
    fn echo_all(mut inc: Incoming) {
        tokio::spawn(async move {
            while let Some(s) = inc.next().await {
                tokio::spawn(async move {
                    let (mut r, mut w) = split(s);
                    tokio::io::copy(&mut r, &mut w).await.unwrap();
                    w.shutdown().await.unwrap();
                });
            }
        });
    }

    async fn round_trips(b: &mut MuxStream, n: usize) {
        for i in 0..n {
            let out = vec![i as u8; 1024];
            b.write_all(&out).await.unwrap();
            let mut back = vec![0u8; 1024];
            b.read_exact(&mut back).await.unwrap();
            assert_eq!(back, out);
        }
    }

    /// Frame (type, id) pairs in what `collect` wrote.
    fn frames_in(mut out: &[u8]) -> Vec<(u8, u32)> {
        let mut v = Vec::new();
        while !out.is_empty() {
            let id = u32::from_be_bytes([out[1], out[2], out[3], out[4]]);
            let len = u16::from_be_bytes([out[5], out[6]]) as usize;
            v.push((out[0], id));
            out = &out[HEAD + len..];
        }
        v
    }

    /// A stream holding `n` bytes to send, with full credit, queued for the writer.
    fn busy(st: &mut State, id: u32, n: usize) {
        let mut s = Sub::new();
        s.send.push(&vec![0u8; n]);
        st.streams.insert(id, s);
        st.schedule(id);
    }

    #[tokio::test]
    async fn data_frames_take_turns() {
        let mut st = State::new(true);
        busy(&mut st, 1, 3 * MAX_FRAME);
        busy(&mut st, 3, 3 * MAX_FRAME);
        let (mut out, mut wakers, mut ids) = (Vec::new(), Vec::new(), Vec::new());
        loop {
            st.collect(&mut out, &mut wakers);
            if out.is_empty() {
                break;
            }
            ids.extend(frames_in(&out).into_iter().map(|(t, id)| (t == DATA).then_some(id).unwrap()));
            out.clear();
        }
        assert_eq!(ids, [1, 3, 1, 3, 1, 3]);
    }

    #[tokio::test]
    async fn no_fin_after_a_reset() {
        let mut st = State::new(true);
        busy(&mut st, 1, 10);
        st.streams.get_mut(&1).unwrap().fin_queued = true;
        st.on_frame(RST, 1, &[], &mut Vec::new()).unwrap();
        let mut out = Vec::new();
        st.collect(&mut out, &mut Vec::new());
        assert_eq!(frames_in(&out), []);
    }

    #[tokio::test]
    async fn bytes_both_ways_and_half_close() {
        let (c, _s, mut inc) = pair();
        let mut a = c.open().unwrap();
        a.write_all(b"ping").await.unwrap();
        a.shutdown().await.unwrap();
        let mut b = inc.next().await.unwrap();
        let mut got = Vec::new();
        b.read_to_end(&mut got).await.unwrap();
        assert_eq!(got, b"ping");
        // 对面写完之后，这一头还能回
        b.write_all(b"pong").await.unwrap();
        b.shutdown().await.unwrap();
        let mut back = Vec::new();
        a.read_to_end(&mut back).await.unwrap();
        assert_eq!(back, b"pong");
    }

    #[tokio::test]
    async fn two_hundred_streams_at_once() {
        let (c, _s, inc) = pair();
        echo_all(inc);
        let mut jobs = Vec::new();
        for i in 0..200u32 {
            let s = c.open().unwrap();
            jobs.push(tokio::spawn(async move {
                let data: Vec<u8> = (0..64 * 1024u32).map(|k| (k.wrapping_mul(31) ^ i) as u8).collect();
                let (mut r, mut w) = split(s);
                let sent = data.clone();
                let send = async move {
                    w.write_all(&sent).await.unwrap();
                    w.shutdown().await.unwrap();
                };
                let recv = async move {
                    let mut got = Vec::new();
                    r.read_to_end(&mut got).await.unwrap();
                    got
                };
                let ((), got) = tokio::join!(send, recv);
                assert_eq!(got, data, "stream {i}");
            }));
        }
        timeout(Duration::from_secs(30), async {
            for j in jobs {
                j.await.unwrap();
            }
        })
        .await
        .unwrap();
        assert_eq!(c.opened(), 200);
    }

    #[tokio::test]
    async fn a_stalled_reader_does_not_block_another() {
        let (c, _s, mut inc) = pair();
        let mut a = c.open().unwrap();
        let writing = tokio::spawn(async move {
            a.write_all(&vec![7u8; 4 << 20]).await.unwrap();
            a
        });
        let _held = inc.next().await.unwrap(); // the server holds A and never reads it
        sleep(Duration::from_millis(200)).await;
        assert!(!writing.is_finished(), "A's write should be stuck on WINDOW");

        let mut b = c.open().unwrap();
        let sb = inc.next().await.unwrap();
        tokio::spawn(async move {
            let (mut r, mut w) = split(sb);
            tokio::io::copy(&mut r, &mut w).await.unwrap();
        });
        timeout(Duration::from_secs(2), round_trips(&mut b, 10)).await.unwrap();
        assert!(!writing.is_finished());
    }

    #[tokio::test]
    async fn a_big_flow_does_not_starve_a_small_one() {
        const BIG: u64 = 64 << 20;
        let (c, _s, mut inc) = pair();
        let mut a = c.open().unwrap();
        a.write_all(b"a").await.unwrap();
        let mut sa = inc.next().await.unwrap();
        tokio::spawn(async move {
            let chunk = vec![1u8; 64 * 1024];
            for _ in 0..BIG / chunk.len() as u64 {
                if sa.write_all(&chunk).await.is_err() {
                    return;
                }
            }
            let _ = sa.shutdown().await;
        });
        let got = Arc::new(AtomicU64::new(0));
        let got2 = got.clone();
        tokio::spawn(async move {
            let mut buf = vec![0u8; 64 * 1024];
            loop {
                match a.read(&mut buf).await {
                    Ok(0) | Err(_) => return,
                    Ok(n) => {
                        got2.fetch_add(n as u64, Ordering::SeqCst);
                    }
                }
            }
        });
        // let A get going before B starts
        while got.load(Ordering::SeqCst) < 2 << 20 {
            tokio::task::yield_now().await;
        }

        let mut b = c.open().unwrap();
        b.write_all(b"b").await.unwrap();
        let mut sb = inc.next().await.unwrap();
        let mut one = [0u8; 1];
        sb.read_exact(&mut one).await.unwrap();
        tokio::spawn(async move {
            let (mut r, mut w) = split(sb);
            tokio::io::copy(&mut r, &mut w).await.unwrap();
        });
        round_trips(&mut b, 10).await;
        let at_b = got.load(Ordering::SeqCst);
        assert!(at_b < BIG, "A finished ({at_b}) before B");
    }

    #[tokio::test]
    async fn dropping_before_fin_resets() {
        let (c, _s, mut inc) = pair();
        let mut a = c.open().unwrap();
        a.write_all(b"x").await.unwrap();
        drop(a);
        let mut b = inc.next().await.unwrap();
        let mut one = [0u8; 1];
        b.read_exact(&mut one).await.unwrap();
        assert_eq!(&one, b"x");
        let e = b.read(&mut one).await.unwrap_err();
        assert_eq!(e.kind(), io::ErrorKind::ConnectionReset);
        assert!(!c.is_closed());
    }

    async fn violation(bytes: Vec<u8>, want: &str) {
        let (mut raw, s, _inc) = raw_client();
        raw.write_all(&bytes).await.unwrap();
        timeout(Duration::from_secs(1), s.closed()).await.unwrap_or_else(|_| panic!("not closed for {want}"));
        assert!(s.is_closed());
        assert_eq!(s.reason().as_deref(), Some(want));
        drop(raw);
    }

    #[tokio::test]
    async fn protocol_violations_close_the_channel() {
        violation(frame(9, 1, b""), "protocol: type").await;

        let mut long = vec![DATA, 0, 0, 0, 1];
        long.extend(((MAX_FRAME + 1) as u16).to_be_bytes());
        violation(long, "protocol: len").await;

        violation(frame(OPEN, 2, b""), "protocol: id").await;

        let mut twice = frame(OPEN, 1, b"");
        twice.extend(frame(OPEN, 1, b""));
        violation(twice, "protocol: id").await;

        let mut over = frame(OPEN, 1, b"");
        let full = vec![0u8; MAX_FRAME];
        for _ in 0..WINDOW as usize / MAX_FRAME {
            over.extend(frame(DATA, 1, &full));
        }
        over.extend(frame(DATA, 1, b"!"));
        violation(over, "protocol: credit").await;
    }

    #[tokio::test]
    async fn opens_past_the_cap() {
        let (c, _s, _inc) = pair();
        let mut held = Vec::new();
        for _ in 0..MAX_STREAMS {
            held.push(c.open().unwrap());
        }
        assert!(c.open().is_err());
        assert_eq!(c.live(), MAX_STREAMS);

        let (mut raw, s, _inc2) = raw_client();
        let mut opens = Vec::new();
        for k in 0..=MAX_STREAMS as u32 {
            opens.extend(frame(OPEN, 2 * k + 1, b""));
        }
        raw.write_all(&opens).await.unwrap();
        let last = 2 * MAX_STREAMS as u32 + 1;
        timeout(Duration::from_secs(5), async {
            loop {
                let (t, id, _) = read_raw(&mut raw).await;
                if t == RST {
                    assert_eq!(id, last);
                    return;
                }
            }
        })
        .await
        .unwrap();
        assert!(!s.is_closed());
        assert_eq!(s.live(), MAX_STREAMS);
    }

    #[tokio::test(start_paused = true)]
    async fn silence_closes_the_channel() {
        let (c, mut raw) = raw_server();
        tokio::spawn(async move {
            let mut sink = vec![0u8; 1024];
            while matches!(raw.read(&mut sink).await, Ok(n) if n > 0) {}
        });
        sleep(DEAD_AFTER + Duration::from_secs(1)).await;
        assert!(c.is_closed());
        assert_eq!(c.reason().as_deref(), Some("dead"));
    }

    #[tokio::test(start_paused = true)]
    async fn pings_keep_a_quiet_channel_open() {
        let (c, s, _inc) = pair();
        let _a = c.open().unwrap();
        sleep(Duration::from_secs(90)).await;
        assert!(!c.is_closed(), "{:?}", c.reason());
        assert!(!s.is_closed(), "{:?}", s.reason());
    }

    #[tokio::test(start_paused = true)]
    async fn an_idle_client_closes() {
        let (c, _s, mut inc) = pair();
        let mut a = c.open().unwrap();
        a.shutdown().await.unwrap();
        let mut b = inc.next().await.unwrap();
        b.shutdown().await.unwrap();
        let mut sink = Vec::new();
        b.read_to_end(&mut sink).await.unwrap();
        a.read_to_end(&mut sink).await.unwrap();
        drop(a);
        drop(b);
        let start = Instant::now();
        sleep(CHANNEL_IDLE - Duration::from_secs(1)).await;
        assert!(!c.is_closed(), "closed early: {:?}", c.reason());
        sleep(Duration::from_secs(2)).await;
        assert!(start.elapsed() > CHANNEL_IDLE);
        assert_eq!(c.reason().as_deref(), Some("idle"));

        let (c2, s2, _inc2) = pair();
        let _kept = c2.open().unwrap();
        sleep(CHANNEL_IDLE + Duration::from_secs(1)).await;
        assert!(!c2.is_closed(), "{:?}", c2.reason());
        assert!(!s2.is_closed(), "{:?}", s2.reason());
    }

    #[tokio::test]
    async fn writes_go_out_before_ready() {
        let (a, b) = duplex(PIPE);
        let (ar, aw) = halves(a);
        let (br, bw) = halves(b);
        let (tx, rx) = tokio::sync::oneshot::channel::<()>();
        let c = Mux::client(
            async move {
                rx.await.map_err(io::Error::other)?;
                Ok(ar)
            },
            aw,
        );
        let (_s, mut inc) = Mux::server(br, bw);
        let mut x = c.open().unwrap();
        x.write_all(b"x").await.unwrap();
        let mut got = inc.next().await.unwrap();
        let mut one = [0u8; 1];
        timeout(Duration::from_secs(1), got.read_exact(&mut one)).await.unwrap().unwrap();
        assert_eq!(&one, b"x");
        tx.send(()).unwrap();
        got.write_all(b"y").await.unwrap();
        timeout(Duration::from_secs(1), x.read_exact(&mut one)).await.unwrap().unwrap();
        assert_eq!(&one, b"y");
    }

    #[tokio::test]
    async fn a_ready_error_closes_with_its_text() {
        let (a, _b) = duplex(PIPE);
        let (_ar, aw) = halves(a);
        let c = Mux::client(async { Err(io::Error::other("unknown op")) }, aw);
        let mut s = c.open().unwrap();
        let mut one = [0u8; 1];
        let e = s.read(&mut one).await.unwrap_err();
        assert_eq!(e.to_string(), "unknown op");
        assert_eq!(e.kind(), io::ErrorKind::ConnectionAborted);
        assert_eq!(c.reason().as_deref(), Some("unknown op"));
        assert!(c.open().is_err());
    }

    #[tokio::test]
    async fn dropping_every_handle_ends_the_channel() {
        let (c, s, inc) = pair();
        let a = c.open().unwrap();
        drop(c);
        assert!(!s.is_closed());
        drop(a);
        timeout(Duration::from_secs(1), s.closed()).await.unwrap();
        assert_eq!(s.reason().as_deref(), Some("eof"));
        drop(inc);
    }
}
