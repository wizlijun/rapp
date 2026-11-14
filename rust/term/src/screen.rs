//! One screen of a pane: its rows as `capture-pane -e` printed them, plus the cursor.

/// A pane's visible screen. Rows keep their colour escapes; they are never parsed here.
#[derive(Clone, Debug, PartialEq)]
pub struct Screen {
    pub cols: u16,
    pub rows: u16,
    pub cx: u16,
    pub cy: u16,
    pub cursor: bool,
    pub alt: bool,
    pub lines: Vec<String>,
}

impl Screen {
    /// Build a screen from `capture-pane -e -p` output and the `cmd::meta` line
    /// (`cursor_x cursor_y cursor_flag alternate_on pane_width pane_height`).
    pub fn from_capture(text: &str, meta: &str) -> anyhow::Result<Screen> {
        let bad = || anyhow::anyhow!("could not read the pane geometry");
        let f: Vec<&str> = meta.split_whitespace().collect();
        if f.len() != 6 {
            return Err(bad());
        }
        let num = |s: &str| s.parse::<u16>().map_err(|_| bad());
        let flag = |s: &str| match s {
            "0" => Ok(false),
            "1" => Ok(true),
            _ => Err(bad()),
        };
        let (cx, cy, cursor, alt, cols, rows) =
            (num(f[0])?, num(f[1])?, flag(f[2])?, flag(f[3])?, num(f[4])?, num(f[5])?);
        let mut lines: Vec<String> = text.split('\n').map(String::from).collect();
        if lines.last().is_some_and(|l| l.is_empty()) {
            lines.pop();
        }
        lines.resize(rows as usize, String::new());
        Ok(Screen { cols, rows, cx, cy, cursor, alt, lines })
    }

    /// The rows that differ from `prev`; every row when there is no previous screen or the size changed.
    pub fn changed(&self, prev: Option<&Screen>) -> Vec<(u16, String)> {
        let same_size = prev.filter(|p| p.cols == self.cols && p.rows == self.rows);
        self.lines
            .iter()
            .enumerate()
            .filter(|(i, l)| same_size.is_none_or(|p| p.lines.get(*i) != Some(*l)))
            .map(|(i, l)| (i as u16, l.clone()))
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn capture_is_padded_to_the_pane_height() {
        let s = Screen::from_capture("a\n\x1b[1mb\x1b[0m\n", "3 1 1 0 80 4").unwrap();
        assert_eq!(s.lines, ["a", "\x1b[1mb\x1b[0m", "", ""]);
        assert_eq!((s.cols, s.rows, s.cx, s.cy, s.cursor, s.alt), (80, 4, 3, 1, true, false));
    }
    #[test]
    fn changed_rows_only() {
        let a = Screen::from_capture("a\nb\nc\n", "0 0 1 0 80 3").unwrap();
        let mut b = a.clone();
        b.lines[1] = "B".into();
        assert_eq!(b.changed(Some(&a)), [(1, "B".to_string())]);
        assert_eq!(b.changed(None).len(), 3);
        let wider = Screen::from_capture("a\nB\nc\n", "0 0 1 0 100 3").unwrap();
        assert_eq!(wider.changed(Some(&a)).len(), 3); // a size change is a whole screen
    }
    #[test]
    fn a_bad_meta_line_is_an_error_without_screen_text() {
        let e = Screen::from_capture("secret\n", "1 2 x").unwrap_err().to_string();
        assert!(!e.contains("secret"));
        assert!(Screen::from_capture("a\n", "0 0 2 0 80 3").is_err());
    }
    #[test]
    fn too_many_rows_are_cut() {
        let s = Screen::from_capture("a\nb\nc\n", "0 0 1 0 80 2").unwrap();
        assert_eq!(s.lines, ["a", "b"]);
    }
}
