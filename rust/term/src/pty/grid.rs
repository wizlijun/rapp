//! The emulator behind `rapp-term run`: pty output goes in, `Screen` / `HistoryRows` come out, with rows written
//! the way `capture-pane -e` writes them so the same reader (`sgr.dart`) understands both backends.

use crate::screen::Screen;
use crate::tmux::{HistoryRows, MAX_HISTORY};
use alacritty_terminal::event::VoidListener;
use alacritty_terminal::grid::Dimensions;
use alacritty_terminal::index::{Column, Line};
use alacritty_terminal::term::cell::{Cell, Flags};
use alacritty_terminal::term::{Config, Term, TermMode};
use alacritty_terminal::vte::ansi::{Color, CursorShape, NamedColor, Processor};

/// Rows of scrollback the emulator keeps.
const HISTORY: usize = 10_000;

/// What the program asked of the keyboard.
#[derive(Default, Clone, Copy, PartialEq, Eq, Debug)]
pub struct Modes {
    pub app_cursor: bool,
    pub bracketed_paste: bool,
}

struct Size {
    cols: usize,
    rows: usize,
}

impl Dimensions for Size {
    fn total_lines(&self) -> usize {
        self.rows
    }
    fn screen_lines(&self) -> usize {
        self.rows
    }
    fn columns(&self) -> usize {
        self.cols
    }
}

/// A terminal emulator holding the program's screen and scrollback. Events the program provokes (queries, title
/// changes, bell) are dropped; whoever shows the program's output answers them.
pub struct Emu {
    term: Term<VoidListener>,
    parser: Processor,
}

impl Emu {
    pub fn new(cols: u16, rows: u16) -> Emu {
        let size = Size { cols: cols.max(1) as usize, rows: rows.max(1) as usize };
        let config = Config { scrolling_history: HISTORY, ..Config::default() };
        Emu { term: Term::new(config, &size, VoidListener), parser: Processor::new() }
    }

    pub fn feed(&mut self, bytes: &[u8]) {
        self.parser.advance(&mut self.term, bytes);
    }

    /// Is a synchronized update (`CSI ? 2026 h`) open, its bytes held back until the matching end?
    pub fn sync_pending(&self) -> bool {
        self.parser.sync_timeout().sync_timeout().is_some()
    }

    /// Apply a synchronized update whose end never came, once its 150 ms timeout has passed. The `run` loop calls
    /// this on its own timer (about every 50 ms); nothing happens when no update is open or it has time left.
    pub fn tick(&mut self) {
        if self.parser.sync_timeout().sync_timeout().is_some_and(|t| std::time::Instant::now() >= t) {
            self.parser.stop_sync(&mut self.term);
        }
    }

    /// Columns and rows.
    pub fn size(&self) -> (u16, u16) {
        (self.term.columns() as u16, self.term.screen_lines() as u16)
    }

    pub fn resize(&mut self, cols: u16, rows: u16) {
        self.term.resize(Size { cols: cols.max(1) as usize, rows: rows.max(1) as usize });
    }

    pub fn screen(&self) -> Screen {
        let g = self.term.grid();
        let (cols, rows) = (g.columns(), g.screen_lines());
        let mut lines = Vec::with_capacity(rows);
        let mut wrapped = Vec::new();
        for r in 0..rows {
            let line = Line(r as i32);
            lines.push(row_text(g, line, cols));
            if r + 1 < rows && g[line][Column(cols - 1)].flags.contains(Flags::WRAPLINE) {
                wrapped.push(r as u16);
            }
        }
        let cursor = g.cursor.point;
        let style = self.term.cursor_style();
        let shape = if style == Default::default() {
            ""
        } else {
            match style.shape {
                CursorShape::Block => "block",
                CursorShape::Underline => "underline",
                CursorShape::Beam => "bar",
                CursorShape::HollowBlock | CursorShape::Hidden => "",
            }
        };
        Screen {
            cols: cols as u16,
            rows: rows as u16,
            cx: cursor.column.0 as u16,
            cy: cursor.line.0.max(0) as u16,
            cursor: self.term.mode().contains(TermMode::SHOW_CURSOR),
            alt: self.term.mode().contains(TermMode::ALT_SCREEN),
            hist: g.history_size() as u32,
            limit: HISTORY as u32,
            shape: shape.to_string(),
            wrapped,
            lines,
        }
    }

    /// `lines` rows of scrollback (at most `MAX_HISTORY`) ending `before` rows above the screen, top to bottom;
    /// `size` is how many rows of scrollback there are.
    pub fn history(&self, before: u32, lines: u32) -> HistoryRows {
        let g = self.term.grid();
        let size = g.history_size() as u32;
        if lines == 0 || before >= size {
            return HistoryRows { size, ..HistoryRows::default() };
        }
        let lines = lines.min(MAX_HISTORY).min(size - before);
        let cols = g.columns();
        let first = -((before + lines) as i32);
        let mut out = Vec::with_capacity(lines as usize);
        let mut wrapped = Vec::new();
        for k in 0..lines {
            let line = Line(first + k as i32);
            out.push(row_text(g, line, cols));
            if k + 1 < lines && g[line][Column(cols - 1)].flags.contains(Flags::WRAPLINE) {
                wrapped.push(k);
            }
        }
        HistoryRows { lines: out, wrapped, size }
    }

    pub fn modes(&self) -> Modes {
        let m = self.term.mode();
        Modes { app_cursor: m.contains(TermMode::APP_CURSOR), bracketed_paste: m.contains(TermMode::BRACKETED_PASTE) }
    }
}

const SHOWN: Flags = Flags::BOLD
    .union(Flags::DIM)
    .union(Flags::ITALIC)
    .union(Flags::ALL_UNDERLINES)
    .union(Flags::INVERSE)
    .union(Flags::HIDDEN)
    .union(Flags::STRIKEOUT);

fn is_default(c: Color) -> bool {
    matches!(c, Color::Named(NamedColor::Foreground | NamedColor::Background))
}

/// Can the cell be dropped at the end of a row: a plain space.
fn is_blank(c: &Cell) -> bool {
    c.c == ' ' && is_default(c.fg) && is_default(c.bg) && !c.flags.intersects(SHOWN) && c.hyperlink().is_none()
}

/// The SGR parameters (without `0`) that draw a cell's colours and attributes.
fn sgr_params(c: &Cell) -> Vec<String> {
    let f = c.flags;
    let (mut fg, fd) = color_params(c.fg, 30);
    let (mut bg, bd) = color_params(c.bg, 40);
    let mut p = Vec::new();
    for (flag, n) in [(Flags::BOLD, "1"), (Flags::DIM, "2")] {
        if f.contains(flag) {
            p.push(n.to_string());
        }
    }
    if (fd || bd) && !f.contains(Flags::DIM) {
        p.push("2".into());
    }
    if f.contains(Flags::ITALIC) {
        p.push("3".into());
    }
    if f.intersects(Flags::ALL_UNDERLINES) {
        p.push("4".into());
    }
    for (flag, n) in [(Flags::INVERSE, "7"), (Flags::HIDDEN, "8"), (Flags::STRIKEOUT, "9")] {
        if f.contains(flag) {
            p.push(n.to_string());
        }
    }
    p.append(&mut fg);
    p.append(&mut bg);
    p
}

/// A colour as SGR parameters (empty for the default colour), and whether it is a "dim" named colour.
fn color_params(c: Color, base: u8) -> (Vec<String>, bool) {
    match c {
        Color::Named(n) => {
            let i = n as usize;
            match i {
                0..=7 => (vec![(base as usize + i).to_string()], false),
                8..=15 => (vec![(base as usize + 60 + i - 8).to_string()], false),
                _ => match n {
                    NamedColor::DimBlack => (vec![base.to_string()], true),
                    NamedColor::DimRed => (vec![(base + 1).to_string()], true),
                    NamedColor::DimGreen => (vec![(base + 2).to_string()], true),
                    NamedColor::DimYellow => (vec![(base + 3).to_string()], true),
                    NamedColor::DimBlue => (vec![(base + 4).to_string()], true),
                    NamedColor::DimMagenta => (vec![(base + 5).to_string()], true),
                    NamedColor::DimCyan => (vec![(base + 6).to_string()], true),
                    NamedColor::DimWhite => (vec![(base + 7).to_string()], true),
                    NamedColor::DimForeground => (Vec::new(), true),
                    _ => (Vec::new(), false),
                },
            }
        }
        Color::Indexed(i) => (vec![(base + 8).to_string(), "5".into(), i.to_string()], false),
        Color::Spec(r) => {
            (vec![(base + 8).to_string(), "2".into(), r.r.to_string(), r.g.to_string(), r.b.to_string()], false)
        }
    }
}

/// One row as an SGR line: styles start from the default, trailing plain blanks are dropped.
fn row_text(g: &alacritty_terminal::grid::Grid<Cell>, line: Line, cols: usize) -> String {
    let row = &g[line];
    let skip = |c: &Cell| c.flags.intersects(Flags::WIDE_CHAR_SPACER | Flags::LEADING_WIDE_CHAR_SPACER);
    let end = (0..cols).rev().find(|&i| !skip(&row[Column(i)]) && !is_blank(&row[Column(i)])).map_or(0, |i| i + 1);
    let mut out = String::new();
    let mut style: Vec<String> = Vec::new();
    let mut link: Option<String> = None;
    for i in 0..end {
        let c = &row[Column(i)];
        if skip(c) {
            continue;
        }
        let want_link = c.hyperlink().map(|h| h.uri().to_string());
        if want_link != link {
            if link.is_some() {
                out.push_str("\x1b]8;;\x1b\\");
            }
            if let Some(u) = &want_link {
                out.push_str(&format!("\x1b]8;;{u}\x1b\\"));
            }
            link = want_link;
        }
        let want = sgr_params(c);
        if want != style {
            if want.is_empty() {
                out.push_str("\x1b[0m");
            } else {
                out.push_str(&format!("\x1b[0;{}m", want.join(";")));
            }
            style = want;
        }
        out.push(c.c);
        if let Some(z) = c.zerowidth() {
            out.extend(z.iter());
        }
    }
    if !style.is_empty() {
        out.push_str("\x1b[0m");
    }
    if link.is_some() {
        out.push_str("\x1b]8;;\x1b\\");
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn lines(bytes: &[u8]) -> Vec<String> {
        let mut e = Emu::new(20, 3);
        e.feed(bytes);
        e.screen().lines
    }

    #[test]
    fn plain_text_drops_trailing_blanks() {
        assert_eq!(lines(b"hi   ")[0], "hi");
    }

    #[test]
    fn colors_and_attributes_are_written_as_sgr() {
        assert_eq!(lines(b"\x1b[1;31mA\x1b[0mB")[0], "\x1b[0;1;31mA\x1b[0mB");
        assert_eq!(lines(b"\x1b[38;5;200mC")[0], "\x1b[0;38;5;200mC\x1b[0m");
        assert_eq!(lines(b"\x1b[48;2;1;2;3mD")[0], "\x1b[0;48;2;1;2;3mD\x1b[0m");
        assert_eq!(lines(b"\x1b[94mE")[0], "\x1b[0;94mE\x1b[0m");
    }

    #[test]
    fn wide_and_combining_chars_keep_their_columns() {
        let mut e = Emu::new(20, 3);
        e.feed("中文😀e\u{301}x".as_bytes());
        let s = e.screen();
        assert_eq!(s.lines[0], "中文😀e\u{301}x");
        assert_eq!((s.cx, s.cy), (8, 0));
    }

    #[test]
    fn a_space_with_a_background_is_kept() {
        assert_eq!(lines(b"a\x1b[41m  \x1b[0m")[0], "a\x1b[0;41m  \x1b[0m");
    }

    #[test]
    fn hyperlinks_are_osc_8() {
        assert_eq!(lines(b"\x1b]8;;http://x\x1b\\L\x1b]8;;\x1b\\")[0], "\x1b]8;;http://x\x1b\\L\x1b]8;;\x1b\\");
    }

    #[test]
    fn a_wrapped_row_is_listed() {
        let mut e = Emu::new(4, 3);
        e.feed(b"abcdef");
        assert_eq!(e.screen().wrapped, vec![0]);
    }

    #[test]
    fn history_ends_before_rows_above_the_screen() {
        let mut e = Emu::new(10, 2);
        for i in 0..10 {
            e.feed(format!("{i}\r\n").as_bytes());
        }
        let h = e.history(0, 3);
        assert_eq!((h.lines, h.size), (vec!["6".to_string(), "7".into(), "8".into()], 9));
        assert_eq!(e.history(2, 100).lines.len(), 7);
        assert!(e.history(50, 3).lines.is_empty());
    }

    #[test]
    fn a_complete_synchronized_update_shows_at_once() {
        let mut e = Emu::new(20, 3);
        e.feed(b"\x1b[?2026hhello\x1b[?2026l");
        assert!(!e.sync_pending());
        assert_eq!(e.screen().lines[0], "hello");
    }

    #[test]
    fn an_unfinished_synchronized_update_shows_after_tick() {
        let mut e = Emu::new(20, 3);
        e.feed(b"\x1b[?2026hhello");
        assert!(e.sync_pending());
        e.tick();
        assert_eq!(e.screen().lines[0], "", "the timeout has not passed yet");
        std::thread::sleep(std::time::Duration::from_millis(200));
        e.tick();
        assert!(!e.sync_pending());
        assert_eq!(e.screen().lines[0], "hello");
    }

    #[test]
    fn tick_with_nothing_pending_changes_nothing() {
        let mut e = Emu::new(20, 3);
        e.feed(b"abc");
        let before = e.screen();
        e.tick();
        assert!(!e.sync_pending());
        assert_eq!(e.screen(), before);
    }

    #[test]
    fn modes_follow_the_program() {
        let mut e = Emu::new(10, 2);
        e.feed(b"\x1b[?1h\x1b[?2004h");
        assert_eq!(e.modes(), Modes { app_cursor: true, bracketed_paste: true });
    }

    #[test]
    fn alt_screen_cursor_and_shape() {
        let mut e = Emu::new(10, 2);
        e.feed(b"\x1b[?1049h\x1b[?25l\x1b[6 q");
        let s = e.screen();
        assert!(s.alt && !s.cursor);
        assert_eq!(s.shape, "bar");
        assert_eq!(Emu::new(10, 2).screen().shape, "");
    }
}
