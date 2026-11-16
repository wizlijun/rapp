//! The parts of the session protocol every backend shares: reading input lines, writing output lines, the pane
//! list and history messages, and joining a paste that comes in chunks.

use crate::proto::{self, Out, Pane};
use tokio::io::{AsyncBufRead, AsyncBufReadExt, AsyncWrite, AsyncWriteExt};

/// The most text one paste may carry, in bytes.
pub const MAX_PASTE: usize = 1_048_576;
/// A slice of scrollback: `wrapped` holds indexes into `lines` (k: row k+1 continues row k); `size` is how many rows
/// of scrollback the pane held when it was read.
#[derive(Debug, Default, PartialEq)]
pub struct HistoryRows {
    pub lines: Vec<String>,
    pub wrapped: Vec<u32>,
    pub size: u32,
}

/// The most scrollback rows one `history` call reads.
pub const MAX_HISTORY: u32 = 2000;

/// The longest `In` line accepted, newline excluded: input lines are held to `proto::MAX_LINE` like output.
/// A longer paste comes as several `Text` chunks.
pub const MAX_IN_LINE: usize = proto::MAX_LINE - 1;
/// Why a paste over `MAX_PASTE` in all was not made.
pub const TOO_LONG: &str = "text is too long (1 MiB at most)";

/// A `Panes` message that fits in one line: when the panes do not all fit, the ones at the end are left out.
pub fn panes_msg(panes: &[Pane]) -> Out {
    let mut used = proto::encode(&Out::Panes { panes: Vec::new() }).len();
    let mut keep = 0;
    for p in panes {
        // The pane and the comma before it.
        used += serde_json::to_string(p).expect("a pane always serializes").len() + 1;
        if used > proto::MAX_LINE {
            break;
        }
        keep += 1;
    }
    Out::Panes { panes: panes[..keep].to_vec() }
}

/// One line written to `w`, flushed. A message too long for one line is never written: a fixed error goes instead.
pub async fn put<W: AsyncWrite + Unpin>(w: &mut W, m: &Out) -> std::io::Result<()> {
    let mut line = proto::encode(m);
    if line.len() > proto::MAX_LINE {
        line = proto::encode(&Out::Error { error: "message too large".into() });
    }
    w.write_all(line.as_bytes()).await?;
    w.flush().await
}

/// A `History` message that fits in one line: when the rows do not all fit, the ones nearest the screen are kept
/// (the peer asks again from `before` plus what it got). A row too long for a line on its own is shrunk like a
/// screen row, so there is always at least one.
pub fn history_msg(pane: &str, before: u32, rows: HistoryRows) -> Out {
    let HistoryRows { mut lines, wrapped, size } = rows;
    // Room for every index, so cutting rows never needs a second measure.
    let mut used = proto::encode(&Out::History {
        pane: pane.to_string(),
        before,
        lines: Vec::new(),
        wrapped: wrapped.clone(),
        hist: size,
    })
    .len();
    let mut keep = lines.len();
    while keep > 0 {
        let n = serde_json::to_string(&lines[keep - 1]).expect("a string always serializes").len() + 1;
        if used + n > proto::MAX_LINE {
            break;
        }
        used += n;
        keep -= 1;
    }
    if keep > 0 && keep == lines.len() {
        let last = lines.pop().expect("there are rows");
        let lines = vec![proto::shrink_text(&last, proto::MAX_LINE - used)];
        return Out::History { pane: pane.to_string(), before, lines, wrapped: Vec::new(), hist: size };
    }
    lines.drain(..keep);
    let n = lines.len() as u32;
    let keep = keep as u32;
    let wrapped = wrapped.into_iter().filter(|&k| k >= keep && k - keep < n).map(|k| k - keep).collect();
    Out::History { pane: pane.to_string(), before, lines, wrapped, hist: size }
}

/// What reading one input line gave.
pub enum Got {
    /// A line, newline removed.
    Line(Vec<u8>),
    /// A line longer than the limit; it was read and dropped.
    TooLong,
    Eof,
}

/// Lines of `r` up to `limit` bytes each. Cancel-safe: a read cancelled half way keeps what it had, and the next
/// call goes on from there. A line over the limit is dropped as it streams past, never held whole.
pub struct Lines<R> {
    r: R,
    buf: Vec<u8>,
    limit: usize,
    /// The current line went over the limit.
    over: bool,
}

impl<R: AsyncBufRead + Unpin> Lines<R> {
    pub fn new(r: R, limit: usize) -> Lines<R> {
        Lines { r, buf: Vec::new(), limit, over: false }
    }

    pub async fn next(&mut self) -> std::io::Result<Got> {
        loop {
            // The only await; nothing is consumed or kept until it has returned.
            let chunk = self.r.fill_buf().await?;
            if chunk.is_empty() {
                if std::mem::take(&mut self.over) {
                    return Ok(Got::TooLong);
                }
                if self.buf.is_empty() {
                    return Ok(Got::Eof);
                }
                return Ok(Got::Line(std::mem::take(&mut self.buf)));
            }
            let (part, used, ends) = match chunk.iter().position(|&b| b == b'\n') {
                Some(i) => (&chunk[..i], i + 1, true),
                None => (chunk, chunk.len(), false),
            };
            if !self.over {
                if self.buf.len() + part.len() > self.limit {
                    self.over = true;
                    self.buf = Vec::new();
                } else {
                    self.buf.extend_from_slice(part);
                }
            }
            self.r.consume(used);
            if ends {
                if std::mem::take(&mut self.over) {
                    return Ok(Got::TooLong);
                }
                return Ok(Got::Line(std::mem::take(&mut self.buf)));
            }
        }
    }
}

/// What one chunk of a paste came to.
#[derive(Debug, PartialEq, Eq)]
pub enum PasteStep {
    /// More chunks are to come.
    Pending,
    /// The last chunk came: the whole text.
    Ready(String),
    /// The paste went over `MAX_PASTE`; said once, on its last chunk.
    TooLong,
    /// A chunk of a paste that is not going to be made.
    Dropped,
}

enum Held {
    Idle,
    /// The chunks so far, joined.
    Text(String),
    /// Not going to be made; the last chunk is answered with this.
    Failed(&'static str),
}

/// A paste still coming in chunks. One at a time: a chunk for another pane drops the unfinished paste.
pub struct PasteBuf {
    pane: String,
    held: Held,
}

impl Default for PasteBuf {
    fn default() -> PasteBuf {
        PasteBuf { pane: String::new(), held: Held::Idle }
    }
}

impl PasteBuf {
    /// One chunk of `pane`'s paste; `more` is whether chunks follow.
    pub fn push(&mut self, pane: &str, data: String, more: bool) -> PasteStep {
        if self.pane != pane {
            self.clear();
            self.pane = pane.to_string();
        }
        let held = match std::mem::replace(&mut self.held, Held::Idle) {
            Held::Idle if data.len() > MAX_PASTE => Held::Failed(TOO_LONG),
            Held::Idle => Held::Text(data),
            Held::Text(t) if t.len() + data.len() > MAX_PASTE => Held::Failed(TOO_LONG),
            Held::Text(mut t) => {
                t.push_str(&data);
                Held::Text(t)
            }
            failed => failed,
        };
        if more {
            let step = if matches!(held, Held::Text(_)) { PasteStep::Pending } else { PasteStep::Dropped };
            self.held = held;
            return step;
        }
        self.pane.clear();
        match held {
            Held::Text(t) => PasteStep::Ready(t),
            Held::Failed(why) if why == TOO_LONG => PasteStep::TooLong,
            _ => PasteStep::Dropped,
        }
    }

    /// Forget any paste still coming.
    pub fn clear(&mut self) {
        self.pane.clear();
        self.held = Held::Idle;
    }

    /// Why `pane`'s paste still coming is not going to be made, if it is not.
    pub fn failure(&self, pane: &str) -> Option<&'static str> {
        match self.held {
            Held::Failed(why) if self.pane == pane => Some(why),
            _ => None,
        }
    }

    /// A chunk of `pane`'s paste could not be taken. On the last chunk (`more` false) the paste is over and the
    /// reason to answer with comes back: the first one it failed for. Before it, the paste is marked failed, but
    /// only when `keep` (the pane is one the caller knows, so made-up names hold nothing).
    pub fn fail(&mut self, pane: &str, more: bool, why: &'static str, keep: bool) -> Option<&'static str> {
        let first = self.failure(pane);
        if !more {
            if self.pane == pane {
                self.clear();
            }
            return Some(first.unwrap_or(why));
        }
        if first.is_none() && keep {
            self.pane = pane.to_string();
            self.held = Held::Failed(why);
        }
        None
    }

    /// Every paste still coming fails: a line that may have been one of its chunks was lost.
    pub fn fail_all(&mut self, why: &'static str) {
        if let Held::Text(_) = self.held {
            self.held = Held::Failed(why);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;
    use tokio::io::AsyncWriteExt;

    #[test]
    fn chunks_are_joined_and_ready_on_the_last() {
        let mut p = PasteBuf::default();
        assert_eq!(p.push("%1", "ab".into(), true), PasteStep::Pending);
        assert_eq!(p.push("%1", "cd".into(), false), PasteStep::Ready("abcd".into()));
    }

    #[test]
    fn over_one_mib_fails_once_on_the_last_chunk() {
        let mut p = PasteBuf::default();
        let half = "x".repeat(MAX_PASTE / 2 + 1);
        assert_eq!(p.push("%1", half.clone(), true), PasteStep::Pending);
        assert_eq!(p.push("%1", half.clone(), true), PasteStep::Dropped);
        assert_eq!(p.push("%1", "y".into(), false), PasteStep::TooLong);
        // The next paste starts afresh.
        assert_eq!(p.push("%1", "z".into(), false), PasteStep::Ready("z".into()));
    }

    #[test]
    fn a_new_pane_drops_the_unfinished_paste() {
        let mut p = PasteBuf::default();
        p.push("%1", "ab".into(), true);
        assert_eq!(p.push("%2", "cd".into(), false), PasteStep::Ready("cd".into()));
    }

    #[test]
    fn a_failed_paste_keeps_its_first_reason() {
        let mut p = PasteBuf::default();
        p.push("%1", "ab".into(), true);
        p.fail_all("bad message");
        assert_eq!(p.failure("%1"), Some("bad message"));
        assert_eq!(p.fail("%1", true, "other", true), None);
        assert_eq!(p.fail("%1", false, "other", true), Some("bad message"));
        assert_eq!(p.failure("%1"), None);
        assert_eq!(p.fail("%9", true, "x", false), None);
        assert_eq!(p.failure("%9"), None);
    }

    #[test]
    fn the_pane_list_fits_one_line_dropping_panes_at_the_end() {
        // Control characters escape to six bytes each: 100 such panes cannot fit in 64 KiB.
        let panes: Vec<Pane> = (0..100)
            .map(|i| Pane {
                id: format!("%{i}"),
                window: "\u{1}".repeat(256),
                title: "\u{1}".repeat(256),
                command: "\u{1}".repeat(256),
                cols: 80,
                rows: 24,
                dead: false,
                win: "@0".into(),
                active: i == 0,
            })
            .collect();
        let m = panes_msg(&panes);
        assert!(proto::encode(&m).len() <= proto::MAX_LINE);
        let Out::Panes { panes: sent } = m else { panic!() };
        assert!(!sent.is_empty() && sent.len() < panes.len());
        assert_eq!(sent[..], panes[..sent.len()]);
        assert_eq!(panes_msg(&panes[..2]), Out::Panes { panes: panes[..2].to_vec() });
    }

    #[tokio::test]
    async fn no_message_is_written_over_the_line_limit() {
        let mut w: Vec<u8> = Vec::new();
        put(&mut w, &Out::Error { error: "x".repeat(70000) }).await.unwrap();
        assert_eq!(String::from_utf8(w).unwrap(), proto::encode(&Out::Error { error: "message too large".into() }));
    }

    fn line(got: Got) -> Vec<u8> {
        match got {
            Got::Line(l) => l,
            Got::TooLong => panic!("too long"),
            Got::Eof => panic!("eof"),
        }
    }

    #[tokio::test]
    async fn a_line_over_the_limit_is_dropped_and_reading_goes_on() {
        let (mut w, r) = tokio::io::duplex(8);
        let mut lines = Lines::new(tokio::io::BufReader::with_capacity(4, r), 16);
        let feed = tokio::spawn(async move {
            w.write_all(b"0123456789abcdef\n0123456789abcdefg\nok\nlast").await.unwrap();
        });
        assert_eq!(line(lines.next().await.unwrap()), b"0123456789abcdef"); // exactly the limit is fine
        assert!(matches!(lines.next().await.unwrap(), Got::TooLong));
        assert_eq!(line(lines.next().await.unwrap()), b"ok");
        feed.await.unwrap();
        assert_eq!(line(lines.next().await.unwrap()), b"last"); // a last line without a newline still counts
        assert!(matches!(lines.next().await.unwrap(), Got::Eof));
    }

    #[tokio::test]
    async fn a_cancelled_read_keeps_what_it_had_read() {
        let (mut w, r) = tokio::io::duplex(64);
        let mut lines = Lines::new(tokio::io::BufReader::new(r), 1024);
        w.write_all(b"{\"t\":\"ack\",").await.unwrap();
        assert!(tokio::time::timeout(Duration::from_millis(20), lines.next()).await.is_err());
        w.write_all(b"\"rev\":3}\n").await.unwrap();
        assert_eq!(line(lines.next().await.unwrap()), b"{\"t\":\"ack\",\"rev\":3}");
        drop(w);
        assert!(matches!(lines.next().await.unwrap(), Got::Eof));
    }

    #[test]
    fn history_is_cut_to_the_line_limit_keeping_the_rows_nearest_the_screen() {
        let rows: Vec<String> = (0..1000).map(|i| format!("{i:0>200}")).collect();
        let last = rows.len() as u32 - 1;
        let m = history_msg("%1", 5, HistoryRows { lines: rows.clone(), wrapped: vec![0, 3, last - 1], size: 9000 });
        assert!(proto::encode(&m).len() <= proto::MAX_LINE);
        let Out::History { pane, before, lines, wrapped, hist } = m else { panic!() };
        let cut = (rows.len() - lines.len()) as u32;
        assert_eq!((wrapped, hist), (vec![last - 1 - cut], 9000));
        assert_eq!((pane.as_str(), before), ("%1", 5));
        assert!(!lines.is_empty() && lines.len() < rows.len());
        assert_eq!(lines[..], rows[rows.len() - lines.len()..]);
        let two = HistoryRows { lines: vec!["a".into(), "b".into()], wrapped: vec![0], size: 2 };
        let small = history_msg("%1", 0, two);
        assert!(matches!(small, Out::History { lines, wrapped, hist: 2, .. } if lines == ["a", "b"] && wrapped == [0]));
    }

    #[test]
    fn a_single_row_over_the_line_limit_is_stripped_then_cut() {
        let row = format!("\x1b[31m{}", "é".repeat(40_000));
        let m = history_msg("%1", 0, HistoryRows { lines: vec!["before".into(), row], wrapped: vec![0], size: 2 });
        assert!(proto::encode(&m).len() <= proto::MAX_LINE);
        let Out::History { lines, .. } = m else { panic!() };
        assert_eq!(lines.len(), 1);
        assert!(lines[0].len() > 60_000 && lines[0].chars().all(|c| c == 'é'), "{}", lines[0].len());
    }
}
