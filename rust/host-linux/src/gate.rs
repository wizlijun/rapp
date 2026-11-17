//! Same one-second input yield as the macOS worker. A held drag/key finishes;
//! a dropped press never acquires a release after the block expires.
use crate::wire::Input;
use std::{
    collections::HashSet,
    time::{Duration, Instant},
};

#[derive(Default)]
pub struct Gate {
    blocked: Option<(Instant, String)>,
    keys: HashSet<u16>,
    buttons: HashSet<u8>,
    dropped_keys: HashSet<u16>,
    dropped_buttons: HashSet<u8>,
    last_report: Option<Instant>,
    last_notice: Option<Instant>,
    owes_report: bool,
}
pub struct Decision {
    pub pass: bool,
    pub report: bool,
    pub notice: Option<String>,
}
impl Gate {
    pub fn yielded(&mut self, by: String, now: Instant) {
        self.blocked = Some((now + Duration::from_secs(1), by));
    }
    pub fn tick(&mut self, now: Instant) -> bool {
        if self.owes_report
            && self
                .last_report
                .is_none_or(|t| now.duration_since(t) >= Duration::from_millis(250))
        {
            self.last_report = Some(now);
            self.owes_report = false;
            true
        } else {
            false
        }
    }
    pub fn admit(&mut self, input: &Input, now: Instant) -> Decision {
        let blocked = self.blocked.as_ref().is_some_and(|(until, _)| now < *until);
        let (pass, report, notify) = match input {
            Input::Key(k, _, down) => {
                transition(&mut self.keys, &mut self.dropped_keys, *k, *down, blocked)
            }
            Input::Mouse(kind, button, _, _) => match kind {
                0 | 1 => transition(
                    &mut self.buttons,
                    &mut self.dropped_buttons,
                    *button,
                    *kind == 0,
                    blocked,
                ),
                2 if self.buttons.contains(button) => (true, true, false),
                2 if self.dropped_buttons.contains(button) => (false, false, false),
                _ => (!blocked, false, blocked),
            },
            _ => (!blocked, true, blocked),
        };
        let mut decision = Decision {
            pass,
            report: false,
            notice: None,
        };
        if pass && report {
            self.owes_report = true;
            decision.report = self.tick(now);
        }
        if notify
            && self
                .last_notice
                .is_none_or(|t| now.duration_since(t) >= Duration::from_millis(500))
        {
            self.last_notice = Some(now);
            decision.notice = Some(
                self.blocked
                    .as_ref()
                    .map(|(_, by)| by.clone())
                    .unwrap_or_default(),
            );
        }
        decision
    }
}
fn transition<T: Eq + std::hash::Hash + Copy>(
    held: &mut HashSet<T>,
    dropped: &mut HashSet<T>,
    key: T,
    down: bool,
    blocked: bool,
) -> (bool, bool, bool) {
    if down {
        if held.contains(&key) {
            return (true, true, false);
        }
        if dropped.contains(&key) {
            return (false, false, false);
        }
        if blocked {
            dropped.insert(key);
            return (false, false, true);
        }
        held.insert(key);
        (true, true, false)
    } else if held.remove(&key) {
        (true, true, false)
    } else if dropped.remove(&key) {
        (false, false, false)
    } else {
        (!blocked, false, blocked)
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn held_inputs_finish_but_dropped_press_cannot_resume_after_yield() {
        let mut g = Gate::default();
        let now = Instant::now();
        assert!(g.admit(&Input::Key(8, 0, true), now).pass);
        g.yielded("other".into(), now);
        assert!(g.admit(&Input::Key(8, 0, false), now).pass);
        assert!(!g.admit(&Input::Key(9, 0, true), now).pass);
        let later = now + Duration::from_secs(2);
        assert!(!g.admit(&Input::Key(9, 0, true), later).pass);
        assert!(!g.admit(&Input::Key(9, 0, false), later).pass);
        assert!(g.admit(&Input::Key(9, 0, true), later).pass);
    }
    #[test]
    fn mouse_hover_does_not_steal_input_and_reports_are_deferred() {
        let mut g = Gate::default();
        let now = Instant::now();
        assert!(!g.admit(&Input::Mouse(3, 0, 1., 1.), now).report);
        assert!(g.admit(&Input::Text("a".into()), now).report);
        assert!(!g.admit(&Input::Text("b".into()), now).report);
        assert!(g.tick(now + Duration::from_millis(251)));
        assert!(!g.tick(now + Duration::from_millis(502)));
    }
}
