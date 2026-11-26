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

use super::fg::LaunchInfo;
use super::fit::Window;
use super::grid::Emu;
use super::ps::{Fed, Tracker, MAX_REPLIES, PROBE_REPLY};
use super::saved::{self, Snapshot};
use super::{local, view, Meta, Shared};
use crate::id::{clean_name, default_name, session_name};
use anyhow::{anyhow, Context};
use portable_pty::{native_pty_system, CommandBuilder, ExitStatus, MasterPty, PtySize};
use std::io::{Read, Write};
use std::panic::AssertUnwindSafe;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering};
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
/// A snapshot is written once nothing changed for this long.
const SNAPSHOT_QUIET: Duration = Duration::from_secs(2);
/// ... or once things kept changing for this long, so a program that never settles is still saved.
const SNAPSHOT_MAX_WAIT: Duration = Duration::from_secs(10);
/// How long a restored terminal waits for its shell's first prompt before it pre-types the command anyway.
const PREFILL_WAIT: Duration = Duration::from_secs(2);
/// The shells a snapshot names as its shell when one is the command.
const SHELLS: [&str; 8] = ["zsh", "bash", "fish", "sh", "dash", "ksh", "tcsh", "csh"];

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
    /// Start zsh, bash and fish through the shell hook (`shellHook` in term.json).
    pub shell_hook: bool,
    /// The key of the terminal to restore (`saved/<key>.json`): its key, name, directory, environments and command.
    pub restore: Option<String>,
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

/// How to start the command through the shell hook; none when it is not a hooked shell or the hook files cannot be
/// written (the shell then starts as it is).
fn hook_launch(opts: &RunOpts, restore: Option<&super::shell::Restore>) -> Option<super::shell::Launch> {
    let zdotdir = std::env::var_os("ZDOTDIR");
    // A ZDOTDIR that is not UTF-8 could not be put back as it was: no hook rather than the wrong startup files.
    let zdotdir = match &zdotdir {
        Some(z) => Some(z.to_str()?),
        None => None,
    };
    let dir = super::shell::install(&opts.dir).ok()?;
    super::shell::launch(&opts.command, &dir, zdotdir, restore)
}

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
    // The terminal to restore: its snapshot, unless there is none for the key.
    let mut restoring = opts.restore.as_deref().and_then(|k| saved::read(&opts.dir, k).filter(|s| s.key == k));

    // The name (and a restored key): picked and bound under the lock, so two runs starting together never get the same.
    let dir = opts.dir.clone();
    let lock = tokio::task::spawn_blocking(move || local::name_lock(&dir)).await??;
    let live = local::scan(&opts.dir, &token).await;
    // A key that is live already is that terminal's: this one starts as a new terminal.
    if restoring.as_ref().is_some_and(|r| live.iter().any(|s| s.key.as_deref() == Some(r.key.as_str()))) {
        restoring = None;
    }
    let taken: Vec<String> = live.into_iter().map(|s| s.name).collect();
    let base = restoring.as_ref().and_then(|r| session_name(&r.name)).unwrap_or(base);
    let name = local::pick_name(&base, &taken);
    let key = restoring.as_ref().map_or_else(local::new_key, |r| r.key.clone());
    let named = restoring.as_ref().map_or(opts.name.is_some(), |r| r.named);
    let (input, input_rx) = mpsc::unbounded_channel();
    let shared = Arc::new(Shared {
        emu: Mutex::new(Emu::new(cols, rows)),
        rev: watch::channel(0).0,
        input,
        meta: Meta { key, name: Mutex::new(name), command, pid, ticket: opts.ticket.clone(), named: AtomicBool::new(named) },
        viewers: AtomicU32::new(0),
        ended: watch::channel(false).0,
        activity: AtomicU64::new(now()),
        fit: Mutex::default(),
        ps: Mutex::new(None),
        title: Mutex::new(None),
        fg: Mutex::default(),
        fg_rev: watch::channel(0).0,
        shell: Mutex::default(),
        input_at: AtomicU64::new(0),
        dirty: watch::channel(0).0,
        tty: tty_name(),
        end: tokio::sync::Notify::new(),
        prompted: tokio::sync::Notify::new(),
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
    let restore = restoring.as_ref().map(|r| super::shell::Restore { venv: r.venv.clone(), conda: r.conda.clone() });
    let hook = if opts.shell_hook { hook_launch(&opts, restore.as_ref()) } else { None };
    // The restored command waits for the user, pre-typed; its directory and (through the hook) environments are
    // the snapshot's until the shell reports its own.
    let prefill_text = restoring.as_ref().and_then(|r| {
        let mut st = shared.shell.lock().unwrap_or_else(|e| e.into_inner());
        st.pending = r.cmd.clone().or_else(|| r.prog.clone());
        st.cwd = r.cwd.clone();
        if hook.is_some() {
            (st.venv, st.conda, st.conda_name) = (r.venv.clone(), r.conda.clone(), r.conda_name.clone());
        }
        st.pending.as_deref().map(super::resume::prefill)
    });
    let started = restoring.as_ref().map_or_else(now, |r| r.started);
    let start_dir = restoring.as_ref().and_then(|r| r.cwd.as_ref()).map(PathBuf::from).filter(|d| d.is_dir());
    let mut cmd = match opts.command.split_first() {
        None => CommandBuilder::new_default_prog(),
        Some((program, args)) => {
            let mut c = CommandBuilder::new(program);
            match &hook {
                Some(l) => {
                    c.args(&l.args);
                    for (k, v) in &l.set {
                        c.env(k, v);
                    }
                    for k in &l.unset {
                        c.env_remove(k);
                    }
                }
                None => c.args(args),
            }
            c
        }
    };
    if let Some(d) = opts.cwd.clone().or(start_dir).or_else(|| std::env::var_os("HOME").map(PathBuf::from)) {
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
    let is_tty = unsafe { libc::isatty(1) } == 1;
    let mut win_obj = Window::new(std::io::stdout()).tty(is_tty);
    if is_tty {
        win_obj = win_obj.titles(std::env::var_os("HOME").map(PathBuf::from).unwrap_or_default());
    }
    let window = Arc::new(Mutex::new(win_obj));
    let (sh, win) = (shared.clone(), window.clone());
    let tracker = opts.program_status.then(Tracker::default);
    // The output pump's own copy of the master, to look up the foreground group the moment a title arrives.
    let fg_fd = pair.master.as_raw_fd().and_then(|fd| {
        let d = unsafe { libc::dup(fd) };
        // SAFETY: a descriptor `dup` just made, owned by nobody else.
        (d >= 0).then(|| unsafe { <std::os::fd::OwnedFd as std::os::fd::FromRawFd>::from_raw_fd(d) })
    });
    let pid0 = child_pid.unwrap_or(0);
    let fresh_fg = move |sh: &Shared| {
        use std::os::fd::AsRawFd;
        let g = fg_fd.as_ref().map(|fd| unsafe { libc::tcgetpgrp(fd.as_raw_fd()) }).filter(|&g| g > 0);
        probe_fg(sh, g, pid0);
    };
    std::thread::spawn(move || pump_output(from_pty, &win, &sh, drained_tx, Emu::feed, tracker, fresh_fg));
    let to_window = shared.input.clone();
    // It may stay blocked on a read when run ends; the process exits under it.
    let kb = shared.clone();
    std::thread::spawn(move || pump_keyboard(to_window, &kb));
    std::thread::spawn(move || pump_input(to_pty, input_rx));
    let (exit_tx, mut exited) = oneshot::channel();
    std::thread::spawn(move || {
        let _ = exit_tx.send(child.wait());
    });

    // The only writer of this terminal's snapshot (`saved::write` has one temporary file per key and process).
    let snapshots = tokio::spawn(keep_snapshot(shared.clone(), opts.dir.clone(), shell_of(&opts.command), started));
    if let Some(text) = prefill_text {
        let sh = shared.clone();
        tokio::spawn(async move {
            let _ = tokio::time::timeout(PREFILL_WAIT, sh.prompted.notified()).await;
            // Typed, never run: no line end, nor any other control character.
            let text: String = text.chars().filter(|c| !c.is_control()).collect();
            if !text.is_empty() {
                let _ = sh.input.send(text.into_bytes());
            }
        });
    }

    let mut tick = tokio::time::interval(TICK);
    tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    let mut fg_tick = tokio::time::interval(FG_EVERY);
    fg_tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    let end = loop {
        tokio::select! {
            // A signal first: a shutdown that stops everything ends the program too, and the snapshot is kept then.
            biased;
            _ = hup.recv() => break End::Signal(libc::SIGHUP),
            _ = term.recv() => break End::Signal(libc::SIGTERM),
            _ = int.recv() => break End::Signal(libc::SIGINT),
            _ = quit.recv() => break End::Signal(libc::SIGQUIT),
            _ = shared.end.notified() => break End::Ended,
            status = &mut exited => break End::Exited(exit_code(status)),
            _ = winch.recv() => resize(pair.master.as_ref(), &shared),
            _ = fg_tick.tick() => probe_fg(&shared, pair.master.process_group_leader(), child_pid.unwrap_or(0)),
            _ = tick.tick() => {
                tick_sync(&shared, Emu::tick);
                resize_window(&window, &shared);
                refresh_title(&window, &shared);
            }
        }
    };
    // Stopped before the program is: what it looks like while it goes is not what to restore.
    snapshots.abort();
    let code = match end {
        End::Exited(code) => code,
        End::Ended | End::Signal(_) => {
            let sig = match end {
                End::Signal(s) => s,
                _ => libc::SIGHUP,
            };
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
    finish_snapshot(&end, &opts.dir, &shared.meta.key);
    // The last screen is in before anyone is told it was the last; each viewer sends it before saying so.
    let _ = tokio::time::timeout(DRAIN_WAIT, drained).await;
    shared.ended.send_replace(true);
    let until = Instant::now() + VIEWERS_WAIT;
    while shared.viewers.load(Ordering::Relaxed) > 0 && Instant::now() < until {
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    drop(bound);
    drop(raw);
    // Last: the marker tells `serve` the window is left empty and can be closed.
    if opts.ticket.is_some() && unsafe { libc::isatty(1) } == 1 {
        if let Some(name) = shared.tty.as_deref().and_then(marker_name) {
            let secs = now();
            let _ = std::fs::write(opts.dir.join("ended").join(name), secs.to_string());
        }
    }
    Ok(code)
}

/// How often the foreground program is looked up.
const FG_EVERY: Duration = Duration::from_secs(1);

/// The marker's file name for a tty path: its basename (`/dev/ttys012` gives `ttys012`).
fn marker_name(tty: &str) -> Option<String> {
    let base = tty.rsplit('/').next()?;
    (!base.is_empty()).then(|| base.to_string())
}

/// The holder's own window tty, read once.
fn tty_name() -> Option<String> {
    let p = unsafe { libc::ttyname(0) };
    (!p.is_null()).then(|| unsafe { std::ffi::CStr::from_ptr(p) }.to_string_lossy().into_owned())
}

/// Reads the foreground group into `shared.fg`; on a change bumps `shared.fg_rev`.
fn probe_fg(shared: &Shared, pgrp: Option<i32>, child_pid: u32) {
    let changed = shared.fg.lock().unwrap_or_else(|e| e.into_inner()).update(pgrp, child_pid);
    if changed {
        shared.fg_rev.send_modify(|v| *v += 1);
        shared.touch();
    }
}

/// Why the main loop stopped.
#[derive(Debug)]
enum End {
    /// The program exited, with this code.
    Exited(i32),
    /// The `end` op (结束终端, ⌘W): the program is stopped like on SIGHUP.
    Ended,
    /// run got this signal.
    Signal(i32),
}

/// The snapshot after a run ended: gone when the user ended the terminal (the program exited, or `end`), kept for a
/// signal from outside (a closed window, a logout or shutdown, an upgrade), so the terminal can be restored.
fn finish_snapshot(end: &End, dir: &Path, key: &str) {
    match end {
        End::Exited(_) | End::Ended => saved::remove(dir, key),
        End::Signal(_) => {}
    }
}

/// The shell a snapshot names: the command when it is one, else the login shell.
fn shell_of(command: &[String]) -> String {
    match command.first() {
        Some(c) if SHELLS.contains(&super::fg::prog_name(c).as_str()) => c.clone(),
        _ => std::env::var("SHELL").unwrap_or_default(),
    }
}

/// Keeps `saved/<key>.json` up to date: written at start, then each time things settle after a change, when the
/// snapshot (its time aside) is not the one written last. Ends when aborted.
async fn keep_snapshot(shared: Arc<Shared>, dir: PathBuf, shell: String, started: u64) {
    let mut changes = shared.dirty.subscribe();
    let mut last: Option<Snapshot> = None;
    loop {
        let s = snapshot_of(&shared, &shell, started, now());
        if last.as_ref().map(|l| Snapshot { saved: s.saved, ..l.clone() }).as_ref() != Some(&s) {
            // Written here, not on a blocking thread: once aborted, no write is left half done.
            if saved::write(&dir, &s).is_ok() {
                last = Some(s);
            }
        }
        if changes.changed().await.is_err() {
            return;
        }
        let cap = tokio::time::Instant::now() + SNAPSHOT_MAX_WAIT;
        loop {
            let quiet = (tokio::time::Instant::now() + SNAPSHOT_QUIET).min(cap);
            tokio::select! {
                r = changes.changed() => if r.is_err() { return },
                _ = tokio::time::sleep_until(quiet) => break,
            }
        }
    }
}

/// What the terminal looks like now, for `saved/<key>.json`.
pub fn snapshot_of(shared: &Shared, shell_path: &str, started: u64, now: u64) -> Snapshot {
    snapshot_with(shared, shell_path, started, now, super::fg::launch_info)
}

/// `snapshot_of` with the foreground program's argv and environment read by `launch_info`.
fn snapshot_with(
    shared: &Shared,
    shell_path: &str,
    started: u64,
    now: u64,
    launch_info: impl Fn(i32) -> Option<LaunchInfo>,
) -> Snapshot {
    let st = shared.shell.lock().unwrap_or_else(|e| e.into_inner()).clone();
    let fg = shared.fg.lock().unwrap_or_else(|e| e.into_inner()).clone();
    let fg_cwd = fg.cwd.as_ref().map(|p| p.to_string_lossy().into_owned());
    let cwd = if st.hooked { st.cwd.clone().or(fg_cwd) } else { fg_cwd.or(st.cwd.clone()) };
    let (mut venv, mut conda, mut conda_name) = (st.venv.clone(), st.conda.clone(), st.conda_name.clone());
    let (cmd, prog) = if let Some(p) = &st.pending {
        (Some(p.clone()), saved::clean_cmd(p).1)
    } else if let Some(r) = &st.running {
        saved::clean_cmd(r)
    } else if !st.hooked && fg.probed && !fg.shell {
        // No hook: what the program in front was started with. Only with no hook: a hooked shell keeps out what it
        // does not report (a command kept out of history).
        match fg.pgrp.and_then(&launch_info) {
            Some((argv, env)) => {
                let get = |k: &str| env.iter().find(|(n, _)| n == k).map(|(_, v)| v.clone());
                (venv, conda, conda_name) = (get("VIRTUAL_ENV"), get("CONDA_PREFIX"), get("CONDA_DEFAULT_ENV"));
                saved::clean_cmd(&argv.join(" "))
            }
            None => (None, None),
        }
    } else {
        (None, None)
    };
    Snapshot {
        v: 1,
        key: shared.meta.key.clone(),
        name: shared.meta.name(),
        named: shared.meta.named.load(Ordering::Relaxed),
        shell: shell_path.to_string(),
        cwd,
        venv,
        conda,
        conda_name,
        cmd,
        prog,
        started,
        saved: now,
    }
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

/// Writes the window's title if it is due. Never waits for the window, like `resize_window`.
fn refresh_title<W: Write>(window: &Mutex<Window<W>>, shared: &Shared) {
    let mut w = match window.try_lock() {
        Ok(w) => w,
        Err(std::sync::TryLockError::Poisoned(e)) => e.into_inner(),
        Err(std::sync::TryLockError::WouldBlock) => return,
    };
    let fg = shared.fg.lock().unwrap_or_else(|e| e.into_inner()).clone();
    let _ = w.refresh_title(&fg, Instant::now());
}

/// The program's output: to the window first, with any resize a viewer asked for once it is between sequences, then
/// to the emulator through `feed`. Says so on `drained` when the pty is done. `fresh_fg` probes the foreground
/// program into `shared.fg` now: a title is credited to the program in front when it arrives, not to the one the
/// last once-a-second probe saw.
fn pump_output<W: Write>(
    mut pty: impl Read,
    window: &Mutex<Window<W>>,
    shared: &Shared,
    drained: oneshot::Sender<()>,
    feed: impl Fn(&mut Emu, &[u8]),
    mut tracker: Option<Tracker>,
    fresh_fg: impl Fn(&Shared),
) {
    let mut b = vec![0u8; 64 * 1024];
    let mut titles = Some(super::title::Titles::default());
    let mut shell_scan = Some(super::ps::Scanner::default());
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
        // Titles are kept whether or not the tracker runs. A panic there only ends the titles.
        if let Some(t) = titles.as_mut() {
            match std::panic::catch_unwind(AssertUnwindSafe(|| t.feed(&b[..n]).then(|| t.shown()))) {
                Ok(Some(shown)) => *shared.title.lock().unwrap_or_else(|e| e.into_inner()) = shown,
                Ok(None) => {}
                Err(_) => titles = None,
            }
        }
        // 7502 reports and prompts keep the shell state. The bytes still go to the window below. A panic there only
        // ends the shell state.
        if let Some(sc) = shell_scan.as_mut() {
            let fed = std::panic::catch_unwind(AssertUnwindSafe(|| {
                sc.feed(&b[..n], |e| match e {
                    super::ps::Event::Shell(r) => {
                        shared.shell.lock().unwrap_or_else(|e| e.into_inner()).apply(r);
                        shared.touch();
                    }
                    super::ps::Event::Prompt => {
                        shared.prompted.notify_one();
                        let mut st = shared.shell.lock().unwrap_or_else(|e| e.into_inner());
                        let was = st.running.clone();
                        st.prompt();
                        let changed = st.running != was;
                        drop(st);
                        if changed {
                            shared.touch();
                        }
                    }
                    _ => {}
                })
            }));
            if fed.is_err() {
                shell_scan = None;
            }
        }
        // A window that is gone is no reason to stop: viewers still see the screen.
        {
            let mut w = window.lock().unwrap_or_else(|e| e.into_inner());
            let _ = w.output(&b[..n]);
            let _ = w.resize_if_idle(&shared.fit);
            // A new title from the program shows at once, not at the next tick, with the program in front now.
            if w.title_fresh() {
                fresh_fg(shared);
                let fg = shared.fg.lock().unwrap_or_else(|e| e.into_inner()).clone();
                let _ = w.refresh_title(&fg, Instant::now());
            }
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
fn pump_keyboard(input: mpsc::UnboundedSender<Vec<u8>>, shared: &Shared) {
    let mut stdin = std::io::stdin();
    let mut b = [0u8; 4096];
    loop {
        match stdin.read(&mut b) {
            Ok(0) => return,
            Ok(n) => {
                if input.send(b[..n].to_vec()).is_err() {
                    return;
                }
                shared.note_input();
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
                    shared.meta.named.store(true, Ordering::Relaxed);
                    shared.touch();
                    serde_json::json!({ "ok": true })
                }
                None => serde_json::json!({ "error": "invalid name" }),
            };
            let _ = w.write_all(format!("{reply}\n").as_bytes()).await;
        }
        "end" => {
            // The answer goes first; only then does the run begin to end.
            let _ = w.write_all(b"{\"ok\":true}\n").await;
            let _ = w.flush().await;
            shared.end.notify_one();
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

    #[test]
    fn ended_and_exited_remove_the_snapshot_signals_keep_it() {
        let key = "0123456789abcdef";
        let cases = [(End::Exited(0), false), (End::Ended, false), (End::Signal(libc::SIGHUP), true), (End::Signal(libc::SIGTERM), true)];
        for (end, kept) in cases {
            let d = tempfile::tempdir().unwrap();
            saved::write(d.path(), &Snapshot { v: 1, key: key.into(), ..Default::default() }).unwrap();
            finish_snapshot(&end, d.path(), key);
            assert_eq!(saved::path(d.path(), key).exists(), kept, "{end:?}");
        }
    }

    fn fg_of(prog: &str, cwd: &str, shell: bool, pgrp: i32) -> super::super::fg::Fg {
        super::super::fg::Fg { prog: Some(prog.into()), cwd: Some(cwd.into()), shell, probed: true, pgrp: Some(pgrp) }
    }

    type Info = Option<LaunchInfo>;

    fn no_info(_: i32) -> Info {
        panic!("the foreground program is not read here")
    }

    fn state(cwd: &str, venv: Option<&str>) -> super::super::shell::Report {
        super::super::shell::Report::State {
            cwd: Some(cwd.into()),
            venv: venv.map(Into::into),
            conda: Some("/c/ml".into()),
            conda_name: Some("ml".into()),
        }
    }

    #[test]
    fn snapshot_of_prefers_hook_state_over_fg() {
        let sh = shared(30, 4);
        *sh.fg.lock().unwrap() = fg_of("zsh", "/fg/dir", true, 5);
        sh.shell.lock().unwrap().apply(state("/hook/dir", Some("/hook/.venv")));
        let s = snapshot_with(&sh, "/bin/zsh", 10, 20, no_info);
        assert_eq!((s.v, s.key.as_str(), s.name.as_str(), s.named, s.shell.as_str()), (1, "0123456789abcdef", "t", false, "/bin/zsh"));
        assert_eq!((s.started, s.saved), (10, 20));
        assert_eq!((s.cwd.as_deref(), s.venv.as_deref()), (Some("/hook/dir"), Some("/hook/.venv")));
        assert_eq!((s.conda.as_deref(), s.conda_name.as_deref()), (Some("/c/ml"), Some("ml")));
        assert_eq!((s.cmd, s.prog), (None, None));
        // A program in front elsewhere: the shell's own directory and environments, the hook's command line, cleaned.
        *sh.fg.lock().unwrap() = fg_of("claude", "/fg/other", false, 9);
        sh.shell.lock().unwrap().apply(super::super::shell::Report::Run("KEY=x claude --model opus".into()));
        let s = snapshot_with(&sh, "/bin/zsh", 10, 20, no_info);
        assert_eq!((s.cwd.as_deref(), s.venv.as_deref()), (Some("/hook/dir"), Some("/hook/.venv")));
        assert_eq!((s.cmd.as_deref(), s.prog.as_deref()), (Some("claude --model opus"), Some("claude")));
        // A command line holding a secret keeps only its program.
        sh.shell.lock().unwrap().apply(super::super::shell::Report::Run("claude --api-key sk-zzz".into()));
        let s = snapshot_with(&sh, "/bin/zsh", 10, 20, no_info);
        assert_eq!((s.cmd, s.prog.as_deref()), (None, Some("claude")));
        // A rename is in it too.
        *sh.meta.name.lock().unwrap() = "mine".into();
        sh.meta.named.store(true, Ordering::Relaxed);
        let s = snapshot_with(&sh, "/bin/zsh", 10, 20, no_info);
        assert_eq!((s.name.as_str(), s.named), ("mine", true));
    }

    #[test]
    fn snapshot_of_pending_wins_until_run() {
        let sh = shared(30, 4);
        *sh.fg.lock().unwrap() = fg_of("zsh", "/fg/dir", true, 5);
        sh.shell.lock().unwrap().pending = Some("claude --continue".into());
        let s = snapshot_with(&sh, "/bin/zsh", 10, 20, no_info);
        assert_eq!((s.cmd.as_deref(), s.prog.as_deref()), (Some("claude --continue"), Some("claude")));
        // The hook comes up and draws a prompt: still waiting for the user.
        sh.shell.lock().unwrap().apply(state("/w", None));
        sh.shell.lock().unwrap().prompt();
        let s = snapshot_with(&sh, "/bin/zsh", 10, 20, no_info);
        assert_eq!(s.cmd.as_deref(), Some("claude --continue"));
        // The user runs something: that is the command now; once it is done, none.
        sh.shell.lock().unwrap().apply(super::super::shell::Report::Run("ls -l".into()));
        let s = snapshot_with(&sh, "/bin/zsh", 10, 20, no_info);
        assert_eq!((s.cmd.as_deref(), s.prog.as_deref()), (Some("ls -l"), Some("ls")));
        sh.shell.lock().unwrap().prompt();
        let s = snapshot_with(&sh, "/bin/zsh", 10, 20, no_info);
        assert_eq!((s.cmd, s.prog), (None, None));
    }

    #[test]
    fn snapshot_of_fallback_reads_foreground_argv() {
        let sh = shared(30, 4);
        *sh.fg.lock().unwrap() = fg_of("npm", "/w/app", false, 42);
        let info = |pid: i32| -> Info {
            assert_eq!(pid, 42);
            let env = vec![("VIRTUAL_ENV".to_string(), "/w/.venv".to_string()), ("CONDA_PREFIX".into(), "/c/ml".into())];
            Some((vec!["npm".into(), "run".into(), "dev".into()], env))
        };
        let s = snapshot_with(&sh, "/bin/zsh", 10, 20, info);
        assert_eq!((s.cmd.as_deref(), s.prog.as_deref(), s.cwd.as_deref()), (Some("npm run dev"), Some("npm"), Some("/w/app")));
        assert_eq!((s.venv.as_deref(), s.conda.as_deref(), s.conda_name), (Some("/w/.venv"), Some("/c/ml"), None));
        // A secret in the argv keeps only the program; an unreadable process gives nothing.
        let s = snapshot_with(&sh, "/bin/zsh", 10, 20, |_| Some((vec!["tool".into(), "--token".into(), "x".into()], vec![])));
        assert_eq!((s.cmd, s.prog.as_deref()), (None, Some("tool")));
        let s = snapshot_with(&sh, "/bin/zsh", 10, 20, |_| None);
        assert_eq!((s.cmd, s.prog, s.venv, s.cwd.as_deref()), (None, None, None, Some("/w/app")));
    }

    #[test]
    fn snapshot_of_shell_idle_has_no_cmd() {
        let sh = shared(30, 4);
        // No hook, the shell in front: its directory, nothing else.
        *sh.fg.lock().unwrap() = fg_of("zsh", "/fg/dir", true, 5);
        let s = snapshot_with(&sh, "/bin/zsh", 10, 20, no_info);
        assert_eq!((s.cmd, s.prog, s.venv, s.conda, s.cwd.as_deref()), (None, None, None, None, Some("/fg/dir")));
        // Hooked, at a prompt.
        sh.shell.lock().unwrap().apply(state("/hook/dir", None));
        sh.shell.lock().unwrap().prompt();
        let s = snapshot_with(&sh, "/bin/zsh", 10, 20, no_info);
        assert_eq!((s.cmd, s.prog, s.venv, s.cwd.as_deref()), (None, None, None, Some("/hook/dir")));
    }

    #[test]
    fn marker_name_is_the_tty_basename() {
        assert_eq!(marker_name("/dev/ttys012").as_deref(), Some("ttys012"));
        assert_eq!(marker_name("/dev/"), None);
        assert_eq!(marker_name(""), None);
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
            meta: Meta { key: "0123456789abcdef".into(), name: Mutex::new("t".into()), command: "sh".into(), pid: 1, ticket: None, named: AtomicBool::new(false) },
            viewers: AtomicU32::new(0),
            ended: watch::channel(false).0,
            activity: AtomicU64::new(0),
            fit: Mutex::default(),
            ps: Mutex::new(None),
            title: Mutex::new(None),
            fg: Mutex::default(),
            fg_rev: watch::channel(0).0,
            shell: Mutex::default(),
            input_at: AtomicU64::new(0),
            dirty: watch::channel(0).0,
            tty: None,
            end: tokio::sync::Notify::new(),
            prompted: tokio::sync::Notify::new(),
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
    fn a_title_reaches_the_status_even_with_program_status_off() {
        let (sh, _rx) = shared_with_input(30, 4);
        let window = Mutex::new(Window::new(Vec::new()));
        let (tx, _d) = oneshot::channel();
        let pty = Chunks(VecDeque::from([&b"\x1b]1;~/git/rapp\x07"[..]]));
        pump_output(pty, &window, &sh, tx, Emu::feed, None, |_: &Shared| {});
        assert_eq!(sh.status().title.as_deref(), Some("~/git/rapp"));
    }

    #[test]
    fn a_title_is_credited_to_the_program_in_front_when_it_arrives() {
        use super::super::fg::Fg;
        let (sh, _rx) = shared_with_input(30, 4);
        let fgd = |prog: &str, shell: bool| Fg { prog: Some(prog.into()), cwd: Some("/h/x".into()), shell, probed: true, pgrp: None };
        // The last once-a-second probe still saw the shell; vim has just started and sets its title.
        *sh.fg.lock().unwrap() = fgd("zsh", true);
        let window = Mutex::new(Window::new(Vec::new()).titles("/h".into()));
        let (tx, _d) = oneshot::channel();
        let pty = Chunks(VecDeque::from([&b"\x1b]0;notes.txt\x07"[..]]));
        pump_output(pty, &window, &sh, tx, Emu::feed, None, |sh: &Shared| *sh.fg.lock().unwrap() = fgd("vim", false));
        let mut w = window.lock().unwrap();
        assert!(w.get_ref().ends_with("~/x · vim — notes.txt\x07".as_bytes()), "{:?}", String::from_utf8_lossy(w.get_ref()));
        // The next tick's probe agrees: the title stays.
        let at = Instant::now() + Duration::from_secs(2);
        w.refresh_title(&fgd("vim", false), at).unwrap();
        assert!(w.get_ref().ends_with("~/x · vim — notes.txt\x07".as_bytes()));
    }

    #[test]
    fn a_hand_named_session_reports_no_title() {
        let (sh, _rx) = shared_with_input(30, 4);
        sh.meta.named.store(true, Ordering::Relaxed);
        let window = Mutex::new(Window::new(Vec::new()));
        let (tx, _d) = oneshot::channel();
        pump_output(Chunks(VecDeque::from([&b"\x1b]0;vim\x07"[..]])), &window, &sh, tx, Emu::feed, None, |_: &Shared| {});
        assert_eq!(sh.status().title, None);
    }

    #[test]
    fn the_probe_answer_is_queued_before_the_window_sees_the_probe() {
        let (sh, rx) = shared_with_input(30, 4);
        let window = Mutex::new(Window::new(Ordered { rx, log: vec![] }));
        let (tx, _d) = oneshot::channel();
        let pty = Chunks(VecDeque::from([&b"\x1b]7501;?\x07\x1b[c"[..]]));
        pump_output(pty, &window, &sh, tx, Emu::feed, Some(Tracker::default()), |_: &Shared| {});
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
        pump_output(pty, &window, &sh, tx, Emu::feed, Some(Tracker::default()), |_: &Shared| {});
        let ps = sh.status().ps.unwrap();
        assert_eq!((ps.state.as_str(), ps.kind.as_deref()), ("blocked", Some("permission")));
    }

    #[test]
    fn a_7502_report_updates_shared_shell_and_bumps_dirty() {
        let (sh, _rx) = shared_with_input(30, 4);
        let window = Mutex::new(Window::new(Vec::new()));
        let (tx, _d) = oneshot::channel();
        let before = *sh.dirty.borrow();
        let pty = Chunks(VecDeque::from([&b"\x1b]7502;state;cwd=L3RtcA==\x07\x1b]7502;run;bHM=\x07"[..]]));
        pump_output(pty, &window, &sh, tx, Emu::feed, None, |_: &Shared| {});
        let st = sh.shell.lock().unwrap().clone();
        assert!(st.hooked);
        assert_eq!((st.cwd.as_deref(), st.running.as_deref()), (Some("/tmp"), Some("ls")));
        assert!(*sh.dirty.borrow() > before);
        // A prompt ends the run.
        let (tx, _d) = oneshot::channel();
        pump_output(Chunks(VecDeque::from([&b"\x1b]133;A\x07"[..]])), &window, &sh, tx, Emu::feed, None, |_: &Shared| {});
        assert_eq!(sh.shell.lock().unwrap().running, None);
    }

    #[test]
    fn input_moves_input_at() {
        let (sh, _rx) = shared_with_input(30, 4);
        assert_eq!(sh.status().input, 0);
        sh.note_input();
        assert!(sh.input_at.load(Ordering::Relaxed) > 0);
        assert!(sh.status().input > 0);
    }

    #[tokio::test]
    async fn a_rename_makes_the_session_hand_named_and_hides_its_title() {
        let (sh, _rx) = shared_with_input(30, 4);
        *sh.title.lock().unwrap() = Some("vim".into());
        assert_eq!(sh.status().title.as_deref(), Some("vim"));
        let sh = Arc::new(sh);
        let (a, b) = UnixStream::pair().unwrap();
        let task = tokio::spawn(client(a, sh.clone(), "tok".into()));
        let (r, mut w) = b.into_split();
        w.write_all(b"{\"op\":\"rename\",\"v\":1,\"name\":\"mine\"}\ntok\n").await.unwrap();
        let mut line = String::new();
        tokio::io::AsyncBufReadExt::read_line(&mut BufReader::new(r), &mut line).await.unwrap();
        task.await.unwrap();
        assert!(line.contains("\"ok\":true"), "{line}");
        assert!(sh.meta.named.load(Ordering::Relaxed));
        assert_eq!(sh.status().title, None);
    }

    #[test]
    fn a_flood_of_probes_gets_64_answers() {
        let (sh, mut rx) = shared_with_input(30, 4);
        let window = Mutex::new(Window::new(Vec::new()));
        let (tx, _d) = oneshot::channel();
        let flood: &'static [u8] = Box::leak(b"\x1b]7501;?\x07".repeat(1000).into_boxed_slice());
        pump_output(Chunks(VecDeque::from([flood])), &window, &sh, tx, Emu::feed, Some(Tracker::default()), |_: &Shared| {});
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
        pump_output(pty, &window, &sh, tx, |_: &mut Emu, _: &[u8]| panic!("the emulator fell over"), Some(Tracker::default()), |_: &Shared| {});
        assert_eq!(sh.status().ps.unwrap().state, "working");
    }

    #[test]
    fn off_means_byte_for_byte_today() {
        let (sh, mut rx) = shared_with_input(30, 4);
        let window = Mutex::new(Window::new(Vec::new()));
        let (tx, _d) = oneshot::channel();
        let bytes: &[u8] = b"\x1b]7501;?\x07\x1b]7501;state=working\x07hi";
        pump_output(Chunks(VecDeque::from([bytes])), &window, &sh, tx, Emu::feed, None, |_: &Shared| {});
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
        }, None, |_: &Shared| {});
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
