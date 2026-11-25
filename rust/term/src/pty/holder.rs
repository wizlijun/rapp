//! `rapp-term run`: holds a program in a pty inside the terminal window it was started from. The window shows and
//! types exactly as if the program ran there directly; the output also feeds an emulator, which viewers reach over
//! the unix socket `pty/<pid>.sock` (the local protocol in `local`).
//!
//! `run` ends only when the program exits, or on SIGHUP (the window was closed), SIGTERM, SIGINT or SIGQUIT sent
//! to its pid (^C and ^\ typed in the window go to the program: the window is raw); never because of a viewer, a
//! missing `serve` or a socket error. It answers none of the program's terminal queries (the window does) except
//! the OSC 7501 probe, which it answers itself while `programStatus` is on. A viewer may ask the window to resize
//! (`fit`), and the pty follows the window.
//!
//! The exit code is the program's, 1 when the program was killed by a signal; 128 + the signal when `run` itself
//! got SIGHUP (129), SIGINT (130), SIGQUIT (131) or SIGTERM (143).

use super::fit::Window;
use super::grid::Emu;
use super::ps::{Fed, Tracker, MAX_REPLIES, PROBE_REPLY};
use super::{local, view, Meta, Shared};
use crate::id::{clean_name, default_name, session_name};
use anyhow::{anyhow, Context};
use portable_pty::{native_pty_system, CommandBuilder, ExitStatus, MasterPty, PtySize};
use std::io::{Read, Write};
use std::panic::AssertUnwindSafe;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU32, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use tokio::io::{AsyncWriteExt, BufReader};
use tokio::net::{UnixListener, UnixStream};
use tokio::signal::unix::{signal, SignalKind};
use tokio::sync::{mpsc, oneshot, watch};

/// How often a synchronized update whose end never came is checked for its timeout.
const TICK: Duration = Duration::from_millis(50);
/// How long viewers get to be told the program ended.
const VIEWERS_WAIT: Duration = Duration::from_secs(1);
/// How long the program's last output gets to come in after it exited. A process it left behind can keep the pty
/// open for ever.
const DRAIN_WAIT: Duration = Duration::from_secs(1);
/// How long the program gets to end on SIGHUP before it is killed.
const KILL_WAIT: Duration = Duration::from_secs(1);
/// The size when the window's cannot be read.
const DEFAULT_SIZE: (u16, u16) = (80, 24);

pub struct RunOpts {
    pub name: Option<String>,
    /// `$HOME` when not given.
    pub cwd: Option<PathBuf>,
    /// The `term` directory holding `pty/`.
    pub dir: PathBuf,
    pub ticket: Option<String>,
    /// Empty: the user's login shell.
    pub command: Vec<String>,
    /// Answer the OSC 7501 probe and track the program's status (`programStatus` in term.json).
    pub program_status: bool,
}

/// Standard input is not a terminal.
#[derive(Debug)]
pub struct NoTerminal;

impl std::fmt::Display for NoTerminal {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("rapp-term run needs a terminal window")
    }
}

impl std::error::Error for NoTerminal {}

/// Run the program until it exits or the window goes; its exit code.
pub async fn run(opts: RunOpts) -> anyhow::Result<i32> {
    if unsafe { libc::isatty(0) } != 1 {
        return Err(NoTerminal.into());
    }
    // First, so that a window closed during setup still ends run the way it should.
    let mut hup = signal(SignalKind::hangup())?;
    let mut term = signal(SignalKind::terminate())?;
    let mut int = signal(SignalKind::interrupt())?;
    let mut quit = signal(SignalKind::quit())?;
    let mut winch = signal(SignalKind::window_change())?;
    local::ensure_dirs(&opts.dir)?;
    let token: Arc<str> = local::token(&opts.dir)?.into();
    let pid = std::process::id();
    let path = local::socket_path(&opts.dir, pid)?;
    let command = match opts.command.is_empty() {
        true => std::env::var("SHELL").unwrap_or_default(),
        false => opts.command.join(" "),
    };
    let base = match &opts.name {
        Some(n) => session_name(n).ok_or_else(|| anyhow!("invalid name"))?,
        None => session_name(default_name(&command)).unwrap_or_else(|| "shell".into()),
    };
    let (cols, rows) = window_size().unwrap_or(DEFAULT_SIZE);

    // The name: picked and bound under the lock, so two runs starting together never get the same one.
    let dir = opts.dir.clone();
    let lock = tokio::task::spawn_blocking(move || local::name_lock(&dir)).await??;
    let taken: Vec<String> = local::scan(&opts.dir, &token).await.into_iter().map(|s| s.name).collect();
    let name = local::pick_name(&base, &taken);
    let (input, input_rx) = mpsc::unbounded_channel();
    let shared = Arc::new(Shared {
        emu: Mutex::new(Emu::new(cols, rows)),
        rev: watch::channel(0).0,
        input,
        meta: Meta { key: local::new_key(), name: Mutex::new(name), command, pid, ticket: opts.ticket.clone() },
        viewers: AtomicU32::new(0),
        ended: watch::channel(false).0,
        activity: AtomicU64::new(now()),
        fit: Mutex::default(),
        ps: Mutex::new(None),
    });
    let _ = std::fs::remove_file(&path);
    let listener = UnixListener::bind(&path).with_context(|| format!("cannot listen on {}", path.display()))?;
    let bound = Bound(path);
    // Accepting before the lock goes, so the next run's scan finds this one answering.
    tokio::spawn(accept(listener, shared.clone(), token));
    drop(lock);

    let pair = native_pty_system()
        .openpty(PtySize { rows, cols, pixel_width: 0, pixel_height: 0 })
        .map_err(|_| anyhow!("cannot open a pty"))?;
    let mut cmd = match opts.command.split_first() {
        None => CommandBuilder::new_default_prog(),
        Some((program, args)) => {
            let mut c = CommandBuilder::new(program);
            c.args(args);
            c
        }
    };
    if let Some(d) = opts.cwd.clone().or_else(|| std::env::var_os("HOME").map(PathBuf::from)) {
        cmd.cwd(d);
    }
    // The program's own words may quote the command, so they are not passed on.
    let mut child = pair.slave.spawn_command(cmd).map_err(|_| anyhow!("could not start the program"))?;
    drop(pair.slave);
    let mut killer = child.clone_killer();
    let child_pid = child.process_id();
    let (from_pty, to_pty) = match (pair.master.try_clone_reader(), pair.master.take_writer()) {
        (Ok(r), Ok(w)) => (r, w),
        _ => {
            let _ = killer.kill();
            return Err(anyhow!("cannot use the pty"));
        }
    };
    let raw = match Raw::enter() {
        Ok(r) => r,
        Err(e) => {
            let _ = killer.kill();
            return Err(e);
        }
    };

    let (drained_tx, drained) = oneshot::channel();
    let window = Arc::new(Mutex::new(Window::new(std::io::stdout()).tty(unsafe { libc::isatty(1) } == 1)));
    let (sh, win) = (shared.clone(), window.clone());
    let tracker = opts.program_status.then(Tracker::default);
    std::thread::spawn(move || pump_output(from_pty, &win, &sh, drained_tx, Emu::feed, tracker));
    let to_window = shared.input.clone();
    // It may stay blocked on a read when run ends; the process exits under it.
    std::thread::spawn(move || pump_keyboard(to_window));
    std::thread::spawn(move || pump_input(to_pty, input_rx));
    let (exit_tx, mut exited) = oneshot::channel();
    std::thread::spawn(move || {
        let _ = exit_tx.send(child.wait());
    });

    let mut tick = tokio::time::interval(TICK);
    tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    let end = loop {
        tokio::select! {
            status = &mut exited => break End::Exited(exit_code(status)),
            _ = hup.recv() => break End::Signal(libc::SIGHUP),
            _ = term.recv() => break End::Signal(libc::SIGTERM),
            _ = int.recv() => break End::Signal(libc::SIGINT),
            _ = quit.recv() => break End::Signal(libc::SIGQUIT),
            _ = winch.recv() => resize(pair.master.as_ref(), &shared),
            _ = tick.tick() => {
                tick_sync(&shared, Emu::tick);
                resize_window(&window, &shared);
            }
        }
    };
    let code = match end {
        End::Exited(code) => code,
        End::Signal(sig) => {
            let _ = killer.kill();
            if tokio::time::timeout(KILL_WAIT, &mut exited).await.is_err() {
                if let Some(p) = child_pid {
                    unsafe { libc::kill(p as libc::pid_t, libc::SIGKILL) };
                }
                let _ = tokio::time::timeout(KILL_WAIT, &mut exited).await;
            }
            128 + sig
        }
    };
    // The last screen is in before anyone is told it was the last; each viewer sends it before saying so.
    let _ = tokio::time::timeout(DRAIN_WAIT, drained).await;
    shared.ended.send_replace(true);
    let until = Instant::now() + VIEWERS_WAIT;
    while shared.viewers.load(Ordering::Relaxed) > 0 && Instant::now() < until {
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    drop(bound);
    drop(raw);
    Ok(code)
}

/// Why the main loop stopped.
enum End {
    /// The program exited, with this code.
    Exited(i32),
    /// run got this signal.
    Signal(i32),
}

fn now() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |d| d.as_secs())
}

fn exit_code(status: Result<std::io::Result<ExitStatus>, oneshot::error::RecvError>) -> i32 {
    match status {
        Ok(Ok(s)) => i32::try_from(s.exit_code()).unwrap_or(1),
        _ => 1,
    }
}

/// The window's size, from standard output.
fn window_size() -> Option<(u16, u16)> {
    let mut w: libc::winsize = unsafe { std::mem::zeroed() };
    let ok = unsafe { libc::ioctl(1, libc::TIOCGWINSZ, &mut w) } == 0;
    (ok && w.ws_col > 0 && w.ws_row > 0).then_some((w.ws_col, w.ws_row))
}

/// The window changed size: so do the pty and the emulator.
fn resize(master: &dyn MasterPty, shared: &Shared) {
    let Some((cols, rows)) = window_size() else { return };
    let _ = master.resize(PtySize { rows, cols, pixel_width: 0, pixel_height: 0 });
    guarded(shared, Some((cols, rows)), |emu| emu.resize(cols, rows));
    shared.rev.send_modify(|r| *r += 1);
}

/// Apply a synchronized update whose end never came once its time is up, through `tick`.
fn tick_sync(shared: &Shared, tick: impl FnOnce(&mut Emu)) {
    // Applying replays the held bytes through the parser, so it can panic like a feed.
    let applied = guarded(shared, None, |emu| {
        if !emu.sync_pending() {
            return false;
        }
        tick(emu);
        !emu.sync_pending()
    });
    // None: a fresh emulator, which viewers are shown too.
    if applied != Some(false) {
        shared.rev.send_modify(|r| *r += 1);
    }
}

/// A resize a viewer asked for, while the program's output is quiet. Never waits for the window: the output pump
/// may be in a slow write to it, and this runs on the main loop; the next tick tries again.
fn resize_window<W: Write>(window: &Mutex<Window<W>>, shared: &Shared) {
    // Accepted risk: the ~12-byte write below can still block if the host terminal stops reading; rare, so not
    // worth a thread of its own.
    let mut w = match window.try_lock() {
        Ok(w) => w,
        Err(std::sync::TryLockError::Poisoned(e)) => e.into_inner(),
        Err(std::sync::TryLockError::WouldBlock) => return,
    };
    // A window that is gone fails quietly, as its output does.
    let _ = w.resize_if_idle(&shared.fit);
}

/// The program's output: to the window first, with any resize a viewer asked for once it is between sequences, then
/// to the emulator through `feed`. Says so on `drained` when the pty is done.
fn pump_output<W: Write>(
    mut pty: impl Read,
    window: &Mutex<Window<W>>,
    shared: &Shared,
    drained: oneshot::Sender<()>,
    feed: impl Fn(&mut Emu, &[u8]),
    mut tracker: Option<Tracker>,
) {
    let mut b = vec![0u8; 64 * 1024];
    loop {
        let n = match pty.read(&mut b) {
            Ok(0) => break,
            Ok(n) => n,
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(_) => break,
        };
        // The probe's answer is queued before the window sees the chunk, so the window's own answers to whatever
        // the program sent after the probe come behind it. The tracker is outside `guarded`: an emulator panic
        // cannot stop it. At most MAX_REPLIES answers per chunk keeps an unread input queue bounded by the output.
        if tracker.is_some() {
            let at = now();
            match track(&mut tracker, |t| t.feed(&b[..n], at)) {
                Some(fed) => {
                    if fed.probes > 0 {
                        let _ = shared.input.send(PROBE_REPLY.repeat(fed.probes.min(MAX_REPLIES)));
                    }
                    if fed.changed {
                        *shared.ps.lock().unwrap_or_else(|e| e.into_inner()) = tracker.as_ref().and_then(|t| t.ps().cloned());
                    }
                }
                // The tracker panicked and is gone: the status stops, the output keeps flowing.
                None if tracker.is_none() => *shared.ps.lock().unwrap_or_else(|e| e.into_inner()) = None,
                None => {}
            }
        }
        // A window that is gone is no reason to stop: viewers still see the screen.
        {
            let mut w = window.lock().unwrap_or_else(|e| e.into_inner());
            let _ = w.output(&b[..n]);
            let _ = w.resize_if_idle(&shared.fit);
        }
        guarded(shared, None, |emu| feed(emu, &b[..n]));
        shared.activity.store(now(), Ordering::Relaxed);
        shared.rev.send_modify(|r| *r += 1);
    }
    let _ = drained.send(());
}

/// Runs `f` on the tracker; if it panics the tracker is dropped (None) and so is the result. Nothing the program
/// prints may stop `pump_output`, the only thread draining the pty.
fn track(tracker: &mut Option<Tracker>, f: impl FnOnce(&mut Tracker) -> Fed) -> Option<Fed> {
    let t = tracker.as_mut()?;
    match std::panic::catch_unwind(AssertUnwindSafe(|| f(t))) {
        Ok(v) => Some(v),
        Err(_) => {
            *tracker = None;
            None
        }
    }
}

/// Runs `f` on the emulator; None when it panicked, and the emulator is then a fresh one of size `fresh`, or else of
/// the size it had. No escape sequence may end run (the main loop ticks and resizes it) or stop its output
/// (`pump_output` is the only thread draining the pty).
fn guarded<T>(shared: &Shared, fresh: Option<(u16, u16)>, f: impl FnOnce(&mut Emu) -> T) -> Option<T> {
    let mut emu = shared.emu.lock().unwrap_or_else(|e| e.into_inner());
    let (cols, rows) = fresh.unwrap_or_else(|| emu.size());
    match std::panic::catch_unwind(AssertUnwindSafe(|| f(&mut emu))) {
        Ok(v) => Some(v),
        Err(_) => {
            // The window is raw: the line ends with its own carriage return. A window that is gone fails quietly.
            let line = b"rapp-term: the emulator failed on the program's output; viewers start from a blank screen\r\n";
            let _ = std::io::stderr().write_all(line);
            *emu = Emu::new(cols, rows);
            None
        }
    }
}

/// The window's keyboard, into the same queue viewers type into.
fn pump_keyboard(input: mpsc::UnboundedSender<Vec<u8>>) {
    let mut stdin = std::io::stdin();
    let mut b = [0u8; 4096];
    loop {
        match stdin.read(&mut b) {
            Ok(0) => return,
            Ok(n) => {
                if input.send(b[..n].to_vec()).is_err() {
                    return;
                }
            }
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => {}
            Err(_) => return,
        }
    }
}

/// The queue into the pty, for as long as run lives. Once the pty stops taking bytes (the program is gone) the
/// rest is dropped, so viewers sending more never see an error for it.
fn pump_input(mut pty: Box<dyn Write + Send>, mut input: mpsc::UnboundedReceiver<Vec<u8>>) {
    let mut open = true;
    while let Some(b) = input.blocking_recv() {
        if open {
            open = pty.write_all(&b).and_then(|()| pty.flush()).is_ok();
        }
    }
}

/// Connections, each on its own task: whatever goes wrong with one ends only that one.
async fn accept(listener: UnixListener, shared: Arc<Shared>, token: Arc<str>) {
    loop {
        match listener.accept().await {
            Ok((s, _)) => {
                tokio::spawn(client(s, shared.clone(), token.clone()));
            }
            // Out of files or the like: this connection is lost, the next may work.
            Err(_) => tokio::time::sleep(Duration::from_millis(50)).await,
        }
    }
}

async fn client(s: UnixStream, shared: Arc<Shared>, token: Arc<str>) {
    let (r, mut w) = s.into_split();
    let mut r = BufReader::new(r);
    let head = match local::read_head(&mut r, &token).await {
        Ok(h) => h,
        Err(e) => {
            let _ = w.write_all(format!("{}\n", serde_json::json!({ "error": e })).as_bytes()).await;
            return;
        }
    };
    match head.op.as_str() {
        "status" => {
            let line = serde_json::to_string(&shared.status()).expect("always serializes");
            let _ = w.write_all(format!("{line}\n").as_bytes()).await;
        }
        "view" => {
            let _ = view::serve(shared, r, w).await;
        }
        "rename" => {
            let reply = match head.name.as_deref().and_then(clean_name) {
                Some(n) => {
                    *shared.meta.name.lock().unwrap_or_else(|e| e.into_inner()) = n;
                    serde_json::json!({ "ok": true })
                }
                None => serde_json::json!({ "error": "invalid name" }),
            };
            let _ = w.write_all(format!("{reply}\n").as_bytes()).await;
        }
        _ => {
            let reply = serde_json::json!({ "error": "unsupported", "v": local::LOCAL_V });
            let _ = w.write_all(format!("{reply}\n").as_bytes()).await;
        }
    }
}

/// The socket file, removed on every way out.
struct Bound(PathBuf);

impl Drop for Bound {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.0);
    }
}

/// The window in raw mode; put back as it was on every way out.
struct Raw(libc::termios);

impl Raw {
    fn enter() -> anyhow::Result<Raw> {
        let mut was: libc::termios = unsafe { std::mem::zeroed() };
        if unsafe { libc::tcgetattr(0, &mut was) } != 0 {
            return Err(std::io::Error::last_os_error()).context("cannot read the window's mode");
        }
        let mut raw = was;
        unsafe { libc::cfmakeraw(&mut raw) };
        if unsafe { libc::tcsetattr(0, libc::TCSANOW, &raw) } != 0 {
            return Err(std::io::Error::last_os_error()).context("cannot put the window in raw mode");
        }
        Ok(Raw(was))
    }
}

impl Drop for Raw {
    fn drop(&mut self) {
        // Fails harmlessly when the window is gone.
        unsafe { libc::tcsetattr(0, libc::TCSANOW, &self.0) };
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::VecDeque;

    /// Hands out one chunk per read.
    struct Chunks(VecDeque<&'static [u8]>);

    impl Read for Chunks {
        fn read(&mut self, b: &mut [u8]) -> std::io::Result<usize> {
            let Some(c) = self.0.pop_front() else { return Ok(0) };
            b[..c.len()].copy_from_slice(c);
            Ok(c.len())
        }
    }

    fn shared(cols: u16, rows: u16) -> Shared {
        shared_with_input(cols, rows).0
    }

    fn shared_with_input(cols: u16, rows: u16) -> (Shared, mpsc::UnboundedReceiver<Vec<u8>>) {
        let (input, rx) = mpsc::unbounded_channel();
        let sh = Shared {
            emu: Mutex::new(Emu::new(cols, rows)),
            rev: watch::channel(0).0,
            input,
            meta: Meta { key: "0123456789abcdef".into(), name: Mutex::new("t".into()), command: "sh".into(), pid: 1, ticket: None },
            viewers: AtomicU32::new(0),
            ended: watch::channel(false).0,
            activity: AtomicU64::new(0),
            fit: Mutex::default(),
            ps: Mutex::new(None),
        };
        (sh, rx)
    }

    /// Before each write to the window, notes what is already queued for the program, then the write.
    struct Ordered {
        rx: mpsc::UnboundedReceiver<Vec<u8>>,
        log: Vec<String>,
    }

    impl Write for Ordered {
        fn write(&mut self, b: &[u8]) -> std::io::Result<usize> {
            while let Ok(v) = self.rx.try_recv() {
                self.log.push(format!("reply:{}", v.len()));
            }
            self.log.push("window".into());
            Ok(b.len())
        }
        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }

    #[test]
    fn the_probe_answer_is_queued_before_the_window_sees_the_probe() {
        let (sh, rx) = shared_with_input(30, 4);
        let window = Mutex::new(Window::new(Ordered { rx, log: vec![] }));
        let (tx, _d) = oneshot::channel();
        let pty = Chunks(VecDeque::from([&b"\x1b]7501;?\x07\x1b[c"[..]]));
        pump_output(pty, &window, &sh, tx, Emu::feed, Some(Tracker::default()));
        assert_eq!(window.lock().unwrap().get_ref().log, ["reply:10", "window"]);
    }

    #[test]
    fn a_panicking_tracker_is_dropped_and_output_keeps_flowing() {
        let mut t = Some(Tracker::default());
        assert!(track(&mut t, |_| panic!("tracker fell over")).is_none());
        assert!(t.is_none());
        assert!(track(&mut t, |t| t.feed(b"x", 1)).is_none());
    }

    #[test]
    fn a_report_updates_shared_ps() {
        let (sh, _rx) = shared_with_input(30, 4);
        let window = Mutex::new(Window::new(Vec::new()));
        let (tx, _d) = oneshot::channel();
        let pty = Chunks(VecDeque::from([&b"\x1b]7501;state=blocked:kind=permission:app=claude-code\x07"[..]]));
        pump_output(pty, &window, &sh, tx, Emu::feed, Some(Tracker::default()));
        let ps = sh.status().ps.unwrap();
        assert_eq!((ps.state.as_str(), ps.kind.as_deref()), ("blocked", Some("permission")));
    }

    #[test]
    fn a_flood_of_probes_gets_64_answers() {
        let (sh, mut rx) = shared_with_input(30, 4);
        let window = Mutex::new(Window::new(Vec::new()));
        let (tx, _d) = oneshot::channel();
        let flood: &'static [u8] = Box::leak(b"\x1b]7501;?\x07".repeat(1000).into_boxed_slice());
        pump_output(Chunks(VecDeque::from([flood])), &window, &sh, tx, Emu::feed, Some(Tracker::default()));
        assert_eq!(rx.try_recv().unwrap().len(), 64 * PROBE_REPLY.len());
        assert!(rx.try_recv().is_err());
        assert_eq!(window.lock().unwrap().get_ref().as_slice(), flood); // the output was not stalled
    }

    #[test]
    fn status_keeps_updating_when_the_emulator_panics() {
        let (sh, _rx) = shared_with_input(30, 4);
        let window = Mutex::new(Window::new(Vec::new()));
        let (tx, _d) = oneshot::channel();
        let pty = Chunks(VecDeque::from([&b"\x1b]7501;state=working\x07"[..]]));
        pump_output(pty, &window, &sh, tx, |_: &mut Emu, _: &[u8]| panic!("the emulator fell over"), Some(Tracker::default()));
        assert_eq!(sh.status().ps.unwrap().state, "working");
    }

    #[test]
    fn off_means_byte_for_byte_today() {
        let (sh, mut rx) = shared_with_input(30, 4);
        let window = Mutex::new(Window::new(Vec::new()));
        let (tx, _d) = oneshot::channel();
        let bytes: &[u8] = b"\x1b]7501;?\x07\x1b]7501;state=working\x07hi";
        pump_output(Chunks(VecDeque::from([bytes])), &window, &sh, tx, Emu::feed, None);
        assert_eq!(window.lock().unwrap().get_ref().as_slice(), bytes);
        assert!(rx.try_recv().is_err() && sh.status().ps.is_none());
    }

    #[test]
    fn an_emulator_panic_never_stops_the_window_s_output() {
        let sh = shared(30, 4);
        let window = Mutex::new(Window::new(Vec::new()));
        let (tx, mut drained) = oneshot::channel();
        let pty = Chunks(VecDeque::from([&b"one "[..], b"boom ", b"two"]));
        pump_output(pty, &window, &sh, tx, |emu: &mut Emu, b: &[u8]| {
            assert!(!b.starts_with(b"boom"), "the emulator fell over");
            emu.feed(b);
        }, None);
        assert_eq!(window.lock().unwrap().get_ref().as_slice(), b"one boom two");
        assert!(drained.try_recv().is_ok());
        // A fresh emulator, at the old size, with what came after.
        let s = sh.emu.lock().unwrap().screen();
        assert_eq!((s.cols, s.rows, s.lines[0].as_str()), (30, 4, "two"));
    }

    #[test]
    fn an_emulator_panic_on_a_tick_is_caught_and_shown() {
        let sh = shared(30, 4);
        // A synchronized update whose end never comes.
        sh.emu.lock().unwrap().feed(b"\x1b[?2026hheld");
        assert!(sh.emu.lock().unwrap().sync_pending());
        let rev = sh.rev.subscribe();
        tick_sync(&sh, |_: &mut Emu| panic!("the emulator fell over"));
        let emu = sh.emu.lock().unwrap();
        assert!(!emu.sync_pending());
        assert_eq!((emu.size(), emu.screen().lines[0].as_str()), ((30, 4), ""));
        assert!(rev.has_changed().unwrap(), "viewers are told");
    }

    #[test]
    fn an_emulator_that_panics_on_a_resize_comes_back_at_the_new_size() {
        let sh = shared(30, 4);
        let done = guarded(&sh, Some((50, 6)), |_: &mut Emu| panic!("the emulator fell over"));
        assert!(done.is_none());
        assert_eq!(sh.emu.lock().unwrap().size(), (50, 6));
        assert_eq!(guarded(&sh, None, |e: &mut Emu| e.size()), Some((50, 6)));
    }
}
