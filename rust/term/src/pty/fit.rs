//! Which console's size the host window follows (spec §4.3).
//!
//! A pure, clock-injected state machine: no I/O. Viewers report what they want
//! and when they act; `take` says whether a resize request is due.

use std::collections::HashMap;
use std::io::Write;
use std::sync::Mutex;
use std::time::{Duration, Instant};

pub type Conn = u64;

pub const MIN_COLS: u16 = 20;
pub const MIN_ROWS: u16 = 5;
/// How long the actor must be idle before another console may take over.
pub const HANDOVER: Duration = Duration::from_secs(2);

#[derive(Clone, Copy, PartialEq, Eq)]
struct Want {
    fit: bool,
    cols: u16,
    rows: u16,
}

#[derive(Default)]
pub struct Fit {
    next: Conn,
    wants: HashMap<Conn, Want>,
    actor: Option<Conn>,
    last_op: Option<Instant>,
    pending: Option<(u16, u16)>,
}

impl Fit {
    pub fn join(&mut self) -> Conn {
        self.next += 1;
        self.next
    }

    pub fn view(&mut self, c: Conn, fit: bool, cols: u16, rows: u16, now: Instant) {
        let new = Want { fit, cols, rows };
        let old = self.wants.insert(c, new);
        if old.is_some_and(|o| !o.fit) && fit {
            self.op(c, now);
            if self.actor == Some(c) {
                self.request();
            }
        } else if self.actor.is_none() && fit {
            self.actor = Some(c);
            self.last_op = None;
            self.request();
        } else if self.actor == Some(c) && fit && old != Some(new) {
            self.request();
        }
    }

    pub fn input(&mut self, c: Conn, now: Instant) {
        self.op(c, now);
    }

    pub fn leave(&mut self, c: Conn) {
        self.wants.remove(&c);
        if self.actor == Some(c) {
            self.actor = None;
            self.last_op = None;
        }
    }

    /// The size to ask the window for, `(cols, rows)`, already floored.
    pub fn take(&mut self) -> Option<(u16, u16)> {
        self.pending.take()
    }

    fn op(&mut self, c: Conn, now: Instant) {
        if self.actor == Some(c) {
            self.last_op = Some(now);
            return;
        }
        let free = match (self.actor, self.last_op) {
            (None, _) | (Some(_), None) => true,
            (Some(_), Some(t)) => now.saturating_duration_since(t) >= HANDOVER,
        };
        if free {
            self.actor = Some(c);
            self.last_op = Some(now);
            self.request();
        }
    }

    fn request(&mut self) {
        let want = self.actor.and_then(|a| self.wants.get(&a));
        if let Some(w) = want.filter(|w| w.fit) {
            self.pending = Some((w.cols.max(MIN_COLS), w.rows.max(MIN_ROWS)));
        }
    }
}

#[derive(Clone, Copy, Default, PartialEq, Eq)]
enum Seq {
    #[default]
    Ground,
    Utf8(u8),
    Esc,
    Csi,
    Str,
    StrEsc,
}

/// Follows the program's output byte stream and says whether it is between
/// escape sequences and UTF-8 characters, i.e. safe to insert bytes.
#[derive(Default)]
pub struct SeqTracker {
    state: Seq,
}

impl SeqTracker {
    pub fn feed(&mut self, bytes: &[u8]) {
        for &b in bytes {
            self.state = Self::step(self.state, b);
        }
    }

    pub fn ground(&self) -> bool {
        self.state == Seq::Ground
    }

    fn step(state: Seq, b: u8) -> Seq {
        if b == 0x18 || b == 0x1A {
            return Seq::Ground;
        }
        // ESC restarts a sequence from every state except inside a string,
        // where it may begin the terminator.
        if b == 0x1B && !matches!(state, Seq::Str | Seq::StrEsc) {
            return Seq::Esc;
        }
        match state {
            Seq::Ground => Self::from_ground(b),
            Seq::Utf8(n) => {
                if (0x80..=0xBF).contains(&b) {
                    if n <= 1 {
                        Seq::Ground
                    } else {
                        Seq::Utf8(n - 1)
                    }
                } else {
                    Self::from_ground(b)
                }
            }
            Seq::Esc => match b {
                b'[' => Seq::Csi,
                b']' | b'P' | b'X' | b'^' | b'_' => Seq::Str,
                0x20..=0x2F => Seq::Esc,
                _ => Seq::Ground,
            },
            Seq::Csi => {
                if (0x40..=0x7E).contains(&b) {
                    Seq::Ground
                } else {
                    Seq::Csi
                }
            }
            // Known limit: an unterminated string holds resizes until BEL, ST,
            // CAN or SUB (not capped, so long OSC 52 payloads stay intact).
            Seq::Str => match b {
                0x07 => Seq::Ground,
                0x1B => Seq::StrEsc,
                _ => Seq::Str,
            },
            Seq::StrEsc => {
                if b == b'\\' {
                    Seq::Ground
                } else {
                    Self::step(Seq::Esc, b)
                }
            }
        }
    }

    fn from_ground(b: u8) -> Seq {
        match b {
            0x1B => Seq::Esc,
            0xC0..=0xDF => Seq::Utf8(1),
            0xE0..=0xEF => Seq::Utf8(2),
            0xF0..=0xF7 => Seq::Utf8(3),
            _ => Seq::Ground,
        }
    }
}

/// The host window's stdout: program output passes through, and a resize
/// request is only inserted between escape sequences.
pub struct Window<W: Write> {
    out: W,
    seq: SeqTracker,
}

impl<W: Write> Window<W> {
    pub fn new(out: W) -> Self {
        Self {
            out,
            seq: SeqTracker::default(),
        }
    }

    pub fn output(&mut self, bytes: &[u8]) -> std::io::Result<()> {
        self.out.write_all(bytes)?;
        self.out.flush()?;
        self.seq.feed(bytes);
        Ok(())
    }

    /// Writes `ESC[8;rows;colst` if the stream is idle and a size is pending.
    pub fn resize_if_idle(&mut self, fit: &Mutex<Fit>) -> std::io::Result<bool> {
        if !self.seq.ground() {
            return Ok(false);
        }
        let size = fit.lock().unwrap_or_else(|e| e.into_inner()).take();
        let Some((cols, rows)) = size else {
            return Ok(false);
        };
        self.out
            .write_all(format!("\x1b[8;{rows};{cols}t").as_bytes())?;
        self.out.flush()?;
        Ok(true)
    }

    #[cfg(test)]
    pub fn get_ref(&self) -> &W {
        &self.out
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ms(t0: Instant, n: u64) -> Instant {
        t0 + Duration::from_millis(n)
    }

    #[test]
    fn the_first_fit_view_takes_over() {
        let mut f = Fit::default();
        let a = f.join();
        f.view(a, true, 100, 30, Instant::now());
        assert_eq!(f.take(), Some((100, 30)));
        assert_eq!(f.take(), None);
    }

    #[test]
    fn a_fit_false_view_never_requests() {
        let t0 = Instant::now();
        let mut f = Fit::default();
        let a = f.join();
        f.view(a, false, 100, 30, t0);
        f.input(a, t0);
        assert_eq!(f.take(), None);
    }

    #[test]
    fn a_second_viewer_opening_does_not_take_over() {
        let t0 = Instant::now();
        let mut f = Fit::default();
        let (a, b) = (f.join(), f.join());
        f.view(a, true, 100, 30, t0);
        f.take();
        f.view(b, true, 80, 20, t0);
        assert_eq!(f.take(), None);
    }

    #[test]
    fn handover_waits_for_two_idle_seconds() {
        let t0 = Instant::now();
        let mut f = Fit::default();
        let (a, b) = (f.join(), f.join());
        f.view(a, true, 100, 30, t0);
        f.take();
        f.view(b, true, 80, 20, t0);
        f.input(a, t0);
        f.input(b, ms(t0, 500));
        assert_eq!(f.take(), None);
        f.input(b, ms(t0, 2000));
        assert_eq!(f.take(), Some((80, 20)));
        f.input(b, ms(t0, 2100));
        assert_eq!(f.take(), None);
    }

    #[test]
    fn typing_by_the_actor_does_not_rewrite() {
        let t0 = Instant::now();
        let mut f = Fit::default();
        let a = f.join();
        f.view(a, true, 100, 30, t0);
        f.take();
        for n in 1..=3 {
            f.input(a, ms(t0, n * 100));
            assert_eq!(f.take(), None);
        }
    }

    #[test]
    fn the_actor_s_new_size_applies_but_a_bystander_s_does_not() {
        let t0 = Instant::now();
        let mut f = Fit::default();
        let (a, b) = (f.join(), f.join());
        f.view(a, true, 100, 30, t0);
        f.take();
        f.view(b, true, 90, 25, ms(t0, 10));
        assert_eq!(f.take(), None);
        f.view(a, true, 110, 35, ms(t0, 20));
        assert_eq!(f.take(), Some((110, 35)));
    }

    #[test]
    fn turning_fit_on_is_an_operation() {
        let t0 = Instant::now();
        let mut f = Fit::default();
        let (a, b) = (f.join(), f.join());
        f.view(a, true, 100, 30, t0);
        f.take();
        f.view(b, false, 80, 20, ms(t0, 10));
        f.view(b, true, 80, 20, ms(t0, 3000));
        assert_eq!(f.take(), Some((80, 20)));
    }

    #[test]
    fn the_actor_leaving_frees_the_seat() {
        let t0 = Instant::now();
        let mut f = Fit::default();
        let (a, b) = (f.join(), f.join());
        f.view(a, true, 100, 30, t0);
        f.view(b, true, 70, 20, t0);
        f.take();
        f.leave(a);
        assert_eq!(f.take(), None);
        f.view(b, true, 70, 20, ms(t0, 10));
        assert_eq!(f.take(), Some((70, 20)));
    }

    #[test]
    fn sizes_are_floored() {
        let mut f = Fit::default();
        let a = f.join();
        f.view(a, true, 10, 3, Instant::now());
        assert_eq!(f.take(), Some((20, 5)));
    }

    fn pending(c: u16, r: u16) -> Mutex<Fit> {
        let mut f = Fit::default();
        let a = f.join();
        f.view(a, true, c, r, Instant::now());
        Mutex::new(f)
    }

    #[test]
    fn resize_is_written_at_once_when_idle() {
        let fit = pending(100, 30);
        let mut w = Window::new(Vec::new());
        w.output(b"hi").unwrap();
        assert!(w.resize_if_idle(&fit).unwrap());
        assert!(w.get_ref().ends_with(b"\x1b[8;30;100t"));
    }

    #[test]
    fn resize_waits_for_an_open_sequence() {
        let fit = pending(100, 30);
        let mut w = Window::new(Vec::new());
        w.output(b"a\x1b[3").unwrap();
        assert!(!w.resize_if_idle(&fit).unwrap());
        assert!(!w.get_ref().windows(2).any(|x| x == b"8;"));
        w.output(b"1mX").unwrap();
        assert!(w.resize_if_idle(&fit).unwrap());
        assert_eq!(w.get_ref().as_slice(), b"a\x1b[31mX\x1b[8;30;100t");
    }

    #[test]
    fn resize_waits_for_a_split_utf8_char() {
        let fit = pending(100, 30);
        let mut w = Window::new(Vec::new());
        w.output(&[0xE4, 0xB8]).unwrap();
        assert!(!w.resize_if_idle(&fit).unwrap());
        assert_eq!(w.get_ref().as_slice(), &[0xE4, 0xB8]);
        w.output(&[0xAD]).unwrap();
        assert!(w.resize_if_idle(&fit).unwrap());
        assert_eq!(w.get_ref().as_slice(), b"\xE4\xB8\xAD\x1b[8;30;100t");
    }

    #[test]
    fn an_osc_title_holds_the_resize_until_bel_or_st() {
        for end in [&b"\x07"[..], &b"\x1b\\"[..]] {
            let fit = pending(100, 30);
            let mut w = Window::new(Vec::new());
            w.output(b"\x1b]0;t").unwrap();
            assert!(!w.resize_if_idle(&fit).unwrap());
            w.output(end).unwrap();
            assert!(w.resize_if_idle(&fit).unwrap());
            let mut want = b"\x1b]0;t".to_vec();
            want.extend_from_slice(end);
            want.extend_from_slice(b"\x1b[8;30;100t");
            assert_eq!(w.get_ref().as_slice(), want.as_slice());
        }
    }

    #[test]
    fn the_tracker_follows_real_terminal_parsing() {
        let cases: &[(&[u8], bool)] = &[
            (b"\x1b\x1b", false),
            (b"\x1b\x1b[", false),
            (b"\x1b[3\x1b[", false),
            (b"\x1b[3\x1b[m", true),
            (b"\x1b[3\x1b]0;title", false),
            (b"\x1b[3\x1b]0;title\x07", true),
            (b"\x1b]0;t\x1b[0", false),
            (b"\x1b]0;t\x1b[0m", true),
            (b"\x1b]0;t\x1b[", false),
            (b"\x1b]0;t\x1b\\", true),
            (b"\x1b[3\x18", true),
            (b"\x1b[3\x1a", true),
            (b"\x1b]0;t\x18", true),
            (b"\x1b]0;t\x1a", true),
            (&[0xE4, 0x18], true),
            (&[0xE4, 0x1A], true),
            (b"\x1b(", false),
            (b"\x1b(B", true),
            (b"\x1bPq\x1b", false),
            (b"\x1bPq\x1b\\", true),
            (&[0xE4, 0x1B], false),
            (&[0xE4, 0x1B, b'c'], true),
            (b"abc\x1b", false),
        ];
        for (bytes, ground) in cases {
            let mut t = SeqTracker::default();
            t.feed(bytes);
            assert_eq!(t.ground(), *ground, "{bytes:?}");
        }
    }

    #[test]
    fn nothing_pending_writes_nothing() {
        let fit = Mutex::new(Fit::default());
        let mut w = Window::new(Vec::new());
        w.output(b"x").unwrap();
        assert!(!w.resize_if_idle(&fit).unwrap());
        assert_eq!(w.get_ref().as_slice(), b"x");
    }
}
