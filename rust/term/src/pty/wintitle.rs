//! The host window's title (spec §4.2): `<dir> · <prog>[ — <program title>]`.
//!
//! The program's own OSC 0/1/2 are taken out of the window's byte stream only; the emulator and `title.rs` still see
//! the raw bytes.

use super::fg::Fg;
use super::title::clean;
use std::path::Path;

/// A partial OSC longer than this is not held: a title (0/1/2) is dropped up to its end, any other goes to the
/// window as it came.
const MAX_HELD: usize = 4096;
/// Longer than this, a directory is cut to its last two levels.
const MAX_DIR: usize = 32;

#[derive(Default, Clone, Copy, PartialEq, Eq)]
enum State {
    #[default]
    Ground,
    Esc,
    Osc,
    OscEsc,
    /// Inside a title too long to hold: everything up to its BEL, ST, CAN or SUB is dropped.
    Drop,
    DropEsc,
}

/// Removes complete OSC 0/1/2 sequences from a byte stream, across chunk borders.
#[derive(Default)]
pub struct OscStrip {
    state: State,
    /// The raw bytes of the sequence being read, from its ESC.
    held: Vec<u8>,
}

impl OscStrip {
    /// Copies `bytes` to `out` minus complete OSC 0/1/2; returns the last program title seen (empty when cleared).
    pub fn feed(&mut self, bytes: &[u8], out: &mut Vec<u8>) -> Option<String> {
        let mut title = None;
        let mut i = 0;
        while i < bytes.len() {
            if self.state == State::Ground {
                // Plain text goes out in one copy, up to the next ESC.
                let run = bytes[i..].iter().position(|&b| b == 0x1B).unwrap_or(bytes.len() - i);
                out.extend_from_slice(&bytes[i..i + run]);
                i += run;
                if i == bytes.len() {
                    break;
                }
            }
            self.byte(bytes[i], out, &mut title);
            i += 1;
        }
        title
    }

    fn byte(&mut self, b: u8, out: &mut Vec<u8>, title: &mut Option<String>) {
        match self.state {
            State::Ground => {
                if b == 0x1B {
                    self.state = State::Esc;
                    self.held.clear();
                    self.held.push(b);
                } else {
                    out.push(b);
                }
            }
            State::Esc => match b {
                b']' => {
                    self.held.push(b);
                    self.state = State::Osc;
                }
                _ => {
                    self.give_up(out);
                    self.byte(b, out, title);
                }
            },
            State::Osc => match b {
                0x07 => {
                    self.held.push(b);
                    self.finish(out, title);
                }
                0x1B => {
                    self.held.push(b);
                    self.state = State::OscEsc;
                }
                0x18 | 0x1A => {
                    self.give_up(out);
                    out.push(b);
                }
                _ => {
                    self.held.push(b);
                    if self.held.len() > MAX_HELD {
                        if matches!(self.held[2..], [b'0' | b'1' | b'2', b';', ..]) {
                            self.held.clear();
                            self.state = State::Drop;
                        } else {
                            self.give_up(out);
                        }
                    }
                }
            },
            State::Drop => match b {
                0x07 | 0x18 | 0x1A => self.state = State::Ground,
                0x1B => self.state = State::DropEsc,
                _ => {}
            },
            State::DropEsc => {
                self.state = State::Ground;
                if b != b'\\' {
                    // ESC began something else.
                    self.byte(0x1B, out, title);
                    self.byte(b, out, title);
                }
            }
            State::OscEsc => {
                if b == b'\\' {
                    self.held.push(b);
                    self.finish(out, title);
                } else {
                    // ESC began something else: the held part goes out, minus that ESC.
                    self.held.pop();
                    self.give_up(out);
                    self.state = State::Ground;
                    self.byte(0x1B, out, title);
                    self.byte(b, out, title);
                }
            }
        }
    }

    fn give_up(&mut self, out: &mut Vec<u8>) {
        out.extend_from_slice(&self.held);
        self.held.clear();
        self.state = State::Ground;
    }

    fn finish(&mut self, out: &mut Vec<u8>, title: &mut Option<String>) {
        let body = &self.held[2..];
        let payload = match body {
            [b'0' | b'1' | b'2', b';', rest @ ..] => {
                let end = rest.iter().position(|&c| c == 0x07 || c == 0x1B).unwrap_or(rest.len());
                Some(&rest[..end])
            }
            _ => None,
        };
        match payload {
            Some(p) => *title = Some(clean(&String::from_utf8_lossy(p)).unwrap_or_default()),
            None => {
                // Not ours; it ends with BEL or ESC \ exactly as read.
                out.extend_from_slice(&self.held);
            }
        }
        self.held.clear();
        self.state = State::Ground;
    }
}

/// `dir` for a title: the home directory as `~`, and only the last two levels (`…/a/b`) when long.
pub fn short_dir(home: &Path, dir: &Path) -> String {
    let s = match dir.strip_prefix(home) {
        Ok(rest) if !home.as_os_str().is_empty() => {
            if rest.as_os_str().is_empty() {
                "~".to_string()
            } else {
                format!("~/{}", rest.display())
            }
        }
        _ => dir.display().to_string(),
    };
    if s.chars().count() <= MAX_DIR {
        return s;
    }
    let parts: Vec<&str> = s.split('/').filter(|p| !p.is_empty()).collect();
    match parts.len() {
        0..=2 => s,
        n => format!("…/{}/{}", parts[n - 2], parts[n - 1]),
    }
}

/// The whole title; none while neither a directory nor a program is known.
pub fn compose(home: &Path, fg: &Fg, prog_title: Option<&str>) -> Option<String> {
    let dir = fg.cwd.as_deref().map(|d| short_dir(home, d));
    let prog = fg.prog.as_deref();
    let mut t = match (&dir, prog) {
        (None, None) => return None,
        (Some(d), Some(p)) => format!("{d} · {p}"),
        (Some(d), None) => d.clone(),
        (None, Some(p)) => p.to_string(),
    };
    if !fg.shell {
        if let Some(pt) = prog_title.filter(|s| !s.is_empty()) {
            if Some(pt) != prog && Some(pt) != dir.as_deref() {
                t.push_str(" — ");
                t.push_str(pt);
            }
        }
    }
    Some(t)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    fn strip(chunks: &[&[u8]]) -> (Vec<u8>, Option<String>) {
        let mut s = OscStrip::default();
        let mut out = Vec::new();
        let mut t = None;
        for c in chunks {
            if let Some(x) = s.feed(c, &mut out) {
                t = Some(x);
            }
        }
        (out, t)
    }

    #[test]
    fn strips_osc0_bel() {
        assert_eq!(strip(&[b"a\x1b]0;hi\x07b"]), (b"ab".to_vec(), Some("hi".into())));
    }

    #[test]
    fn strips_osc2_st() {
        assert_eq!(strip(&[b"a\x1b]2;hi\x1b\\b"]), (b"ab".to_vec(), Some("hi".into())));
    }

    #[test]
    fn osc_split_across_chunks() {
        assert_eq!(strip(&[b"a\x1b]", b"2;x\x07b"]), (b"ab".to_vec(), Some("x".into())));
        assert_eq!(strip(&[b"a\x1b]2;x\x1b", b"\\b"]), (b"ab".to_vec(), Some("x".into())));
    }

    #[test]
    fn keeps_osc7_and_8() {
        let a = b"x\x1b]7;file:///tmp\x07y\x1b]8;;http://a\x1b\\z";
        assert_eq!(strip(&[a]), (a.to_vec(), None));
        let (out, _) = strip(&[b"\x1b]7;fi", b"le\x07"]);
        assert_eq!(out, b"\x1b]7;file\x07");
    }

    #[test]
    fn an_overlong_title_is_dropped_up_to_its_end() {
        for end in [&b"\x07"[..], b"\x1b\\", b"\x18", b"\x1a"] {
            let mut a = b"a\x1b]2;".to_vec();
            a.extend(std::iter::repeat_n(b'x', 5000));
            a.extend_from_slice(end);
            a.extend_from_slice(b"after");
            assert_eq!(strip(&[&a]), (b"aafter".to_vec(), None));
            // Across chunks too.
            let (one, two) = a.split_at(3000);
            assert_eq!(strip(&[one, two]), (b"aafter".to_vec(), None));
        }
        // An ESC that starts something else ends it.
        let mut a = b"\x1b]0;".to_vec();
        a.extend(std::iter::repeat_n(b'x', 5000));
        a.extend_from_slice(b"\x1b[31mred");
        assert_eq!(strip(&[&a]), (b"\x1b[31mred".to_vec(), None));
    }

    #[test]
    fn an_overlong_other_osc_passes_through() {
        let mut a = b"\x1b]52;c;".to_vec();
        a.extend(std::iter::repeat_n(b'x', 5000));
        a.extend_from_slice(b"\x07z");
        assert_eq!(strip(&[&a]), (a.clone(), None));
    }

    #[test]
    fn plain_runs_between_sequences_keep_their_order() {
        let (out, t) = strip(&[b"one\x1b[1mtwo\x1b]0;t\x07three", b"\x1b", b"]0;u\x07four"]);
        assert_eq!((out, t), (b"one\x1b[1mtwothreefour".to_vec(), Some("u".into())));
    }

    #[test]
    fn a_broken_sequence_passes_through() {
        let a = b"\x1b]0;ab\x1b[31mred";
        assert_eq!(strip(&[a]), (a.to_vec(), None));
        let b = b"\x1bXq";
        assert_eq!(strip(&[b]), (b.to_vec(), None));
    }

    #[test]
    fn short_dir_home_tilde() {
        assert_eq!(short_dir(Path::new("/Users/u"), Path::new("/Users/u/git/rapp")), "~/git/rapp");
        assert_eq!(short_dir(Path::new("/Users/u"), Path::new("/Users/u")), "~");
    }

    #[test]
    fn short_dir_long_keeps_two() {
        let d = "/opt/aaaaaaaaaa/bbbbbbbbbb/cccccccccc/dd";
        assert_eq!(short_dir(Path::new("/Users/u"), Path::new(d)), "…/cccccccccc/dd");
    }

    fn fg(prog: &str, cwd: &str, shell: bool) -> Fg {
        Fg { prog: Some(prog.into()), cwd: Some(PathBuf::from(cwd)), shell, probed: true }
    }

    #[test]
    fn compose_shell_drops_title() {
        let h = Path::new("/Users/u");
        assert_eq!(compose(h, &fg("zsh", "/Users/u/git", true), Some("zsh")).as_deref(), Some("~/git · zsh"));
        assert_eq!(compose(h, &fg("zsh", "/Users/u/git", true), Some("u@h: ~/git")).as_deref(), Some("~/git · zsh"));
    }

    #[test]
    fn compose_with_title() {
        let h = Path::new("/Users/u");
        assert_eq!(
            compose(h, &fg("claude", "/Users/u/git", false), Some("Fix bug")).as_deref(),
            Some("~/git · claude — Fix bug")
        );
    }

    #[test]
    fn compose_drops_title_equal_prog() {
        let h = Path::new("/Users/u");
        assert_eq!(compose(h, &fg("vim", "/Users/u", false), Some("vim")).as_deref(), Some("~ · vim"));
        assert_eq!(compose(h, &fg("vim", "/Users/u", false), Some("~")).as_deref(), Some("~ · vim"));
    }

    #[test]
    fn compose_nothing_known() {
        assert_eq!(compose(Path::new("/"), &Fg::default(), Some("x")), None);
    }
}
