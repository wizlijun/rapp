//! Idle memory of the relay with 100 registered devices (spec §9.4). The test is `#[ignore]`d: it
//! sleeps 10 s. Run with `cargo test -p rapp-relay --release --test bench -- --ignored --nocapture`.
//!
//! The relay runs as a child process and is measured by its own `wait4` rusage, so the fake devices'
//! QUIC work (in this process) does not count against it.
mod common;

use std::io::{BufRead, BufReader};
use std::net::SocketAddr;
use std::process::{Command, Stdio};
use std::sync::mpsc;
use std::time::Duration;

use common::FakeDevice;
use rapp_relay::admin;
use rapp_wire::{Fp, Identity};
use serde_json::{json, Value};

/// A relay child process. Killed on drop unless `finish` reaped it.
struct Proc {
    pid: libc::pid_t,
    reaped: bool,
}

struct Usage {
    rss_mb: f64,
}

impl Proc {
    /// Spawns `cmd` and waits for a stderr JSON line mentioning `marker`; returns it too.
    #[allow(clippy::zombie_processes)] // reaped by `wait4` in `finish` (or `waitpid` in drop), never by `Child`
    fn spawn(mut cmd: Command, marker: &str) -> (Proc, Value) {
        let mut child = cmd.stderr(Stdio::piped()).stdout(Stdio::null()).stdin(Stdio::null()).spawn().expect("spawn");
        let proc = Proc { pid: child.id() as libc::pid_t, reaped: false };
        let stderr = child.stderr.take().unwrap();
        let (tx, rx) = mpsc::channel();
        let marker = marker.to_string();
        // Keeps draining after the marker so the child never blocks on a full pipe.
        std::thread::spawn(move || {
            let mut tx = Some(tx);
            for line in BufReader::new(stderr).lines().map_while(Result::ok) {
                if let Some(t) = &tx {
                    if line.contains(&marker) {
                        if let Ok(v) = serde_json::from_str::<Value>(&line) {
                            let _ = t.send(v);
                            tx = None;
                        }
                    }
                }
            }
        });
        let line = rx.recv_timeout(Duration::from_secs(20)).expect("relay announced itself on stderr");
        // `child` is dropped without waiting: only `wait4` below reaps it.
        (proc, line)
    }

    /// SIGTERM, then this child's own rusage.
    async fn finish(mut self) -> Usage {
        let pid = self.pid;
        unsafe { libc::kill(pid, libc::SIGTERM) };
        let ru = tokio::task::spawn_blocking(move || unsafe {
            let mut status = 0;
            let mut ru: libc::rusage = std::mem::zeroed();
            assert_eq!(libc::wait4(pid, &mut status, 0, &mut ru), pid, "wait4");
            ru
        })
        .await
        .unwrap();
        self.reaped = true;
        let bytes = if cfg!(target_os = "macos") { ru.ru_maxrss as f64 } else { ru.ru_maxrss as f64 * 1024.0 };
        Usage { rss_mb: bytes / (1024.0 * 1024.0) }
    }
}

impl Drop for Proc {
    fn drop(&mut self) {
        if !self.reaped {
            unsafe {
                libc::kill(self.pid, libc::SIGKILL);
                libc::waitpid(self.pid, std::ptr::null_mut(), 0);
            }
        }
    }
}

struct Relay2 {
    proc: Proc,
    _data: tempfile::TempDir,
    addr: SocketAddr,
    fp: Fp,
    key: rapp_wire::Key,
}

/// Starts `rapp-relay` on a fresh data dir with a key installed, like the `key` subcommand does.
async fn start_relay(env: &[(&str, &str)]) -> Relay2 {
    let data = tempfile::tempdir().unwrap();
    let mut cmd = Command::new(env!("CARGO_BIN_EXE_rapp-relay"));
    cmd.arg("--data").arg(data.path()).env("RAPP_RELAY_LISTEN", "127.0.0.1:0");
    for (k, v) in env {
        cmd.env(k, v);
    }
    let (proc, _) = Proc::spawn(cmd, "\"listening\"");
    let info = admin::call(data.path(), json!({"cmd": "info"})).await.unwrap();
    let fp: Fp = info["fp"].as_str().unwrap().parse().unwrap();
    let addr: SocketAddr = info["listen"].as_str().unwrap().parse().unwrap();
    let key = admin::issue_key(data.path(), false).await.unwrap().expect("a new key");
    Relay2 { proc, _data: data, addr, fp, key }
}

impl Relay2 {
    async fn device(&self) -> FakeDevice {
        let d = FakeDevice::dial_remote(self.addr, &self.fp, Identity::generate().unwrap()).await.unwrap();
        let v = d.enroll(&self.key).await;
        assert_eq!(v["ok"], true, "enroll: {v}");
        d
    }
}

#[tokio::test(flavor = "multi_thread")]
#[ignore]
async fn idle_memory_with_100_devices() {
    let env = [("RAPP_RELAY_LIMIT_MAX_CONNS_PER_IP", "1000"), ("RAPP_RELAY_LIMIT_ENROLL_PER_IP_PER_MIN", "1000")];
    let r = start_relay(&env).await;
    let mut devices = Vec::new();
    for i in 0..100 {
        let d = r.device().await;
        let id = format!("{}", 100_000_000 + i);
        assert_eq!(d.register(&id, &["192.168.1.5:22028"]).await["ok"], true);
        devices.push(d);
    }
    tokio::time::sleep(Duration::from_secs(10)).await;
    let u = r.proc.finish().await;
    drop(devices);
    println!("rss_mb={:.1}", u.rss_mb);
    assert!(u.rss_mb < 50.0, "idle relay peaked at {:.1} MB (limit 50)", u.rss_mb);
}
