//! A private tmux server for live tests; never the user's own.

use rapp_term::runner::Runner;
use rapp_term::tmux::Tmux;
use std::process::Command;
use std::sync::atomic::{AtomicUsize, Ordering};

static COUNTER: AtomicUsize = AtomicUsize::new(0);

pub struct Server {
    pub socket: String,
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
        let s = Server { socket };
        s.raw(&["new-session", "-d", "-s", "boot"]);
        s.raw(&["set", "-g", "exit-empty", "off"]);
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
    }
}
