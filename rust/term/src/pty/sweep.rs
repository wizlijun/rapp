//! Closing the Terminal tabs whose holder has ended: the holder leaves `ended/<tty basename>` when it exits, and
//! this reads those markers, deletes them, and hands the fresh ones' ttys to `close`.

use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, SystemTime};

/// A marker younger than this is left for a later sweep: its holder may still be exiting.
const SETTLE: Duration = Duration::from_secs(1);

/// A marker older than this is deleted without closing anything: its tab was probably closed or reused long ago.
const FRESH: Duration = Duration::from_secs(10 * 60);

/// Read `dir/ended/*`, delete every marker, and pass the ttys (basenames, like `ttys012`) of those written at most
/// ten minutes ago to `close`, once, unless there are none. The marker file's mtime is its age.
pub fn sweep(dir: &Path, close: impl Fn(&[String])) {
    let Ok(entries) = std::fs::read_dir(dir.join("ended")) else {
        return;
    };
    let now = SystemTime::now();
    let mut fresh = Vec::new();
    for e in entries.flatten() {
        let age = e.metadata().and_then(|m| m.modified()).ok().and_then(|t| now.duration_since(t).ok());
        if age.is_some_and(|a| a < SETTLE) {
            continue;
        }
        let _ = std::fs::remove_file(e.path());
        let name = e.file_name().to_string_lossy().into_owned();
        let tty_like = name.starts_with("tty") && name.bytes().all(|b| b.is_ascii_alphanumeric());
        if tty_like && age.is_none_or(|a| a <= FRESH) {
            fresh.push(name);
        }
    }
    if !fresh.is_empty() {
        close(&fresh);
    }
}

/// [`sweep`], unless one that shares `running` is under way: then nothing (that one closes the tabs, and a later one
/// gets the markers it left), so overlapping sweeps never run two osascripts at once.
pub fn sweep_once(dir: &Path, running: &AtomicBool, close: impl Fn(&[String])) {
    if running.swap(true, Ordering::AcqRel) {
        return;
    }
    struct Done<'a>(&'a AtomicBool);
    impl Drop for Done<'_> {
        fn drop(&mut self) {
            self.0.store(false, Ordering::Release);
        }
    }
    let _done = Done(running);
    sweep(dir, close);
}

/// Closes the Terminal tabs on these ttys that have nothing running in them any more. Blocks up to 5 s.
const CLOSE_TABS: &str = r#"on run argv
	if not (application "Terminal" is running) then return
	tell application "Terminal"
		repeat with w in windows
			try
				if (count of tabs of w) is 1 then
					set t to tab 1 of w
					if (argv contains (tty of t)) and (busy of t is false) and ((count of processes of t) is 0) then close w
				end if
			end try
		end repeat
	end tell
end run
"#;

/// The real `close` of `sweep`: one osascript run. macOS only.
pub fn close_tabs(ttys: &[String]) {
    if !cfg!(target_os = "macos") {
        return;
    }
    let mut c = std::process::Command::new("osascript");
    c.arg("-e").arg(CLOSE_TABS);
    for t in ttys {
        c.arg(format!("/dev/{t}"));
    }
    match super::launch::bounded_command(&mut c, Duration::from_secs(5)) {
        Ok(_) => {}
        Err(super::launch::CommandFailure::TimedOut) => eprintln!("rapp-term: closing the ended terminal tabs timed out"),
        Err(super::launch::CommandFailure::Failed) => eprintln!("rapp-term: closing the ended terminal tabs failed"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;

    #[test]
    fn sweep_only_targets_marked_ttys() {
        let d = tempfile::tempdir().unwrap();
        let ended = d.path().join("ended");
        std::fs::create_dir(&ended).unwrap();
        let aged = |name: &str, secs: u64| {
            let f = std::fs::File::create(ended.join(name)).unwrap();
            f.set_modified(SystemTime::now() - Duration::from_secs(secs)).unwrap();
        };
        aged("ttys001", 5);
        let old = std::fs::File::create(ended.join("ttys002")).unwrap();
        old.set_modified(SystemTime::now() - Duration::from_secs(11 * 60)).unwrap();
        let got = RefCell::new(Vec::new());
        sweep(d.path(), |t| got.borrow_mut().push(t.to_vec()));
        assert_eq!(*got.borrow(), [vec!["ttys001".to_string()]]);
        assert_eq!(std::fs::read_dir(&ended).unwrap().count(), 0);
    }

    #[test]
    fn a_marker_younger_than_a_second_waits_for_a_later_sweep() {
        let d = tempfile::tempdir().unwrap();
        let ended = d.path().join("ended");
        std::fs::create_dir(&ended).unwrap();
        std::fs::write(ended.join("ttys003"), "1").unwrap();
        let called = RefCell::new(false);
        sweep(d.path(), |_| *called.borrow_mut() = true);
        assert!(!*called.borrow());
        assert!(ended.join("ttys003").exists());
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn the_close_script_compiles() {
        let out = std::env::temp_dir().join(format!("rapp-close-{}.scpt", std::process::id()));
        let status = std::process::Command::new("osacompile").arg("-o").arg(&out).arg("-e").arg(CLOSE_TABS)
            .stdout(std::process::Stdio::null()).stderr(std::process::Stdio::inherit()).status().unwrap();
        let _ = std::fs::remove_file(&out);
        assert!(status.success());
    }

    #[test]
    fn a_sweep_while_another_runs_does_nothing() {
        let d = tempfile::tempdir().unwrap();
        let ended = d.path().join("ended");
        std::fs::create_dir(&ended).unwrap();
        let f = std::fs::File::create(ended.join("ttys004")).unwrap();
        f.set_modified(SystemTime::now() - Duration::from_secs(5)).unwrap();
        let running = AtomicBool::new(false);
        let calls = RefCell::new(0);
        sweep_once(d.path(), &running, |_| {
            // A second sweep starting meanwhile leaves it to this one.
            sweep_once(d.path(), &running, |_| *calls.borrow_mut() += 10);
            *calls.borrow_mut() += 1;
        });
        assert_eq!(*calls.borrow(), 1);
        assert!(!running.load(Ordering::Acquire));
        // Done: the next one runs.
        let f = std::fs::File::create(ended.join("ttys005")).unwrap();
        f.set_modified(SystemTime::now() - Duration::from_secs(5)).unwrap();
        sweep_once(d.path(), &running, |_| *calls.borrow_mut() += 1);
        assert_eq!(*calls.borrow(), 2);
    }

    #[test]
    fn nothing_fresh_means_no_close_call() {
        let d = tempfile::tempdir().unwrap();
        let called = RefCell::new(false);
        sweep(d.path(), |_| *called.borrow_mut() = true);
        assert!(!*called.borrow());
    }
}
