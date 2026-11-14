//! A private tmux server for live tests; never the user's own.

use rapp_term::runner::Runner;
use rapp_term::tmux::Tmux;
use std::process::Command;
use std::sync::atomic::{AtomicUsize, Ordering};

static COUNTER: AtomicUsize = AtomicUsize::new(0);

pub struct Server {
    pub socket: String,
    /// The socket file, which `kill-server` leaves behind.
    path: String,
}

#[allow(dead_code)]
impl Server {
    /// A running server with zero sessions, or `None` (skip) when tmux is missing.
    pub fn start() -> Option<Server> {
        if Command::new("tmux").arg("-V").output().is_err() {
            if std::env::var("RAPP_TERM_REQUIRE_TMUX").as_deref() == Ok("1") {
                panic!("tmux is not installed and RAPP_TERM_REQUIRE_TMUX=1");
            }
            eprintln!("skipped: tmux is not installed");
            return None;
        }
        let socket = format!("rapp-term-test-{}-{}", std::process::id(), COUNTER.fetch_add(1, Ordering::SeqCst));
        let mut s = Server { socket, path: String::new() };
        s.raw(&["new-session", "-d", "-s", "boot"]);
        s.raw(&["set", "-g", "exit-empty", "off"]);
        s.path = s.raw(&["display-message", "-p", "-t", "boot", "#{socket_path}"]).trim().to_string();
        s.raw(&["kill-session", "-t", "boot"]);
        Some(s)
    }

    pub fn tmux(&self) -> Tmux {
        Tmux { runner: Runner::Local, bin: "tmux".into(), socket: Some(self.socket.clone()) }
    }

    /// Run a tmux command on this server directly (not through `Tmux`); stdout.
    pub fn raw(&self, args: &[&str]) -> String {
        let out = Command::new("tmux").args(["-L", &self.socket, "-f", "/dev/null"]).args(args).output().unwrap();
        String::from_utf8_lossy(&out.stdout).into_owned()
    }
}

impl Drop for Server {
    fn drop(&mut self) {
        let _ = Command::new("tmux").args(["-L", &self.socket, "-f", "/dev/null", "kill-server"]).output();
        if !self.path.is_empty() {
            let _ = std::fs::remove_file(&self.path);
        }
    }
}

/// Give a freshly started pane command time to print.
#[allow(dead_code)]
pub async fn settle() {
    tokio::time::sleep(std::time::Duration::from_millis(300)).await;
}

/// A real terminal client on a pty (through `script`), as a person's terminal would be; it leaves when dropped.
pub struct RealClient(std::process::Child);

#[allow(dead_code)]
impl Server {
    /// Attach a real client of `session` whose terminal is `cols` x `rows`, and wait until tmux counts it.
    pub fn attach_real(&self, session: &str, cols: u16, rows: u16) -> RealClient {
        let count = || self.raw(&["display-message", "-p", "-t", session, "#{session_attached}"]).trim().to_string();
        let before: u32 = count().parse().unwrap();
        let inner =
            format!("stty cols {cols} rows {rows}; exec tmux -L {} -f /dev/null attach -t {session}", self.socket);
        let mut c = Command::new("script");
        if cfg!(target_os = "macos") {
            c.args(["-q", "/dev/null", "sh", "-c", &inner]);
        } else {
            c.args(["-q", "-c", &inner, "/dev/null"]);
        }
        let child = c
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .spawn()
            .expect("script is needed to attach a real client");
        let client = RealClient(child);
        let end = std::time::Instant::now() + std::time::Duration::from_secs(5);
        while count().parse::<u32>().unwrap_or(0) <= before {
            assert!(std::time::Instant::now() < end, "the real client did not attach within 5 seconds");
            std::thread::sleep(std::time::Duration::from_millis(50));
        }
        client
    }
}

impl Drop for RealClient {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}
