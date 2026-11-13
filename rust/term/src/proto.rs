//! Wire messages: one JSON object per line, UTF-8, at most `MAX_LINE` bytes with the newline.

use crate::screen::Screen as Frame;
use serde::{Deserialize, Serialize};

pub const PROTO: u32 = 1;
pub const MAX_LINE: usize = 65536;

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Pane {
    pub id: String,
    pub window: String,
    pub title: String,
    pub command: String,
    pub cols: u16,
    pub rows: u16,
    pub dead: bool,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "t", rename_all = "snake_case")]
pub enum Out {
    Hello {
        v: u32,
        backend: String,
    },
    Panes {
        panes: Vec<Pane>,
    },
    Screen {
        pane: String,
        rev: u64,
        cols: u16,
        rows: u16,
        cx: u16,
        cy: u16,
        cursor: bool,
        alt: bool,
        full: bool,
        more: bool,
        lines: Vec<(u16, String)>,
    },
    History {
        pane: String,
        before: u32,
        lines: Vec<String>,
    },
    Pasted {
        ok: bool,
        #[serde(skip_serializing_if = "Option::is_none")]
        error: Option<String>,
    },
    Error {
        error: String,
    },
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "t", rename_all = "snake_case")]
pub enum In {
    View { pane: Option<String>, cols: u16, rows: u16 },
    Ack { rev: u64 },
    Text { pane: String, data: String, enter: bool },
    Keys { pane: String, keys: Vec<String> },
    Type { pane: String, text: String },
    History { pane: String, before: u32, lines: u32 },
    Refit { pane: String, cols: u16, rows: u16 },
}

/// One line of output, newline included.
pub fn encode(m: &Out) -> String {
    let mut s = serde_json::to_string(m).expect("wire messages always serialize");
    s.push('\n');
    s
}

/// Remove terminal escape sequences (CSI, OSC, and two-byte escapes) from a row.
fn strip_escapes(s: &str) -> String {
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

/// Encoded size of one row inside the `lines` array, comma included.
fn row_size(row: &(u16, String)) -> usize {
    serde_json::to_string(row).expect("a row always serializes").len() + 1
}

/// Make a row fit in `budget` bytes: strip escapes, then cut at a char boundary.
fn shrink_row(row: (u16, String), budget: usize) -> (u16, String) {
    let (i, text) = row;
    let text = strip_escapes(&text);
    if row_size(&(i, text.clone())) <= budget {
        return (i, text);
    }
    let mut cut = String::new();
    let mut used = row_size(&(i, String::new()));
    for c in text.chars() {
        let n = serde_json::to_string(&c.to_string()).expect("a char always serializes").len() - 2;
        if used + n > budget {
            break;
        }
        used += n;
        cut.push(c);
    }
    (i, cut)
}

/// Split one screen update into messages that each encode to at most `MAX_LINE` bytes.
/// Always returns at least one message; `more` is true on all but the last.
pub fn screen_msgs(pane: &str, rev: u64, s: &Frame, lines: Vec<(u16, String)>, full: bool) -> Vec<Out> {
    let make = |lines: Vec<(u16, String)>, more: bool| Out::Screen {
        pane: pane.to_string(),
        rev,
        cols: s.cols,
        rows: s.rows,
        cx: s.cx,
        cy: s.cy,
        cursor: s.cursor,
        alt: s.alt,
        full,
        more,
        lines,
    };
    let overhead = encode(&make(Vec::new(), true)).len();
    let budget = MAX_LINE - overhead;
    let mut groups: Vec<Vec<(u16, String)>> = vec![Vec::new()];
    let mut total = 0;
    for row in lines {
        let mut n = row_size(&row);
        let row = if n > budget {
            let r = shrink_row(row, budget);
            n = row_size(&r);
            r
        } else {
            row
        };
        if total + n > budget && !groups.last().unwrap().is_empty() {
            groups.push(Vec::new());
            total = 0;
        }
        total += n;
        groups.last_mut().unwrap().push(row);
    }
    let last = groups.len() - 1;
    groups.into_iter().enumerate().map(|(i, g)| make(g, i < last)).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn wire_shapes_are_exact() {
        assert_eq!(
            encode(&Out::Hello { v: 1, backend: "tmux".into() }),
            "{\"t\":\"hello\",\"v\":1,\"backend\":\"tmux\"}\n"
        );
        assert_eq!(encode(&Out::Pasted { ok: true, error: None }), "{\"t\":\"pasted\",\"ok\":true}\n");
        let i: In = serde_json::from_str(r#"{"t":"view","pane":"%3","cols":118,"rows":38}"#).unwrap();
        assert!(matches!(i, In::View { pane: Some(p), cols: 118, rows: 38 } if p == "%3"));
        let i: In = serde_json::from_str(r#"{"t":"view","pane":null,"cols":0,"rows":0}"#).unwrap();
        assert!(matches!(i, In::View { pane: None, .. }));
        assert!(serde_json::from_str::<In>(r#"{"t":"set_option"}"#).is_err());
    }

    #[test]
    fn big_screens_split_under_the_line_limit() {
        let s = Frame {
            cols: 500,
            rows: 200,
            cx: 0,
            cy: 0,
            cursor: true,
            alt: false,
            lines: vec!["\x1b[38;2;1;2;3mx".repeat(60); 200],
        };
        let msgs = screen_msgs("%1", 7, &s, s.changed(None), true);
        assert!(msgs.len() > 1);
        let mut seen = 0;
        for (i, m) in msgs.iter().enumerate() {
            assert!(encode(m).len() <= MAX_LINE);
            let Out::Screen { rev, more, lines, full, .. } = m else { panic!() };
            assert_eq!((*rev, *full, *more), (7, true, i + 1 < msgs.len()));
            seen += lines.len();
        }
        assert_eq!(seen, 200);
    }

    #[test]
    fn a_small_change_is_one_message() {
        let s = Frame { cols: 80, rows: 24, cx: 1, cy: 2, cursor: true, alt: false, lines: vec![String::new(); 24] };
        assert_eq!(screen_msgs("%1", 2, &s, vec![(3, "x".into())], false).len(), 1);
    }

    #[test]
    fn cursor_only_change_is_one_empty_message() {
        let s = Frame { cols: 80, rows: 24, cx: 1, cy: 2, cursor: true, alt: false, lines: vec![String::new(); 24] };
        let m = screen_msgs("%1", 2, &s, vec![], false);
        assert_eq!(m.len(), 1);
        assert!(matches!(&m[0], Out::Screen { lines, more: false, .. } if lines.is_empty()));
    }

    #[test]
    fn an_oversized_row_is_stripped_then_cut() {
        let s = Frame { cols: 80, rows: 3, cx: 0, cy: 0, cursor: true, alt: false, lines: vec![String::new(); 3] };
        // Escapes alone push the row over the limit; once stripped it fits whole.
        let esc = format!("{}ok", "\x1b[1m".repeat(20000));
        let m = screen_msgs("%1", 1, &s, vec![(0, "a".into()), (1, esc), (2, "b".into())], true);
        assert!(m.iter().all(|m| encode(m).len() <= MAX_LINE));
        let rows: Vec<_> = m
            .iter()
            .flat_map(|m| match m {
                Out::Screen { lines, .. } => lines.clone(),
                _ => vec![],
            })
            .collect();
        assert_eq!(rows.len(), 3);
        assert_eq!(rows[1], (1, "ok".to_string()));
        // Plain text too long even without escapes is cut at a char boundary.
        let long = "é\"".repeat(40000);
        let m = screen_msgs("%1", 1, &s, vec![(1, long)], true);
        assert_eq!(m.len(), 1);
        assert!(encode(&m[0]).len() <= MAX_LINE);
        let Out::Screen { lines, .. } = &m[0] else { panic!() };
        assert!(lines[0].1.starts_with("é\"") && !lines[0].1.is_empty());
    }
}
