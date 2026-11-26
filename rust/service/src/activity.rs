//! What the auto-update waits out (cli-update spec §5.1): the last time anyone used this device
//! from far away (input, a session starting, bytes over a pipe, forward or map), and how many
//! remote windows the GUI has open, counted per IPC connection.

use std::collections::HashMap;
use std::sync::Mutex;
use std::time::{Duration, Instant};

#[derive(Default)]
pub struct Activity {
    last: Mutex<Option<Instant>>,
    gui_windows: Mutex<HashMap<u64, usize>>,
}

impl Activity {
    pub fn touch(&self) {
        *self.last.lock().unwrap() = Some(Instant::now());
    }

    /// Nothing happened for `d` (or ever).
    pub fn quiet_for(&self, d: Duration) -> bool {
        self.last.lock().unwrap().is_none_or(|t| t.elapsed() >= d)
    }

    pub fn set_windows(&self, conn: u64, n: usize) {
        let mut w = self.gui_windows.lock().unwrap();
        if n == 0 {
            w.remove(&conn);
        } else {
            w.insert(conn, n);
        }
    }

    pub fn drop_conn(&self, conn: u64) {
        self.gui_windows.lock().unwrap().remove(&conn);
    }

    /// The remote windows open in every GUI connected now.
    pub fn windows(&self) -> usize {
        self.gui_windows.lock().unwrap().values().sum()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn never_touched_is_quiet() {
        assert!(Activity::default().quiet_for(Duration::from_millis(1)));
    }

    #[test]
    fn touch_then_not_quiet() {
        let a = Activity::default();
        a.touch();
        assert!(!a.quiet_for(Duration::from_secs(10)));
        assert!(a.quiet_for(Duration::ZERO));
    }

    #[test]
    fn windows_sum_and_drop() {
        let a = Activity::default();
        a.set_windows(1, 2);
        a.set_windows(2, 3);
        assert_eq!(a.windows(), 5);
        a.drop_conn(2);
        assert_eq!(a.windows(), 2);
        a.set_windows(1, 0);
        assert_eq!(a.windows(), 0);
    }
}
