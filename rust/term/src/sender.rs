//! Send gate: only the latest screen is kept, and the next one goes out only after the previous is acknowledged.

use crate::proto::{screen_msgs, Out};
use crate::screen::Screen as Frame;

pub struct Sender {
    pane: String,
    next_rev: u64,
    /// The screen the peer has acknowledged.
    acked: Option<Frame>,
    /// The screen sent but not yet acknowledged, with its revision.
    in_flight: Option<(u64, Frame)>,
    /// The newest screen offered; replaced by every `offer`.
    latest: Option<Frame>,
}

impl Sender {
    pub fn new(pane: &str) -> Sender {
        Sender { pane: pane.to_string(), next_rev: 1, acked: None, in_flight: None, latest: None }
    }

    /// Replace the latest screen; sends it only when nothing is in flight.
    pub fn offer(&mut self, s: Frame) -> Vec<Out> {
        self.latest = Some(s);
        if self.in_flight.is_some() {
            return Vec::new();
        }
        self.send_latest()
    }

    /// Acknowledge the in-flight revision; a matching ack releases the latest screen if it differs.
    pub fn ack(&mut self, rev: u64) -> Vec<Out> {
        match self.in_flight.take() {
            Some((r, screen)) if r == rev => {
                self.acked = Some(screen);
                self.send_latest()
            }
            other => {
                self.in_flight = other;
                Vec::new()
            }
        }
    }

    fn send_latest(&mut self) -> Vec<Out> {
        let Some(latest) = self.latest.take() else { return Vec::new() };
        if self.acked.as_ref() == Some(&latest) {
            return Vec::new();
        }
        let base = self.acked.as_ref().filter(|a| a.cols == latest.cols && a.rows == latest.rows);
        let full = base.is_none();
        let lines = latest.changed(base);
        let rev = self.next_rev;
        self.next_rev += 1;
        let msgs = screen_msgs(&self.pane, rev, &latest, lines, full);
        self.in_flight = Some((rev, latest));
        msgs
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn scr(tag: &str) -> Frame {
        Frame {
            cols: 80,
            rows: 3,
            cx: 0,
            cy: 0,
            cursor: true,
            alt: false,
            lines: vec![tag.into(), "".into(), "".into()],
        }
    }
    fn rev_of(v: &[Out]) -> u64 {
        match &v[0] {
            Out::Screen { rev, .. } => *rev,
            _ => panic!(),
        }
    }

    #[test]
    fn first_screen_goes_out_whole() {
        let mut s = Sender::new("%1");
        let out = s.offer(scr("a"));
        assert!(matches!(&out[0], Out::Screen { full: true, rev: 1, lines, .. } if lines.len() == 3));
    }

    #[test]
    fn nothing_more_goes_out_until_the_ack_and_then_only_the_latest() {
        let mut s = Sender::new("%1");
        let r1 = rev_of(&s.offer(scr("a")));
        for i in 0..1000 {
            assert!(s.offer(scr(&format!("flood {i}"))).is_empty());
        }
        let out = s.ack(r1);
        assert!(
            matches!(&out[0], Out::Screen { full: false, rev: 2, lines, .. } if lines == &[(0, "flood 999".to_string())])
        );
    }

    #[test]
    fn unchanged_screens_and_stale_acks_send_nothing() {
        let mut s = Sender::new("%1");
        let r1 = rev_of(&s.offer(scr("a")));
        assert!(s.ack(r1).is_empty());
        assert!(s.offer(scr("a")).is_empty());
        assert!(s.ack(99).is_empty());
        assert!(s.ack(r1).is_empty());
    }

    #[test]
    fn a_cursor_move_alone_is_sent() {
        let mut s = Sender::new("%1");
        let r1 = rev_of(&s.offer(scr("a")));
        s.ack(r1);
        let mut moved = scr("a");
        moved.cx = 5;
        assert!(matches!(&s.offer(moved)[0], Out::Screen { cx: 5, lines, .. } if lines.is_empty()));
    }

    #[test]
    fn a_size_change_sends_whole_again() {
        let mut s = Sender::new("%1");
        let r1 = rev_of(&s.offer(scr("a")));
        s.ack(r1);
        let mut big = scr("a");
        big.cols = 100;
        assert!(matches!(&s.offer(big)[0], Out::Screen { full: true, rev: 2, lines, .. } if lines.len() == 3));
    }
}
