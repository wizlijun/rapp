//! A reply to a session with no view open.
//!
//! The bytes go straight into `shared.input`, like the local keyboard: no `view`, no `fit`, no viewer count, so the
//! host window keeps its size and whoever it follows. With a `seq` the reply is for one status snapshot: it is
//! refused when the snapshot moved on, or when somebody typed into the session since that state began.

use super::Shared;
use crate::keys;
use serde::Deserialize;
use serde_json::{json, Value};
use std::sync::atomic::Ordering;

/// The most text one reply carries, in UTF-8 bytes: the request head is one line of at most 4096.
pub const MAX_TEXT: usize = 3000;

/// What a reply asks for. Text goes first (bracketed when the program asked for it), then `enter`, then `keys`.
#[derive(Debug, Default, Clone, PartialEq, Deserialize)]
pub struct Reply {
    /// The `ps.seq` the sender saw; none sends whatever the state.
    #[serde(default)]
    pub seq: Option<u64>,
    #[serde(default)]
    pub text: Option<String>,
    #[serde(default)]
    pub enter: bool,
    #[serde(default)]
    pub keys: Vec<String>,
}

/// Checks and sends `r`. The error is the answer line for the client.
pub fn apply(shared: &Shared, r: &Reply) -> Result<(), Value> {
    if r.text.as_ref().is_some_and(|t| t.len() > MAX_TEXT) {
        return Err(json!({ "error": "too long" }));
    }
    let modes = shared.emu.lock().unwrap_or_else(|e| e.into_inner()).modes();
    let mut b = Vec::new();
    if let Some(t) = r.text.as_deref().filter(|t| !t.is_empty()) {
        if modes.bracketed_paste {
            b.extend_from_slice(b"\x1b[200~");
        }
        b.extend_from_slice(t.as_bytes());
        if modes.bracketed_paste {
            b.extend_from_slice(b"\x1b[201~");
        }
    }
    if r.enter {
        b.push(b'\r');
    }
    for k in &r.keys {
        match keys::to_bytes(k, modes) {
            Some(k) => b.extend(k),
            None => return Err(json!({ "error": "unknown key" })),
        }
    }
    if b.is_empty() {
        return Err(json!({ "error": "empty" }));
    }
    // Held while the bytes are queued, so the output pump cannot move the snapshot between the check and the send.
    let ps = shared.ps.lock().unwrap_or_else(|e| e.into_inner());
    if let Some(want) = r.seq {
        let Some(p) = ps.as_ref() else {
            return Err(json!({ "error": "changed", "seq": null }));
        };
        if p.seq != want {
            return Err(json!({ "error": "changed", "seq": p.seq, "state": p.state }));
        }
        let typed = shared.input_at.load(Ordering::Relaxed);
        if p.since != 0 && typed >= p.since {
            return Err(json!({ "error": "typed", "seq": p.seq }));
        }
    }
    if shared.input.send(b).is_err() {
        return Err(json!({ "error": "ended" }));
    }
    drop(ps);
    shared.note_input();
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::pty::grid::Emu;
    use crate::pty::ps::Ps;
    use crate::pty::Meta;
    use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64};
    use std::sync::Mutex;
    use tokio::sync::{mpsc, watch};

    fn shared() -> (Shared, mpsc::UnboundedReceiver<Vec<u8>>) {
        let (input, rx) = mpsc::unbounded_channel();
        let sh = Shared {
            emu: Mutex::new(Emu::new(100, 30)),
            rev: watch::channel(0).0,
            input,
            meta: Meta {
                key: "k".into(),
                name: Mutex::new("t".into()),
                command: "cat".into(),
                pid: 1,
                ticket: None,
                named: AtomicBool::new(false),
            },
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

    fn blocked(seq: u64, since: u64) -> Ps {
        Ps {
            state: "blocked".into(),
            kind: Some("permission".into()),
            app: None,
            msg: None,
            progress: None,
            since,
            stopped: 0,
            seq,
        }
    }

    #[test]
    fn text_enter_and_keys_go_in_order() {
        let (sh, mut rx) = shared();
        let r = Reply { text: Some("yes".into()), enter: true, keys: vec!["Esc".into()], ..Default::default() };
        assert_eq!(apply(&sh, &r), Ok(()));
        assert_eq!(rx.try_recv().unwrap(), b"yes\r\x1b");
        assert_ne!(sh.input_at.load(Ordering::Relaxed), 0);
    }

    #[test]
    fn a_reply_never_touches_fit_or_viewers() {
        let (sh, _rx) = shared();
        let t0 = std::time::Instant::now();
        let a = {
            let mut f = sh.fit.lock().unwrap();
            let a = f.join();
            f.view(a, true, 90, 20, t0);
            assert_eq!(f.take(), Some((90, 20)));
            a
        };
        assert_eq!(apply(&sh, &Reply { keys: vec!["Enter".into()], ..Default::default() }), Ok(()));
        let mut f = sh.fit.lock().unwrap();
        assert_eq!(f.take(), None);
        // A still holds the seat: its next size is followed at once.
        f.view(a, true, 80, 18, std::time::Instant::now());
        assert_eq!(f.take(), Some((80, 18)));
        assert_eq!(sh.viewers.load(Ordering::Relaxed), 0);
    }

    #[test]
    fn a_stale_seq_is_refused_with_the_current_one() {
        let (sh, mut rx) = shared();
        *sh.ps.lock().unwrap() = Some(blocked(4, 100));
        let r = Reply { seq: Some(3), keys: vec!["Enter".into()], ..Default::default() };
        assert_eq!(apply(&sh, &r), Err(json!({ "error": "changed", "seq": 4, "state": "blocked" })));
        assert!(rx.try_recv().is_err());
        let r = Reply { seq: Some(4), ..r };
        assert_eq!(apply(&sh, &r), Ok(()));
    }

    #[test]
    fn a_seq_without_status_is_refused() {
        let (sh, mut rx) = shared();
        let r = Reply { seq: Some(1), keys: vec!["Enter".into()], ..Default::default() };
        assert_eq!(apply(&sh, &r).unwrap_err()["error"], "changed");
        assert!(rx.try_recv().is_err());
    }

    #[test]
    fn typing_since_the_question_refuses_a_seq_reply() {
        let (sh, mut rx) = shared();
        *sh.ps.lock().unwrap() = Some(blocked(2, 100));
        sh.input_at.store(100, Ordering::Relaxed);
        let r = Reply { seq: Some(2), keys: vec!["Enter".into()], ..Default::default() };
        assert_eq!(apply(&sh, &r), Err(json!({ "error": "typed", "seq": 2 })));
        assert!(rx.try_recv().is_err());
        // Typing before the question began does not count.
        sh.input_at.store(99, Ordering::Relaxed);
        assert_eq!(apply(&sh, &r), Ok(()));
        // And the reply itself counts as typing: a second click on the same question is refused.
        assert_eq!(apply(&sh, &r).unwrap_err()["error"], "typed");
    }

    #[test]
    fn bad_input_is_refused() {
        let (sh, _rx) = shared();
        assert_eq!(apply(&sh, &Reply::default()).unwrap_err()["error"], "empty");
        assert_eq!(apply(&sh, &Reply { keys: vec!["Nope-Nope".into()], ..Default::default() }).unwrap_err()["error"], "unknown key");
        assert_eq!(apply(&sh, &Reply { text: Some("x".repeat(MAX_TEXT + 1)), ..Default::default() }).unwrap_err()["error"], "too long");
    }
}
