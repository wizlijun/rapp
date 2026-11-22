//! What the server sends besides pictures while the client has paused them (v15 `set_stream`
//! fps 0): the window table at most every `WINDOWS_EVERY` seconds, the menu bar and focus region
//! held until resume, `changed` at most every `CHANGED_EVERY` seconds. Same rules as the macOS
//! host's `PauseOutbox`; here over raw packets, each also deduplicated against the last one sent.
use rapp_client_core::protocol::packet;

pub const WINDOWS_EVERY: f64 = 5.;
pub const CHANGED_EVERY: f64 = 1.;

#[derive(Default)]
struct Slot {
    sent: Vec<u8>,
    held: Option<Vec<u8>>,
}
impl Slot {
    /// Some(packet) to send now; None when it equals what was sent or is held.
    fn offer(&mut self, packet: Vec<u8>, hold: bool) -> Option<Vec<u8>> {
        if packet == self.sent {
            self.held = None;
            return None;
        }
        if hold {
            self.held = Some(packet);
            return None;
        }
        self.held = None;
        self.sent = packet.clone();
        Some(packet)
    }
    fn flush(&mut self) -> Option<Vec<u8>> {
        let p = self.held.take()?;
        self.sent = p.clone();
        Some(p)
    }
}

pub struct Outbox {
    paused: bool,
    windows: Slot,
    menus: Slot,
    focus: Slot,
    windows_sent: f64,
    changed_sent: f64,
}
impl Outbox {
    /// `windows`: the table the session started with (already sent).
    pub fn new(windows: Vec<u8>) -> Self {
        Self {
            paused: false,
            windows: Slot { sent: windows, held: None },
            menus: Slot::default(),
            focus: Slot::default(),
            windows_sent: f64::NEG_INFINITY,
            changed_sent: f64::NEG_INFINITY,
        }
    }
    pub fn paused(&self) -> bool {
        self.paused
    }
    /// Call with the current table whenever it is read; while paused the newest goes out once
    /// 5 s have passed since the last one sent.
    pub fn windows(&mut self, packet: Vec<u8>, now: f64) -> Option<Vec<u8>> {
        let hold = self.paused && now - self.windows_sent < WINDOWS_EVERY;
        let p = self.windows.offer(packet, hold)?;
        self.windows_sent = now;
        Some(p)
    }
    pub fn menus(&mut self, packet: Vec<u8>) -> Option<Vec<u8>> {
        self.menus.offer(packet, self.paused)
    }
    pub fn focus(&mut self, packet: Vec<u8>) -> Option<Vec<u8>> {
        self.focus.offer(packet, self.paused)
    }
    /// `changed` for a picture change seen while paused, unless one went out less than a second ago.
    pub fn changed(&mut self, now: f64) -> Option<Vec<u8>> {
        if !self.paused || now - self.changed_sent < CHANGED_EVERY {
            return None;
        }
        self.changed_sent = now;
        Some(packet(42, vec![]))
    }
    /// Resuming returns what was held, in the order windows, menus, focus, to send before the picture.
    pub fn set_paused(&mut self, on: bool, now: f64) -> Vec<Vec<u8>> {
        let resumed = self.paused && !on;
        self.paused = on;
        if !resumed {
            return vec![];
        }
        let windows = self.windows.flush();
        if windows.is_some() {
            self.windows_sent = now;
        }
        [windows, self.menus.flush(), self.focus.flush()].into_iter().flatten().collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn w(n: u8) -> Vec<u8> {
        packet(13, vec![1, 0, n])
    }
    fn m(n: u8) -> Vec<u8> {
        packet(17, vec![n])
    }
    fn f(n: u8) -> Vec<u8> {
        packet(36, vec![n])
    }
    #[test]
    fn streaming_sends_changes_and_drops_repeats() {
        let mut o = Outbox::new(w(0));
        assert_eq!(o.windows(w(0), 0.), None);
        assert_eq!(o.windows(w(1), 0.), Some(w(1)));
        assert_eq!(o.windows(w(2), 0.1), Some(w(2)));
        assert_eq!(o.menus(m(1)), Some(m(1)));
        assert_eq!(o.menus(m(1)), None);
        assert_eq!(o.focus(f(1)), Some(f(1)));
        assert_eq!(o.changed(0.), None);
    }
    #[test]
    fn paused_holds_menus_and_focus_and_flushes_the_newest_in_order() {
        let mut o = Outbox::new(w(0));
        assert_eq!(o.menus(m(1)), Some(m(1)));
        assert!(o.set_paused(true, 0.).is_empty());
        assert_eq!(o.focus(f(1)), None);
        assert_eq!(o.menus(m(2)), None);
        assert_eq!(o.focus(f(2)), None);
        assert_eq!(o.windows(w(1), 1.), Some(w(1)), "the first table goes out");
        assert_eq!(o.windows(w(2), 2.), None);
        assert_eq!(o.set_paused(false, 3.), vec![w(2), m(2), f(2)]);
        assert!(o.set_paused(true, 4.).is_empty());
        assert!(o.set_paused(false, 5.).is_empty(), "nothing held twice");
    }
    #[test]
    fn paused_change_back_to_what_was_sent_is_not_flushed() {
        let mut o = Outbox::new(w(0));
        assert_eq!(o.menus(m(1)), Some(m(1)));
        o.set_paused(true, 0.);
        assert_eq!(o.menus(m(2)), None);
        assert_eq!(o.menus(m(1)), None);
        assert!(o.set_paused(false, 1.).is_empty());
    }
    #[test]
    fn paused_window_table_at_most_every_five_seconds() {
        let mut o = Outbox::new(w(0));
        assert_eq!(o.windows(w(1), 0.), Some(w(1)));
        o.set_paused(true, 1.);
        assert_eq!(o.windows(w(2), 2.), None);
        assert_eq!(o.windows(w(3), 4.9), None);
        assert_eq!(o.windows(w(3), 5.), Some(w(3)), "the newest, 5 s after the last sent");
        assert_eq!(o.windows(w(3), 20.), None, "sent once");
        assert_eq!(o.windows(w(4), 20.), Some(w(4)));
        assert_eq!(o.windows(w(5), 21.), None);
        o.set_paused(false, 22.);
        assert_eq!(o.windows(w(6), 22.5), Some(w(6)), "streaming again: no throttle");
    }
    #[test]
    fn changed_at_most_once_per_second_only_while_paused() {
        let mut o = Outbox::new(w(0));
        assert_eq!(o.changed(0.), None);
        o.set_paused(true, 0.);
        assert_eq!(o.changed(0.), Some(vec![42, 0, 0, 0, 0]));
        assert_eq!(o.changed(0.99), None);
        assert_eq!(o.changed(1.), Some(vec![42, 0, 0, 0, 0]));
        o.set_paused(false, 2.);
        assert_eq!(o.changed(5.), None);
    }
}
