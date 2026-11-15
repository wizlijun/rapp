//! `rapp-term run`: holds a program in a pty inside the terminal window it was started from. The window shows and
//! types exactly as if the program ran there directly; the output also feeds an emulator, which viewers reach over
//! the unix socket `pty/<pid>.sock` (the local protocol in `local`).
//!
//! `run` ends only when the program exits, or on SIGHUP (the window was closed) or SIGTERM; never because of a
//! viewer, a missing `serve` or a socket error. It answers none of the program's terminal queries (the window
//! does), and viewers never change the pty's size.
//!
//! The exit code is the program's, 1 when the program was killed by a signal; 128 + the signal when `run` itself
//! got SIGHUP (129) or SIGTERM (143).

use super::grid::Emu;
use super::{local, view, Meta, Shared};
use crate::id::{default_name, session_name};
use anyhow::{anyhow, Context};
use portable_pty::{native_pty_system, CommandBuilder, ExitStatus, MasterPty, PtySize};
use std::io::{Read, Write};
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
        meta: Meta { name, command, pid, ticket: opts.ticket.clone() },
        viewers: AtomicU32::new(0),
        ended: watch::channel(false).0,
        activity: AtomicU64::new(now()),
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
    let sh = shared.clone();
    std::thread::spawn(move || pump_output(from_pty, &sh, drained_tx));
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
            _ = winch.recv() => resize(pair.master.as_ref(), &shared),
            _ = tick.tick() => tick_sync(&shared),
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
    shared.emu.lock().unwrap_or_else(|e| e.into_inner()).resize(cols, rows);
    shared.rev.send_modify(|r| *r += 1);
}

/// Apply a synchronized update whose end never came once its time is up.
fn tick_sync(shared: &Shared) {
    let mut emu = shared.emu.lock().unwrap_or_else(|e| e.into_inner());
    if !emu.sync_pending() {
        return;
    }
    emu.tick();
    let applied = !emu.sync_pending();
    drop(emu);
    if applied {
        shared.rev.send_modify(|r| *r += 1);
    }
}

/// The program's output: to the window first, then to the emulator. Says so on `drained` when the pty is done.
fn pump_output(mut pty: Box<dyn Read + Send>, shared: &Shared, drained: oneshot::Sender<()>) {
    let mut window = std::io::stdout();
    let mut b = vec![0u8; 64 * 1024];
    loop {
        let n = match pty.read(&mut b) {
            Ok(0) => break,
            Ok(n) => n,
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(_) => break,
        };
        // A window that is gone is no reason to stop: viewers still see the screen.
        let _ = window.write_all(&b[..n]).and_then(|()| window.flush());
        shared.emu.lock().unwrap_or_else(|e| e.into_inner()).feed(&b[..n]);
        shared.activity.store(now(), Ordering::Relaxed);
        shared.rev.send_modify(|r| *r += 1);
    }
    let _ = drained.send(());
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
