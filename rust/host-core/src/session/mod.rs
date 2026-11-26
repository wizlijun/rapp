//! The serving side of the worker (`Sources/rapp-host/Server.swift`).
//!
//! Threads (plan B Task 13 step 3): one accept loop (`server`); per connection an intake
//! thread that reads the first message (`intake`) and then keeps reading for the session it
//! opened; one session thread that owns all session state and handles one `Event` at a time,
//! which is what Swift's serial queue gives (`session`); background threads for the platform
//! calls that may be slow (window polls, capture, queries, paste, unlock). They never touch
//! session state: they post an `Event` back.

pub mod capture;
pub mod intake;
pub mod server;
pub mod session;
mod stage;
pub mod tracker;

use std::sync::{Arc, Mutex, MutexGuard};

use crate::platform::RawWindow;
use crate::protocol::{CodecError, Message, WindowInfo};

/// A platform handle several threads share. Each call takes the lock for that call only.
pub type Shared<T> = Arc<Mutex<Box<T>>>;

pub fn shared<T: ?Sized>(b: Box<T>) -> Shared<T> {
    Arc::new(Mutex::new(b))
}

/// Locks a shared handle; a panic on another thread does not poison it for the session.
pub fn hold<T: ?Sized>(m: &Mutex<Box<T>>) -> MutexGuard<'_, Box<T>> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

/// A job a background thread finished; it runs on the session thread.
pub type Job = Box<dyn FnOnce(&mut session::Session) + Send>;

/// One thing for the session thread to handle.
pub enum Event {
    /// A message from the client's connection.
    Message(Message),
    /// The connection's bytes did not parse.
    BadData(CodecError),
    /// The connection ended; the reason the session ends with.
    Closed(String),
    /// Another hello took over; `ack` is answered once this session has ended.
    TakeOver { by: Option<String>, ack: std::sync::mpsc::Sender<()> },
    /// stdin `kick`.
    Kick,
    /// stdin `quit` or EOF: end with "host stopped"; `ack` once ended.
    Stop { ack: std::sync::mpsc::Sender<()> },
    /// stdin `yield`.
    Yield(String),
    /// The capture thread left a picture in its slot (`capture::CaptureHandle::take`).
    FrameReady,
    /// The capture thread gave up.
    CaptureStopped(String),
    /// A new window table from the poll thread, with the raw list it came from.
    Table(Vec<WindowInfo>, Vec<RawWindow>),
    /// A background job's result.
    Run(Job),
}
