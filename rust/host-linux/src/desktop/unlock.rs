use super::Desktop;
use anyhow::{ensure, Context, Result};
use std::{
    fs::{self, OpenOptions},
    os::{
        fd::AsRawFd,
        unix::fs::{MetadataExt, OpenOptionsExt},
    },
    path::PathBuf,
    time::Duration,
};

/// A compositor lock notification proves exclusive lock-screen input. A logind
/// hint alone does not. Also bind the known locker to this exact Wayland session.
fn trusted_locker() -> bool {
    let Ok(display) = std::env::var("WAYLAND_DISPLAY") else {
        return false;
    };
    let Ok(runtime) = std::env::var("XDG_RUNTIME_DIR") else {
        return false;
    };
    let Ok(processes) = fs::read_dir("/proc") else {
        return false;
    };
    processes.flatten().any(|process| {
        if !process
            .file_name()
            .to_string_lossy()
            .bytes()
            .all(|c| c.is_ascii_digit())
        {
            return false;
        }
        if !process
            .metadata()
            .is_ok_and(|m| m.uid() == unsafe { libc::getuid() })
        {
            return false;
        }
        let path = process.path();
        let Ok(exe) = fs::read_link(path.join("exe")) else {
            return false;
        };
        if ![
            PathBuf::from("/usr/bin/hyprlock"),
            PathBuf::from("/usr/bin/swaylock"),
        ]
        .contains(&exe)
        {
            return false;
        }
        let Ok(env) = fs::read(path.join("environ")) else {
            return false;
        };
        let value = |key: &[u8]| {
            env.split(|c| *c == 0)
                .find_map(|entry| entry.strip_prefix(key))
        };
        value(b"WAYLAND_DISPLAY=") == Some(display.as_bytes())
            && value(b"XDG_RUNTIME_DIR=") == Some(runtime.as_bytes())
    })
}
pub fn type_password(desktop: &mut Desktop, password: &str) -> Result<()> {
    ensure!(
        desktop.lock_state()? == Some(true),
        "no verified lock screen"
    );
    let runtime = std::env::var_os("XDG_RUNTIME_DIR").context("no session runtime directory")?;
    let lock = OpenOptions::new()
        .create(true)
        .truncate(false)
        .read(true)
        .write(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(PathBuf::from(runtime).join("rapp-unlock.lock"))?;
    ensure!(
        unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } == 0,
        "another session is entering a password"
    );
    // Check readiness after acquiring the cross-process input lock: another
    // worker may have submitted a password while we were verifying the session.
    if !trusted_locker() {
        super::omarchy_lock::verify()?;
    }
    enter_password(desktop, password)
}
trait LockInput {
    fn locked(&mut self) -> Result<bool>;
    fn key(&mut self, code: u16, flags: u64, down: bool) -> Result<()>;
    fn text(&mut self, text: &str) -> Result<()>;
    fn release(&mut self);
    fn pause(&self, duration: Duration) {
        std::thread::sleep(duration);
    }
}
impl LockInput for Desktop {
    fn locked(&mut self) -> Result<bool> {
        Ok(self.lock_state()? == Some(true))
    }
    fn key(&mut self, code: u16, flags: u64, down: bool) -> Result<()> {
        Desktop::key(self, code, flags, down)
    }
    fn text(&mut self, text: &str) -> Result<()> {
        Desktop::text(self, text)
    }
    fn release(&mut self) {
        Desktop::release(self);
    }
}
fn enter_password(desktop: &mut impl LockInput, password: &str) -> Result<()> {
    desktop.release();
    let result = (|| {
        if !desktop.locked()? {
            return Ok(());
        }
        desktop.key(32, 1 << 20, true)?;
        desktop.key(32, 0, false)?;
        // Round-trip between individual Unicode scalars, so a local unlock
        // cancels the remaining password before it reaches an application.
        for chunk in chunks(password, 1) {
            if !desktop.locked()? {
                return Ok(());
            }
            desktop.text(chunk)?;
            desktop.pause(Duration::from_millis(5));
        }
        desktop.pause(Duration::from_millis(50));
        if desktop.locked()? {
            desktop.key(36, 0, true)?;
            desktop.key(36, 0, false)?;
        }
        Ok(())
    })();
    desktop.release();
    result
}
fn chunks(text: &str, size: usize) -> Vec<&str> {
    let mut parts = vec![];
    let mut start = 0;
    let mut count = 0;
    for (i, _) in text.char_indices() {
        if count == size {
            parts.push(&text[start..i]);
            start = i;
            count = 0;
        }
        count += 1;
    }
    if start < text.len() {
        parts.push(&text[start..]);
    }
    parts
}
#[cfg(test)]
mod tests {
    use super::*;
    #[derive(Default)]
    struct Fake {
        lock: bool,
        unlock_after_text: bool,
        fail_text: bool,
        text: String,
        keys: Vec<u16>,
        releases: usize,
    }
    impl LockInput for Fake {
        fn locked(&mut self) -> Result<bool> {
            Ok(self.lock)
        }
        fn key(&mut self, code: u16, _: u64, down: bool) -> Result<()> {
            if down {
                self.keys.push(code);
            }
            Ok(())
        }
        fn text(&mut self, text: &str) -> Result<()> {
            ensure!(!self.fail_text, "synthetic input failure");
            self.text += text;
            if self.unlock_after_text {
                self.lock = false;
            }
            Ok(())
        }
        fn release(&mut self) {
            self.releases += 1;
        }
        fn pause(&self, _: Duration) {}
    }
    #[test]
    fn never_types_into_unlocked_desktop_and_cancels_at_lock_transition() {
        let mut d = Fake::default();
        enter_password(&mut d, "中secret").unwrap();
        assert!(d.text.is_empty() && d.keys.is_empty());
        let mut d = Fake {
            lock: true,
            unlock_after_text: true,
            ..Default::default()
        };
        enter_password(&mut d, "中secret").unwrap();
        assert_eq!(d.text, "中");
        assert_eq!(d.keys, [32]);
        assert_eq!(d.releases, 2);
        let mut d = Fake {
            lock: true,
            ..Default::default()
        };
        enter_password(&mut d, "中secret").unwrap();
        assert_eq!(d.text, "中secret");
        assert_eq!(d.keys, [32, 36]);
    }
    #[test]
    fn releases_keys_and_never_submits_after_input_error() {
        let mut d = Fake {
            lock: true,
            fail_text: true,
            ..Default::default()
        };
        assert!(enter_password(&mut d, "secret").is_err());
        assert!(d.text.is_empty());
        assert_eq!(d.keys, [32]);
        assert_eq!(d.releases, 2);
    }
    #[test]
    fn chunks_preserve_unicode_without_copying_passwords() {
        let text = "a中😀".repeat(40);
        let parts = chunks(&text, 32);
        assert!(parts.iter().all(|s| s.chars().count() <= 32));
        assert_eq!(parts.concat(), text);
    }
}
