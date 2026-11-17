pub mod fit;
pub mod grid;
pub mod holder;
pub mod launch;
pub mod local;
pub mod view;

use std::sync::atomic::{AtomicU32, AtomicU64, Ordering};
use std::sync::Mutex;
use tokio::sync::{mpsc, watch};

/// What a `run` is called and what it runs. Only the name changes, by a rename.
pub struct Meta {
    /// The stable id of the session, made at start.
    pub key: String,
    pub name: Mutex<String>,
    pub command: String,
    pub pid: u32,
    pub ticket: Option<String>,
}

/// What `run`'s tasks share: the emulator, how to reach the program, and who is watching.
pub struct Shared {
    /// Never held across an `.await`.
    pub emu: Mutex<grid::Emu>,
    /// Bumped on new output or a size change.
    pub rev: watch::Sender<u64>,
    /// Bytes for the pty.
    pub input: mpsc::UnboundedSender<Vec<u8>>,
    pub meta: Meta,
    pub viewers: AtomicU32,
    /// Becomes true when the program has ended.
    pub ended: watch::Sender<bool>,
    /// The Unix second of the last output.
    pub activity: AtomicU64,
    /// Which viewer's size the host window follows.
    pub fit: Mutex<fit::Fit>,
}

impl Meta {
    pub fn name(&self) -> String {
        self.name.lock().unwrap_or_else(|e| e.into_inner()).clone()
    }
}

impl Shared {
    pub fn status(&self) -> local::Status {
        let s = self.emu.lock().unwrap_or_else(|e| e.into_inner()).screen();
        local::Status {
            v: local::LOCAL_V,
            name: self.meta.name(),
            command: self.meta.command.clone(),
            cols: s.cols,
            rows: s.rows,
            activity: self.activity.load(Ordering::Relaxed),
            viewers: self.viewers.load(Ordering::Relaxed),
            pid: self.meta.pid,
            ticket: self.meta.ticket.clone(),
            key: Some(self.meta.key.clone()),
        }
    }
}
