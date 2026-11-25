//! OSC 7501 program-status scanner.
//!
//! The state machine is ported from gascity `internal/runtime/programstatus/scanner.go`
//! (MIT, Copyright (c) 2026 Gas City Contributors, commit
//! 0997336456fe67f0315d9e41dabc7167e74c2fa9), without the tmux passthrough
//! unwrapping: any DCS is skipped whole, up to its `ESC \`.
//!
//! `parse` and `Records` are ported from zellij
//! `zellij-server/src/attention/program_status.rs` (MIT, Copyright (c) 2020
//! Zellij contributors, commit d73e7d5bf0ae58a13cee11ede9bab0fa141de7b6) and
//! gascity `internal/runtime/programstatus/parse.go`.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

use base64::alphabet::STANDARD as BASE64_STANDARD_ALPHABET;
use base64::engine::general_purpose::{GeneralPurpose, GeneralPurposeConfig};
use base64::engine::{DecodePaddingMode, Engine as _};

/// Longest accepted sequence, `ESC ]` and terminator included.
pub const MAX_SEQUENCE: usize = 4096;

const OSC_INTRO: usize = 2; // ESC ]
const BEL_LEN: usize = 1;
const ST_LEN: usize = 2; // ESC \
const MAX_BUFFER: usize = MAX_SEQUENCE - OSC_INTRO - BEL_LEN;
const P7501: &[u8] = b"7501;";
const P133A: &[u8] = b"133;A";

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Event {
    /// `ESC ] 7501 ; ?`
    Probe,
    /// Text between `ESC ] 7501 ;` and the terminator.
    Report(String),
    /// `OSC 133;A`, a shell prompt start.
    Prompt,
}

#[derive(Default, Clone, Copy, PartialEq, Eq)]
enum Mode {
    #[default]
    Ground,
    Esc,
    Osc,
    OscEsc,
    Dcs,
    DcsEsc,
}

#[derive(Default, Clone, Copy, PartialEq, Eq)]
enum Kind {
    #[default]
    Pending,
    Is7501,
    Prompt,
    Skip,
}

#[derive(Default)]
pub struct Scanner {
    state: Mode,
    kind: Kind,
    buf: Vec<u8>,
}

impl Scanner {
    pub fn feed(&mut self, bytes: &[u8], mut emit: impl FnMut(Event)) {
        for &c in bytes {
            self.step(c, &mut emit);
        }
    }

    fn step(&mut self, c: u8, emit: &mut impl FnMut(Event)) {
        match self.state {
            Mode::Ground => {
                if c == 0x1b {
                    self.state = Mode::Esc;
                }
            }
            Mode::Esc => self.escape(c),
            Mode::Osc => match c {
                0x07 => self.finish(BEL_LEN, emit),
                0x1b => self.state = Mode::OscEsc,
                0x18 | 0x1a => self.state = Mode::Ground,
                _ => self.osc_byte(c),
            },
            Mode::OscEsc => {
                if c == b'\\' {
                    self.finish(ST_LEN, emit);
                } else {
                    self.escape(c); // the interrupting escape starts anew
                }
            }
            Mode::Dcs => {
                if c == 0x1b {
                    self.state = Mode::DcsEsc;
                }
            }
            Mode::DcsEsc => {
                self.state = if c == b'\\' { Mode::Ground } else { Mode::Dcs };
            }
        }
    }

    fn escape(&mut self, c: u8) {
        match c {
            b']' => {
                self.state = Mode::Osc;
                self.kind = Kind::Pending;
                self.buf.clear();
            }
            b'P' => self.state = Mode::Dcs,
            0x1b => self.state = Mode::Esc,
            _ => self.state = Mode::Ground,
        }
    }

    fn osc_byte(&mut self, c: u8) {
        match self.kind {
            Kind::Skip | Kind::Prompt => return,
            Kind::Is7501 => {
                if self.buf.len() >= MAX_BUFFER {
                    self.kind = Kind::Skip;
                    self.buf.clear();
                } else {
                    self.buf.push(c);
                }
                return;
            }
            Kind::Pending => {}
        }
        self.buf.push(c);
        let b = self.buf.as_slice();
        if b == P7501 {
            self.kind = Kind::Is7501;
        } else if b == b"133;A;" {
            self.kind = Kind::Prompt;
        } else if !(P7501.starts_with(b) || P133A.starts_with(b)) {
            self.kind = Kind::Skip;
        }
    }

    fn finish(&mut self, term_len: usize, emit: &mut impl FnMut(Event)) {
        self.state = Mode::Ground;
        match self.kind {
            Kind::Prompt => emit(Event::Prompt),
            Kind::Pending if self.buf == P133A => emit(Event::Prompt),
            Kind::Is7501 => {
                if OSC_INTRO + self.buf.len() + term_len > MAX_SEQUENCE {
                    return;
                }
                let body = &self.buf[P7501.len()..];
                if body == b"?" {
                    emit(Event::Probe);
                } else {
                    emit(Event::Report(String::from_utf8_lossy(body).into_owned()));
                }
            }
            _ => {}
        }
    }
}

const MAX_KEY: usize = 16;
const MAX_APP: usize = 32;
const MAX_ID: usize = 128;
const MAX_ID_SEGMENT: usize = 32;
const MAX_ID_DEPTH: usize = 8;
const MAX_MSG_ENCODED: usize = 2732;
const MAX_MSG_DECODED: usize = 2048;
const MAX_TITLE_ENCODED: usize = 256;
const MAX_TITLE_DECODED: usize = 192;
const MAX_RECORDS: usize = 256;

const BASE64: GeneralPurpose = GeneralPurpose::new(
    &BASE64_STANDARD_ALPHABET,
    GeneralPurposeConfig::new().with_decode_padding_mode(DecodePaddingMode::Indifferent),
);

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum State {
    Idle,
    Working,
    Done,
    Blocked,
    Error,
}

impl State {
    pub fn as_str(self) -> &'static str {
        match self {
            State::Idle => "idle",
            State::Working => "working",
            State::Done => "done",
            State::Blocked => "blocked",
            State::Error => "error",
        }
    }

    pub fn is_transient(self) -> bool {
        matches!(self, State::Idle | State::Working | State::Blocked)
    }

    fn parse(s: &str) -> Option<State> {
        Some(match s {
            "idle" => State::Idle,
            "working" => State::Working,
            "done" => State::Done,
            "blocked" => State::Blocked,
            "error" => State::Error,
            _ => return None,
        })
    }

    fn rank(self) -> u8 {
        match self {
            State::Idle => 0,
            State::Working => 1,
            State::Done => 2,
            State::Error => 3,
            State::Blocked => 4,
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct Record {
    pub id: Option<String>,
    pub state: State,
    /// permission | question | auth, only on `Blocked`.
    pub kind: Option<String>,
    pub app: Option<String>,
    pub title: Option<String>,
    pub msg: Option<String>,
    pub progress: Option<u8>,
}

#[derive(Clone, Debug, PartialEq)]
pub enum Message {
    Set(Record),
    Clear { id: Option<String> },
}

fn is_value_byte(b: u8) -> bool {
    b.is_ascii_alphanumeric() || matches!(b, b'_' | b'.' | b',' | b'+' | b'/' | b'=' | b'-')
}

fn is_app_byte(b: u8) -> bool {
    b.is_ascii_alphanumeric() || matches!(b, b'_' | b'.' | b'+' | b'-')
}

fn valid_id(id: &str) -> bool {
    if id.is_empty() || id.len() > MAX_ID {
        return false;
    }
    let segments: Vec<&str> = id.split('/').collect();
    segments.len() <= MAX_ID_DEPTH
        && segments
            .iter()
            .all(|s| !s.is_empty() && s.len() <= MAX_ID_SEGMENT && s.bytes().all(is_app_byte))
}

fn invisible(c: char) -> bool {
    let n = c as u32;
    n == 0x061c
        || (0x200b..=0x200f).contains(&n)
        || (0x202a..=0x202e).contains(&n)
        || (0x2060..=0x2069).contains(&n)
        || n == 0xfeff
}

/// Decode a base64 text field. `Err` drops the whole report.
fn decode_text(value: &str, max_encoded: usize, max_decoded: usize) -> Result<Option<String>, ()> {
    if value.len() > max_encoded {
        return Err(());
    }
    if value.is_empty() {
        return Ok(None);
    }
    let bytes = BASE64.decode(value.as_bytes()).map_err(|_| ())?;
    if bytes.len() > max_decoded {
        return Err(());
    }
    let text = String::from_utf8(bytes).map_err(|_| ())?;
    if text.chars().any(|c| {
        let n = c as u32;
        n < 0x20 || (0x7f..=0x9f).contains(&n)
    }) {
        return Err(());
    }
    let text: String = text.chars().filter(|&c| !invisible(c)).collect();
    Ok(if text.is_empty() { None } else { Some(text) })
}

/// Parse one OSC 7501 report body (the text after `7501;`). `None` drops it.
pub fn parse(body: &str) -> Option<Message> {
    let mut pairs: BTreeMap<&str, &str> = BTreeMap::new();
    for pair in body.split(':') {
        let Some((key, value)) = pair.split_once('=') else {
            continue;
        };
        let (key, value) = (key.trim(), value.trim());
        if key.is_empty() || !key.bytes().all(|b| b.is_ascii_lowercase()) {
            continue;
        }
        if key.len() > MAX_KEY {
            return None;
        }
        if !value.bytes().all(is_value_byte) {
            continue;
        }
        pairs.insert(key, value);
    }
    let state_value = *pairs.get("state")?;
    let state = if state_value == "clear" { None } else { Some(State::parse(state_value)?) };
    let id = match pairs.get("id") {
        Some(id) if valid_id(id) => Some((*id).to_owned()),
        Some(_) => return None,
        None => None,
    };
    let app = match pairs.get("app") {
        Some(app) if app.len() > MAX_APP => return None,
        Some(app) if !app.is_empty() && app.bytes().all(is_app_byte) => Some((*app).to_owned()),
        _ => None,
    };
    let title = match pairs.get("title") {
        Some(t) => decode_text(t, MAX_TITLE_ENCODED, MAX_TITLE_DECODED).ok()?,
        None => None,
    };
    let msg = match pairs.get("msg") {
        Some(m) => decode_text(m, MAX_MSG_ENCODED, MAX_MSG_DECODED).ok()?,
        None => None,
    };
    let Some(state) = state else {
        return Some(Message::Clear { id });
    };
    let kind = if state == State::Blocked {
        pairs
            .get("kind")
            .filter(|k| matches!(**k, "permission" | "question" | "auth"))
            .map(|k| (*k).to_owned())
    } else {
        None
    };
    let progress = if matches!(state, State::Working | State::Blocked) {
        pairs
            .get("progress")
            .filter(|p| !p.is_empty() && p.bytes().all(|b| b.is_ascii_digit()))
            .filter(|p| p.len() == 1 || !p.starts_with('0'))
            .and_then(|p| p.parse::<u32>().ok())
            .filter(|p| *p <= 100)
            .map(|p| p as u8)
    } else {
        None
    };
    Some(Message::Set(Record { id, state, kind, app, title, msg, progress }))
}

#[derive(Default)]
pub struct Records {
    records: BTreeMap<String, (u64, Record)>,
    sequence: u64,
}

impl Records {
    /// Returns true when the table changed.
    pub fn apply(&mut self, m: Message) -> bool {
        match m {
            Message::Clear { id: None } => {
                let changed = !self.records.is_empty();
                self.records.clear();
                changed
            }
            Message::Clear { id: Some(id) } => {
                let prefix = format!("{id}/");
                let before = self.records.len();
                self.records.retain(|k, _| k != &id && !k.starts_with(&prefix));
                before != self.records.len()
            }
            Message::Set(record) => {
                let key = record.id.clone().unwrap_or_default();
                if !self.records.contains_key(&key) && self.records.len() >= MAX_RECORDS {
                    if let Some(oldest) =
                        self.records.iter().min_by_key(|(_, (seq, _))| *seq).map(|(k, _)| k.clone())
                    {
                        self.records.remove(&oldest);
                    }
                }
                self.sequence += 1;
                let changed = self.records.get(&key).map(|(_, old)| old != &record).unwrap_or(true);
                self.records.insert(key, (self.sequence, record));
                changed
            }
        }
    }

    /// Drop idle, working and blocked records; done and error stay.
    pub fn drop_transient(&mut self) -> bool {
        let before = self.records.len();
        self.records.retain(|_, (_, r)| !r.state.is_transient());
        before != self.records.len()
    }

    /// The root record, raised by a blocked or error child; `app` is inherited
    /// from the nearest ancestor when empty.
    pub fn deciding(&self) -> Option<Record> {
        let mut best = self.records.get("").map(|(_, r)| r.clone());
        for (key, (_, r)) in &self.records {
            if key.is_empty() || !matches!(r.state, State::Blocked | State::Error) {
                continue;
            }
            if best.as_ref().is_none_or(|b| r.state.rank() > b.state.rank()) {
                best = Some(r.clone());
            }
        }
        best.map(|mut r| {
            if r.app.is_none() {
                r.app = self.inherited_app(r.id.as_deref());
            }
            r
        })
    }

    /// Number of records with an id.
    pub fn children(&self) -> usize {
        self.records.keys().filter(|k| !k.is_empty()).count()
    }

    fn inherited_app(&self, id: Option<&str>) -> Option<String> {
        let mut cur = id?;
        loop {
            let parent = cur.rsplit_once('/').map(|(p, _)| p).unwrap_or("");
            if let Some((_, r)) = self.records.get(parent) {
                if r.app.is_some() {
                    return r.app.clone();
                }
            }
            if parent.is_empty() {
                return None;
            }
            cur = parent;
        }
    }

    #[cfg(test)]
    fn get(&self, id: &str) -> Option<&Record> {
        self.records.get(id).map(|(_, r)| r)
    }
}

#[cfg(test)]
pub(crate) fn capture(name: &str) -> (Vec<u8>, Vec<usize>) {
    let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("testdata/ps");
    let data = std::fs::read(dir.join(format!("{name}.bin"))).unwrap();
    let reads: Vec<usize> = std::fs::read_to_string(dir.join(format!("{name}.reads")))
        .unwrap()
        .split_whitespace()
        .map(|s| s.parse().unwrap())
        .collect();
    assert_eq!(reads.iter().sum::<usize>(), data.len(), "{name}");
    (data, reads)
}

#[cfg(test)]
pub(crate) fn chunks(name: &str) -> Vec<Vec<u8>> {
    let (data, reads) = capture(name);
    let mut at = 0;
    reads
        .iter()
        .map(|&n| {
            at += n;
            data[at - n..at].to_vec()
        })
        .collect()
}

/// At most this many chars of `msg` go into a snapshot; a longer one is cut and gets `…`.
pub const MSG_CHARS: usize = 200;

/// The program's status as the session list shows it.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct Ps {
    /// idle | working | done | blocked | error
    pub state: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub kind: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub app: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub msg: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub progress: Option<u8>,
    /// The Unix second this `state` began.
    pub since: u64,
    /// The Unix second the program last stopped (working or blocked to done, error or idle); 0 if never.
    pub stopped: u64,
    /// Goes up by one whenever the snapshot changes.
    pub seq: u64,
}

/// What one `Tracker::feed` saw.
pub struct Fed {
    pub probes: usize,
    pub changed: bool,
}

#[derive(Default)]
pub struct Tracker {
    scanner: Scanner,
    records: Records,
    ps: Option<Ps>,
    seq: u64,
    stopped: u64,
}

fn cut(msg: String) -> String {
    match msg.char_indices().nth(MSG_CHARS) {
        Some((i, _)) => format!("{}…", &msg[..i]),
        None => msg,
    }
}

impl Tracker {
    pub fn feed(&mut self, bytes: &[u8], now: u64) -> Fed {
        let mut events = Vec::new();
        self.scanner.feed(bytes, |e| events.push(e));
        let mut probes = 0;
        let mut stopped_changed = false;
        let mut prev = self.records.deciding().map(|r| r.state);
        for e in events {
            match e {
                Event::Probe => probes += 1,
                Event::Report(body) => {
                    if let Some(m) = parse(&body) {
                        self.records.apply(m);
                    }
                }
                Event::Prompt => {
                    self.records.drop_transient();
                }
            }
            let cur = self.records.deciding().map(|r| r.state);
            if matches!(prev, Some(State::Working | State::Blocked))
                && matches!(cur, Some(State::Done | State::Error | State::Idle))
            {
                self.stopped = now;
                stopped_changed = true;
            }
            prev = cur;
        }
        let next = self.records.deciding().map(|r| Ps {
            state: r.state.as_str().to_string(),
            kind: r.kind,
            app: r.app,
            msg: r.msg.map(cut),
            progress: r.progress,
            since: now,
            stopped: self.stopped,
            seq: self.seq,
        });
        let mut changed = stopped_changed;
        let next = match (next, self.ps.take()) {
            (None, old) => {
                if old.is_some() {
                    self.seq += 1;
                    changed = true;
                }
                None
            }
            (Some(mut n), None) => {
                self.seq += 1;
                n.seq = self.seq;
                changed = true;
                Some(n)
            }
            (Some(mut n), Some(old)) => {
                if n.state == old.state {
                    n.since = old.since;
                }
                let same = n.state == old.state
                    && n.kind == old.kind
                    && n.app == old.app
                    && n.msg == old.msg
                    && n.progress == old.progress;
                if !same || stopped_changed {
                    self.seq += 1;
                    changed = true;
                }
                n.seq = self.seq;
                Some(n)
            }
        };
        self.ps = next;
        Fed { probes, changed }
    }

    pub fn ps(&self) -> Option<&Ps> {
        self.ps.as_ref()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn b64(s: &str) -> String {
        base64::engine::general_purpose::STANDARD.encode(s)
    }
    fn rep(body: &str) -> Vec<u8> {
        format!("\x1b]7501;{body}\x07").into_bytes()
    }

    #[test]
    fn tracker_snapshot_since_stopped_seq() {
        let mut t = Tracker::default();
        assert!(!t.feed(b"plain text", 100).changed);
        assert!(t.ps().is_none());
        let f = t.feed(&rep("state=working:app=codex"), 100);
        assert!(f.changed);
        assert_eq!(t.ps().map(|p| (p.state.as_str(), p.since, p.stopped, p.seq)), Some(("working", 100, 0, 1)));
        assert!(!t.feed(&rep("state=working:app=codex"), 105).changed);
        t.feed(&rep("state=blocked:kind=permission:app=codex"), 110);
        assert_eq!(t.ps().map(|p| (p.kind.as_deref(), p.since, p.seq)), Some((Some("permission"), 110, 2)));
        t.feed(&rep("state=done:app=codex"), 120);
        assert_eq!(t.ps().map(|p| (p.since, p.stopped, p.seq)), Some((120, 120, 3)));
    }
    #[test]
    fn tracker_one_chunk_working_then_done_still_stops() {
        let mut t = Tracker::default();
        let mut b = rep("state=working");
        b.extend(rep("state=done"));
        t.feed(&b, 50);
        assert_eq!(t.ps().map(|p| (p.state.as_str(), p.stopped, p.seq)), Some(("done", 50, 1)));
    }
    #[test]
    fn tracker_idle_at_start_is_not_a_stop() {
        let mut t = Tracker::default();
        t.feed(&rep("state=idle"), 10);
        assert_eq!(t.ps().unwrap().stopped, 0);
    }
    #[test]
    fn tracker_counts_probes_and_clear_empties() {
        let mut t = Tracker::default();
        assert_eq!(t.feed(b"\x1b]7501;?\x07\x1b]7501;?\x1b\\", 1).probes, 2);
        t.feed(&rep("state=working"), 2);
        t.feed(&rep("state=clear"), 3);
        assert!(t.ps().is_none());
        t.feed(&rep("state=working"), 4);
        assert_eq!(t.ps().unwrap().seq, 3);
    }
    #[test]
    fn tracker_prompt_drops_blocked() {
        let mut t = Tracker::default();
        t.feed(&rep("state=blocked:kind=question"), 1);
        t.feed(b"\x1b]133;A\x07", 2);
        assert!(t.ps().is_none());
    }
    #[test]
    fn msg_is_cut_to_200_chars() {
        let mut t = Tracker::default();
        let long = "问".repeat(150) + &"😀".repeat(150);
        t.feed(&rep(&format!("state=done:msg={}", b64(&long))), 1);
        let m = t.ps().unwrap().msg.clone().unwrap();
        assert_eq!(m.chars().count(), 201);
        assert!(m.ends_with('…') && m.starts_with(&"问".repeat(150)));
    }

    fn events(chunks: &[&[u8]]) -> Vec<String> {
        let mut s = Scanner::default();
        let mut out = Vec::new();
        for c in chunks {
            s.feed(c, |e| {
                out.push(match e {
                    Event::Probe => "probe".to_string(),
                    Event::Prompt => "prompt".to_string(),
                    Event::Report(b) => format!("report:{b}"),
                })
            });
        }
        out
    }

    #[test]
    fn probe_with_bel_or_st() {
        assert_eq!(events(&[b"\x1b]7501;?\x07"]), ["probe"]);
        assert_eq!(events(&[b"\x1b]7501;?\x1b\\"]), ["probe"]);
    }

    #[test]
    fn report_body_and_prompt() {
        assert_eq!(
            events(&[b"a\x1b]7501;state=working\x07b\x1b]133;A\x07"]),
            ["report:state=working", "prompt"]
        );
        assert_eq!(events(&[b"\x1b]133;A;k=v\x1b\\"]), ["prompt"]);
    }

    #[test]
    fn every_split_gives_the_same_events() {
        let whole = b"x\x1b]7501;state=blocked:kind=question:msg=QWxsb3c=\x1b\\y\x1b]7501;?\x07";
        let want = events(&[whole]);
        assert_eq!(want.len(), 2);
        for i in 0..=whole.len() {
            assert_eq!(events(&[&whole[..i], &whole[i..]]), want, "split at {i}");
        }
        let bytes: Vec<&[u8]> = whole.chunks(1).collect();
        assert_eq!(events(&bytes), want);
    }

    #[test]
    fn esc_can_sub_abandon_a_sequence() {
        assert_eq!(events(&[b"\x1b]7501;state=working\x1b[0m\x1b]7501;?\x07"]), ["probe"]);
        assert_eq!(events(&[b"\x1b]7501;state=working\x18\x1b]7501;?\x07"]), ["probe"]);
        assert_eq!(events(&[b"\x1b]7501;state=working\x1a"]), Vec::<String>::new());
    }

    #[test]
    fn dcs_is_skipped_whole() {
        assert_eq!(
            events(&[b"\x1bPtmux;\x1b\x1b]7501;?\x07\x1b\\\x1b]7501;?\x07"]),
            ["probe"]
        );
    }

    #[test]
    fn other_osc_is_ignored() {
        assert!(events(&[b"\x1b]0;title\x07\x1b]75010;x\x07\x1b]1337;?\x07"]).is_empty());
    }

    #[test]
    fn over_4096_bytes_is_dropped() {
        let ok = format!("\x1b]7501;state=idle:x={}\x07", "a".repeat(4096 - 21));
        assert_eq!(ok.len(), 4096);
        assert_eq!(events(&[ok.as_bytes()]).len(), 1);
        let long = format!("\x1b]7501;state=idle:x={}\x07", "a".repeat(4096 - 20));
        assert!(events(&[long.as_bytes()]).is_empty());
        assert_eq!(events(&[long.as_bytes(), b"\x1b]7501;?\x07"]), ["probe"]);
        // an ST terminator is one byte longer: the payload is the same 4075 chars as
        // the accepted case, but the total sequence length 4097 is too long
        let st = format!("\x1b]7501;state=idle:x={}\x1b\\", "a".repeat(4096 - 21));
        assert!(events(&[st.as_bytes()]).is_empty());
    }

    #[test]
    fn recordings_split_as_recorded_match_whole() {
        for name in ["claude-turns", "claude-children", "claude-error", "codex-turns", "synthetic-split"] {
            let (data, _) = capture(name);
            let split = chunks(name);
            let split: Vec<&[u8]> = split.iter().map(|c| c.as_slice()).collect();
            let whole = events(&[&data]);
            assert!(whole.iter().any(|e| e.starts_with("report:")), "{name}: no report");
            assert_eq!(events(&split), whole, "{name}");
        }
    }

    #[test]
    fn recordings_probe_counts() {
        let probes = |n| events(&[&capture(n).0]).iter().filter(|e| *e == "probe").count();
        assert_eq!((probes("claude-turns"), probes("claude-error"), probes("codex-turns")), (1, 1, 0));
        assert_eq!((probes("claude-children"), probes("synthetic-split")), (1, 2));
    }

    fn set(body: &str) -> Message {
        parse(body).unwrap_or_else(|| panic!("{body}"))
    }
    fn rec(m: Option<Message>) -> Record {
        match m {
            Some(Message::Set(r)) => r,
            other => panic!("{other:?}"),
        }
    }
    fn st(m: Option<Message>) -> State {
        rec(m).state
    }
    fn msg(m: Option<Message>) -> Option<String> {
        rec(m).msg
    }
    fn kind(m: Option<Message>) -> Option<String> {
        rec(m).kind
    }
    fn progress(m: Option<Message>) -> Option<u8> {
        rec(m).progress
    }
    fn app(m: Option<Message>) -> Option<String> {
        rec(m).app
    }

    #[test]
    fn parse_basic() {
        let Some(Message::Set(r)) = parse("state=blocked:kind=permission:app=claude-code:msg=aGk=") else { panic!() };
        assert_eq!((r.state, r.kind.as_deref(), r.app.as_deref(), r.msg.as_deref()), (State::Blocked, Some("permission"), Some("claude-code"), Some("hi")));
        assert_eq!(parse("state=clear"), Some(Message::Clear { id: None }));
        assert_eq!(parse("state=clear:id=a/b"), Some(Message::Clear { id: Some("a/b".into()) }));
    }

    #[test]
    fn parse_tolerates() {
        assert_eq!(st(parse("zz=1:state=idle:state=done:junk")), State::Done);
        assert_eq!(msg(parse("state=done:msg=aGk")), Some("hi".into()));
        assert_eq!(kind(parse("state=working:kind=permission")), None);
        assert_eq!(kind(parse("state=blocked:kind=weird")), None);
        assert_eq!(progress(parse("state=working:progress=42")), Some(42));
        for p in ["101", "042", "-1", "x"] {
            assert_eq!(progress(parse(&format!("state=working:progress={p}"))), None);
        }
        assert_eq!(progress(parse("state=done:progress=42")), None);
        assert_eq!(app(parse("state=idle:app=a*b")), None);
    }

    #[test]
    fn parse_drops_whole() {
        for body in [
            "kind=permission",
            "state=sleeping",
            "state=idle:id=",
            "state=idle:id=a//b",
            "state=idle:id=a,b", // not "a*b": a value byte outside the charset skips the pair (gascity parse_test.go:149)
            &format!("state=idle:id={}", "a".repeat(33)),
            &format!("state=idle:id={}", ["a"; 9].join("/")),
            &format!("state=idle:id={}", vec!["a".repeat(31); 5].join("/")),
            &format!("state=idle:app={}", "a".repeat(33)),
            &format!("state=idle:{}=1", "a".repeat(17)),
            "state=done:msg=a",
            "state=done:msg=Cg==",
            "state=done:msg=wp8=",
            "state=done:msg=/w==",
        ] {
            assert_eq!(parse(body), None, "{body}");
        }
    }

    #[test]
    fn parse_strips_invisible() {
        assert_eq!(msg(parse("state=done:msg=YeKAi2LigK5j77u/")), Some("abc".into()));
    }

    #[test]
    fn records_rules() {
        let mut r = Records::default();
        r.apply(set("state=working:app=claude-code"));
        r.apply(set("state=working:id=a:title=dA=="));
        r.apply(set("state=blocked:id=a/b:kind=question"));
        let d = r.deciding().unwrap();
        assert_eq!((d.state, d.id.as_deref(), d.app.as_deref()), (State::Blocked, Some("a/b"), Some("claude-code")));
        r.apply(Message::Clear { id: Some("a".into()) });
        assert_eq!((r.children(), r.deciding().unwrap().state), (0, State::Working));
        r.apply(set("state=error:id=x"));
        r.apply(set("state=done"));
        assert_eq!(r.deciding().unwrap().state, State::Error);
        r.apply(set("state=working"));
        r.drop_transient();
        assert_eq!((r.deciding().unwrap().state, r.children()), (State::Error, 1));
        r.apply(Message::Clear { id: None });
        assert!(r.deciding().is_none());
    }

    #[test]
    fn records_cap_drops_least_recently_updated() {
        let mut r = Records::default();
        for i in 0..256 {
            r.apply(set(&format!("state=idle:id=c{i}")));
        }
        r.apply(set("state=idle:id=c0"));
        r.apply(set("state=idle:id=new"));
        assert_eq!(r.children(), 256);
        assert!(r.get("c1").is_none() && r.get("c0").is_some() && r.get("new").is_some());
    }

    fn trace(name: &str) -> Vec<String> {
        let mut sc = Scanner::default();
        let mut recs = Records::default();
        let mut out = Vec::new();
        for c in chunks(name) {
            sc.feed(&c, |e| match e {
                Event::Probe => out.push("probe".to_string()),
                Event::Prompt => {
                    recs.drop_transient();
                    out.push("prompt".to_string());
                }
                Event::Report(b) => match parse(&b) {
                    None => out.push("dropped".to_string()),
                    Some(m) => {
                        recs.apply(m);
                        out.push(match recs.deciding() {
                            None => "-".to_string(),
                            Some(r) => match r.kind {
                                Some(k) => format!("{}:{k}", r.state.as_str()),
                                None => r.state.as_str().to_string(),
                            },
                        });
                    }
                },
            });
        }
        out
    }

    /// Replay, calling `f` with each parsed message and the table after it.
    fn replay(name: &str, mut f: impl FnMut(&Message, &Records)) -> Records {
        let mut sc = Scanner::default();
        let mut recs = Records::default();
        for c in chunks(name) {
            sc.feed(&c, |e| match e {
                Event::Prompt => {
                    recs.drop_transient();
                }
                Event::Report(b) => {
                    let m = parse(&b).unwrap_or_else(|| panic!("dropped {b}"));
                    recs.apply(m.clone());
                    f(&m, &recs);
                }
                Event::Probe => {}
            });
        }
        recs
    }

    fn msgs_of(name: &str, state: State) -> Vec<(Option<String>, Option<String>)> {
        let mut out = Vec::new();
        replay(name, |m, _| {
            if let Message::Set(r) = m {
                if r.state == state {
                    out.push((r.kind.clone(), r.msg.clone()));
                }
            }
        });
        out
    }

    fn blocked_msgs(name: &str) -> Vec<String> {
        msgs_of(name, State::Blocked)
            .into_iter()
            .map(|(k, m)| format!("{}|{}", k.unwrap(), m.unwrap()))
            .collect()
    }

    #[test]
    fn golden_claude_turns() {
        assert_eq!(trace("claude-turns"), ["probe","idle","working","blocked:permission","working","blocked:question","working",
            "done","working","done","working","idle","-","-","-"]);
    }

    #[test]
    fn golden_claude_msgs() {
        assert_eq!(blocked_msgs("claude-turns"), ["permission|approve Bash: touch /tmp/osc7501x-work/claude-approved-marker",
            "question|answer: Which color do you prefer? (Red · Blue)"]);
    }

    #[test]
    fn golden_codex_turns() {
        assert_eq!(trace("codex-turns"), ["idle","working","blocked:permission","working","done","idle","-"]);
    }

    #[test]
    fn golden_claude_error() {
        assert_eq!(trace("claude-error"), ["probe","idle","working","error","-","-","-"]);
        let errs = msgs_of("claude-error", State::Error);
        assert_eq!(errs.last().unwrap().1.as_deref(), Some("API Error: 400 mock invalid_request_error"));
    }

    #[test]
    fn golden_claude_children() {
        let mut peak = 0;
        let recs = replay("claude-children", |_, r| peak = peak.max(r.children()));
        assert_eq!(peak, 2);
        assert_eq!(recs.children(), 0);
        assert!(recs.deciding().is_none());
    }

    #[test]
    fn golden_synthetic_split() {
        let q = msgs_of("synthetic-split", State::Blocked);
        assert!(q.iter().any(|(k, m)| k.as_deref() == Some("question") && m.as_deref() == Some("Allow `rm -rf build`?")), "{q:?}");
        let recs = replay("synthetic-split", |_, _| {});
        assert!(recs.deciding().is_none());
    }
}
