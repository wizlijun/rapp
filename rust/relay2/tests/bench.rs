//! Relay cost against the old relay, and idle memory (spec §9.4). Both tests are `#[ignore]`d: they
//! move 512 MiB several times. Run with
//! `cargo build --release -p rapp-relay && cargo test -p rapp-relay2 --release --test bench -- --ignored
//! --nocapture --test-threads=1`.
//!
//! Each relay runs as a child process and is measured by its own `wait4` rusage, so the fake devices'
//! QUIC work (in this process) does not dilute the ratio and one child's peak memory does not leak
//! into another's.
mod common;

use std::io::{BufRead, BufReader};
use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::mpsc;
use std::time::Duration;

use common::FakeDevice;
use rapp_net::line::{read_json, write_json};
use rapp_net::quic::{bi, client_endpoint, connect, ALPN_RELAY};
use rapp_relay2::admin;
use rapp_wire::{Fp, Identity};
use serde_json::{json, Value};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};

const PAYLOAD: u64 = 512 * 1024 * 1024;
const CHUNK: usize = 64 * 1024;
/// Interleaved old/new runs; the gate compares the fastest of each (interference only adds CPU time,
/// and per-run CPU is bimodal by about 15% with core placement and thermal state).
const RUNS: usize = 7;
const A_ID: &str = "123456789";

/// A relay child process. Killed on drop unless `finish` reaped it.
struct Proc {
    pid: libc::pid_t,
    reaped: bool,
}

struct Usage {
    cpu_ms: f64,
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
        let ms = |t: libc::timeval| t.tv_sec as f64 * 1e3 + t.tv_usec as f64 / 1e3;
        let bytes = if cfg!(target_os = "macos") { ru.ru_maxrss as f64 } else { ru.ru_maxrss as f64 * 1024.0 };
        Usage { cpu_ms: ms(ru.ru_utime) + ms(ru.ru_stime), rss_mb: bytes / (1024.0 * 1024.0) }
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

fn payload_chunk() -> Vec<u8> {
    let mut x: u64 = 0x9E37_79B9_7F4A_7C15;
    (0..CHUNK)
        .map(|_| {
            x ^= x << 13;
            x ^= x >> 7;
            x ^= x << 17;
            x as u8
        })
        .collect()
}

/// Sends `PAYLOAD` bytes in 64 KiB chunks on `tx` while `rx` reads the same number.
async fn carry(mut tx: impl AsyncWrite + Unpin, mut rx: impl AsyncRead + Unpin) {
    let chunk = payload_chunk();
    let send = async {
        for _ in 0..PAYLOAD / CHUNK as u64 {
            tx.write_all(&chunk).await.unwrap();
        }
        tx.flush().await.unwrap();
    };
    let recv = async {
        let (mut got, mut buf) = (0u64, vec![0u8; CHUNK]);
        while got < PAYLOAD {
            let n = rx.read(&mut buf).await.unwrap();
            assert!(n > 0, "stream ended after {got} bytes");
            got += n as u64;
        }
    };
    tokio::join!(send, recv);
}

fn workspace_bin(name: &str) -> PathBuf {
    let p = Path::new(env!("CARGO_MANIFEST_DIR")).join("../target/release").join(name);
    assert!(p.exists(), "{} is missing: run `cargo build --release -p rapp-relay` first", p.display());
    p
}

/// One run through the old relay: register A, B connects, 512 MiB B -> A. Its CPU and memory.
async fn old_run() -> Usage {
    let dir = tempfile::tempdir().unwrap();
    let mut cmd = Command::new(workspace_bin("rapp-relay"));
    cmd.args(["--key", "bench-key", "--listen", "127.0.0.1:0", "--db"]).arg(dir.path().join("relay.json"));
    let (proc, line) = Proc::spawn(cmd, "relay_start");
    let addr: SocketAddr = line["listen"].as_str().expect("listen in relay_start").parse().unwrap();

    let ep = client_endpoint("127.0.0.1:0".parse().unwrap()).unwrap();
    let a = connect(&ep, addr, ALPN_RELAY, Duration::from_secs(5)).await.unwrap();
    let mut s = bi(a.open_bi().await.unwrap());
    let salt = "00".repeat(16);
    let reg = json!({"op":"register","key":"bench-key","id":A_ID,"secret":"ab".repeat(16),"name":"a",
                     "pw_salt":salt,"pw_hash":rapp_net::crypto::pw_hash(&salt, "pw"),"lan":[]});
    write_json(&mut s, &reg).await.unwrap();
    let r = read_json(&mut s).await.unwrap();
    assert_eq!(r, json!({"ok": true, "id": A_ID}));

    // A answers `incoming` while B's `connect` waits for it, then takes the `relayed` stream.
    let a_conn = a.clone();
    let a_side = tokio::spawn(async move {
        loop {
            let mut st = bi(a_conn.accept_bi().await.unwrap());
            let first = read_json(&mut st).await.unwrap();
            if first["op"] == "incoming" {
                write_json(&mut st, &json!({"ok":true})).await.unwrap();
            } else {
                assert_eq!(first["op"], "relayed");
                return st;
            }
        }
    });

    let ep_b = client_endpoint("127.0.0.1:0".parse().unwrap()).unwrap();
    let b = connect(&ep_b, addr, ALPN_RELAY, Duration::from_secs(5)).await.unwrap();
    let mut c = bi(b.open_bi().await.unwrap());
    write_json(&mut c, &json!({"op":"connect","key":"bench-key","id":A_ID,"password":"pw"})).await.unwrap();
    let ok = read_json(&mut c).await.unwrap();
    let token = ok["token"].as_str().unwrap_or_else(|| panic!("connect: {ok}")).to_string();

    let mut on_b = bi(b.open_bi().await.unwrap());
    write_json(&mut on_b, &json!({"op":"relay","key":"bench-key","token":token})).await.unwrap();
    let on_a = a_side.await.unwrap();
    let (_, w) = tokio::io::split(on_b);
    let (r, _) = tokio::io::split(on_a);
    carry(w, r).await;
    drop((a, b, ep, ep_b, c, s));
    proc.finish().await
}

struct NewRelay {
    proc: Proc,
    data: tempfile::TempDir,
    addr: SocketAddr,
    fp: Fp,
    key: rapp_wire::Key,
}

/// Starts `rapp-relay2` on a fresh data dir with a key installed, like the `key` subcommand does.
async fn new_relay(env: &[(&str, &str)]) -> NewRelay {
    let data = tempfile::tempdir().unwrap();
    let mut cmd = Command::new(env!("CARGO_BIN_EXE_rapp-relay2"));
    cmd.arg("--data").arg(data.path()).env("RAPP_RELAY_LISTEN", "127.0.0.1:0");
    for (k, v) in env {
        cmd.env(k, v);
    }
    let (proc, _) = Proc::spawn(cmd, "\"listening\"");
    let info = admin::call(data.path(), json!({"cmd": "info"})).await.unwrap();
    let fp: Fp = info["fp"].as_str().unwrap().parse().unwrap();
    let addr: SocketAddr = info["listen"].as_str().unwrap().parse().unwrap();
    let key = admin::issue_key(data.path(), false).await.unwrap().expect("a new key");
    NewRelay { proc, data, addr, fp, key }
}

impl NewRelay {
    async fn device(&self) -> FakeDevice {
        let d = FakeDevice::dial_remote(self.addr, &self.fp, Identity::generate().unwrap()).await.unwrap();
        let v = d.enroll(&self.key).await;
        assert_eq!(v["ok"], true, "enroll: {v}");
        d
    }
}

async fn new_run() -> Usage {
    let r = new_relay(&[]).await;
    let mut a = r.device().await;
    assert_eq!(a.register(A_ID, &[]).await["ok"], true);
    let b = r.device().await;
    let on_b = b.relay_to(A_ID).await.unwrap();
    let (_, _, on_a) = a.next_relayed().await;
    let (_, w) = tokio::io::split(on_b);
    let (rd, _) = tokio::io::split(on_a);
    carry(w, rd).await;
    drop((a, b));
    let usage = r.proc.finish().await;
    drop(r.data);
    usage
}

fn median(mut v: Vec<f64>) -> f64 {
    v.sort_by(|a, b| a.partial_cmp(b).unwrap());
    v[v.len() / 2]
}

#[tokio::test(flavor = "multi_thread")]
#[ignore]
async fn relaying_costs_no_more_cpu_than_the_old_relay() {
    let (mut old, mut new) = (Vec::new(), Vec::new());
    for i in 0..RUNS {
        let o = old_run().await;
        let n = new_run().await;
        println!("run {i}: old {:.0} ms, new {:.0} ms", o.cpu_ms, n.cpu_ms);
        old.push(o.cpu_ms);
        new.push(n.cpu_ms);
    }
    let min = |v: &[f64]| v.iter().cloned().fold(f64::INFINITY, f64::min);
    let (old_min, new_min) = (min(&old), min(&new));
    let (old_med, new_med) = (median(old), median(new));
    println!("old_med={old_med:.0} new_med={new_med:.0} median_ratio={:.3} (informational)", new_med / old_med);
    let ratio = new_min / old_min;
    println!("old_ms={old_min:.0} new_ms={new_min:.0} ratio={ratio:.3} (min/min: the gate)");
    assert!(ratio <= 1.05, "the new relay's fastest run costs {ratio:.3}x the old one's fastest (limit 1.05)");
}

#[tokio::test(flavor = "multi_thread")]
#[ignore]
async fn idle_memory_with_100_devices() {
    let env = [("RAPP_RELAY_LIMIT_MAX_CONNS_PER_IP", "1000"), ("RAPP_RELAY_LIMIT_ENROLL_PER_IP_PER_MIN", "1000")];
    let r = new_relay(&env).await;
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
