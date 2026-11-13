//! Unread rule: a session is unread when it had output and then `QUIET_SECS` of quiet since it was last seen.

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
    pub fn seen(&mut self, session: &str, now: u64) {
        self.seen.insert(session.to_string(), now);
    }

    /// True when output at `activity` came after the last look and the session has been quiet for `QUIET_SECS`.
    pub fn is_unread(&self, session: &str, activity: u64, now: u64) -> bool {
        let last_seen = self.seen.get(session).copied().unwrap_or(0);
        activity > self.started.max(last_seen) && now.saturating_sub(activity) >= QUIET_SECS
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
}
