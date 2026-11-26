//! Lock and unlock rules against the Swift reference. Fixtures are written by
//! `Tests/RappCoreTests/HostCoreFixtures/LockFixtures.swift` (`lock.json`,
//! `unlock-sequence.json`); the lock-file tests are Rust only (Swift's are `FileLockTests`).

mod common;
mod rules_common;

use std::cell::RefCell;
use std::collections::HashMap;
use std::sync::mpsc;
use std::time::{Duration, Instant};

use common::raw_cases;
use rapp_host_core::geometry::Rect;
use rapp_host_core::lock::*;
use rules_common::*;
use serde_json::{json, Value};

/// JSON equality where numbers compare as f64: Swift writes `2` for the Double 2.0.
fn same(a: &Value, b: &Value) -> bool {
    match (a, b) {
        (Value::Number(x), Value::Number(y)) => x.as_f64() == y.as_f64(),
        (Value::Array(x), Value::Array(y)) => x.len() == y.len() && x.iter().zip(y).all(|(p, q)| same(p, q)),
        (Value::Object(x), Value::Object(y)) => {
            x.len() == y.len() && x.iter().all(|(k, v)| y.get(k).is_some_and(|w| same(v, w)))
        }
        _ => a == b,
    }
}

/// `isLocked` scripted as the generator does: the i-th call returns `locked[i]`, the last
/// value once the list is spent, `false` for an empty list.
fn scripted(locked: Vec<bool>, events: &RefCell<Vec<Value>>) -> impl FnMut() -> bool + '_ {
    let mut i = 0usize;
    move || {
        let v = if locked.is_empty() { false } else { locked[i.min(locked.len() - 1)] };
        i += 1;
        events.borrow_mut().push(json!({"op": "is_locked", "v": v}));
        v
    }
}

fn outcome_json(o: &LockOutcome) -> Value {
    match o {
        LockOutcome::Locked => json!({"kind": "locked", "reason": null}),
        LockOutcome::Already => json!({"kind": "already", "reason": null}),
        LockOutcome::Failed(r) => json!({"kind": "failed", "reason": r}),
    }
}

#[test]
fn lock_rules_match_swift() {
    let cases = raw_cases("lock.json");
    assert!(!cases.is_empty());
    for c in cases {
        let i = &c.input;
        let got = match func(i) {
            "lock_screen" => {
                let events = RefCell::new(Vec::new());
                let reason: Option<String> = arg(&i["call"]);
                let mut is_locked = scripted(arg(&i["locked"]), &events);
                let mut call = || {
                    events.borrow_mut().push(json!({"op": "call"}));
                    reason.clone()
                };
                let mut sleep = |s: f64| events.borrow_mut().push(json!({"op": "sleep", "s": s}));
                let o = lock_screen(&mut is_locked, &mut call, &mut sleep, arg(&i["timeout"]), arg(&i["step"]));
                drop(is_locked);
                json!({"outcome": outcome_json(&o), "events": events.into_inner()})
            }
            "wait_until_unlocked" => {
                let events = RefCell::new(Vec::new());
                let mut is_locked = scripted(arg(&i["locked"]), &events);
                let mut sleep = |s: f64| events.borrow_mut().push(json!({"op": "sleep", "s": s}));
                wait_until_unlocked(&mut is_locked, &mut sleep, arg(&i["timeout"]), arg(&i["step"]));
                drop(is_locked);
                json!({"events": events.into_inner()})
            }
            "locked_start_display" => {
                let windows: Vec<Rect> = arg(&i["windows"]);
                let displays: Vec<Rect> = arg(&i["displays"]);
                serde_json::to_value(locked_start_display(&windows, &displays)).unwrap()
            }
            "stay_awake" => {
                let granted: bool = arg(&i["granted"]);
                let steps: Vec<String> = arg(&i["steps"]);
                let events = std::sync::Arc::new(std::sync::Mutex::new(Vec::new()));
                let (e1, e2) = (events.clone(), events.clone());
                let mut holds = 0u32;
                let mut awake = StayAwake::new(
                    move || {
                        holds += 1;
                        let id = if granted { Some(holds) } else { None };
                        e1.lock().unwrap().push(json!({"op": "hold", "id": id}));
                        id
                    },
                    move |id| e2.lock().unwrap().push(json!({"op": "release", "id": id})),
                );
                for s in &steps {
                    match s.as_str() {
                        "begin" => awake.begin(),
                        "end" => awake.end(),
                        other => panic!("{}: step {other}", c.name),
                    }
                }
                let got = events.lock().unwrap().clone();
                json!({"events": got})
            }
            other => panic!("{}: unknown fn {other}", c.name),
        };
        assert!(same(&got, &c.out), "{}: got {got}, Swift {}", c.name, c.out);
    }
}

#[test]
fn unlock_sequence_matches_swift() {
    let cases = raw_cases("unlock-sequence.json");
    assert!(!cases.is_empty());
    for c in cases {
        let i = &c.input;
        assert_eq!(func(i), "type_unlock_password", "{}", c.name);
        let password = password_units(&arg::<String>(&i["password"]));
        let after: Option<(String, usize)> =
            if i["unlock_after"].is_null() { None } else { Some((arg(&i["unlock_after"]["op"]), arg(&i["unlock_after"]["n"]))) };

        // One state shared by every closure: the events, A's lock state, the call counts.
        struct State {
            events: Vec<Value>,
            locked: bool,
            counts: HashMap<&'static str, usize>,
            after: Option<(String, usize)>,
        }
        impl State {
            fn did(&mut self, op: &'static str) {
                let n = self.counts.entry(op).or_insert(0);
                *n += 1;
                if let Some((a, k)) = &self.after {
                    if a == op && *n == *k {
                        self.locked = false;
                    }
                }
            }
        }
        let st = RefCell::new(State { events: Vec::new(), locked: arg(&i["locked"]), counts: HashMap::new(), after });
        type_unlock_password(
            &password,
            &mut || {
                let mut s = st.borrow_mut();
                let v = s.locked;
                s.events.push(json!({"op": "is_locked", "v": v}));
                v
            },
            &mut || {
                let mut s = st.borrow_mut();
                s.events.push(json!({"op": "wake"}));
                s.did("wake");
            },
            &mut |secs| {
                let mut s = st.borrow_mut();
                let us = (secs * 1_000_000.0).round() as u64;
                s.events.push(json!({"op": "wait", "us": us}));
                s.did("wait");
            },
            &mut |chunk| {
                let mut s = st.borrow_mut();
                s.events.push(json!({"op": "type", "units": chunk}));
                s.did("type");
            },
            &mut || st.borrow_mut().events.push(json!({"op": "return"})),
        );
        let got = json!({"events": st.into_inner().events});
        assert!(same(&got, &c.out), "{}: events differ from Swift", c.name);
    }
}

#[test]
fn defaults_are_swifts() {
    assert_eq!((LOCK_TIMEOUT, LOCK_STEP), (2.0, 0.1));
    assert_eq!((UNLOCK_SETTLE_TIMEOUT, UNLOCK_SETTLE_STEP), (8.0, 0.1));
    assert_eq!((WAKE_WAIT, CHUNK_WAIT, RETURN_WAIT), (1.0, 0.005, 0.05));
    assert_eq!(UNLOCK_LOCK_FILE, "unlock.lock");
    let mut never = || false;
    let mut ok = || None;
    let o = lock_screen(&mut never, &mut ok, &mut |_| {}, LOCK_TIMEOUT, LOCK_STEP);
    assert_eq!(o, LockOutcome::Failed("调用后 2 秒内没有锁上".into()));
}

#[test]
fn two_typists_do_not_overlap() {
    let dir = tempfile::tempdir().unwrap();
    let file = unlock_lock_file(dir.path());
    let start = Instant::now();
    let spans: Vec<(Duration, Duration)> = std::thread::scope(|s| {
        let a = s.spawn(|| {
            with_unlock_lock(&file, &mut |l| panic!("log {l}"), || {
                let t0 = start.elapsed();
                std::thread::sleep(Duration::from_millis(300));
                (t0, start.elapsed())
            })
        });
        std::thread::sleep(Duration::from_millis(50));
        let b = s.spawn(|| {
            with_unlock_lock(&file, &mut |l| panic!("log {l}"), || {
                let t0 = start.elapsed();
                std::thread::sleep(Duration::from_millis(50));
                (t0, start.elapsed())
            })
        });
        vec![a.join().unwrap(), b.join().unwrap()]
    });
    let (a, b) = (spans[0], spans[1]);
    assert!(a.1 <= b.0 || b.1 <= a.0, "bodies overlap: {a:?} {b:?}");
}

#[test]
fn lock_file_is_released_when_body_panics() {
    let dir = tempfile::tempdir().unwrap();
    let file = unlock_lock_file(dir.path());
    let r = std::panic::catch_unwind(|| with_unlock_lock(&file, &mut |_| {}, || panic!("boom")));
    assert!(r.is_err());
    // Another thread (its own handle) gets the lock at once.
    let (tx, rx) = mpsc::channel();
    let f2 = file.clone();
    std::thread::spawn(move || {
        let v = with_unlock_lock(&f2, &mut |l| panic!("log {l}"), || 7);
        tx.send(v).unwrap();
    });
    assert_eq!(rx.recv_timeout(Duration::from_millis(500)).unwrap(), 7);
}

#[test]
fn lock_file_and_directory_are_created() {
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("a").join("b").join("x.lock");
    assert_eq!(with_unlock_lock(&file, &mut |l| panic!("log {l}"), || 1), 1);
    assert!(file.is_file());
}

#[test]
fn unavailable_lock_logs_and_types_anyway() {
    let dir = tempfile::tempdir().unwrap();
    // The lock's directory is a regular file, so the lock file cannot be made.
    let blocker = dir.path().join("blocker");
    std::fs::write(&blocker, b"x").unwrap();
    let mut logs = Vec::new();
    let v = with_unlock_lock(&blocker.join("unlock.lock"), &mut |l| logs.push(l.to_string()), || 9);
    assert_eq!(v, 9);
    assert_eq!(logs, ["unlock lock unavailable"]);
}

#[test]
fn password_buffer_is_utf16() {
    let p = password_units("pässword🔑");
    assert_eq!(p.len(), 10);
    assert_eq!(&p[8..], &[0xD83D, 0xDD11]);
}
