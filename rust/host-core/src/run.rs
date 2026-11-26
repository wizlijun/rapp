//! The worker program (`Sources/rapp-host/main.swift`, and `WorkerOutput` /
//! `readCommands` of `Sources/RappCore/WorkerCLI.swift:347-400`).
//!
//! Swift's `finish` writes the exit event and calls `exit`. Here `finish` writes the same
//! lines, marks the output finished (nothing is written after the exit event) and hands the
//! code to `run`, which returns it; the platform's `main` exits with it.

use std::io::{BufRead, Write};
use std::sync::mpsc::{channel, Receiver, Sender};
use std::sync::{Arc, Mutex};

use crate::cli::{
    apps_json, apps_text, check_json, exit_code, lock_json, parse_host_arguments, parse_worker_command,
    version_json, HostCommand, WorkerCommand, WorkerEvent,
};
use crate::clock::Clock;
use crate::lock::{lock_screen, LockOutcome, LOCK_STEP, LOCK_TIMEOUT};
use crate::platform::Platform;
use crate::protocol::PROTOCOL_VERSION;
use crate::session::server::Server;

/// The worker's three standard streams.
pub struct WorkerIo {
    pub stdin: Box<dyn BufRead + Send>,
    pub stdout: Box<dyn Write + Send>,
    pub stderr: Box<dyn Write + Send>,
}

/// `main.swift:7-14`, with Swift's default port.
pub const USAGE_TEXT: &str = "usage: rapp-host --token <secret> [--port 47800]
       rapp-host serve --app <bundle-id> (--token <secret> | --token-env <VAR>) [--port 47800] [--bind <address>] [--json]
       rapp-host list-apps [--json]
       rapp-host check [--prompt] [--json]
       rapp-host lock [--json]
       rapp-host version [--json]";

struct Streams {
    stdout: Box<dyn Write + Send>,
    stderr: Box<dyn Write + Send>,
    finished: bool,
}

/// Swift's `WorkerOutput`: one lock around both streams, so lines never interleave.
pub struct Output {
    json: bool,
    streams: Mutex<Streams>,
    exit: Mutex<Option<Sender<i32>>>,
}

impl Output {
    fn new(json: bool, stdout: Box<dyn Write + Send>, stderr: Box<dyn Write + Send>) -> (Arc<Output>, Receiver<i32>) {
        let (tx, rx) = channel();
        let out = Output { json, streams: Mutex::new(Streams { stdout, stderr, finished: false }), exit: Mutex::new(Some(tx)) };
        (Arc::new(out), rx)
    }

    pub fn json(&self) -> bool {
        self.json
    }

    fn write(&self, to_stderr: bool, text: &str) {
        let mut s = self.streams.lock().unwrap_or_else(|e| e.into_inner());
        if s.finished {
            return;
        }
        let w = if to_stderr { &mut s.stderr } else { &mut s.stdout };
        let _ = w.write_all(text.as_bytes());
        let _ = w.write_all(b"\n");
        let _ = w.flush();
    }

    /// Human-readable progress: stderr with `--json` (stdout carries events), else stdout.
    pub fn log(&self, text: &str) {
        self.write(self.json, text);
    }

    pub fn error(&self, text: &str) {
        self.write(true, text);
    }

    /// One event line on stdout, only with `--json`.
    pub fn emit(&self, event: &WorkerEvent) {
        if self.json {
            self.write(false, &event.json_line());
        }
    }

    /// A command's result on stdout.
    pub fn result(&self, line: &str) {
        self.write(false, line);
    }

    /// Writes the raw text without a newline (`appsText` already ends in one).
    fn raw(&self, text: &str) {
        let mut s = self.streams.lock().unwrap_or_else(|e| e.into_inner());
        if s.finished {
            return;
        }
        let _ = s.stdout.write_all(text.as_bytes());
        let _ = s.stdout.flush();
    }

    /// The reason on stderr when the code is not 0, the exit event with `--json`, then
    /// nothing more: later writes are dropped. Only the first call counts.
    pub fn finish(&self, code: i32, reason: &str) {
        {
            let mut s = self.streams.lock().unwrap_or_else(|e| e.into_inner());
            if s.finished {
                return;
            }
            if code != 0 {
                let _ = s.stderr.write_all(reason.as_bytes());
                let _ = s.stderr.write_all(b"\n");
                let _ = s.stderr.flush();
            }
            if self.json {
                let line = WorkerEvent::Exit { code, reason: reason.to_string() }.json_line();
                let _ = s.stdout.write_all(line.as_bytes());
                let _ = s.stdout.write_all(b"\n");
                let _ = s.stdout.flush();
            }
            s.finished = true;
        }
        if let Some(tx) = self.exit.lock().unwrap_or_else(|e| e.into_inner()).take() {
            let _ = tx.send(code);
        }
    }

    pub fn is_finished(&self) -> bool {
        self.streams.lock().unwrap_or_else(|e| e.into_inner()).finished
    }
}

/// Swift's `readCommands`: one command per stdin line, on its own thread; an unknown
/// non-empty line is logged as ignored; `on_eof` runs once at the end.
fn read_commands(
    stdin: Box<dyn BufRead + Send>,
    out: Arc<Output>,
    on_command: impl Fn(WorkerCommand) + Send + 'static,
    on_eof: impl FnOnce() + Send + 'static,
) {
    std::thread::Builder::new()
        .name("rapp-host stdin".into())
        .spawn(move || {
            let mut stdin = stdin;
            let mut line = String::new();
            loop {
                line.clear();
                match stdin.read_line(&mut line) {
                    Ok(0) | Err(_) => break,
                    Ok(_) => {}
                }
                let text = line.trim_end_matches(['\n', '\r']);
                match parse_worker_command(text) {
                    Some(command) => on_command(command),
                    None => {
                        if !text.trim().is_empty() {
                            out.error(&format!("ignored stdin line: {text}"));
                        }
                    }
                }
            }
            on_eof();
        })
        .expect("spawn stdin reader");
}

/// The worker. `args` excludes the program name. Returns the exit code; never exits itself.
pub fn run(
    args: &[String],
    env: &(dyn Fn(&str) -> Option<String> + Sync),
    platform: Arc<dyn Platform>,
    io: WorkerIo,
    clock: Arc<dyn Clock>,
) -> i32 {
    let WorkerIo { stdin, stdout, stderr } = io;
    let command = match parse_host_arguments(args, &|k| env(k)) {
        Ok(c) => c,
        Err(error) => {
            let (out, rx) = Output::new(args.iter().any(|a| a == "--json"), stdout, stderr);
            out.error(USAGE_TEXT);
            out.finish(exit_code::USAGE, &error.to_string());
            return rx.recv().unwrap_or(exit_code::USAGE);
        }
    };
    match command {
        HostCommand::Version { json } => {
            let (out, rx) = Output::new(json, stdout, stderr);
            if json {
                out.result(version_json(platform.name()).trim_end());
            } else {
                out.result(&format!("rapp-host {} (protocol {})", env!("CARGO_PKG_VERSION"), PROTOCOL_VERSION));
            }
            out.finish(exit_code::OK, "done");
            rx.recv().unwrap_or(exit_code::OK)
        }
        HostCommand::ListApps { json } => {
            let (out, rx) = Output::new(json, stdout, stderr);
            let permissions = platform.permissions();
            // No app can be listed without a screen; the reason travels in `error`.
            let apps = if permissions.error.is_some() || !permissions.applications {
                Vec::new()
            } else {
                match platform.applications() {
                    Ok(a) => a,
                    Err(reason) => {
                        out.log(&format!("could not list apps: {reason}"));
                        Vec::new()
                    }
                }
            };
            if json {
                out.result(apps_json(&platform.displays(), &apps, &permissions).trim_end());
            } else if !apps.is_empty() {
                out.raw(&apps_text(&apps));
            }
            out.finish(exit_code::OK, "done");
            rx.recv().unwrap_or(exit_code::OK)
        }
        HostCommand::Check { json } => {
            let (out, rx) = Output::new(json, stdout, stderr);
            let permissions = platform.permissions();
            out.result(check_json(&permissions).trim_end());
            match missing(&permissions) {
                None => out.finish(exit_code::OK, "done"),
                Some(text) => out.finish(exit_code::PERMISSION, &text),
            }
            rx.recv().unwrap_or(exit_code::PERMISSION)
        }
        HostCommand::Lock { json } => {
            let (out, rx) = Output::new(json, stdout, stderr);
            let outcome = lock_now(platform.as_ref(), clock.as_ref());
            match &outcome {
                LockOutcome::Locked => {
                    out.result(if json { lock_json(&outcome) } else { "locked".to_string() }.trim_end());
                    out.finish(exit_code::OK, "done");
                }
                LockOutcome::Already => {
                    out.result(if json { lock_json(&outcome) } else { "already locked".to_string() }.trim_end());
                    out.finish(exit_code::OK, "done");
                }
                LockOutcome::Failed(reason) => {
                    out.result(if json { lock_json(&outcome) } else { format!("lock failed: {reason}") }.trim_end());
                    out.finish(exit_code::RUNTIME, reason);
                }
            }
            rx.recv().unwrap_or(exit_code::RUNTIME)
        }
        HostCommand::SecureHelper { .. } => {
            // The secure-desktop helper is the Windows platform crate's own program (spec §7.4);
            // its `main` handles this subcommand before calling `run`.
            let (out, rx) = Output::new(false, stdout, stderr);
            out.finish(exit_code::USAGE, &format!("secure-helper is not available on {}", platform.name()));
            rx.recv().unwrap_or(exit_code::USAGE)
        }
        HostCommand::Serve(options) => {
            let (out, rx) = Output::new(options.json, stdout, stderr);
            let permissions = platform.permissions();
            if let Some(error) = &permissions.error {
                // No picture can be shown at all (spec §6.1): the reason is the exit reason.
                out.finish(exit_code::RUNTIME, &error.reason());
                return rx.recv().unwrap_or(exit_code::RUNTIME);
            }
            if let Some(text) = missing(&permissions) {
                let legacy = options.app.is_none();
                out.finish(
                    if legacy { exit_code::USAGE } else { exit_code::PERMISSION },
                    &format!(
                        "{text}\nAllow rApp (or the terminal running rapp-host) under System Settings > Privacy & Security, then connect again."
                    ),
                );
                return rx.recv().unwrap_or(exit_code::PERMISSION);
            }
            let downloads = crate::transfers::transfer_dir(&|k| env(k), &platform.data_root());
            let server = match Server::start(options.clone(), platform, clock, out.clone(), downloads) {
                Ok(s) => s,
                Err(e) => {
                    out.finish(exit_code::RUNTIME, &format!("cannot start: {e}"));
                    return rx.recv().unwrap_or(exit_code::RUNTIME);
                }
            };
            if options.json {
                let on_command = {
                    let server = server.clone();
                    move |command: WorkerCommand| match command {
                        WorkerCommand::Kick => server.kick(),
                        WorkerCommand::Quit => server.stop("quit"),
                        WorkerCommand::Peer { port, name } => server.peer(port, &name),
                        WorkerCommand::Yield { by } => server.yield_to(&by),
                        // A rapp-client command; the host has no window of its own.
                        WorkerCommand::Focus => {}
                    }
                };
                let on_eof = {
                    let server = server.clone();
                    move || server.stop("stdin closed")
                };
                read_commands(stdin, out.clone(), on_command, on_eof);
            }
            let code = rx.recv().unwrap_or(exit_code::RUNTIME);
            server.shutdown();
            code
        }
    }
}

/// `missingPermissions`: Windows reports Screen Recording through `screen_recording`;
/// Accessibility is always granted there, but a platform may say otherwise.
fn missing(p: &crate::platform::Permissions) -> Option<String> {
    let mut names = Vec::new();
    if !p.screen_recording {
        names.push("Screen Recording");
    }
    if !p.accessibility {
        names.push("Accessibility");
    }
    if names.is_empty() {
        None
    } else {
        Some(format!("missing permission: {}", names.join(", ")))
    }
}

/// `ScreenLocker.lock()`: the platform's lock call, then 2 s of polling at 0.1 s.
fn lock_now(platform: &dyn Platform, clock: &dyn Clock) -> LockOutcome {
    let lock = Mutex::new(platform.lock());
    let mut is_locked = || lock.lock().unwrap_or_else(|e| e.into_inner()).locked();
    let mut call = || lock.lock().unwrap_or_else(|e| e.into_inner()).lock();
    let mut sleep = |s: f64| clock.sleep(s);
    lock_screen(&mut is_locked, &mut call, &mut sleep, LOCK_TIMEOUT, LOCK_STEP)
}
