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
    /// Rows of scrollback above the screen, and the most it can hold.
    pub hist: u32,
    pub limit: u32,
    /// The cursor shape the program asked for: `block`, `underline` or `bar`; empty is the terminal's own.
    pub shape: String,
    /// The rows whose next row is their own text wrapped, not a new line.
    pub wrapped: Vec<u16>,
    pub lines: Vec<String>,
}

impl Screen {
    /// Build a screen from `capture-pane -e -p` output and the `cmd::meta` line
    /// (`cursor_x cursor_y cursor_flag alternate_on pane_width pane_height history_size history_limit cursor_shape`,
    /// the last missing on a tmux without it). `wrapped` is left empty.
    pub fn from_capture(text: &str, meta: &str) -> anyhow::Result<Screen> {
        let bad = || anyhow::anyhow!("could not read the pane geometry");
        let f: Vec<&str> = meta.split_whitespace().collect();
        if f.len() != 8 && f.len() != 9 {
            return Err(bad());
        }
        let num = |s: &str| s.parse::<u16>().map_err(|_| bad());
        let big = |s: &str| s.parse::<u32>().map_err(|_| bad());
        let flag = |s: &str| match s {
            "0" => Ok(false),
            "1" => Ok(true),
            _ => Err(bad()),
        };
        let (cx, cy, cursor, alt, cols, rows) =
            (num(f[0])?, num(f[1])?, flag(f[2])?, flag(f[3])?, num(f[4])?, num(f[5])?);
        let (hist, limit) = (big(f[6])?, big(f[7])?);
        let shape = match f.get(8) {
            Some(&k @ ("block" | "underline" | "bar")) => k.to_string(),
            _ => String::new(),
        };
        let mut lines: Vec<String> = text.split('\n').map(String::from).collect();
        if lines.last().is_some_and(|l| l.is_empty()) {
            lines.pop();
        }
        lines.resize(rows as usize, String::new());
        Ok(Screen { cols, rows, cx, cy, cursor, alt, hist, limit, shape, wrapped: Vec::new(), lines })
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

/// The indexes of `rows` (a plain capture, escapes stripped) whose next row is their text wrapped, read off
/// `joined` (the same screen captured with `-J`, wrapped rows joined into one). Spaces are ignored on both sides:
/// the plain capture trims a wrapped row's trailing spaces, `-J` keeps them. So are SO and SI (0x0e, 0x0f), which
/// `-e` writes around line-drawing cells and `-J` does not. Where the two still disagree marking stops: the screen
/// changed between the captures, or tmux wrote something else into one capture and not the other.
pub fn wrapped_rows(rows: &[String], joined: &[String]) -> Vec<u16> {
    let squeeze = |s: &str| s.chars().filter(|&c| !matches!(c, ' ' | '\x0e' | '\x0f')).collect::<String>();
    let mut out = Vec::new();
    let mut i = 0;
    for line in joined {
        let line = squeeze(line);
        let mut acc = String::new();
        loop {
            let Some(row) = rows.get(i) else { return out };
            acc.push_str(&squeeze(row));
            if acc == line {
                i += 1;
                break;
            }
            if !line.starts_with(&acc) {
                return out;
            }
            out.push(i as u16);
            i += 1;
        }
    }
    out
}

/// Remove terminal escape sequences (CSI, OSC, and two-byte escapes) from a row.
pub(crate) fn strip_escapes(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut it = s.chars();
    while let Some(c) = it.next() {
        if c != '\x1b' {
            out.push(c);
            continue;
        }
        match it.next() {
            Some('[') => {
                for d in it.by_ref() {
                    if ('\u{40}'..='\u{7e}').contains(&d) {
                        break;
                    }
                }
            }
            Some(']') => {
                while let Some(d) = it.next() {
                    if d == '\x07' {
                        break;
                    }
                    if d == '\x1b' {
                        it.next();
                        break;
                    }
                }
            }
            _ => {}
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn capture_is_padded_to_the_pane_height() {
        let s = Screen::from_capture("a\n\x1b[1mb\x1b[0m\n", "3 1 1 0 80 4 0 2000").unwrap();
        assert_eq!(s.lines, ["a", "\x1b[1mb\x1b[0m", "", ""]);
        assert_eq!((s.cols, s.rows, s.cx, s.cy, s.cursor, s.alt), (80, 4, 3, 1, true, false));
    }
    #[test]
    fn changed_rows_only() {
        let a = Screen::from_capture("a\nb\nc\n", "0 0 1 0 80 3 0 2000").unwrap();
        let mut b = a.clone();
        b.lines[1] = "B".into();
        assert_eq!(b.changed(Some(&a)), [(1, "B".to_string())]);
        assert_eq!(b.changed(None).len(), 3);
        let wider = Screen::from_capture("a\nB\nc\n", "0 0 1 0 100 3 0 2000").unwrap();
        assert_eq!(wider.changed(Some(&a)).len(), 3); // a size change is a whole screen
    }
    #[test]
    fn a_bad_meta_line_is_an_error_without_screen_text() {
        let e = Screen::from_capture("secret\n", "1 2 x").unwrap_err().to_string();
        assert!(!e.contains("secret"));
        assert!(Screen::from_capture("a\n", "0 0 2 0 80 3 0 2000").is_err());
    }
    #[test]
    fn too_many_rows_are_cut() {
        let s = Screen::from_capture("a\nb\nc\n", "0 0 1 0 80 2 0 2000").unwrap();
        assert_eq!(s.lines, ["a", "b"]);
    }
    #[test]
    fn meta_reads_history_and_cursor_shape() {
        let s = Screen::from_capture("a\n", "1 0 1 0 80 2 120 2000 bar").unwrap();
        assert_eq!((s.hist, s.limit, s.shape.as_str()), (120, 2000, "bar"));
        // tmux older than cursor_shape prints nothing for it; "default" means the terminal's own: both are "".
        assert_eq!(Screen::from_capture("", "0 0 1 0 80 2 0 2000").unwrap().shape, "");
        assert_eq!(Screen::from_capture("", "0 0 1 0 80 2 0 2000 default").unwrap().shape, "");
        assert!(Screen::from_capture("", "0 0 1 0 80 2").is_err());
    }
    #[test]
    fn wrapped_rows_match_the_joined_capture() {
        let rows = ["abcdefghijklmnopqrst", "uvwxyz0123", "next", ""].map(String::from);
        let joined = ["abcdefghijklmnopqrstuvwxyz0123", "next", ""].map(String::from);
        assert_eq!(wrapped_rows(&rows, &joined), vec![0]);
        // a wrapped row ending in spaces: plain capture trims them, -J keeps them
        let rows = ["ab", "cd"].map(String::from);
        assert_eq!(wrapped_rows(&rows, &["ab   cd".to_string()]), vec![0]);
        // line drawing: -e wraps it in SO/SI, -J does not
        assert_eq!(wrapped_rows(&["ab\x0eqq".into(), "q\x0fcd".into()], &["abqqqcd".into()]), vec![0]);
        // the two captures disagree (the screen changed between them): no flags from there on, no panic
        let rows = ["x", "y", "z"].map(String::from);
        assert_eq!(wrapped_rows(&rows, &["other".to_string()]), Vec::<u16>::new());
    }
}
