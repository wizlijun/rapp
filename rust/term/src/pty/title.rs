//! Terminal titles (OSC 0/1/2) and the name a session is shown by.

use super::ps::{Event, Scanner};

const MAX_CHARS: usize = 64;

fn decoration(c: char) -> bool {
    c.is_whitespace()
        || matches!(c, '*' | '·')
        || matches!(c as u32,
            0x2190..=0x21ff | 0x2300..=0x23ff | 0x25a0..=0x27bf | 0x2800..=0x28ff | 0x2b00..=0x2bff)
}

fn invisible(c: char) -> bool {
    c.is_control()
        || matches!(c as u32,
            0x200b..=0x200f | 0x2028 | 0x2029 | 0x202a..=0x202e | 0x2060..=0x2064 | 0x2066..=0x2069 | 0xfeff)
}

/// A title as shown: no control chars, no leading spinner or decoration, at most 64 chars.
pub fn clean(raw: &str) -> Option<String> {
    let no_ctl: String = raw.chars().filter(|c| !invisible(*c)).collect();
    let text: String = no_ctl.trim().trim_start_matches(decoration).chars().take(MAX_CHARS).collect();
    let text = text.trim_end().to_string();
    if text.is_empty() {
        None
    } else {
        Some(text)
    }
}

/// The tab name (OSC 1) and window title (OSC 2) a program has set; OSC 0 sets both.
#[derive(Default)]
pub struct Titles {
    scanner: Scanner,
    tab: Option<String>,
    window: Option<String>,
}

impl Titles {
    /// Returns true when `shown()` changed.
    pub fn feed(&mut self, bytes: &[u8]) -> bool {
        let mut titles = Vec::new();
        self.scanner.feed(bytes, |e| {
            if let Event::Title { slot, text } = e {
                titles.push((slot, clean(&text)));
            }
        });
        if titles.is_empty() {
            return false;
        }
        let before = self.shown();
        for (slot, text) in titles {
            if slot != 2 {
                self.tab = text.clone();
            }
            if slot != 1 {
                self.window = text;
            }
        }
        before != self.shown()
    }

    pub fn shown(&self) -> Option<String> {
        self.tab.clone().or_else(|| self.window.clone())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn clean_strips_controls_spinners_and_cuts_at_64() {
        assert_eq!(clean("  ~/git/rapp \t"), Some("~/git/rapp".into()));
        assert_eq!(clean("✳ Claude Code"), Some("Claude Code".into()));
        assert_eq!(clean("⠐ Fix the build"), Some("Fix the build".into()));
        assert_eq!(clean("a\u{7}b"), Some("ab".into()));
        assert_eq!(clean("修复 终端"), Some("修复 终端".into()));
        assert_eq!(clean("⠂ "), None);
        assert_eq!(clean(""), None);
        assert_eq!(clean("\u{202E}abc"), Some("abc".into()));
        assert_eq!(clean("a\u{2028}b"), Some("ab".into()));
        assert_eq!(clean("\u{200B}\u{FEFF}"), None);
        assert_eq!(clean(&"x".repeat(80)).unwrap().chars().count(), 64);
    }

    #[test]
    fn tab_name_wins_over_window_title() {
        let mut t = Titles::default();
        assert!(t.feed(b"\x1b]2;bruce@mac:~/git/rapp\x07"));
        assert_eq!(t.shown().as_deref(), Some("bruce@mac:~/git/rapp"));
        assert!(t.feed(b"\x1b]1;~/git/rapp\x07"));
        assert_eq!(t.shown().as_deref(), Some("~/git/rapp"));
        assert!(t.feed(b"\x1b]0;vim x\x07")); // 0 sets both
        assert_eq!(t.shown().as_deref(), Some("vim x"));
        assert!(t.feed(b"\x1b]0;\x07")); // empty clears both
        assert_eq!(t.shown(), None);
    }

    #[test]
    fn a_spinner_frame_is_no_change() {
        let mut t = Titles::default();
        assert!(t.feed(b"\x1b]0;\xe2\xa0\x82 task\x07")); // ⠂
        assert!(!t.feed(b"\x1b]0;\xe2\xa0\x90 task\x07")); // ⠐
        assert!(!t.feed(b"plain output"));
    }
}
