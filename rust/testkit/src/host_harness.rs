//! Drives `rapp_host_core::run::run` in-process (plan B, Task 13): `Host` is the worker with its
//! three standard streams captured, `Controller` a plain-TCP rApp client built from
//! `rapp_client_core`'s message builders, reader and decoder.

use std::collections::VecDeque;
use std::io::{BufRead, Read, Write};
use std::net::{Shutdown, TcpStream};
use std::sync::mpsc::{channel, Receiver, RecvTimeoutError, Sender};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use rapp_client_core::codec::Decoder;
use rapp_client_core::protocol::{read_message, Address, Incoming};
use rapp_host_core::platform::Platform;
use rapp_host_core::run::{run, WorkerIo};
use rapp_host_core::ScaledClock;
use serde_json::Value;

use crate::fake_platform::FakePlatform;

/// How much faster than real time the host's clock runs in these tests.
pub const SPEED: f64 = 20.0;
/// Longest real wait for a host event (the service's `START_WAIT` is 15 s).
pub const EVENT_WAIT: Duration = Duration::from_secs(15);
/// Longest real wait for one client message.
pub const MESSAGE_WAIT: Duration = Duration::from_secs(10);

/// A `Write` that appends to a buffer the test can read at any time.
#[derive(Clone, Default)]
struct Captured(Arc<Mutex<Vec<u8>>>);

impl Captured {
    fn text(&self) -> String {
        String::from_utf8_lossy(&self.0.lock().unwrap_or_else(|e| e.into_inner())).into_owned()
    }
}

impl Write for Captured {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        self.0.lock().unwrap_or_else(|e| e.into_inner()).extend_from_slice(buf);
        Ok(buf.len())
    }
    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

/// The worker's stdin: lines the test sends; EOF once the sender is dropped.
struct Stdin {
    rx: Receiver<Vec<u8>>,
    buf: Vec<u8>,
    pos: usize,
}

impl Read for Stdin {
    fn read(&mut self, out: &mut [u8]) -> std::io::Result<usize> {
        let n = {
            let available = self.fill_buf()?;
            let n = available.len().min(out.len());
            out[..n].copy_from_slice(&available[..n]);
            n
        };
        self.consume(n);
        Ok(n)
    }
}

impl BufRead for Stdin {
    fn fill_buf(&mut self) -> std::io::Result<&[u8]> {
        while self.pos >= self.buf.len() {
            match self.rx.recv() {
                Ok(chunk) => {
                    self.buf = chunk;
                    self.pos = 0;
                }
                Err(_) => return Ok(&[]),
            }
        }
        Ok(&self.buf[self.pos..])
    }
    fn consume(&mut self, amt: usize) {
        self.pos = (self.pos + amt).min(self.buf.len());
    }
}

/// The worker running on its own thread.
pub struct Host {
    platform: FakePlatform,
    stdin: Mutex<Option<Sender<Vec<u8>>>>,
    stdout: Captured,
    stderr: Captured,
    worker: JoinHandle<i32>,
    /// Events before this index were already returned by `wait_event`.
    cursor: Mutex<usize>,
    downloads: std::path::PathBuf,
}

impl Host {
    /// `serve --app <app> --bind 127.0.0.1 --port 0 --token-env RAPP_TOKEN --json`, the way the
    /// service starts it (spec §6.1), with the host clock at `SPEED`.
    pub fn start(platform: FakePlatform, app: &str, token: &str) -> Host {
        let args = ["serve", "--app", app, "--bind", "127.0.0.1", "--port", "0", "--token-env", "RAPP_TOKEN", "--json"];
        Host::start_with(platform, &args, &[("RAPP_TOKEN", token)])
    }

    /// Any command line, with `env` as the worker's whole environment plus `RAPP_DOWNLOADS`
    /// (a fresh directory under the fake's data root) unless `env` names it.
    pub fn start_with(platform: FakePlatform, args: &[&str], env: &[(&str, &str)]) -> Host {
        let (tx, rx) = channel();
        let stdout = Captured::default();
        let stderr = Captured::default();
        let downloads = platform.data_root().join("downloads");
        let _ = std::fs::create_dir_all(&downloads);
        let mut vars: Vec<(String, String)> = env.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect();
        if !vars.iter().any(|(k, _)| k == "RAPP_DOWNLOADS") {
            vars.push(("RAPP_DOWNLOADS".to_string(), downloads.to_string_lossy().into_owned()));
        }
        let args: Vec<String> = args.iter().map(|a| a.to_string()).collect();
        let io = WorkerIo {
            stdin: Box::new(Stdin { rx, buf: Vec::new(), pos: 0 }),
            stdout: Box::new(stdout.clone()),
            stderr: Box::new(stderr.clone()),
        };
        let shared: Arc<dyn Platform> = Arc::new(platform.clone());
        let worker = std::thread::Builder::new()
            .name("rapp-host-core worker".into())
            .spawn(move || {
                let env = move |k: &str| vars.iter().find(|(n, _)| n == k).map(|(_, v)| v.clone());
                run(&args, &env, shared, io, Arc::new(ScaledClock::new(SPEED)))
            })
            .expect("spawn the worker");
        Host { platform, stdin: Mutex::new(Some(tx)), stdout, stderr, worker, cursor: Mutex::new(0), downloads }
    }

    /// A one-shot command (`version`, `list-apps`, `check`, `lock`): its exit code and stdout.
    pub fn run_once(platform: FakePlatform, args: &[&str]) -> (i32, String, String) {
        let host = Host::start_with(platform, args, &[]);
        host.close_stdin();
        let (stdout, stderr) = (host.stdout.clone(), host.stderr.clone());
        let code = host.wait_exit();
        (code, stdout.text(), stderr.text())
    }

    pub fn platform(&self) -> &FakePlatform {
        &self.platform
    }

    pub fn downloads(&self) -> &std::path::Path {
        &self.downloads
    }

    /// The port from the `listening` event.
    pub fn port(&self) -> u16 {
        let deadline = Instant::now() + EVENT_WAIT;
        loop {
            if let Some(port) = self.events().iter().find(|e| e["event"] == "listening").and_then(|e| e["port"].as_u64()) {
                return port as u16;
            }
            if Instant::now() > deadline || self.worker.is_finished() {
                panic!("no listening event; stdout:\n{}\nstderr:\n{}", self.stdout_text(), self.stderr_text());
            }
            std::thread::sleep(Duration::from_millis(5));
        }
    }

    /// Every JSON line on stdout so far.
    pub fn events(&self) -> Vec<Value> {
        self.stdout.text().lines().filter_map(|l| serde_json::from_str(l).ok()).collect()
    }

    /// The next event named `ev` after the last one this returned (15 s real limit).
    pub fn wait_event(&self, ev: &str) -> Value {
        self.wait_event_where(|e| e["event"] == ev)
    }

    /// The next event matching `pred` after the last one `wait_event*` returned.
    pub fn wait_event_where(&self, pred: impl Fn(&Value) -> bool) -> Value {
        let deadline = Instant::now() + EVENT_WAIT;
        loop {
            {
                let mut cursor = self.cursor.lock().unwrap_or_else(|e| e.into_inner());
                let events = self.events();
                if let Some(i) = (*cursor..events.len()).find(|&i| pred(&events[i])) {
                    *cursor = i + 1;
                    return events[i].clone();
                }
            }
            if Instant::now() > deadline {
                panic!("event not seen; stdout:\n{}\nstderr:\n{}", self.stdout_text(), self.stderr_text());
            }
            std::thread::sleep(Duration::from_millis(5));
        }
    }

    /// Whether any event so far matches `pred`.
    pub fn saw(&self, pred: impl Fn(&Value) -> bool) -> bool {
        self.events().iter().any(pred)
    }

    /// One stdin line (the newline is added).
    pub fn command(&self, line: &str) {
        if let Some(tx) = self.stdin.lock().unwrap_or_else(|e| e.into_inner()).as_ref() {
            let _ = tx.send(format!("{line}\n").into_bytes());
        }
    }

    pub fn close_stdin(&self) {
        self.stdin.lock().unwrap_or_else(|e| e.into_inner()).take();
    }

    /// The exit code; panics if the worker runs on for 15 s more.
    pub fn wait_exit(self) -> i32 {
        let deadline = Instant::now() + EVENT_WAIT;
        while !self.worker.is_finished() {
            if Instant::now() > deadline {
                panic!("worker did not exit; stdout:\n{}\nstderr:\n{}", self.stdout_text(), self.stderr_text());
            }
            std::thread::sleep(Duration::from_millis(5));
        }
        self.worker.join().expect("worker thread")
    }

    pub fn stdout_text(&self) -> String {
        self.stdout.text()
    }

    pub fn stderr_text(&self) -> String {
        self.stderr.text()
    }
}

/// A short description of an incoming message, for failure output (frames without their bytes).
pub fn describe(m: &Incoming) -> String {
    match m {
        Incoming::Frame { mode, region, width, height, flags, dx, dy, data } => format!(
            "frame mode {mode} region {},{} {}x{} px {width}x{height} flags {flags:#x} move {dx},{dy} ({} bytes)",
            region.x,
            region.y,
            region.w,
            region.h,
            data.len()
        ),
        other => format!("{other:?}"),
    }
}

/// A client over plain TCP. A reader thread turns the stream into messages; frames are decoded
/// on the test's thread as `next` hands them out, so `canvas` is the picture after the last
/// frame returned.
pub struct Controller {
    stream: TcpStream,
    rx: Receiver<Result<Incoming, String>>,
    /// Messages `wait_for` passed over, handed out again by `next`.
    queue: VecDeque<Incoming>,
    decoder: Decoder,
    samples: Vec<u8>,
    closed: bool,
    /// The reason the stream ended, once it did.
    pub end: Option<String>,
    /// Everything received so far, described.
    pub seen: Vec<String>,
}

impl Controller {
    pub fn connect(port: u16) -> Controller {
        let stream = TcpStream::connect(("127.0.0.1", port)).expect("connect to the host");
        let _ = stream.set_nodelay(true);
        let mut reading = stream.try_clone().expect("clone the stream");
        let (tx, rx) = channel();
        std::thread::spawn(move || loop {
            match read_message(&mut reading) {
                Ok((m, _)) => {
                    if tx.send(Ok(m)).is_err() {
                        return;
                    }
                }
                Err(e) => {
                    let _ = tx.send(Err(format!("{e:#}")));
                    return;
                }
            }
        });
        Controller {
            stream,
            rx,
            queue: VecDeque::new(),
            decoder: Decoder::default(),
            samples: Vec::new(),
            closed: false,
            end: None,
            seen: Vec::new(),
        }
    }

    /// The local port, which the `peer` command names.
    pub fn local_port(&self) -> u16 {
        self.stream.local_addr().map(|a| a.port()).unwrap_or(0)
    }

    /// The `peer` command line that names this connection `name` (send it before `hello`).
    pub fn peer_line(&self, name: &str) -> String {
        serde_json::json!({ "cmd": "peer", "port": self.local_port(), "name": name }).to_string()
    }

    /// A hello at density 1, so the canvas is in points. `name` is only kept for failure
    /// output: a device's name reaches the host through the `peer` command.
    pub fn hello(&mut self, token: &str, app: &str, name: &str, mode: u8, fps: u8) {
        let address = Address {
            host: "127.0.0.1".to_string(),
            port: 0,
            app: app.to_string(),
            token: token.to_string(),
            mode,
            fps,
        };
        self.seen.push(format!("(hello as {name})"));
        self.send(&address.hello(1.0));
    }

    pub fn send(&mut self, bytes: &[u8]) {
        if let Err(e) = self.stream.write_all(bytes) {
            self.seen.push(format!("(send failed: {e})"));
        }
    }

    fn take(&mut self, m: Incoming) -> Incoming {
        if let Incoming::Frame { mode, width, height, flags, dx, dy, data, .. } = &m {
            match self.decoder.apply(*mode, *width, *height, *flags, *dx, *dy, data) {
                Ok(true) => self.samples = self.decoder.samples_le(),
                Ok(false) => {}
                Err(e) => self.seen.push(format!("(decode error: {e:#})")),
            }
        }
        self.seen.push(describe(&m));
        m
    }

    /// The next message within 10 s; `None` once the host closed the connection (or nothing came).
    pub fn next(&mut self) -> Option<Incoming> {
        self.next_within(MESSAGE_WAIT)
    }

    pub fn next_within(&mut self, wait: Duration) -> Option<Incoming> {
        if let Some(m) = self.queue.pop_front() {
            return Some(m);
        }
        if self.closed {
            return None;
        }
        match self.rx.recv_timeout(wait) {
            Ok(Ok(m)) => Some(self.take(m)),
            Ok(Err(reason)) => {
                self.closed = true;
                self.end = Some(reason);
                None
            }
            Err(RecvTimeoutError::Timeout) => None,
            Err(RecvTimeoutError::Disconnected) => {
                self.closed = true;
                None
            }
        }
    }

    /// The first message matching `pred` within 10 s real time; others are kept for `next`
    /// unless they are frames (always applied to the canvas). Panics listing what arrived.
    pub fn wait_for(&mut self, pred: impl Fn(&Incoming) -> bool) -> Incoming {
        let deadline = Instant::now() + MESSAGE_WAIT;
        let mut kept = VecDeque::new();
        // Queued messages first, in order.
        while let Some(m) = self.queue.pop_front() {
            if pred(&m) {
                kept.extend(self.queue.drain(..));
                self.queue = kept;
                return m;
            }
            kept.push_back(m);
        }
        loop {
            let left = deadline.saturating_duration_since(Instant::now());
            if left.is_zero() || self.closed {
                self.queue = kept;
                panic!(
                    "expected message not received (closed: {}, end: {:?}); received:\n{}",
                    self.closed,
                    self.end,
                    self.seen.join("\n")
                );
            }
            match self.rx.recv_timeout(left) {
                Ok(Ok(m)) => {
                    let m = self.take(m);
                    if pred(&m) {
                        self.queue = kept;
                        return m;
                    }
                    if !matches!(m, Incoming::Frame { .. }) {
                        kept.push_back(m);
                    }
                }
                Ok(Err(reason)) => {
                    self.closed = true;
                    self.end = Some(reason);
                }
                Err(RecvTimeoutError::Timeout) => {}
                Err(RecvTimeoutError::Disconnected) => self.closed = true,
            }
        }
    }

    /// True when the host closes the connection within `wait` (real time); messages on the
    /// way are taken as usual.
    pub fn closes_within(&mut self, wait: Duration) -> bool {
        let deadline = Instant::now() + wait;
        while !self.closed {
            let left = deadline.saturating_duration_since(Instant::now());
            if left.is_zero() {
                return false;
            }
            match self.rx.recv_timeout(left) {
                Ok(Ok(m)) => {
                    let m = self.take(m);
                    // Handed out later by `next`; frames are already on the canvas.
                    if !matches!(m, Incoming::Frame { .. }) {
                        self.queue.push_back(m);
                    }
                }
                Ok(Err(reason)) => {
                    self.closed = true;
                    self.end = Some(reason);
                }
                Err(RecvTimeoutError::Timeout) => {}
                Err(RecvTimeoutError::Disconnected) => self.closed = true,
            }
        }
        true
    }

    /// Ok when nothing but `noise` arrives within `wait` and the connection stays open.
    pub fn quiet_for(&mut self, wait: Duration, noise: impl Fn(&Incoming) -> bool) -> Result<(), String> {
        let deadline = Instant::now() + wait;
        loop {
            let left = deadline.saturating_duration_since(Instant::now());
            if left.is_zero() {
                return Ok(());
            }
            match self.next_within(left) {
                Some(m) if noise(&m) => {}
                Some(m) => return Err(describe(&m)),
                None if self.closed => return Err(format!("closed: {:?}", self.end)),
                None => {}
            }
        }
    }

    /// The decoded canvas: width, height, samples (1 or 2 bytes each, little-endian).
    pub fn canvas(&self) -> (usize, usize, &[u8]) {
        (self.decoder.width, self.decoder.height, &self.samples)
    }

    pub fn is_closed(&self) -> bool {
        self.closed
    }

    pub fn close(self) {
        let _ = self.stream.shutdown(Shutdown::Both);
    }
}
