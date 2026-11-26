//! `unlock` (35): typing B's password at A's lock screen (`Server.swift:873-912`).
//!
//! The password travels from the message to the typing thread as a `Password` (wiped on
//! drop), becomes UTF-16 units in a `Zeroizing` buffer there, and is handed to the platform
//! only as slices of that buffer. Nothing here logs, prints or stores it.

use std::sync::atomic::Ordering;

use crate::cli::WorkerEvent;
use crate::lock::{
    password_units, type_unlock_password, unlock_lock_file, wait_until_unlocked, with_unlock_lock,
    UNLOCK_SETTLE_STEP, UNLOCK_SETTLE_TIMEOUT,
};
use crate::protocol::{Message, Password};

use super::hold;
use super::session::Session;

impl Session {
    /// Types B's password at the lock screen; dropped (and B told A's state again) when A is
    /// not locked.
    pub(crate) fn unlock(&mut self, password: Password) {
        // Swift: `injector != nil || announced != nil && capture == nil`.
        if !(self.input_on || self.announced.is_some() && self.capture.is_none()) {
            return;
        }
        if !hold(&self.lock).locked() {
            self.inner.out.log("unlock dropped: A is not locked");
            self.sent_locked = Some(false);
            self.send(Message::ScreenLocked(false));
            return;
        }
        if self.unlocking {
            self.inner.out.log("unlock dropped: already typing");
            return;
        }
        // A platform that cannot type at its lock screen (spec §6.4): B hears A is still locked.
        if !hold(&self.lock).can_unlock() {
            self.inner.out.log("unlock not available");
            self.sent_locked = Some(true);
            self.send(Message::ScreenLocked(true));
            return;
        }
        self.unlocking = true;
        self.inner.out.log("typing the unlock password");
        self.inner.out.emit(&WorkerEvent::Unlock);
        let lock = self.lock.clone();
        let alive = self.alive.clone();
        let clock = self.inner.clock.clone();
        let out = self.inner.out.clone();
        let tx = self.tx.clone();
        // One typist at a time across sessions and workers: a second holder finds A already
        // unlocked and types nothing.
        let file = unlock_lock_file(&self.inner.platform.data_root());
        let spawned = std::thread::Builder::new().name("rapp-host unlock".into()).spawn(move || {
            let units = password_units(password.as_str());
            drop(password);
            // Once the session is gone nothing more is typed: B is no longer there to want it.
            let is_locked = || alive.load(Ordering::SeqCst) && hold(&lock).locked();
            let mut log = |text: &str| out.log(text);
            // Held until A has finished checking, so the next typist sees the settled state.
            with_unlock_lock(&file, &mut log, || {
                let mut locked = is_locked;
                type_unlock_password(
                    &units,
                    &mut locked,
                    &mut || hold(&lock).wake(),
                    &mut |seconds: f64| clock.sleep(seconds),
                    &mut |chunk: &[u16]| hold(&lock).type_units(chunk),
                    &mut || hold(&lock).press_return(),
                );
                wait_until_unlocked(
                    &mut locked,
                    &mut |seconds: f64| clock.sleep(seconds),
                    UNLOCK_SETTLE_TIMEOUT,
                    UNLOCK_SETTLE_STEP,
                );
            });
            drop(units);
            Session::post(
                &tx,
                Box::new(|s: &mut Session| {
                    s.unlocking = false;
                    s.send_locked();
                }),
            );
        });
        if spawned.is_err() {
            // No thread, nothing typed: the next unlock may try again.
            self.unlocking = false;
            self.inner.out.log("unlock failed: cannot start the typing thread");
        }
    }
}
