//! A terminal window for `rapp-term run` in tests: a pty of our own with `run` inside, and a viewer that speaks
//! the local protocol. Every wait is bounded, so a bug fails a test instead of hanging it.

// Each test crate uses only some of these.
#![allow(dead_code)]

use portable_pty::{native_pty_system, Child, CommandBuilder, MasterPty, PtySize};
use rapp_term::pty::local::{self, Status};
use serde_json::{json, Value};
use std::collections::BTreeMap;
use std::fs::File;
use std::io::{Read, Write};
use std::os::fd::FromRawFd;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::unix::{OwnedReadHalf, OwnedWriteHalf};

pub const BIN: &str = env!("CARGO_BIN_EXE_rapp-term");
/// The longest any wait in these tests lasts.
pub const WAIT: Duration = Duration::from_secs(10);

/// A directory short enough for `pty/<pid>.sock` to fit a unix socket address.
pub fn short_dir() -> tempfile::TempDir {
    tempfile::Builder::new().prefix("rt").tempdir_in("/tmp").unwrap()
}

/// `rapp-term run --dir <dir> <args…>` in a 100×30 pty, its output collected. Dropping it ends `run`.
///
/// It reads and writes the pty through descriptors of its own rather than portable-pty's: that writer types an
/// end of file when dropped, and that reader cannot be closed while it waits, so the window could never close.
pub struct Window {
    child: Box<dyn Child + Send + Sync>,
    master: Option<Box<dyn MasterPty + Send>>,
    writer: Option<File>,
    out: Arc<Mutex<Vec<u8>>>,
    stop: Arc<AtomicBool>,
    reader: Option<std::thread::JoinHandle<()>>,
}

/// Another descriptor for the window's pty.
fn dup(master: &dyn MasterPty) -> File {
    let fd = unsafe { libc::dup(master.as_raw_fd().unwrap()) };
    assert!(fd >= 0, "dup of the window's pty");
    unsafe { File::from_raw_fd(fd) }
}

impl Window {
    pub fn start(dir: &Path, args: &[&str]) -> Window {
        // One at a time: on macOS openpty is not safe to call from two threads at once (ptsname's buffer is shared).
        static OPEN: Mutex<()> = Mutex::new(());
        let pair = {
            let _one = OPEN.lock().unwrap_or_else(|e| e.into_inner());
            native_pty_system().openpty(PtySize { rows: 30, cols: 100, pixel_width: 0, pixel_height: 0 }).unwrap()
        };
        let mut cmd = CommandBuilder::new(BIN);
        cmd.arg("run");
        cmd.arg("--dir");
        cmd.arg(dir);
        cmd.args(args);
        let child = pair.slave.spawn_command(cmd).unwrap();
        drop(pair.slave);
        let mut reader = dup(pair.master.as_ref());
        let writer = dup(pair.master.as_ref());
        let out = Arc::new(Mutex::new(Vec::new()));
        let stop = Arc::new(AtomicBool::new(false));
        let (sink, stopped) = (out.clone(), stop.clone());
        let reader = std::thread::spawn(move || {
            let mut b = [0u8; 8192];
            // Polled, so that closing the window can stop it and close its descriptor.
            while !stopped.load(Ordering::Relaxed) {
                let mut p =
                    libc::pollfd { fd: std::os::fd::AsRawFd::as_raw_fd(&reader), events: libc::POLLIN, revents: 0 };
                if unsafe { libc::poll(&mut p, 1, 20) } <= 0 {
                    continue;
                }
                match reader.read(&mut b) {
                    Ok(0) => break,
                    Ok(n) => sink.lock().unwrap().extend_from_slice(&b[..n]),
                    Err(e) if e.kind() == std::io::ErrorKind::Interrupted => {}
                    Err(_) => break,
                }
            }
        });
        Window { child, master: Some(pair.master), writer: Some(writer), out, stop, reader: Some(reader) }
    }

    /// The pid of `run`.
    pub fn pid(&self) -> u32 {
        self.child.process_id().unwrap()
    }

    /// Everything `run` has written to the window so far.
    pub fn output(&self) -> String {
        String::from_utf8_lossy(&self.out.lock().unwrap()).into_owned()
    }

    /// Wait until the window shows `text`.
    pub fn wait_output(&self, text: &str) {
        let end = Instant::now() + WAIT;
        while !self.output().contains(text) {
            assert!(Instant::now() < end, "the window never showed {text:?}: {:?}", self.output());
            std::thread::sleep(Duration::from_millis(20));
        }
    }

    /// Type into the window, as someone at its keyboard.
    pub fn type_in(&mut self, bytes: &[u8]) {
        let w = self.writer.as_mut().expect("the window is open");
        w.write_all(bytes).unwrap();
        w.flush().unwrap();
    }

    /// Drag the window to a new size.
    pub fn resize(&self, cols: u16, rows: u16) {
        let m = self.master.as_ref().expect("the window is open");
        m.resize(PtySize { rows, cols, pixel_width: 0, pixel_height: 0 }).unwrap();
    }

    /// The window's line discipline flags (`c_lflag`), to tell raw mode from cooked.
    pub fn lflag(&self) -> libc::tcflag_t {
        let fd = self.master.as_ref().expect("the window is open").as_raw_fd().unwrap();
        let mut t: libc::termios = unsafe { std::mem::zeroed() };
        assert_eq!(unsafe { libc::tcgetattr(fd, &mut t) }, 0, "tcgetattr on the window");
        t.c_lflag
    }

    /// Close the window, as clicking its close button would.
    pub fn close(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
        if let Some(r) = self.reader.take() {
            r.join().unwrap();
        }
        self.writer = None;
        self.master = None;
    }

    /// `run`'s exit code once it has exited; a bounded wait.
    pub fn wait_exit(&mut self) -> u32 {
        let end = Instant::now() + WAIT;
        loop {
            if let Some(s) = self.child.try_wait().unwrap() {
                return s.exit_code();
            }
            assert!(Instant::now() < end, "run did not exit within {WAIT:?}");
            std::thread::sleep(Duration::from_millis(20));
        }
    }

    /// Whether `run` is still running.
    pub fn alive(&mut self) -> bool {
        self.child.try_wait().unwrap().is_none()
    }

    /// The pids of the processes `run` started.
    pub fn children(&self) -> Vec<i32> {
        let out = std::process::Command::new("pgrep").args(["-P", &self.pid().to_string()]).output().unwrap();
        String::from_utf8_lossy(&out.stdout).split_whitespace().filter_map(|p| p.parse().ok()).collect()
    }
}

impl Drop for Window {
    fn drop(&mut self) {
        if std::thread::panicking() {
            // What run said, for the failing test's report.
            eprintln!("the window showed: {:?}", self.output());
        }
        if !matches!(self.child.try_wait(), Ok(Some(_))) {
            // SIGTERM first so `run` ends its program; then for sure.
            if let Some(pid) = self.child.process_id() {
                unsafe { libc::kill(pid as i32, libc::SIGTERM) };
            }
            let end = Instant::now() + Duration::from_secs(3);
            while matches!(self.child.try_wait(), Ok(None)) && Instant::now() < end {
                std::thread::sleep(Duration::from_millis(20));
            }
            let _ = self.child.kill();
            let _ = self.child.wait();
        }
    }
}

/// Whether a process with this pid exists.
pub fn process_exists(pid: i32) -> bool {
    unsafe { libc::kill(pid, 0) == 0 || std::io::Error::last_os_error().raw_os_error() != Some(libc::ESRCH) }
}

/// The status of the `run` named `name` in `dir`, waiting for it to come up.
pub async fn wait_status(dir: &Path, name: &str) -> Status {
    let token = local::token(dir).unwrap();
    let end = Instant::now() + WAIT;
    loop {
        if let Some(s) = local::scan(dir, &token).await.into_iter().find(|s| s.name == name) {
            return s;
        }
        assert!(Instant::now() < end, "no run named {name} came up in {}", dir.display());
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
}

/// The socket of the `run` with `pid`.
pub fn socket_of(dir: &Path, pid: u32) -> PathBuf {
    local::socket_path(dir, pid).unwrap()
}

/// One viewer on the local protocol, keeping the screen as the screens it got describe it.
pub struct Viewer {
    r: BufReader<OwnedReadHalf>,
    w: OwnedWriteHalf,
    pub cols: u16,
    pub rows: u16,
    /// Row number → its text, as the latest screens left it.
    pub lines: BTreeMap<u16, String>,
    /// Between the parts of a split screen.
    mid: bool,
}

impl Viewer {
    /// Connect to the `run` named `name` in `dir` with `op` (normally `view`).
    pub async fn connect_op(dir: &Path, name: &str, op: &str) -> Viewer {
        let s = wait_status(dir, name).await;
        let token = local::token(dir).unwrap();
        let stream = local::connect(&socket_of(dir, s.pid), op, &token).await.unwrap();
        let (r, w) = stream.into_split();
        Viewer { r: BufReader::new(r), w, cols: 0, rows: 0, lines: BTreeMap::new(), mid: false }
    }

    /// Connect to the run behind `sock`, whatever it is called.
    pub async fn connect_op_at(sock: &Path, dir: &Path, op: &str) -> Viewer {
        let token = local::token(dir).unwrap();
        let stream = local::connect(sock, op, &token).await.unwrap();
        let (r, w) = stream.into_split();
        Viewer { r: BufReader::new(r), w, cols: 0, rows: 0, lines: BTreeMap::new(), mid: false }
    }

    pub async fn connect(dir: &Path, name: &str) -> Viewer {
        Viewer::connect_op(dir, name, "view").await
    }

    /// The next line, or `Null` at the end of the stream.
    pub async fn next(&mut self) -> Value {
        let mut s = String::new();
        let n =
            tokio::time::timeout(WAIT, self.r.read_line(&mut s)).await.expect("timed out waiting for a line").unwrap();
        if n == 0 {
            return Value::Null;
        }
        let v: Value = serde_json::from_str(&s).unwrap();
        if v["t"] == "screen" {
            self.apply(&v).await;
        }
        v
    }

    /// Take a screen in, and acknowledge it once its last part is in.
    async fn apply(&mut self, v: &Value) {
        // A whole screen starts over, in its first part only.
        if v["full"] == true && !self.mid {
            self.lines.clear();
        }
        (self.cols, self.rows) = (v["cols"].as_u64().unwrap() as u16, v["rows"].as_u64().unwrap() as u16);
        for l in v["lines"].as_array().unwrap() {
            self.lines.insert(l[0].as_u64().unwrap() as u16, l[1].as_str().unwrap().to_string());
        }
        self.mid = v["more"] == true;
        if !self.mid {
            // The last screen comes right before the end, when there may be nobody left to ack to.
            let _ = self.w.write_all(format!("{}\n", json!({"t":"ack","rev":v["rev"]})).as_bytes()).await;
        }
    }

    pub async fn send(&mut self, v: Value) {
        self.w.write_all(format!("{v}\n").as_bytes()).await.unwrap();
    }

    /// Hello, panes, then view: returns the first screen.
    pub async fn open(&mut self) -> Value {
        let hello = self.next().await;
        assert_eq!((hello["t"].as_str(), hello["backend"].as_str()), (Some("hello"), Some("pty")), "{hello}");
        assert_eq!(self.next().await["t"], "panes");
        self.send(json!({"t":"view","pane":"%0","cols":80,"rows":24})).await;
        loop {
            let v = self.next().await;
            if v["t"] == "screen" {
                return v;
            }
        }
    }

    /// How many rows of the screen hold `text`.
    pub fn count(&self, text: &str) -> usize {
        self.lines.values().filter(|l| l.contains(text)).count()
    }

    /// Read until a message `pick` takes; every message on the way is returned too, in order.
    pub async fn until(&mut self, mut pick: impl FnMut(&Viewer, &Value) -> bool) -> Vec<Value> {
        let end = Instant::now() + WAIT;
        let mut seen = Vec::new();
        loop {
            assert!(Instant::now() < end, "never got the message waited for; got {seen:?}");
            let v = self.next().await;
            assert!(!v.is_null(), "the stream ended first; got {seen:?}");
            let done = pick(self, &v);
            seen.push(v);
            if done {
                return seen;
            }
        }
    }

    /// Read until the screen has `n` rows holding `text`.
    pub async fn wait_text(&mut self, text: &str, n: usize) {
        if self.count(text) >= n {
            return;
        }
        self.until(|v, _| v.count(text) >= n).await;
    }
}
