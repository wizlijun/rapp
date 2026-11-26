//! What a host sends besides pictures while B has paused the session (v15
//! `setStream` fps 0), ported from `PauseOutbox.swift`: the window table at most
//! every `WINDOWS_EVERY` seconds, the menu bar and focus region held until
//! resume, `changed` at most every `CHANGED_EVERY` seconds, everything else at once.

use crate::protocol::Message;

#[derive(Debug, Clone)]
pub struct PauseOutbox {
    paused: bool,
    windows: Option<Message>,
    menu_bar: Option<Message>,
    focus_region: Option<Message>,
    windows_sent: f64,
    changed_sent: f64,
}

impl Default for PauseOutbox {
    fn default() -> Self {
        PauseOutbox {
            paused: false,
            windows: None,
            menu_bar: None,
            focus_region: None,
            windows_sent: f64::NEG_INFINITY,
            changed_sent: f64::NEG_INFINITY,
        }
    }
}

impl PauseOutbox {
    pub const WINDOWS_EVERY: f64 = 5.0;
    pub const CHANGED_EVERY: f64 = 1.0;

    pub fn new() -> Self {
        Self::default()
    }

    pub fn paused(&self) -> bool {
        self.paused
    }

    /// `m` to send now, or None when it is held for later.
    pub fn pass(&mut self, m: Message, now: f64) -> Option<Message> {
        match m {
            Message::Windows(_) => {
                // Swift: `guard paused, now - windowsSent < windowsEvery else { … return m }`.
                if !(self.paused && now - self.windows_sent < Self::WINDOWS_EVERY) {
                    self.windows = None;
                    self.windows_sent = now;
                    return Some(m);
                }
                self.windows = Some(m);
                None
            }
            Message::MenuBar(_) if self.paused => {
                self.menu_bar = Some(m);
                None
            }
            Message::FocusRegion { .. } if self.paused => {
                self.focus_region = Some(m);
                None
            }
            _ => Some(m),
        }
    }

    /// The held window table once its turn has come (call about once a second).
    pub fn due(&mut self, now: f64) -> Option<Message> {
        if !self.paused || self.windows.is_none() || !(now - self.windows_sent >= Self::WINDOWS_EVERY) {
            return None;
        }
        self.windows_sent = now;
        self.windows.take()
    }

    /// `changed` for a picture change seen while paused, unless one went out less than a second ago.
    pub fn changed(&mut self, now: f64) -> Option<Message> {
        if !self.paused || !(now - self.changed_sent >= Self::CHANGED_EVERY) {
            return None;
        }
        self.changed_sent = now;
        Some(Message::Changed)
    }

    /// Pausing holds from now on; resuming returns what was held, to send before the next picture.
    pub fn set_paused(&mut self, on: bool, now: f64) -> Vec<Message> {
        let was = self.paused;
        // Swift `defer { paused = on }`: set on every path.
        self.paused = on;
        if !(was && !on) {
            return Vec::new();
        }
        if self.windows.is_some() {
            self.windows_sent = now;
        }
        [self.windows.take(), self.menu_bar.take(), self.focus_region.take()].into_iter().flatten().collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn held_until_resume() {
        let mut o = PauseOutbox::new();
        assert!(o.set_paused(true, 0.0).is_empty());
        assert_eq!(o.pass(Message::MenuBar(vec![]), 1.0), None);
        assert_eq!(o.pass(Message::Windows(vec![]), 1.0), Some(Message::Windows(vec![])));
        assert_eq!(o.pass(Message::Windows(vec![]), 2.0), None);
        assert_eq!(o.changed(2.0), Some(Message::Changed));
        assert_eq!(o.changed(2.5), None);
        assert_eq!(o.set_paused(false, 3.0), vec![Message::Windows(vec![]), Message::MenuBar(vec![])]);
    }
}
