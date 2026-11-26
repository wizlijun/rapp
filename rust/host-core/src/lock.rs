//! Locking A's screen and typing the unlock password (`Sources/RappCore/ScreenLock.swift`,
//! `UnlockSequence.swift`, `StayAwake.swift`, the `FileLock.exclusive` behaviour of
//! `FileLock.swift`, and the fallback of `Sources/rapp-host/Server.swift:895-900`).
//!
//! Every platform call is injected, so the rules run without a screen. The password is only
//! ever handed around as `&[u16]` slices of the caller's `Zeroizing` buffer: nothing here
//! copies it, logs it or prints it.

use std::fs::{self, File, OpenOptions};
use std::path::{Path, PathBuf};

use zeroize::Zeroizing;

use crate::geometry::{chunk_ranges, Point, Rect};

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LockOutcome {
    Locked,
    Already,
    Failed(String),
}

/// `lockScreen`'s defaults: give up 2 s after the call, polling every 0.1 s.
pub const LOCK_TIMEOUT: f64 = 2.0;
pub const LOCK_STEP: f64 = 0.1;
/// `waitUntilUnlocked`'s defaults: wait at most 8 s for the typed password to settle.
pub const UNLOCK_SETTLE_TIMEOUT: f64 = 8.0;
pub const UNLOCK_SETTLE_STEP: f64 = 0.1;

/// The waits of `typeUnlockPassword`, in seconds (Swift passes microseconds:
/// 1 000 000, 5 000 and 50 000).
pub const WAKE_WAIT: f64 = 1.0;
pub const CHUNK_WAIT: f64 = 0.005;
pub const RETURN_WAIT: f64 = 0.05;
/// Units per typed chunk (`chunkUTF16`'s default).
pub const UNLOCK_CHUNK_UNITS: usize = 20;

/// The cross-worker lock file in the data root (`DataPaths.unlockLockFile`).
pub const UNLOCK_LOCK_FILE: &str = "unlock.lock";
/// Logged when the lock file cannot be used; the password is typed anyway.
pub const UNLOCK_LOCK_UNAVAILABLE: &str = "unlock lock unavailable";

pub fn unlock_lock_file(data_root: &Path) -> PathBuf {
    data_root.join(UNLOCK_LOCK_FILE)
}

/// Locks the screen through `call` and waits for `is_locked` to turn true. `call` returns
/// `None` on success, or the reason it could not call. Callers pass 2.0 and 0.1.
pub fn lock_screen(
    is_locked: &mut dyn FnMut() -> bool,
    call: &mut dyn FnMut() -> Option<String>,
    sleep: &mut dyn FnMut(f64),
    timeout: f64,
    step: f64,
) -> LockOutcome {
    if is_locked() {
        return LockOutcome::Already;
    }
    if let Some(reason) = call() {
        return LockOutcome::Failed(reason);
    }
    let mut waited = 0.0f64;
    while waited < timeout {
        sleep(step);
        waited += step;
        if is_locked() {
            return LockOutcome::Locked;
        }
    }
    LockOutcome::Failed(format!("调用后 {} 秒内没有锁上", swift_int(timeout)))
}

/// Swift's `Int(Double)`: truncates toward zero. Swift traps on NaN and out-of-range
/// values; this port saturates (Rust's `as`), the callers only pass 2.0.
fn swift_int(v: f64) -> i64 {
    v as i64
}

/// After typing the unlock password: waits until `is_locked` turns false (at most
/// `timeout`), so the next typist starts only once the result is settled. Returns at once
/// when A is not locked. Callers pass 8.0 and 0.1.
pub fn wait_until_unlocked(is_locked: &mut dyn FnMut() -> bool, sleep: &mut dyn FnMut(f64), timeout: f64, step: f64) {
    let mut waited = 0.0f64;
    // Swift's `while waited < timeout, isLocked()`: the time check comes first, so a
    // spent timeout does not call `isLocked` again.
    while waited < timeout && is_locked() {
        sleep(step);
        waited += step;
    }
}

/// The display an app session opened on a locked A announces before the app can be
/// captured (spec §6.4): the one holding the centre of the app's largest window (at least
/// 50 x 50). `None` when no window qualifies or no display holds its centre: the caller
/// falls back to the main display.
#[allow(clippy::neg_cmp_op_on_partial_ord)] // `!(a < b)` keeps Swift's NaN behaviour
pub fn locked_start_display(windows: &[Rect], displays: &[Rect]) -> Option<Rect> {
    // Swift's `max(by:)` keeps the first of equal maxima: it replaces only on "less than".
    let mut best: Option<&Rect> = None;
    for w in windows.iter().filter(|w| w.w() >= 50.0 && w.h() >= 50.0) {
        match best {
            Some(b) if !(b.w() * b.h() < w.w() * w.h()) => {}
            _ => best = Some(w),
        }
    }
    let best = best?;
    let centre = Point::new(best.mid_x(), best.mid_y());
    displays.iter().find(|d| d.contains_point(centre)).copied()
}

/// The password as UTF-16 units in a buffer that is wiped when dropped.
pub fn password_units(password: &str) -> Zeroizing<Vec<u16>> {
    Zeroizing::new(password.encode_utf16().collect())
}

/// The lock-screen input sequence. Re-checks `is_locked` immediately before each input
/// step: the user may unlock locally while we wait for the password field, or while a long
/// password is being typed. `wait` takes seconds.
pub fn type_unlock_password(
    password: &[u16],
    is_locked: &mut dyn FnMut() -> bool,
    wake: &mut dyn FnMut(),
    wait: &mut dyn FnMut(f64),
    type_chunk: &mut dyn FnMut(&[u16]),
    press_return: &mut dyn FnMut(),
) {
    if !is_locked() {
        return;
    }
    wake();
    wait(WAKE_WAIT);
    for range in chunk_ranges(password, UNLOCK_CHUNK_UNITS) {
        if !is_locked() {
            return;
        }
        type_chunk(&password[range]);
        wait(CHUNK_WAIT);
    }
    wait(RETURN_WAIT);
    if !is_locked() {
        return;
    }
    press_return();
}

/// One typist at a time across workers: holds an exclusive lock on `file` (created, with
/// its directory, when missing) while `body` runs; blocks until the lock is free. When the
/// lock cannot be taken, logs `unlock lock unavailable` through `log` and runs `body`
/// anyway (`Server.swift:895-900`). The lock is dropped when `body` returns or unwinds.
pub fn with_unlock_lock<T>(file: &Path, log: &mut dyn FnMut(&str), body: impl FnOnce() -> T) -> T {
    match take_lock(file) {
        Ok(held) => {
            let _guard = Held(held);
            body()
        }
        Err(_) => {
            log(UNLOCK_LOCK_UNAVAILABLE);
            body()
        }
    }
}

fn take_lock(file: &Path) -> std::io::Result<File> {
    if let Some(dir) = file.parent() {
        if !dir.as_os_str().is_empty() {
            fs::create_dir_all(dir)?;
        }
    }
    // Swift opens with O_CREAT | O_RDWR, mode 0600. Setting the mode needs a platform
    // extension trait, which host-core does not use; the platform crate may tighten it.
    let f = OpenOptions::new().read(true).write(true).create(true).truncate(false).open(file)?;
    // `File::lock` retries an interrupted wait itself, as Swift's EINTR loop does.
    f.lock()?;
    Ok(f)
}

/// Unlocks, then closes (closing alone also drops the lock).
struct Held(File);

impl Drop for Held {
    fn drop(&mut self) {
        let _ = self.0.unlock();
    }
}

/// Keeps A awake while one session is open: one hold per session, released exactly once.
/// `hold` returns an id to release later, or `None` if the system refused.
pub struct StayAwake {
    hold: Box<dyn FnMut() -> Option<u32> + Send>,
    release: Box<dyn FnMut(u32) + Send>,
    held: Option<u32>,
    begun: bool,
}

impl StayAwake {
    pub fn new(hold: impl FnMut() -> Option<u32> + Send + 'static, release: impl FnMut(u32) + Send + 'static) -> Self {
        StayAwake { hold: Box::new(hold), release: Box::new(release), held: None, begun: false }
    }

    pub fn begin(&mut self) {
        if self.begun {
            return;
        }
        self.begun = true;
        self.held = (self.hold)();
    }

    pub fn end(&mut self) {
        if !self.begun {
            return;
        }
        self.begun = false;
        if let Some(id) = self.held {
            (self.release)(id);
        }
        self.held = None;
    }

    pub fn is_begun(&self) -> bool {
        self.begun
    }
}
