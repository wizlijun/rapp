//! The session table: one row per tmux session, for `list` and the watch stream.

use crate::id::TermId;
use crate::tmux::{cmd, parse, PaneInfo, Tmux};
use crate::unread::Unread;
use serde::Serialize;
use std::collections::{BTreeMap, HashSet};
use std::sync::Mutex;
use std::time::Duration;

/// The first wait after a failure, and the longest one.
const BACKOFF_FIRST: Duration = Duration::from_secs(1);
const BACKOFF_MAX: Duration = Duration::from_secs(15);

/// One session as `list` shows it.
#[derive(Serialize, Clone, Debug, PartialEq)]
pub struct TermRow {
    pub id: String,
    pub host: Option<String>,
    pub name: String,
    pub command: String,
    pub panes: usize,
    pub attached: u32,
    pub activity: u64,
    pub dead: bool,
    pub unread: bool,
}

/// The sessions in `list`, oldest first: `command` is the first pane's of the session's current window (a window
/// in `current`; the first window when none is), `activity` the latest of its windows, `dead` when every pane
/// has exited, `unread` by the rule of `Unread` at time `now`.
pub fn rows(
    list: &[PaneInfo],
    current: &HashSet<String>,
    host: Option<&str>,
    unread: &Unread,
    now: u64,
) -> Vec<TermRow> {
    let mut by: BTreeMap<(u64, &str), Vec<&PaneInfo>> = BTreeMap::new();
    for p in list {
        let n = p.session_id.trim_start_matches('$').parse().unwrap_or(u64::MAX);
        by.entry((n, p.session_id.as_str())).or_default().push(p);
    }
    by.into_values()
        .map(|ps| {
            let place = |p: &&&PaneInfo| (!current.contains(&p.window_id), p.window_index, p.pane_index);
            let first = ps.iter().min_by_key(place).expect("a session has a pane");
            let activity = ps.iter().map(|p| p.activity).max().unwrap_or(0);
            let id = TermId { backend: "tmux".into(), host: host.map(str::to_string), name: first.session.clone() };
            TermRow {
                id: id.to_string(),
                host: host.map(str::to_string),
                name: first.session.clone(),
                command: first.command.clone(),
                panes: ps.len(),
                attached: first.attached,
                activity,
                dead: ps.iter().all(|p| p.dead),
                unread: unread.is_unread(&first.session_id, activity, now),
            }
        })
        .collect()
}

/// The rows of the machine `tmux` runs on. A server that went away between the two calls leaves no current
/// window: the first window stands in.
pub async fn host_rows(
    tmux: &Tmux,
    host: Option<&str>,
    unread: &Mutex<Unread>,
    now: u64,
) -> anyhow::Result<Vec<TermRow>> {
    let panes = tmux.list().await?;
    let current = match panes.is_empty() {
        true => HashSet::new(),
        false => tmux.run(&cmd::window_flags()).await.map(|s| parse::current_windows(&s)).unwrap_or_default(),
    };
    let u = unread.lock().unwrap_or_else(|e| e.into_inner());
    Ok(rows(&panes, &current, host, &u, now))
}

/// The wait before the next try at a host that cannot be reached: 1 second, doubling, 15 at most.
pub struct Backoff {
    next: Duration,
}

impl Backoff {
    pub fn new() -> Backoff {
        Backoff { next: BACKOFF_FIRST }
    }

    /// A try failed: how long to wait before the next one.
    pub fn failed(&mut self) -> Duration {
        let d = self.next;
        self.next = (d * 2).min(BACKOFF_MAX);
        d
    }

    /// A try worked.
    pub fn reset(&mut self) {
        self.next = BACKOFF_FIRST;
    }
}

impl Default for Backoff {
    fn default() -> Backoff {
        Backoff::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pane(sid: &str, wid: &str, wi: u32, pi: u32, cmd: &str, activity: u64, dead: bool) -> PaneInfo {
        PaneInfo {
            session_id: sid.into(),
            session: format!("s{sid}"),
            window_id: wid.into(),
            window: "w".into(),
            pane: format!("%{wi}{pi}"),
            command: cmd.into(),
            title: "t".into(),
            window_index: wi,
            pane_index: pi,
            attached: 1,
            activity,
            cols: 80,
            rows: 24,
            dead,
        }
    }

    #[test]
    fn sessions_take_the_current_windows_first_pane_and_the_latest_activity() {
        let list = [
            pane("$10", "@9", 0, 0, "vim", 5, true),
            pane("$2", "@1", 0, 0, "zsh", 100, false),
            pane("$2", "@2", 1, 1, "htop", 300, false),
            pane("$2", "@2", 1, 0, "claude", 200, true),
        ];
        let current: HashSet<String> = ["@2".to_string()].into_iter().collect();
        let u = Unread::new(0);
        let v = rows(&list, &current, Some("gpu1"), &u, 0);
        assert_eq!(v.len(), 2);
        assert_eq!(
            v[0],
            TermRow {
                id: "term:tmux@gpu1:s$2".into(),
                host: Some("gpu1".into()),
                name: "s$2".into(),
                command: "claude".into(),
                panes: 3,
                attached: 1,
                activity: 300,
                dead: false,
                unread: false,
            }
        );
        assert_eq!((v[1].name.as_str(), v[1].command.as_str(), v[1].dead), ("s$10", "vim", true));
        // No current window known: the first window's first pane.
        assert_eq!(rows(&list, &HashSet::new(), None, &u, 0)[0].command, "zsh");
    }

    #[test]
    fn rows_carry_the_host_and_unread() {
        let list = [pane("$1", "@1", 0, 0, "a", 1050, false), pane("$2", "@2", 0, 0, "b", 1050, false)];
        let mut u = Unread::new(1000);
        u.seen("$2", 1060);
        // Both had output at 1050 and have been quiet for 3 seconds; only $1 was not looked at since.
        let v = rows(&list, &HashSet::new(), Some("gpu1"), &u, 1053);
        assert_eq!((v[0].unread, v[1].unread), (true, false));
        assert_eq!((v[0].id.as_str(), v[0].host.as_deref()), ("term:tmux@gpu1:s$1", Some("gpu1")));
        let v = rows(&list, &HashSet::new(), None, &u, 1053);
        assert_eq!((v[0].id.as_str(), v[0].host.as_deref()), ("term:tmux:s$1", None));
    }

    #[test]
    fn backoff_doubles_to_fifteen_seconds_and_resets() {
        let mut b = Backoff::new();
        let s: Vec<u64> = (0..6).map(|_| b.failed().as_secs()).collect();
        assert_eq!(s, [1, 2, 4, 8, 15, 15]);
        b.reset();
        assert_eq!(b.failed().as_secs(), 1);
    }
}
