//! Who may operate A right now, what A has pressed, and the device names the service
//! announced (`Sources/RappCore/InputYield.swift`, `HeldInput.swift`, `PeerNames.swift`).
//! Pure: every call takes the time from the caller.

use std::collections::HashSet;

use crate::protocol::{Message, MouseButton, MouseKind};

/// How long a remote input waits after another B device operated A (R8).
pub const YIELD_WINDOW: f64 = 1.0;
/// The worker tells the host about input at most this often.
pub const INPUT_REPORT_EVERY: f64 = 0.25;
/// A blocked B hears about it at most this often.
pub const BLOCKED_NOTICE_EVERY: f64 = 0.5;
/// How many announced device names a host keeps (R2).
pub const PEER_NAMES_KEPT: usize = 16;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum YieldDecision {
    /// Let it through; `report`: tell stdout about this input now.
    Pass { report: bool },
    /// Hold it back; `notify`: the device name to tell B (empty string allowed), or `None`.
    Drop { notify: Option<String> },
}

/// Decides which remote input on A waits because another B device is operating A (R7).
#[derive(Debug, Clone)]
pub struct InputYield {
    blocked_until: f64,
    by: String,
    last_report: f64,
    last_notice: f64,
    owes_report: bool,
    held_keys: HashSet<u16>,
    held_buttons: HashSet<MouseButton>,
    dropped_keys: HashSet<u16>,
    dropped_buttons: HashSet<MouseButton>,
}

impl Default for InputYield {
    fn default() -> Self {
        InputYield::new()
    }
}

impl InputYield {
    pub fn new() -> Self {
        InputYield {
            blocked_until: f64::NEG_INFINITY,
            by: String::new(),
            last_report: f64::NEG_INFINITY,
            last_notice: f64::NEG_INFINITY,
            owes_report: false,
            held_keys: HashSet::new(),
            held_buttons: HashSet::new(),
            dropped_keys: HashSet::new(),
            dropped_buttons: HashSet::new(),
        }
    }

    /// Another device is operating A: block until `YIELD_WINDOW` from now.
    pub fn yielded(&mut self, by: &str, now: f64) {
        self.blocked_until = now + YIELD_WINDOW;
        self.by = by.to_string();
    }

    /// True once when a deferred input report is due.
    pub fn tick(&mut self, now: f64) -> bool {
        if !(self.owes_report && now - self.last_report >= INPUT_REPORT_EVERY) {
            return false;
        }
        self.owes_report = false;
        self.last_report = now;
        true
    }

    pub fn admit(&mut self, m: &Message, now: f64) -> YieldDecision {
        let blocking = now < self.blocked_until;
        match m {
            Message::Text(_)
            | Message::Scroll { .. }
            | Message::Paste { .. }
            | Message::MenuPick(_)
            | Message::Focus(_)
            | Message::SelectInput { .. } => {
                if blocking {
                    self.blocked(now)
                } else {
                    self.passed(now)
                }
            }
            Message::Key { key_code, down, .. } => {
                let code = *key_code;
                if *down {
                    if self.held_keys.contains(&code) {
                        return self.passed(now);
                    }
                    if self.dropped_keys.contains(&code) {
                        return YieldDecision::Drop { notify: None };
                    }
                    if blocking {
                        self.dropped_keys.insert(code);
                        return self.blocked(now);
                    }
                    self.held_keys.insert(code);
                    return self.passed(now);
                }
                if self.held_keys.remove(&code) {
                    return self.passed(now);
                }
                if self.dropped_keys.remove(&code) {
                    return YieldDecision::Drop { notify: None };
                }
                if blocking {
                    self.blocked(now)
                } else {
                    YieldDecision::Pass { report: false }
                }
            }
            Message::Mouse { kind, button, .. } => {
                let button = *button;
                match kind {
                    MouseKind::Move => {
                        if blocking {
                            self.blocked(now)
                        } else {
                            YieldDecision::Pass { report: false }
                        }
                    }
                    MouseKind::Down => {
                        if self.held_buttons.contains(&button) {
                            return self.passed(now);
                        }
                        if self.dropped_buttons.contains(&button) {
                            return YieldDecision::Drop { notify: None };
                        }
                        if blocking {
                            self.dropped_buttons.insert(button);
                            return self.blocked(now);
                        }
                        self.held_buttons.insert(button);
                        self.passed(now)
                    }
                    MouseKind::Drag => {
                        if self.held_buttons.contains(&button) {
                            return self.passed(now);
                        }
                        if self.dropped_buttons.contains(&button) {
                            return YieldDecision::Drop { notify: None };
                        }
                        if blocking {
                            self.blocked(now)
                        } else {
                            YieldDecision::Pass { report: false }
                        }
                    }
                    MouseKind::Up => {
                        if self.held_buttons.remove(&button) {
                            return self.passed(now);
                        }
                        if self.dropped_buttons.remove(&button) {
                            return YieldDecision::Drop { notify: None };
                        }
                        if blocking {
                            self.blocked(now)
                        } else {
                            YieldDecision::Pass { report: false }
                        }
                    }
                }
            }
            _ => YieldDecision::Pass { report: false },
        }
    }

    fn passed(&mut self, now: f64) -> YieldDecision {
        if now - self.last_report >= INPUT_REPORT_EVERY {
            self.last_report = now;
            self.owes_report = false;
            return YieldDecision::Pass { report: true };
        }
        self.owes_report = true;
        YieldDecision::Pass { report: false }
    }

    fn blocked(&mut self, now: f64) -> YieldDecision {
        if !(now - self.last_notice >= BLOCKED_NOTICE_EVERY) {
            return YieldDecision::Drop { notify: None };
        }
        self.last_notice = now;
        YieldDecision::Drop { notify: Some(self.by.clone()) }
    }
}

/// What the host has posted as pressed and not yet released. Pure bookkeeping, so a session
/// teardown can release exactly these and nothing else.
#[derive(Debug, Clone, Default)]
pub struct HeldInput {
    keys: HashSet<u16>,
    buttons: HashSet<MouseButton>,
}

impl HeldInput {
    pub fn new() -> Self {
        HeldInput::default()
    }

    pub fn press_key(&mut self, code: u16) {
        self.keys.insert(code);
    }

    pub fn release_key(&mut self, code: u16) {
        self.keys.remove(&code);
    }

    /// Call only for a down that was actually posted.
    pub fn press_button(&mut self, button: MouseButton) {
        self.buttons.insert(button);
    }

    pub fn release_button(&mut self, button: MouseButton) {
        self.buttons.remove(&button);
    }

    /// Everything still held (keys ascending, left button first), then forgets it.
    pub fn drain(&mut self) -> (Vec<u16>, Vec<MouseButton>) {
        let mut keys: Vec<u16> = self.keys.drain().collect();
        keys.sort_unstable();
        let mut buttons: Vec<MouseButton> = self.buttons.drain().collect();
        buttons.sort_by_key(|b| *b as u8);
        (keys, buttons)
    }
}

/// The device names rapp-service announced on stdin, by the peer port of its connection to this
/// worker (R2). Holds the newest `PEER_NAMES_KEPT`; naming a port again makes it the newest.
#[derive(Debug, Clone, Default)]
pub struct PeerNames {
    entries: Vec<(u16, String)>,
}

impl PeerNames {
    pub fn new() -> Self {
        PeerNames::default()
    }

    pub fn count(&self) -> usize {
        self.entries.len()
    }

    pub fn set(&mut self, name: &str, port: u16) {
        self.entries.retain(|(p, _)| *p != port);
        self.entries.push((port, name.to_string()));
        if self.entries.len() > PEER_NAMES_KEPT {
            let extra = self.entries.len() - PEER_NAMES_KEPT;
            self.entries.drain(..extra);
        }
    }

    /// The name announced for `port`; `None` when none was (the device is shown without a name).
    pub fn name(&self, port: u16) -> Option<&str> {
        self.entries.iter().rev().find(|(p, _)| *p == port).map(|(_, n)| n.as_str())
    }
}
