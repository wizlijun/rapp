//! Wire messages: one JSON object per line, UTF-8, at most `MAX_LINE` bytes with the newline.

use crate::screen::{strip_escapes, Screen as Frame};
use serde::{Deserialize, Serialize};

pub const PROTO: u32 = 2;
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
    /// The tmux window id (`@7`) the pane is in.
    #[serde(default)]
    pub win: String,
    /// The window is its session's current window and the pane is its window's current pane.
    #[serde(default)]
    pub active: bool,
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
        /// Rows of scrollback above the screen and the most it holds; 0 from a peer that does not send them.
        #[serde(default)]
        hist: u32,
        #[serde(default)]
        limit: u32,
        /// `block`, `underline` or `bar`; absent is the terminal's own.
        #[serde(default, skip_serializing_if = "String::is_empty")]
        shape: String,
        /// The whole screen's rows whose next row is their text wrapped, in every part of a split update.
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        wrapped: Vec<u16>,
        full: bool,
        more: bool,
        lines: Vec<(u16, String)>,
    },
    History {
        pane: String,
        before: u32,
        lines: Vec<String>,
        /// Indexes into `lines` of rows whose next row continues them.
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        wrapped: Vec<u32>,
        /// How many rows of scrollback the pane held when this was read.
        #[serde(default)]
        hist: u32,
    },
    Pasted {
        ok: bool,
        #[serde(skip_serializing_if = "Option::is_none")]
        error: Option<String>,
    },
    /// A window made by `In::NewWindow`: its pane.
    WindowOpened {
        pane: String,
    },
    Error {
        error: String,
    },
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "t", rename_all = "snake_case")]
pub enum In {
    View {
        pane: Option<String>,
        cols: u16,
        rows: u16,
    },
    Ack {
        rev: u64,
    },
    /// Part of a paste: `more` on every chunk but the last, which carries the paste's `enter`.
    Text {
        pane: String,
        data: String,
        enter: bool,
        #[serde(default)]
        more: bool,
    },
    Keys {
        pane: String,
        keys: Vec<String>,
    },
    Type {
        pane: String,
        text: String,
    },
    History {
        pane: String,
        before: u32,
        lines: u32,
    },
    /// Open a new window beside `pane`'s, in its directory, without switching to it.
    NewWindow {
        pane: String,
    },
    Refit {
        pane: String,
        cols: u16,
        rows: u16,
    },
}

/// One line of output, newline included.
pub fn encode(m: &Out) -> String {
    let mut s = serde_json::to_string(m).expect("wire messages always serialize");
    s.push('\n');
    s
}

/// Encoded size of one row inside the `lines` array, comma included.
fn row_size(row: &(u16, String)) -> usize {
    serde_json::to_string(row).expect("a row always serializes").len() + 1
}

/// Make a row fit in `budget` bytes: strip escapes, then cut at a char boundary.
fn shrink_row(row: (u16, String), budget: usize) -> (u16, String) {
    let (i, text) = row;
    // What the row costs besides its text's encoding (quotes included).
    let around = row_size(&(i, String::new())) - 2;
    (i, shrink_text(&text, budget.saturating_sub(around)))
}

/// Make `text` encode (as a JSON string, quotes included) in at most `budget` bytes: strip escapes, then cut at
/// a char boundary.
pub(crate) fn shrink_text(text: &str, budget: usize) -> String {
    let text = strip_escapes(text);
    if serde_json::to_string(&text).expect("a string always serializes").len() <= budget {
        return text;
    }
    let mut cut = String::new();
    let mut used = 2;
    for c in text.chars() {
        let n = serde_json::to_string(&c.to_string()).expect("a char always serializes").len() - 2;
        if used + n > budget {
            break;
        }
        used += n;
        cut.push(c);
    }
    cut
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
        hist: s.hist,
        limit: s.limit,
        shape: s.shape.clone(),
        wrapped: s.wrapped.clone(),
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

    fn frame(cols: u16, rows: u16, lines: Vec<String>) -> Frame {
        Frame {
            cols,
            rows,
            cx: 0,
            cy: 0,
            cursor: true,
            alt: false,
            hist: 0,
            limit: 0,
            shape: String::new(),
            wrapped: Vec::new(),
            lines,
        }
    }

    #[test]
    fn pane_without_new_fields_still_parses() {
        let p: Pane = serde_json::from_str(
            r#"{"id":"%1","window":"w","title":"","command":"sh","cols":80,"rows":24,"dead":false}"#,
        )
        .unwrap();
        assert_eq!((p.win.as_str(), p.active), ("", false));
    }

    #[test]
    fn wire_shapes_are_exact() {
        assert_eq!(
            encode(&Out::Hello { v: 2, backend: "tmux".into() }),
            "{\"t\":\"hello\",\"v\":2,\"backend\":\"tmux\"}\n"
        );
        assert_eq!(encode(&Out::Pasted { ok: true, error: None }), "{\"t\":\"pasted\",\"ok\":true}\n");
        assert_eq!(
            encode(&Out::WindowOpened { pane: "%7".into() }),
            "{\"t\":\"window_opened\",\"pane\":\"%7\"}\n"
        );
        let i: In = serde_json::from_str(r#"{"t":"new_window","pane":"%3"}"#).unwrap();
        assert!(matches!(i, In::NewWindow { pane } if pane == "%3"));
        let i: In = serde_json::from_str(r#"{"t":"view","pane":"%3","cols":118,"rows":38}"#).unwrap();
        assert!(matches!(i, In::View { pane: Some(p), cols: 118, rows: 38 } if p == "%3"));
        let i: In = serde_json::from_str(r#"{"t":"view","pane":null,"cols":0,"rows":0}"#).unwrap();
        assert!(matches!(i, In::View { pane: None, .. }));
        assert!(serde_json::from_str::<In>(r#"{"t":"set_option"}"#).is_err());
        let i: In = serde_json::from_str(r#"{"t":"text","pane":"%1","data":"a","enter":true}"#).unwrap();
        assert!(matches!(i, In::Text { more: false, enter: true, .. })); // one chunk: the whole paste
        let i: In = serde_json::from_str(r#"{"t":"text","pane":"%1","data":"a","enter":false,"more":true}"#).unwrap();
        assert!(matches!(i, In::Text { more: true, .. }));
    }

    #[test]
    fn big_screens_split_under_the_line_limit() {
        let s = frame(500, 200, vec!["\x1b[38;2;1;2;3mx".repeat(60); 200]);
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
        let s = frame(80, 24, vec![String::new(); 24]);
        assert_eq!(screen_msgs("%1", 2, &s, vec![(3, "x".into())], false).len(), 1);
    }

    #[test]
    fn cursor_only_change_is_one_empty_message() {
        let s = frame(80, 24, vec![String::new(); 24]);
        let m = screen_msgs("%1", 2, &s, vec![], false);
        assert_eq!(m.len(), 1);
        assert!(matches!(&m[0], Out::Screen { lines, more: false, .. } if lines.is_empty()));
    }

    #[test]
    fn an_oversized_row_is_stripped_then_cut() {
        let s = frame(80, 3, vec![String::new(); 3]);
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

    #[test]
    fn screen_parts_all_carry_hist_shape_and_wrapped() {
        let mut s = frame(500, 200, vec!["\x1b[38;2;1;2;3mx".repeat(60); 200]);
        (s.hist, s.limit, s.shape, s.wrapped) = (120, 2000, "bar".into(), vec![0, 7, 150]);
        let msgs = screen_msgs("%1", 3, &s, s.changed(None), true);
        assert!(msgs.len() > 1);
        for m in &msgs {
            assert!(encode(m).len() <= MAX_LINE);
            let Out::Screen { hist, limit, shape, wrapped, .. } = m else { panic!() };
            assert_eq!((*hist, *limit, shape, wrapped), (s.hist, s.limit, &s.shape, &s.wrapped));
        }
        let plain = frame(80, 3, vec![String::new(); 3]);
        let line = encode(&screen_msgs("%1", 1, &plain, vec![], false)[0]);
        assert!(line.contains("\"hist\":0") && line.contains("\"limit\":0"));
        assert!(!line.contains("\"shape\"") && !line.contains("\"wrapped\""));
    }
}
