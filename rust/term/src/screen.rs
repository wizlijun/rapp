//! One screen of a pane: its rows with their colour escapes, plus the cursor.

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

    fn screen(cols: u16, lines: &[&str]) -> Screen {
        Screen {
            cols,
            rows: lines.len() as u16,
            cx: 0,
            cy: 0,
            cursor: true,
            alt: false,
            hist: 0,
            limit: 2000,
            shape: String::new(),
            wrapped: Vec::new(),
            lines: lines.iter().map(|l| l.to_string()).collect(),
        }
    }

    #[test]
    fn changed_rows_only() {
        let a = screen(80, &["a", "b", "c"]);
        let mut b = a.clone();
        b.lines[1] = "B".into();
        assert_eq!(b.changed(Some(&a)), [(1, "B".to_string())]);
        assert_eq!(b.changed(None).len(), 3);
        let wider = screen(100, &["a", "B", "c"]);
        assert_eq!(wider.changed(Some(&a)).len(), 3); // a size change is a whole screen
    }

    #[test]
    fn escapes_are_stripped() {
        assert_eq!(strip_escapes("\x1b[1mb\x1b[0m\x1b]0;title\x07c"), "bc");
    }
}
