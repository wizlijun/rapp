//! Locks A 10 s after the last remote app or desktop closes (spec 2026-11-15 §6).

use crate::state::State;
use rapp_net::log::Lvl;
use serde_json::json;
use std::sync::Arc;
use std::time::Duration;
use tokio::time::Instant;

pub const GRACE: Duration = Duration::from_secs(10);

/// A session that keeps A unlocked: a viewing session, not a file-transfer side connection or a terminal.
pub fn counted(app: &str, side: bool) -> bool {
    !side && !app.starts_with("term:")
}

/// Auto-lock is on and 不锁屏 is off.
fn armed(state: &State) -> bool {
    let cfg = state.cfg.lock().unwrap();
    cfg.auto_lock() && !cfg.no_lock()
}

pub fn spawn(state: Arc<State>, grace: Duration) -> tokio::task::JoinHandle<()> {
    tokio::spawn(async move {
        let mut rx = state.changed.subscribe();
        let mut prev = state.counted_sessions();
        let mut deadline: Option<Instant> = None;
        loop {
            tokio::select! {
                r = rx.changed() => {
                    if r.is_err() {
                        return;
                    }
                    let n = state.counted_sessions();
                    let on = armed(&state);
                    if n > 0 || !on {
                        deadline = None;
                    } else if prev > 0 {
                        deadline = Some(Instant::now() + grace);
                    }
                    prev = n;
                }
                _ = tokio::time::sleep_until(deadline.unwrap_or_else(Instant::now)), if deadline.is_some() => {
                    deadline = None;
                    if state.counted_sessions() == 0 && armed(&state) {
                        match crate::workers::lock(&state).await {
                            Ok(true) => state.log.event(Lvl::Info, "auto_lock", json!({})),
                            Ok(false) => state.log.msg(Lvl::Info, "auto-lock: already locked"),
                            Err(e) => state.log.event(Lvl::Warn, "auto_lock_failed", json!({"error": format!("{e:#}")})),
                        }
                    }
                }
            }
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn counted_is_every_viewing_session_but_terminals_and_side_connections() {
        for app in ["com.apple.TextEdit", "desktop:", "desktop:2"] {
            assert!(counted(app, false), "{app}");
        }
        assert!(!counted("term:abc", false));
        assert!(!counted("com.apple.TextEdit", true));
    }
}
