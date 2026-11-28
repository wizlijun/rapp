#![cfg(unix)]
//! `reply_term` from a hub through an in-process relay to a service on A and the real `rapp-term` there: the
//! program gets the text and Return, the window keeps its size, and a seq that no longer holds is refused.

mod common;

use common::*;
use serde_json::{json, Value};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

/// The real `rapp-term` next to the test binary (`target/debug/deps/reply_term-x` -> `target/debug/rapp-term`),
/// built first if it is not there (`cargo test -p rapp-testkit` alone does not build it).
fn real_term() -> PathBuf {
    if let Some(p) = std::env::var_os("RAPP_REAL_TERM") {
        return PathBuf::from(p);
    }
    let exe = std::env::current_exe().unwrap();
    let bin = exe.parent().unwrap().parent().unwrap().join("rapp-term");
    if !bin.exists() {
        let cargo = std::env::var_os("CARGO").unwrap_or_else(|| "cargo".into());
        let ok = Command::new(cargo).args(["build", "-p", "rapp-term"]).status().unwrap().success();
        assert!(ok && bin.exists(), "cannot build rapp-term");
    }
    bin
}

/// `bins()`, with the real `rapp-term`.
fn bins_real() -> tempfile::TempDir {
    let d = bins();
    std::fs::remove_file(d.path().join("rapp-term")).unwrap();
    std::os::unix::fs::symlink(real_term(), d.path().join("rapp-term")).unwrap();
    d
}

/// A `rapp-term run` in a pty of its own, running a program that logs each line it reads. Its window output goes
/// to `out`.
struct Win {
    child: Child,
    out: PathBuf,
    got: PathBuf,
}

impl Win {
    fn start(pty_dir: &Path, scratch: &Path) -> Win {
        let (out, got) = (scratch.join("window.out"), scratch.join("got.log"));
        let prog = format!(
            "import sys\nf=open({:?},'a')\nfor l in iter(sys.stdin.readline,''):\n  f.write(l.strip()+'\\n'); f.flush()\n",
            got.to_str().unwrap()
        );
        let child = Command::new("/usr/bin/python3")
            .args(["-c", "import pty,sys; pty.spawn(sys.argv[1:])"])
            .arg(real_term())
            .args(["run", "--dir"])
            .arg(pty_dir)
            .args(["--name", "reply", "--", "/usr/bin/python3", "-u", "-c", &prog])
            .stdin(Stdio::piped())
            .stdout(std::fs::File::create(&out).unwrap())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        Win { child, out, got }
    }

    fn output(&self) -> String {
        String::from_utf8_lossy(&std::fs::read(&self.out).unwrap_or_default()).into_owned()
    }

    fn lines(&self) -> Vec<String> {
        std::fs::read_to_string(&self.got).unwrap_or_default().lines().map(String::from).collect()
    }

    async fn wait_lines(&self, n: usize) -> Vec<String> {
        let end = Instant::now() + WAIT;
        loop {
            let l = self.lines();
            if l.len() >= n {
                return l;
            }
            assert!(Instant::now() < end, "program got {l:?}, wanted {n} lines");
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    }
}

impl Drop for Win {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

/// The session named `reply`, as the hub lists it.
async fn listed(hub: &mut Hub, id: &str) -> Value {
    let end = Instant::now() + WAIT;
    loop {
        let r = hub.call(json!({"cmd":"terms","id":id,"req":"t"})).await;
        if let Some(t) = r["terms"].as_array().into_iter().flatten().find(|t| t["name"] == "reply") {
            return t.clone();
        }
        assert!(Instant::now() < end, "no reply session: {r}");
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
}

#[tokio::test]
async fn reply_term_end_to_end() {
    let rig = RelayRig::start().await;
    let (bins, scratch) = (bins_real(), tempfile::tempdir().unwrap());
    let dir = bins.path().to_path_buf();
    // A dead LAN address: the hub can only go through the relay.
    let a = service_on_relay_with(&rig.addr, &rig.key, Some(vec!["127.0.0.1:1".into()]), |o| o.bin_dir = Some(dir)).await;
    let mut ipc = Ipc::open(&a.svc, a.home.path()).await;
    wait_status(&mut ipc, |s| s["relay"] == "connected").await;
    std::fs::write(a.home.path().join("term.json"), r#"{"allow":true}"#).unwrap();
    let win = Win::start(&a.home.path().join("term"), scratch.path());
    let hub_home = tempfile::tempdir().unwrap();
    hub_relay(hub_home.path(), &rig.addr, &rig.key);
    let mut hub = Hub::start(hub_home.path(), bins.path());
    let r = hub.call(json!({"cmd":"add_host","id":a.id,"req":1})).await;
    assert_eq!(r["event"], "host_added", "{r}");

    let row = listed(&mut hub, &a.id).await;
    assert_eq!(row["reply"], true, "{row}");
    let term = row["id"].as_str().unwrap().to_string();

    // Text and Return arrive; the answer names the terminal.
    let r = hub.call(json!({"cmd":"reply_term","id":a.id,"term":term,"text":"hello","enter":true,"req":2})).await;
    assert_eq!(r["event"], "term_replied", "{r}");
    assert_eq!(r["term"], term.as_str(), "{r}");
    assert_eq!(win.wait_lines(1).await, ["hello"]);

    // A seq that no longer holds: refused with the reason, nothing sent.
    let r = hub.call(json!({"cmd":"reply_term","id":a.id,"term":term,"seq":99,"keys":["x","Enter"],"req":3})).await;
    assert_eq!((&r["event"], &r["error"]), (&json!("error"), &json!("changed")), "{r}");
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert_eq!(win.lines(), ["hello"]);

    // A's window was never resized.
    assert!(!win.output().contains("\x1b[8;"), "a resize reached the window");
    // Never the text in A's log, only that a reply came.
    let log = std::fs::read_to_string(a.home.path().join("logs/service.log")).unwrap_or_default();
    assert!(log.contains("reply_term") && !log.contains("hello"), "{log}");
    hub.finish().await;
}
