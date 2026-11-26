//! The listener and the one-session rule (`Server.swift:1-160`).

use std::collections::HashMap;
use std::io::Write;
use std::net::{IpAddr, Ipv4Addr, SocketAddr, TcpListener, TcpStream};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::mpsc::{channel, Sender};
use std::sync::{Arc, Mutex};

use crate::cli::{check_hello, exit_code, HostServeOptions, WorkerEvent};
use crate::clock::Clock;
use crate::input::PeerNames;
use crate::platform::Platform;
use crate::protocol::{Message, MessageParser};
use crate::run::Output;
use crate::transfers::{SideSlots, TransferStore};

use super::intake::{first_message, Outcome};
use super::session::Session;
use super::side::{SideConnection, SideHandle};
use super::Event;

/// How long the server waits for a session it ended (takeover, stop) to finish ending, in
/// host seconds. Swift ends it synchronously on the shared queue.
pub const END_WAIT: f64 = 2.0;

/// The session's transfer store, once its clipboard started (`Session.transfers`). The
/// session fills and clears it; side connections take a clone when they arrive.
pub type TransferSlot = Arc<Mutex<Option<Arc<Mutex<TransferStore>>>>>;

/// A running session as the server sees it.
pub struct SessionHandle {
    pub id: u64,
    pub tx: Sender<Event>,
    pub started: Arc<AtomicBool>,
    pub transfers: TransferSlot,
}

struct State {
    current: Option<SessionHandle>,
    peers: PeerNames,
    next_id: u64,
}

/// What the server and its sessions share.
pub struct Inner {
    pub options: HostServeOptions,
    pub platform: Arc<dyn Platform>,
    pub clock: Arc<dyn Clock>,
    pub out: Arc<Output>,
    /// `RAPP_DOWNLOADS`, or the data root's default (`transfer_dir`).
    pub downloads: PathBuf,
    state: Mutex<State>,
    /// Serialises `route`: one hello decides at a time, as on Swift's queue.
    routing: Mutex<()>,
    /// At most `MAX_SIDE_CONNECTIONS` side connections at a time (`sideSlots`).
    side_slots: Mutex<SideSlots>,
    /// The running side connections, aborted when their session ends (`sides`).
    sides: Mutex<HashMap<u64, SideHandle>>,
    next_side: AtomicU64,
    stopping: AtomicBool,
    local: SocketAddr,
}

#[derive(Clone)]
pub struct Server {
    inner: Arc<Inner>,
}

impl Server {
    /// Binds and starts accepting. A bind failure finishes the worker with Swift's
    /// `cannot listen on port N: …` and is returned as well.
    pub fn start(
        options: HostServeOptions,
        platform: Arc<dyn Platform>,
        clock: Arc<dyn Clock>,
        out: Arc<Output>,
        downloads: PathBuf,
    ) -> Result<Server, String> {
        let requested = options.port;
        let bound = match &options.bind {
            Some(bind) => TcpListener::bind((bind.as_str(), requested)),
            None => TcpListener::bind((IpAddr::V4(Ipv4Addr::UNSPECIFIED), requested)),
        };
        let listener = match bound {
            Ok(l) => l,
            Err(e) => {
                let text = format!("cannot listen on port {requested}: {e}");
                out.finish(exit_code::RUNTIME, &text);
                return Err(text);
            }
        };
        let local = listener.local_addr().map_err(|e| e.to_string())?;
        let inner = Arc::new(Inner {
            options,
            platform,
            clock,
            out,
            downloads,
            state: Mutex::new(State { current: None, peers: PeerNames::new(), next_id: 1 }),
            routing: Mutex::new(()),
            side_slots: Mutex::new(SideSlots::default()),
            sides: Mutex::new(HashMap::new()),
            next_side: AtomicU64::new(1),
            stopping: AtomicBool::new(false),
            local,
        });
        let port = local.port();
        inner.out.log(&format!("listening on {port}"));
        inner.out.emit(&WorkerEvent::Listening { port });
        let accept = inner.clone();
        std::thread::Builder::new()
            .name("rapp-host accept".into())
            .spawn(move || accept_loop(accept, listener))
            .map_err(|e| e.to_string())?;
        Ok(Server { inner })
    }

    pub fn port(&self) -> u16 {
        self.inner.local.port()
    }

    /// Ends the current session, if any; the host keeps listening.
    pub fn kick(&self) {
        if let Some(tx) = self.inner.current_tx() {
            let _ = tx.send(Event::Kick);
        }
    }

    /// Ends the current session, if any, then finishes with exit 0 and `reason`.
    pub fn stop(&self, reason: &str) {
        if let Some(tx) = self.inner.current_tx() {
            let (ack, done) = channel();
            if tx.send(Event::Stop { ack }).is_ok() {
                let _ = done.recv_timeout(self.inner.clock.real(END_WAIT));
            }
        }
        self.inner.out.finish(exit_code::OK, reason);
    }

    /// rapp-service names the device behind its connection from local port `port`.
    pub fn peer(&self, port: u16, name: &str) {
        self.inner.lock_state().peers.set(name, port);
    }

    /// Another device just operated A: this session's input waits.
    pub fn yield_to(&self, by: &str) {
        if let Some(tx) = self.inner.current_tx() {
            let _ = tx.send(Event::Yield(by.to_string()));
        }
    }

    /// After the worker finished: stop accepting (wakes the blocked accept with a connection
    /// to itself).
    pub fn shutdown(&self) {
        if self.inner.stopping.swap(true, Ordering::SeqCst) {
            return;
        }
        let mut addr = self.inner.local;
        if addr.ip().is_unspecified() {
            addr.set_ip(if addr.is_ipv4() { IpAddr::V4(Ipv4Addr::LOCALHOST) } else { "::1".parse().expect("ipv6") });
        }
        let _ = TcpStream::connect_timeout(&addr, self.inner.clock.real(1.0));
    }
}

fn accept_loop(inner: Arc<Inner>, listener: TcpListener) {
    for incoming in listener.incoming() {
        if inner.stopping.load(Ordering::SeqCst) {
            return;
        }
        let Ok(stream) = incoming else { continue };
        let _ = stream.set_nodelay(true);
        let inner = inner.clone();
        let _ = std::thread::Builder::new().name("rapp-host intake".into()).spawn(move || {
            let mut stream = stream;
            match first_message(&mut stream, inner.clock.as_ref()) {
                Outcome::Rejected { reason, notify } => inner.reject(stream, &reason, notify),
                Outcome::First(message, parser) => {
                    // A side connection runs here, on its own thread, after routing let go.
                    if let Some(side) = inner.route(stream, message, parser) {
                        side.run();
                    }
                }
            }
        });
    }
}

impl Inner {
    fn lock_state(&self) -> std::sync::MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn current_tx(&self) -> Option<Sender<Event>> {
        self.lock_state().current.as_ref().map(|s| s.tx.clone())
    }

    /// Logs and reports a refused connection; with `notify`, tells it why first.
    pub fn reject(&self, mut stream: TcpStream, reason: &str, notify: bool) {
        self.out.log(&format!("rejected a connection: {reason}"));
        self.out.emit(&WorkerEvent::Rejected { reason: reason.to_string() });
        if notify {
            // Closed once sent, or after 1 s.
            let _ = stream.set_write_timeout(Some(self.clock.real(1.0)));
            let _ = stream.write_all(&Message::Error(reason.to_string()).encoded());
            let _ = stream.flush();
        }
        let _ = stream.shutdown(std::net::Shutdown::Both);
    }

    /// Decides what a new connection is. A `fetch` or `put` comes back as a side connection
    /// for the caller's thread to run.
    fn route(self: &Arc<Self>, stream: TcpStream, message: Message, parser: MessageParser) -> Option<SideConnection> {
        let _route = self.routing.lock().unwrap_or_else(|e| e.into_inner());
        match &message {
            Message::Hello { token, bundle_id, .. } => {
                let peer = stream.peer_addr().ok();
                let name = peer.and_then(|p| self.lock_state().peers.name(p.port()).map(str::to_string));
                let old = self.lock_state().current.take();
                if let Some(old) = old {
                    // Only a hello that would itself be accepted takes over; any other leaves the
                    // running session alone (R4).
                    if let Err(error) = check_hello(token, bundle_id, &self.options.token, self.options.app.as_deref()) {
                        self.lock_state().current = Some(old);
                        self.reject(stream, &error.to_string(), true);
                        return None;
                    }
                    // One whose own hello failed is already ending with that reason.
                    if old.started.load(Ordering::SeqCst) {
                        let (ack, done) = channel();
                        if old.tx.send(Event::TakeOver { by: name.clone(), ack }).is_ok() {
                            let _ = done.recv_timeout(self.clock.real(END_WAIT));
                        }
                    }
                }
                let id = {
                    let mut s = self.lock_state();
                    let id = s.next_id;
                    s.next_id += 1;
                    id
                };
                let handle = Session::spawn(self.clone(), id, stream, peer, name, message, parser);
                self.lock_state().current = Some(handle);
                None
            }
            Message::Fetch { .. } | Message::Put { .. } => {
                let transfers = self
                    .lock_state()
                    .current
                    .as_ref()
                    .and_then(|c| c.transfers.lock().unwrap_or_else(|e| e.into_inner()).clone());
                let id = self.next_side.fetch_add(1, Ordering::SeqCst);
                let aborted = Arc::new(AtomicBool::new(false));
                match stream.try_clone() {
                    Ok(handle) => {
                        self.lock_sides().insert(id, SideHandle::new(handle, aborted.clone()));
                    }
                    Err(e) => {
                        self.reject(stream, &format!("connection error: {e}"), false);
                        return None;
                    }
                }
                Some(SideConnection::new(self.clone(), id, stream, parser, message, transfers, aborted))
            }
            _ => {
                self.reject(stream, "first message must be hello, fetch or put", true);
                None
            }
        }
    }

    fn lock_sides(&self) -> std::sync::MutexGuard<'_, HashMap<u64, SideHandle>> {
        self.sides.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// `slots.take()`.
    pub(crate) fn take_side_slot(&self) -> bool {
        self.side_slots.lock().unwrap_or_else(|e| e.into_inner()).take()
    }

    /// `slots.release()`.
    pub(crate) fn release_side_slot(&self) {
        self.side_slots.lock().unwrap_or_else(|e| e.into_inner()).release();
    }

    /// A side connection ended (its `onEnd`).
    pub(crate) fn side_ended(&self, id: u64) {
        self.lock_sides().remove(&id);
    }

    /// A session finished ending (Swift's `onEnd`).
    pub fn session_ended(&self, id: u64, reason: &str, started: bool) {
        if started {
            self.out.log(&format!("session ended: {reason}"));
            self.out.emit(&WorkerEvent::SessionEnded { reason: reason.to_string() });
        } else {
            self.out.log(&format!("rejected a connection: {reason}"));
            self.out.emit(&WorkerEvent::Rejected { reason: reason.to_string() });
        }
        // A session that is no longer the current one must not clear its successor or cut its side links.
        let mut s = self.lock_state();
        if s.current.as_ref().is_some_and(|c| c.id == id) {
            s.current = None;
            drop(s);
            // Side connections belong to the session: drop them so their slots and the store are freed.
            let sides: Vec<SideHandle> = self.lock_sides().drain().map(|(_, h)| h).collect();
            for side in &sides {
                side.abort();
            }
        }
    }
}
