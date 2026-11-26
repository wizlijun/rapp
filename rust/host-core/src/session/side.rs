//! One `fetch` (22) or `put` (23) connection (`SideConnection.swift`, spec §2.4): it carries a
//! single transfer and closes. Each runs on its own thread, the intake thread that read its
//! first message; file reads and writes happen there, never on the session thread.

use std::io::{ErrorKind, Read, Write};
use std::net::{Shutdown, TcpStream};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};

use crate::protocol::{constant_time_equals, Message, MessageParser};
use crate::transfers::{FetchSource, PutSink};

use super::clip::{lock_store, SharedStore};
use super::intake::{read_timeout, READ_SLICE};
use super::server::Inner;
use super::session::WRITE_TIMEOUT;

/// Swift reads at most this much per receive.
const READ_BUFFER: usize = 512 * 1024;
/// After `fail`, the error gets this long to go out before the connection closes.
const FAIL_WAIT: f64 = 1.0;

/// What the server keeps of a running side connection: enough to abort it when its session ends.
pub struct SideHandle {
    stream: TcpStream,
    aborted: Arc<AtomicBool>,
}

impl SideHandle {
    pub fn new(stream: TcpStream, aborted: Arc<AtomicBool>) -> Self {
        SideHandle { stream, aborted }
    }

    /// The session is over: close without a word (`abort`). The thread sees the closed socket
    /// or the flag and ends, releasing its slot.
    pub fn abort(&self) {
        self.aborted.store(true, Ordering::SeqCst);
        let _ = self.stream.shutdown(Shutdown::Both);
    }
}

fn lock_sink(s: &Mutex<PutSink>) -> MutexGuard<'_, PutSink> {
    s.lock().unwrap_or_else(|e| e.into_inner())
}

pub struct SideConnection {
    inner: Arc<Inner>,
    id: u64,
    stream: TcpStream,
    parser: MessageParser,
    first: Message,
    /// The current session's store when the connection arrived (`session?.transfers`).
    transfers: Option<SharedStore>,
    aborted: Arc<AtomicBool>,
    took_slot: bool,
    ended: bool,
    /// The closing message went out; later input is ignored (`finishing`).
    finishing: bool,
}

impl SideConnection {
    pub fn new(
        inner: Arc<Inner>,
        id: u64,
        stream: TcpStream,
        parser: MessageParser,
        first: Message,
        transfers: Option<SharedStore>,
        aborted: Arc<AtomicBool>,
    ) -> Self {
        SideConnection {
            inner,
            id,
            stream,
            parser,
            first,
            transfers,
            aborted,
            took_slot: false,
            ended: false,
            finishing: false,
        }
    }

    /// Runs the whole transfer on the calling thread, then ends.
    pub fn run(mut self) {
        let _ = self.stream.set_write_timeout(Some(self.inner.clock.real(WRITE_TIMEOUT)));
        self.start();
        self.end();
    }

    fn aborted(&self) -> bool {
        self.aborted.load(Ordering::SeqCst)
    }

    /// `SideConnection.start`.
    fn start(&mut self) {
        if !self.inner.take_side_slot() {
            return self.fail("busy");
        }
        self.took_slot = true;
        match self.first.clone() {
            Message::Fetch { token, clip, file, offset } => {
                if !constant_time_equals(&token, &self.inner.options.token) {
                    return self.fail("bad token");
                }
                let Some(store) = self.transfers.clone() else { return self.fail("no session") };
                self.inner.out.log(&format!("side fetch clip {clip} file {file} from {offset}"));
                // Opening the file and checking it is unchanged happens under the store's lock,
                // on this thread.
                let fetched = lock_store(&store).fetch(clip, file, offset);
                let mut source = match fetched {
                    Ok(s) => s,
                    Err(e) => return self.fail(&e.0),
                };
                if !self.send(&Message::TransferStart(source.total)) {
                    return;
                }
                self.send_chunks(&mut source);
            }
            Message::Put { token, item, kind, uti, name, total } => {
                if !constant_time_equals(&token, &self.inner.options.token) {
                    return self.fail("bad token");
                }
                let Some(store) = self.transfers.clone() else { return self.fail("no session") };
                let put = lock_store(&store).put(item, kind, &uti, &name, total);
                let sink = match put {
                    Ok(s) => s,
                    Err(e) => return self.fail(&e.0),
                };
                let (have, sink_total) = {
                    let s = lock_sink(&sink);
                    (s.have(), s.total)
                };
                self.inner.out.log(&format!("side put item {item} have {have}"));
                if !self.send(&Message::TransferStart(have)) {
                    return;
                }
                if have == sink_total {
                    return self.finish_put(&sink);
                }
                self.receive_chunks(&sink);
            }
            _ => self.fail("unexpected message from client"),
        }
    }

    // MARK: Fetch

    /// Each chunk goes out after the previous one has left (a blocking write), so a slow B holds
    /// the file reads back (`sendNextChunk`).
    fn send_chunks(&mut self, source: &mut FetchSource) {
        loop {
            if self.ended || self.aborted() {
                return;
            }
            match source.next() {
                Ok(Some(chunk)) => {
                    if !self.send(&Message::Chunk(chunk)) {
                        return;
                    }
                }
                Ok(None) => {
                    self.inner.out.emit(&source.transfer);
                    return;
                }
                Err(e) => return self.fail(&e.0),
            }
        }
    }

    // MARK: Put

    /// Reads chunks until the item is complete, the client closes, or a failure (`receive`,
    /// `drain`, `handle`).
    fn receive_chunks(&mut self, sink: &Arc<Mutex<PutSink>>) {
        let mut buf = vec![0u8; READ_BUFFER];
        loop {
            loop {
                if self.ended || self.finishing {
                    return;
                }
                match self.parser.next() {
                    Ok(Some(m)) => self.handle(m, sink),
                    Ok(None) => break,
                    Err(_) => return self.fail("bad data from client"),
                }
            }
            if self.finishing || self.aborted() {
                return;
            }
            let _ = self.stream.set_read_timeout(Some(read_timeout(self.inner.clock.as_ref(), READ_SLICE)));
            match self.stream.read(&mut buf) {
                // A client that stops before the item is complete: the part file stays for a retry.
                Ok(0) => return,
                Ok(n) => self.parser.append(&buf[..n]),
                Err(e) if matches!(e.kind(), ErrorKind::WouldBlock | ErrorKind::TimedOut | ErrorKind::Interrupted) => {}
                Err(_) => return,
            }
        }
    }

    fn handle(&mut self, message: Message, sink: &Arc<Mutex<PutSink>>) {
        if self.finishing {
            return;
        }
        let Message::Chunk(bytes) = message else { return self.fail("unexpected message from client") };
        let written = lock_sink(sink).write(&bytes);
        match written {
            Ok(true) => self.finish_put(sink),
            Ok(false) => {}
            Err(e) => self.fail(&e.0),
        }
    }

    /// The upload is complete: an empty chunk tells B, then the connection closes.
    fn finish_put(&mut self, sink: &Arc<Mutex<PutSink>>) {
        self.finishing = true;
        let transfer = lock_sink(sink).transfer();
        self.inner.out.emit(&transfer);
        let _ = self.send(&Message::Chunk(Vec::new()));
    }

    // MARK: Sending and ending

    /// A blocking write; false (and the connection ends) when it failed.
    fn send(&mut self, message: &Message) -> bool {
        if self.ended {
            return false;
        }
        let ok = self.stream.write_all(&message.encoded()).and_then(|_| self.stream.flush()).is_ok();
        if !ok {
            self.end();
        }
        ok
    }

    fn fail(&mut self, reason: &str) {
        if self.ended {
            return;
        }
        self.finishing = true;
        self.inner.out.log(&format!("side connection: {reason}"));
        // Closed once sent, or after 1 s.
        let _ = self.stream.set_write_timeout(Some(self.inner.clock.real(FAIL_WAIT)));
        let _ = self.send(&Message::Error(reason.to_string()));
    }

    fn end(&mut self) {
        if self.ended {
            return;
        }
        self.ended = true;
        if self.took_slot {
            self.inner.release_side_slot();
        }
        let _ = self.stream.shutdown(Shutdown::Both);
        self.inner.side_ended(self.id);
    }
}
