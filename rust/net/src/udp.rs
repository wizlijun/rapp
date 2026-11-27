//! The UDP socket under every rapp-net endpoint: quinn's tokio socket, except that a receive that
//! fails stops being retried until the socket is readable again.
//!
//! quinn's tokio socket retries a failed receive at once and forever. iOS leaves a suspended app's
//! socket readable with every receive failing, so the endpoint driver spun on it, never read the
//! socket a rebind put in its place, and every dial timed out until the app restarted.

use quinn::udp::{RecvMeta, Transmit, UdpSocketState};
use quinn::{AsyncTimer, AsyncUdpSocket, UdpPoller};
use std::future::Future;
use std::io;
use std::pin::Pin;
use std::sync::{Arc, Mutex};
use std::task::{ready, Context, Poll};
use std::time::{Duration, Instant};
use tokio::io::Interest;

/// Failed receives are logged at most this often per socket.
const LOG_EVERY: Duration = Duration::from_secs(60);

/// quinn's `TokioRuntime` with `Socket` for its UDP sockets (rebinds included).
#[derive(Debug)]
pub struct Runtime;

impl quinn::Runtime for Runtime {
    fn new_timer(&self, t: Instant) -> Pin<Box<dyn AsyncTimer>> {
        quinn::TokioRuntime.new_timer(t)
    }

    fn spawn(&self, future: Pin<Box<dyn Future<Output = ()> + Send>>) {
        quinn::TokioRuntime.spawn(future)
    }

    fn wrap_udp_socket(&self, sock: std::net::UdpSocket) -> io::Result<Arc<dyn AsyncUdpSocket>> {
        Ok(Arc::new(Socket {
            inner: UdpSocketState::new((&sock).into())?,
            io: tokio::net::UdpSocket::from_std(sock)?,
            logged: Mutex::new(None),
        }))
    }

    fn now(&self) -> Instant {
        quinn::TokioRuntime.now()
    }
}

#[derive(Debug)]
struct Socket {
    io: tokio::net::UdpSocket,
    inner: UdpSocketState,
    logged: Mutex<Option<Instant>>,
}

impl Socket {
    fn log_failure(&self, e: &io::Error) {
        let mut logged = self.logged.lock().unwrap_or_else(|p| p.into_inner());
        if logged.is_none_or(|t| t.elapsed() >= LOG_EVERY) {
            *logged = Some(Instant::now());
            ::log::warn!(target: "quinn_udp", "recvmsg error: {e:?}, local: {:?}", self.io.local_addr().ok());
        }
    }
}

impl AsyncUdpSocket for Socket {
    fn create_io_poller(self: Arc<Self>) -> Pin<Box<dyn UdpPoller>> {
        Box::pin(Writable { sock: self, fut: None })
    }

    fn try_send(&self, transmit: &Transmit) -> io::Result<()> {
        self.io.try_io(Interest::WRITABLE, || self.inner.send((&self.io).into(), transmit))
    }

    fn poll_recv(&self, cx: &mut Context, bufs: &mut [io::IoSliceMut<'_>], meta: &mut [RecvMeta]) -> Poll<io::Result<usize>> {
        loop {
            ready!(self.io.poll_recv_ready(cx))?;
            let mut failed = None;
            // A failure is handed to tokio as WouldBlock, which clears the readiness: the socket
            // is tried again when the system next says it is readable, not straight away.
            // On Windows, ICMP port-unreachable from an offline peer arrives on the next receive as
            // ConnectionReset (WSAECONNRESET, 10054); skip it and read whatever follows.
            let r = self.io.try_io(Interest::READABLE, || loop {
                match self.inner.recv((&self.io).into(), bufs, meta) {
                    #[cfg(windows)]
                    Err(e) if e.kind() == io::ErrorKind::ConnectionReset => continue,
                    Err(e) if e.kind() != io::ErrorKind::WouldBlock => {
                        failed = Some(e);
                        return Err(io::ErrorKind::WouldBlock.into());
                    }
                    r => return r,
                }
            });
            match (r, failed) {
                (Ok(n), _) => return Poll::Ready(Ok(n)),
                (Err(_), Some(e)) => {
                    self.log_failure(&e);
                    if self.io.poll_recv_ready(cx).is_ready() {
                        // Readable again already: come back on the next turn, not in this loop.
                        cx.waker().wake_by_ref();
                    }
                    return Poll::Pending;
                }
                (Err(_), None) => {}
            }
        }
    }

    fn local_addr(&self) -> io::Result<std::net::SocketAddr> {
        self.io.local_addr()
    }

    fn may_fragment(&self) -> bool {
        self.inner.may_fragment()
    }

    fn max_transmit_segments(&self) -> usize {
        self.inner.max_gso_segments()
    }

    fn max_receive_segments(&self) -> usize {
        self.inner.gro_segments()
    }
}

/// Waits for the socket to be writable; one per task that sends, as quinn asks.
struct Writable {
    sock: Arc<Socket>,
    fut: Option<Pin<Box<dyn Future<Output = io::Result<()>> + Send + Sync>>>,
}

impl std::fmt::Debug for Writable {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Writable").finish_non_exhaustive()
    }
}

impl UdpPoller for Writable {
    fn poll_writable(mut self: Pin<&mut Self>, cx: &mut Context) -> Poll<io::Result<()>> {
        let this = &mut *self;
        let fut = this.fut.get_or_insert_with(|| {
            let sock = this.sock.clone();
            Box::pin(async move { sock.io.writable().await })
        });
        let r = fut.as_mut().poll(cx);
        if r.is_ready() {
            this.fut = None;
        }
        r
    }
}
