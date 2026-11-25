//! Unread rule: a session is unread when it had output and then `QUIET_SECS` of quiet since it was last seen.

use crate::pty::ps::Ps;
use std::collections::HashMap;

/// Quiet time, in seconds, that turns output into unread.
const QUIET_SECS: u64 = 3;

#[derive(Default)]
pub struct Unread {
    /// Output at or before this time (service start) does not count.
    started: u64,
    /// Last time each session was seen, by session id.
    seen: HashMap<String, u64>,
}

impl Unread {
    pub fn new(started: u64) -> Unread {
        Unread { started, seen: HashMap::new() }
    }

    /// Record that the session was looked at now.
    pub fn seen(&mut self, session_id: &str, now: u64) {
        self.seen.insert(session_id.to_string(), now);
    }

    /// True when output at `activity` came after the last look and the session has been quiet for `QUIET_SECS`.
    pub fn is_unread(&self, session_id: &str, activity: u64, now: u64) -> bool {
        let last_seen = self.seen.get(session_id).copied().unwrap_or(0);
        activity > self.started.max(last_seen) && now.saturating_sub(activity) >= QUIET_SECS
    }

    /// The rule when the program reports its own status: `blocked` is always unread, a stop (`done`, `error`,
    /// `idle`) is unread when it came after the last look, at once; `working`, and any state not known, never is.
    pub fn is_unread_ps(&self, session_id: &str, ps: &Ps, _now: u64) -> bool {
        match ps.state.as_str() {
            "blocked" => true,
            "done" | "error" | "idle" => {
                ps.stopped > self.started.max(self.seen.get(session_id).copied().unwrap_or(0))
            }
            _ => false,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unread_is_output_then_three_quiet_seconds_since_last_seen() {
        let mut u = Unread::new(1000);
        assert!(!u.is_unread("w", 990, 1100)); // 服务启动之前的输出不算
        assert!(!u.is_unread("w", 1050, 1052)); // 还在动
        assert!(u.is_unread("w", 1050, 1053)); // 安静满 3 秒
        u.seen("w", 1060);
        assert!(!u.is_unread("w", 1050, 1100)); // 看过了
        assert!(u.is_unread("w", 1070, 1073)); // 之后又有输出并停下
        assert!(u.is_unread("other", 1050, 1100)); // 各会话各算各的
    }

    fn ps(state: &str, stopped: u64) -> Ps {
        Ps { state: state.into(), kind: None, app: None, msg: None, progress: None, since: 0, stopped, seq: 1 }
    }

    #[test]
    fn with_ps_working_is_never_unread() {
        assert!(!Unread::new(1000).is_unread_ps("w", &ps("working", 1050), 9999));
        assert!(!Unread::new(1000).is_unread_ps("w", &ps("from-the-future", 1050), 9999));
    }

    #[test]
    fn with_ps_blocked_is_unread_even_when_seen() {
        let mut u = Unread::new(1000);
        u.seen("w", 2000);
        assert!(u.is_unread_ps("w", &ps("blocked", 0), 2001));
    }

    #[test]
    fn with_ps_a_stop_after_the_last_look_is_unread_at_once() {
        let mut u = Unread::new(1000);
        for s in ["done", "error", "idle"] {
            assert!(u.is_unread_ps("w", &ps(s, 1050), 1050), "{s}"); // 不等 3 秒
            assert!(!u.is_unread_ps("w", &ps(s, 990), 1050), "{s}"); // 服务启动之前停的不算
            assert!(!u.is_unread_ps("w", &ps(s, 0), 1050), "{s}"); // 没停过
        }
        u.seen("w", 1060);
        assert!(!u.is_unread_ps("w", &ps("done", 1050), 1100));
        assert!(u.is_unread_ps("w", &ps("done", 1070), 1070));
    }
}
