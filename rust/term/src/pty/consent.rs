//! Whether macOS would stop the Terminal tab script to ask, on this Mac, if rApp may control Terminal or System
//! Events. Asked without a prompt first: when it would ask, the prompt is put up at once (by a thread that waits
//! for the answer) and the new terminal is refused straight away, instead of the script hanging on the prompt
//! until it is cut off — which may take the prompt with it, so the next 新建 hangs the same way.

use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

pub const TERMINAL: &str = "com.apple.Terminal";
pub const SYSTEM_EVENTS: &str = "com.apple.systemevents";
/// `errAEEventWouldRequireUserConsent`: macOS would ask.
pub const WOULD_ASK: i32 = -1744;
/// `procNotFound`: the target is not running, so macOS cannot say.
pub const NOT_RUNNING: i32 = -600;
/// `errAEEventNotPermitted`: the user said no; only 系统设置 › 隐私与安全性 › 自动化 turns it back on.
pub const DENIED: i32 = -1743;

/// What bringing a Terminal tab forward may do: the front script talks to Terminal alone, never System Events.
#[derive(Debug, PartialEq)]
pub enum Front {
    Go,
    /// macOS would ask: the prompt is put up, and the script is not run.
    Ask,
    /// The user refused rApp control of Terminal: the script would fail.
    Denied,
}

/// [`Front`] from macOS's answer for Terminal.
pub fn front_verdict(terminal: i32) -> Front {
    match terminal {
        WOULD_ASK => Front::Ask,
        DENIED => Front::Denied,
        _ => Front::Go,
    }
}

/// [`Front`] now, putting up the Terminal prompt when macOS would ask. Off macOS [`Front::Go`].
pub fn front() -> Front {
    #[cfg(target_os = "macos")]
    {
        mac::front()
    }
    #[cfg(not(target_os = "macos"))]
    {
        Front::Go
    }
}

/// The targets macOS would still ask about, in the order the tab script talks to them. `determine` answers for a
/// bundle id without a prompt; `start_events` starts System Events when it is not running and answers for it then.
/// When Terminal is not running the script talks to neither.
pub fn to_ask(determine: &mut dyn FnMut(&str) -> i32, start_events: &mut dyn FnMut() -> i32) -> Vec<&'static str> {
    let terminal = determine(TERMINAL);
    if terminal == NOT_RUNNING {
        return Vec::new();
    }
    let mut v = Vec::new();
    if terminal == WOULD_ASK {
        v.push(TERMINAL);
    }
    let mut events = determine(SYSTEM_EVENTS);
    if events == NOT_RUNNING {
        events = start_events();
    }
    if events == WOULD_ASK {
        v.push(SYSTEM_EVENTS);
    }
    v
}

/// True when macOS would ask before the tab script can run: the prompts are then up (or still up from an earlier
/// call), and the caller does not run the script. Off macOS never.
pub fn asking() -> bool {
    #[cfg(target_os = "macos")]
    {
        mac::asking()
    }
    #[cfg(not(target_os = "macos"))]
    {
        false
    }
}

/// How long macOS gets to answer before its prompt counts as up. No one answers a prompt this fast; macOS refuses
/// this fast when it will not ask at all (the hardened runtime without the Apple Events entitlement).
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
pub const SHOWN_AFTER: Duration = Duration::from_millis(800);

/// Runs `ask` (it puts the prompts up and waits for the answers) on a thread, unless one already is (`flag`).
/// True when a prompt is up: one already was, or `ask` is still waiting after `shown_after`. False when it came
/// back sooner, so no prompt was ever up and no one should be told to answer one.
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
pub fn put_up(flag: &'static AtomicBool, shown_after: Duration, ask: impl FnOnce() + Send + 'static) -> bool {
    if flag.swap(true, Ordering::SeqCst) {
        return true;
    }
    let (done, answered) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        ask();
        flag.store(false, Ordering::SeqCst);
        let _ = done.send(());
    });
    answered.recv_timeout(shown_after).is_err()
}

#[cfg(target_os = "macos")]
mod mac {
    use super::*;
    use std::ffi::c_void;
    use std::time::Instant;

    #[repr(C)]
    struct AEDesc {
        descriptor_type: u32,
        data_handle: *mut c_void,
    }

    #[link(name = "CoreServices", kind = "framework")]
    extern "C" {
        fn AECreateDesc(type_code: u32, data: *const c_void, size: isize, result: *mut AEDesc) -> i16;
        fn AEDisposeDesc(desc: *mut AEDesc) -> i16;
        fn AEDeterminePermissionToAutomateTarget(target: *const AEDesc, class: u32, id: u32, ask: u8) -> i32;
    }

    const TYPE_BUNDLE_ID: u32 = u32::from_be_bytes(*b"bund");
    const TYPE_WILD_CARD: u32 = u32::from_be_bytes(*b"****");

    /// macOS's answer for sending `bundle` any Apple Event; with `ask`, a prompt when it would ask, waiting for it.
    fn determine(bundle: &str, ask: bool) -> i32 {
        let mut desc = AEDesc { descriptor_type: 0, data_handle: std::ptr::null_mut() };
        // SAFETY: `bundle` outlives the call, which copies it into `desc`; `desc` is disposed of once made.
        unsafe {
            if AECreateDesc(TYPE_BUNDLE_ID, bundle.as_ptr().cast(), bundle.len() as isize, &mut desc) != 0 {
                return 0;
            }
            let r = AEDeterminePermissionToAutomateTarget(&desc, TYPE_WILD_CARD, TYPE_WILD_CARD, ask as u8);
            AEDisposeDesc(&mut desc);
            r
        }
    }

    /// Starts System Events in the background and answers for it once it runs, waiting at most 2 s.
    fn start_events() -> i32 {
        let started = std::process::Command::new("open")
            .args(["-g", "-j", "-b", SYSTEM_EVENTS])
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .status()
            .is_ok_and(|s| s.success());
        if !started {
            return NOT_RUNNING;
        }
        let end = Instant::now() + Duration::from_secs(2);
        loop {
            let r = determine(SYSTEM_EVENTS, false);
            if r != NOT_RUNNING || Instant::now() >= end {
                return r;
            }
            std::thread::sleep(Duration::from_millis(100));
        }
    }

    /// A thread is waiting on the prompts.
    static PROMPTING: AtomicBool = AtomicBool::new(false);

    pub fn asking() -> bool {
        if PROMPTING.load(Ordering::SeqCst) {
            return true;
        }
        let ask = to_ask(&mut |b| determine(b, false), &mut start_events);
        // No prompt came up: the script runs, fails at once, and a window opens instead.
        !ask.is_empty() && prompt(ask)
    }

    pub fn front() -> Front {
        if PROMPTING.load(Ordering::SeqCst) {
            return Front::Ask;
        }
        match front_verdict(determine(TERMINAL, false)) {
            // macOS refused without asking: as good as no.
            Front::Ask if !prompt(vec![TERMINAL]) => Front::Denied,
            v => v,
        }
    }

    /// Puts the prompts for `ask` up, one after another, on a thread that waits for the answers (none while one is).
    /// True when one is up ([`put_up`]).
    fn prompt(ask: Vec<&'static str>) -> bool {
        put_up(&PROMPTING, SHOWN_AFTER, move || {
            for b in ask {
                determine(b, true);
            }
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    use std::sync::atomic::AtomicBool;

    #[test]
    fn a_prompt_answered_at_once_was_never_up() {
        // Under the hardened runtime without the Apple Events entitlement macOS refuses at once and shows nothing.
        static FLAG: AtomicBool = AtomicBool::new(false);
        assert!(!put_up(&FLAG, Duration::from_millis(500), || {}));
        assert!(!FLAG.load(Ordering::SeqCst), "nothing left waiting");
    }

    #[test]
    fn a_prompt_still_waiting_is_up() {
        static FLAG: AtomicBool = AtomicBool::new(false);
        let (tx, rx) = std::sync::mpsc::channel::<()>();
        assert!(put_up(&FLAG, Duration::from_millis(50), move || {
            let _ = rx.recv();
        }));
        // While it waits, no second prompt is put up, and it still counts as up.
        assert!(put_up(&FLAG, Duration::from_millis(50), || panic!("asked twice")));
        drop(tx);
        let end = std::time::Instant::now() + Duration::from_secs(2);
        while FLAG.load(Ordering::SeqCst) && std::time::Instant::now() < end {
            std::thread::sleep(Duration::from_millis(10));
        }
        assert!(!FLAG.load(Ordering::SeqCst), "answered: the flag is down again");
    }

    fn run(terminal: i32, events: i32, after_start: Option<i32>) -> (Vec<&'static str>, bool) {
        let mut started = false;
        let v = to_ask(
            &mut |b| if b == TERMINAL { terminal } else { events },
            &mut || {
                started = true;
                after_start.expect("not started")
            },
        );
        (v, started)
    }

    #[test]
    fn terminal_not_running_asks_nothing() {
        assert_eq!(run(NOT_RUNNING, WOULD_ASK, None), (vec![], false));
    }

    #[test]
    fn both_allowed_asks_nothing() {
        assert_eq!(run(0, 0, None), (vec![], false));
    }

    #[test]
    fn asks_in_the_order_the_script_talks() {
        assert_eq!(run(WOULD_ASK, WOULD_ASK, None), (vec![TERMINAL, SYSTEM_EVENTS], false));
        assert_eq!(run(WOULD_ASK, 0, None), (vec![TERMINAL], false));
        assert_eq!(run(0, WOULD_ASK, None), (vec![SYSTEM_EVENTS], false));
    }

    #[test]
    fn denied_is_left_to_the_script() {
        // Denied fails the script at once, and a window opens instead: no reason to stop.
        assert_eq!(run(DENIED, DENIED, None), (vec![], false));
    }

    #[test]
    fn front_asks_about_terminal_alone() {
        assert_eq!(front_verdict(0), Front::Go);
        // Not running: the front script answers "none" without talking to it.
        assert_eq!(front_verdict(NOT_RUNNING), Front::Go);
        assert_eq!(front_verdict(WOULD_ASK), Front::Ask);
        assert_eq!(front_verdict(DENIED), Front::Denied);
    }

    #[test]
    fn system_events_is_started_to_be_asked_about() {
        assert_eq!(run(0, NOT_RUNNING, Some(WOULD_ASK)), (vec![SYSTEM_EVENTS], true));
        assert_eq!(run(0, NOT_RUNNING, Some(0)), (vec![], true));
        // Still not running: the script starts it, as before.
        assert_eq!(run(0, NOT_RUNNING, Some(NOT_RUNNING)), (vec![], true));
    }
}
