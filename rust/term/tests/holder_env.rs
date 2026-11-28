#![cfg(unix)]
//! What the program `rapp-term run` starts finds in its environment.

#[path = "common/pty.rs"]
mod pty;

use pty::{short_dir, wait_status, Window, WAIT};
use std::time::{Duration, Instant};

#[tokio::test]
async fn child_sees_rapp_term() {
    let d = short_dir();
    let out = d.path().join("out");
    let script = format!("printf %s \"$RAPP_TERM\" > {}; sleep 30", out.display());
    let _w = Window::start(d.path(), &["--name", "t", "--", "/bin/sh", "-c", &script]);
    let key = wait_status(d.path(), "t").await.key.expect("a new run has a key");
    let end = Instant::now() + WAIT;
    // The file is written in one printf, so any content is the whole value.
    while std::fs::read_to_string(&out).unwrap_or_default().is_empty() {
        assert!(Instant::now() < end, "the program never wrote RAPP_TERM");
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    assert_eq!(std::fs::read_to_string(&out).unwrap(), format!("term:pty:{key}"));
}
