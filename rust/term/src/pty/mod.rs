pub mod consent;
pub mod fg;
pub mod fit;
pub mod grid;
#[cfg(unix)]
pub mod holder;
#[cfg(unix)]
pub mod launch;
#[cfg(unix)]
pub mod local;
// Windows: snapshots need unix permissions, `kill` and the holder's socket; back in phase E.
#[cfg(unix)]
pub mod saved;
pub mod ps;
pub mod reply;
pub mod resume;
pub mod shell;
pub mod sweep;
pub mod title;
pub mod view;
pub mod wintitle;

use std::sync::atomic::{AtomicU32, AtomicU64, Ordering};
use std::sync::Mutex;
use std::time::{SystemTime, UNIX_EPOCH};
use tokio::sync::{mpsc, watch};

/// What a `run` is called and what it runs. Only the name changes, by a rename.
pub struct Meta {
    /// The stable id of the session, made at start.
    pub key: String,
    pub name: Mutex<String>,
    pub command: String,
    pub pid: u32,
    pub ticket: Option<String>,
    /// True once the name was given by hand (`run --name` or a rename): the program's title is then not reported.
    pub named: std::sync::atomic::AtomicBool,
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
    /// The program's own status, kept by the output pump.
    pub ps: Mutex<Option<ps::Ps>>,
    /// The title the program set (OSC 0/1/2), cleaned; kept by the output pump.
    pub title: Mutex<Option<String>>,
    /// The foreground program and its directory, probed once a second by the holder.
    pub fg: Mutex<fg::Fg>,
    /// Bumped whenever `fg` changed. The title composer (a later task) subscribes with `fg_rev.subscribe()`.
    pub fg_rev: watch::Sender<u64>,
    /// What the shell hook reported; kept by the output pump.
    pub shell: Mutex<shell::ShellState>,
    /// The Unix second of the last input (keyboard or viewer); 0 for never.
    pub input_at: AtomicU64,
    /// Bumped whenever anything a snapshot holds changes: shell state, name, foreground program or directory.
    pub dirty: watch::Sender<u64>,
    /// The holder's own window tty (`ttyname(0)`, read once at start); none when not a tty.
    pub tty: Option<String>,
    /// Notified by the `end` op; the run loop then ends like a closed window.
    pub end: tokio::sync::Notify,
    /// Notified at each shell prompt (`OSC 133;A`); a restored terminal pre-types its command after the first.
    pub prompted: tokio::sync::Notify,
}

impl Meta {
    pub fn name(&self) -> String {
        self.name.lock().unwrap_or_else(|e| e.into_inner()).clone()
    }
}

impl Shared {
    /// Notes that input just went to the program.
    pub fn note_input(&self) {
        let t = SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |d| d.as_secs());
        self.input_at.store(t, Ordering::Relaxed);
    }

    /// Tells snapshot writers something changed.
    pub fn touch(&self) {
        self.dirty.send_modify(|v| *v += 1);
    }

    #[cfg(unix)]
    pub fn status(&self) -> local::Status {
        let fg = self.fg.lock().unwrap_or_else(|e| e.into_inner()).clone();
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
            ps: self.ps.lock().unwrap_or_else(|e| e.into_inner()).clone(),
            title: if self.meta.named.load(Ordering::Relaxed) { None } else { self.title.lock().unwrap_or_else(|e| e.into_inner()).clone() },
            fg: fg.prog.clone(),
            cwd: fg.cwd.as_ref().map(|p| p.to_string_lossy().into_owned()),
            shell: fg.probed.then_some(fg.shell),
            tty: self.tty.clone(),
            input: self.input_at.load(Ordering::Relaxed),
            reply: true,
        }
    }
}
