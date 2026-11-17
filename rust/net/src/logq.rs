//! Read-only log query (log screen spec §3): `service.log` and `hub.log`
//! read backwards, merged newest first, `repeat` folded, classified, paged by
//! cursor, with 24 h counts and the `launchd.log` tail.

use serde::{Deserialize, Serialize};
use serde_json::{json, Map, Value};
use std::cmp::Reverse;
use std::fs::File;
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

const CHUNK: u64 = 64 * 1024;

/// Which log a line came from.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Src {
    Service,
    Hub,
}

impl Src {
    pub fn name(self) -> &'static str {
        match self {
            Src::Service => "service",
            Src::Hub => "hub",
        }
    }
    pub fn file(self) -> &'static str {
        match self {
            Src::Service => "service.log",
            Src::Hub => "hub.log",
        }
    }
    /// Tie-break order when two sources share a timestamp: service first.
    pub fn rank(self) -> u8 {
        match self {
            Src::Service => 0,
            Src::Hub => 1,
        }
    }
}

/// The three problem cards.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    Unreachable,
    Refused,
    Fault,
}

impl Kind {
    pub fn as_str(self) -> &'static str {
        match self {
            Kind::Unreachable => "unreachable",
            Kind::Refused => "refused",
            Kind::Fault => "fault",
        }
    }
    pub fn parse(s: &str) -> Option<Kind> {
        match s {
            "unreachable" => Some(Kind::Unreachable),
            "refused" => Some(Kind::Refused),
            "fault" => Some(Kind::Fault),
            _ => None,
        }
    }
}

/// Classify one parsed log event (spec §3.2): refused rows first, then
/// unreachable, then fault.
pub fn classify(src: Src, ev: &Value) -> Option<Kind> {
    let name = ev.get("ev").and_then(Value::as_str).unwrap_or("");
    let s = |k: &str| ev.get(k).and_then(Value::as_str);
    let bad_lvl = matches!(s("lvl"), Some("warn" | "error"));

    let refused = match name {
        "auth_fail" | "rejected" | "map_refused" | "forward_refused" | "relay_revoked" => true,
        "request" => s("op") != Some("watch_terms") && s("result").is_some_and(|r| r != "ok"),
        "trust" => s("result") == Some("refused"),
        _ => false,
    };
    if refused {
        return Some(Kind::Refused);
    }

    let unreachable = match (src, name) {
        (Src::Hub, "route" | "log") => bad_lvl,
        (Src::Service, "relay") => {
            s("state") == Some("error") || (s("state") == Some("connecting") && ev.get("error").is_some())
        }
        _ => false,
    };
    if unreachable {
        return Some(Kind::Unreachable);
    }

    if bad_lvl {
        return Some(Kind::Fault);
    }
    if name == "log" && matches!(s("src"), Some("host" | "term" | "client")) {
        let msg = s("msg").unwrap_or("").to_lowercase();
        if ["panic", "fatal", "error"].iter().any(|w| msg.contains(w)) {
            return Some(Kind::Fault);
        }
    }
    None
}

/// Query parameters (spec §3.4); every one may be left out. The hub parses a
/// `logs` command into this, so a key that is not a field here never reaches
/// a peer (and a new reply key must join the hub's list in `hub/src/lib.rs`).
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct LogQuery {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub before: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub after: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub around: Option<String>,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub problems: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub kind: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub src: Option<Vec<String>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub q: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub limit: Option<u32>,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub tail_launchd: bool,
}

/// Events stop being added once the reply reaches this; the line protocol
/// caps a line at `crate::line::MAX_LINE` (64 KiB).
pub const BUDGET: usize = 56 * 1024;
const LIMIT: u32 = 200;
const MAX_LIMIT: u32 = 500;
const AROUND: Duration = Duration::from_secs(60);
const COUNTS: Duration = Duration::from_secs(24 * 3600);
const LAUNCHD: &str = "launchd.log";
const LAUNCHD_LINES: usize = 100;
/// The `launchd` tail's share of the budget (100 lines of 1 KiB would not fit).
const LAUNCHD_BUDGET: usize = 16 * 1024;
/// A `raw` longer than this has its long strings cut to `CUT`.
const RAW_MAX: usize = 4096;
const CUT: usize = 1024;

/// Answer one query (spec §3.4). The reply has no `ok`; callers add it.
/// Synchronous: callers run it on a blocking thread.
pub fn query(dir: &Path, q: &LogQuery, now: SystemTime) -> Value {
    let limit = q.limit.unwrap_or(LIMIT).clamp(1, MAX_LIMIT) as usize;
    let mut reply = json!({});
    if q.before.is_none() && q.after.is_none() && q.around.is_none() {
        let (counts, latest) = counts(dir, now);
        reply["counts"] = counts;
        reply["latest"] = latest;
    }
    if q.tail_launchd {
        if let Some(t) = launchd_tail(dir) {
            reply["launchd"] = t.into();
        }
    }
    let budget = BUDGET.saturating_sub(reply.to_string().len());
    let mut fill = Fill { events: Vec::new(), again: Vec::new(), used: 0, limit, budget, more: false };
    // `around` is oldest first, everything else newest first.
    let (newer, older) = match &q.around {
        Some(c) => {
            around(dir, &parse_cursor(c).checked(dir), &mut fill);
            (fill.events.last().map(|e| e["at"].clone()), fill.events.first())
        }
        None => (page(dir, q, &mut fill).map(Value::from), fill.events.last()),
    };
    if let Some(o) = older {
        reply["older"] = o["at"].clone();
    }
    if let Some(n) = newer {
        reply["newer"] = n;
    }
    if !fill.again.is_empty() {
        reply["again"] = std::mem::take(&mut fill.again).into();
    }
    // An `after` page cut short leaves unsent rows between it and the cursor:
    // `gap` (the GUI reloads the first page). `more` only means older rows.
    if q.around.is_none() && q.after.is_some() && fill.more {
        reply["gap"] = true.into();
        fill.more = false;
    }
    reply["more"] = fill.more.into();
    reply["events"] = fill.events.into();
    reply
}

/// Parse `YYYY-MM-DDTHH:MM:SS.mmmZ` (what `crate::log::timestamp` writes).
pub fn parse_ts(s: &str) -> Option<SystemTime> {
    let b = s.as_bytes();
    let seps = [(4, b'-'), (7, b'-'), (10, b'T'), (13, b':'), (16, b':'), (19, b'.'), (23, b'Z')];
    if b.len() != 24 || seps.iter().any(|&(i, c)| b[i] != c) {
        return None;
    }
    let num = |a: usize, z: usize| -> Option<i64> { b[a..z].iter().all(u8::is_ascii_digit).then(|| s[a..z].parse().ok())? };
    let (y, mo, d) = (num(0, 4)?, num(5, 7)?, num(8, 10)?);
    let (h, mi, sec, ms) = (num(11, 13)?, num(14, 16)?, num(17, 19)?, num(20, 23)?);
    // days_from_civil (Howard Hinnant), the inverse of `timestamp`.
    let yy = if mo <= 2 { y - 1 } else { y };
    let era = yy.div_euclid(400);
    let yoe = yy - era * 400;
    let doy = (153 * ((mo + 9) % 12) + 2) / 5 + d - 1;
    let days = era * 146_097 + yoe * 365 + yoe / 4 - yoe / 100 + doy - 719_468;
    let secs = u64::try_from(days * 86_400 + h * 3600 + mi * 60 + sec).ok()?;
    let t = UNIX_EPOCH + Duration::from_secs(secs) + Duration::from_millis(ms as u64);
    // Out-of-range fields (month 13, Feb 30, hour 24) do not round-trip.
    (crate::log::timestamp(t) == s).then_some(t)
}

/// One parsed event, with any `repeat` that followed it folded in.
struct Ev {
    src: Src,
    ts: String,
    offset: u64,
    text: String,
    val: Value,
    kind: Option<Kind>,
    repeat: u64,
    /// The newest line folded into this event: its last `repeat` line, or
    /// the event itself (`ts`, offset).
    last: (String, u64),
}

/// `"{ts}~{rank}~{offset}"`, the `at` of a line.
fn at(ts: &str, src: Src, offset: u64) -> String {
    format!("{ts}~{}~{offset}", src.rank())
}

impl Ev {
    /// Larger is newer: `ts`, then service before hub, then later in the file.
    fn key(&self) -> (&str, Reverse<u8>, u64) {
        (&self.ts, Reverse(self.src.rank()), self.offset)
    }

    /// `key` of the newest line folded in (see `last`).
    fn last_key(&self) -> (&str, Reverse<u8>, u64) {
        (&self.last.0, Reverse(self.src.rank()), self.last.1)
    }

    /// The event entry (spec §3.4); a long `raw` is cut, staying valid JSON.
    fn entry(&self) -> Value {
        let mut e = json!({"src": self.src.name(), "at": at(&self.ts, self.src, self.offset)});
        if let Some(k) = self.kind {
            e["kind"] = k.as_str().into();
        }
        if self.repeat > 0 {
            e["repeat"] = self.repeat.into();
        }
        if self.text.len() > RAW_MAX {
            let mut v = self.val.clone();
            if cut_strings(&mut v) {
                e["truncated"] = true.into();
                e["raw"] = v.to_string().into();
                return e;
            }
        }
        e["raw"] = self.text.as_str().into();
        e
    }
}

fn cut(s: &mut String, max: usize) {
    if s.len() > max {
        let mut i = max;
        while !s.is_char_boundary(i) {
            i -= 1;
        }
        s.truncate(i);
    }
}

/// Cuts every string longer than `CUT`; true when any was cut.
fn cut_strings(v: &mut Value) -> bool {
    match v {
        Value::String(s) if s.len() > CUT => {
            cut(s, CUT);
            true
        }
        Value::Array(a) => a.iter_mut().fold(false, |any, x| cut_strings(x) | any),
        Value::Object(m) => m.values_mut().fold(false, |any, x| cut_strings(x) | any),
        _ => false,
    }
}

/// One source's events newest first. Bad lines are skipped; a `repeat` line
/// is held and added to the next older event, across chunks and `.1`.
struct Folded<I> {
    src: Src,
    lines: I,
    pending: u64,
    /// The newest `repeat` line held (`ts`, offset).
    pending_last: Option<(String, u64)>,
}

#[cfg(test)]
thread_local! {
    /// Lines parsed by `Folded` on this thread, to test what a query costs.
    static SCANNED: std::cell::Cell<usize> = const { std::cell::Cell::new(0) };
}

impl<I: Iterator<Item = Line>> Iterator for Folded<I> {
    type Item = Ev;
    fn next(&mut self) -> Option<Ev> {
        for l in self.lines.by_ref() {
            #[cfg(test)]
            SCANNED.with(|c| c.set(c.get() + 1));
            let Ok(val) = serde_json::from_str::<Value>(&l.text) else { continue };
            if val.get("ev").and_then(Value::as_str) == Some("repeat") {
                self.pending += val.get("repeat").and_then(Value::as_u64).unwrap_or(0);
                if let (None, Some(ts)) = (&self.pending_last, val.get("ts").and_then(Value::as_str)) {
                    self.pending_last = Some((ts.to_owned(), l.offset));
                }
                continue;
            }
            let Some(ts) = val.get("ts").and_then(Value::as_str).map(str::to_owned) else { continue };
            let kind = classify(self.src, &val);
            let repeat = std::mem::take(&mut self.pending);
            let last = self.pending_last.take().unwrap_or_else(|| (ts.clone(), l.offset));
            return Some(Ev { src: self.src, ts, offset: l.offset, text: l.text, val, kind, repeat, last });
        }
        None
    }
}

/// The sources' events merged newest first (by `Ev::key`), one head each.
struct Merged<I> {
    streams: Vec<Folded<I>>,
    heads: Vec<Option<Ev>>,
}

fn merged(dir: &Path, srcs: &[Src]) -> Merged<impl Iterator<Item = Line>> {
    let mut streams: Vec<_> =
        srcs.iter().map(|&src| Folded { src, lines: lines_rev(dir, src), pending: 0, pending_last: None }).collect();
    let heads = streams.iter_mut().map(Iterator::next).collect();
    Merged { streams, heads }
}

impl<I> Merged<I> {
    /// Before the first `next`: each source's newest event, the only one a
    /// later `repeat` line can still be added to.
    fn heads(&self) -> impl Iterator<Item = &Ev> {
        self.heads.iter().flatten()
    }
}

impl<I: Iterator<Item = Line>> Iterator for Merged<I> {
    type Item = Ev;
    fn next(&mut self) -> Option<Ev> {
        let newest = self.heads.iter().enumerate().filter_map(|(i, h)| h.as_ref().map(|e| (i, e.key())));
        let i = newest.max_by(|a, b| a.1.cmp(&b.1))?.0;
        let ev = self.heads[i].take();
        self.heads[i] = self.streams[i].next();
        ev
    }
}

/// `"{ts}~{rank}~{offset}"`; anything else is a bare `ts` (up to any `~`).
enum Cursor {
    At { ts: String, src: Src, offset: u64 },
    Ts(String),
}

fn parse_cursor(s: &str) -> Cursor {
    let mut it = s.rsplitn(3, '~');
    if let (Some(off), Some(rank), Some(ts)) = (it.next(), it.next(), it.next()) {
        let src = match rank {
            "0" => Some(Src::Service),
            "1" => Some(Src::Hub),
            _ => None,
        };
        if let (Ok(offset), Some(src)) = (off.parse(), src) {
            if !ts.is_empty() {
                return Cursor::At { ts: ts.to_owned(), src, offset };
            }
        }
    }
    Cursor::Ts(s.split('~').next().unwrap_or(s).to_owned())
}

impl Cursor {
    fn ts(&self) -> &str {
        match self {
            Cursor::At { ts, .. } | Cursor::Ts(ts) => ts,
        }
    }

    /// Strictly older than the cursor; a bare `ts` keeps its own ms too.
    fn above(&self, ev: &Ev) -> bool {
        match self {
            Cursor::At { ts, src, offset } => ev.key() < (ts.as_str(), Reverse(src.rank()), *offset),
            Cursor::Ts(ts) => ev.ts <= *ts,
        }
    }

    /// Newer than the cursor. Within the cursor's ms, lines of the other
    /// source are always kept: one written later in that ms can sort on
    /// either side of the cursor, so a duplicate beats a gap.
    fn below(&self, ev: &Ev) -> bool {
        self.below_line(&ev.ts, ev.src, ev.offset)
    }

    /// `below` for the newest line folded into `ev` (a `repeat` written since).
    fn below_last(&self, ev: &Ev) -> bool {
        self.below_line(&ev.last.0, ev.src, ev.last.1)
    }

    fn below_line(&self, l_ts: &str, l_src: Src, l_offset: u64) -> bool {
        match self {
            Cursor::At { ts, src, offset } => l_ts > ts.as_str() || (l_ts == ts && (l_src != *src || l_offset > *offset)),
            Cursor::Ts(ts) => l_ts >= ts.as_str(),
        }
    }

    /// After a rotation the offset points elsewhere; if the line there is not
    /// the cursor's, fall back to the bare `ts` (spec §3.4). Offsets only
    /// shrink on rotation, so `before` is safe without this check.
    fn checked(self, dir: &Path) -> Cursor {
        match self {
            Cursor::At { ts, src, offset } if line_ts(dir, src, offset).as_deref() != Some(ts.as_str()) => Cursor::Ts(ts),
            c => c,
        }
    }
}

/// The `ts` of the line starting at logical `offset` (see `Line`).
fn line_ts(dir: &Path, src: Src, offset: u64) -> Option<String> {
    use std::io::BufRead;
    let cur = dir.join(src.file());
    let old = crate::log::old_path(&cur);
    let old_len = std::fs::metadata(&old).map(|m| m.len()).unwrap_or(0);
    let (path, pos) = if offset < old_len { (old, offset) } else { (cur, offset - old_len) };
    let mut f = std::io::BufReader::new(File::open(path).ok()?);
    f.seek(SeekFrom::Start(pos.saturating_sub(1))).ok()?;
    let mut buf = Vec::new();
    if pos > 0 {
        f.read_until(b'\n', &mut buf).ok()?;
        if buf != b"\n" {
            return None;
        }
        buf.clear();
    }
    f.read_until(b'\n', &mut buf).ok()?;
    let v: Value = serde_json::from_slice(&buf).ok()?;
    v.get("ts")?.as_str().map(str::to_owned)
}

/// Collects event entries up to `limit` and the byte budget.
struct Fill {
    events: Vec<Value>,
    /// Rows already sent whose `repeat` grew since the `after` cursor.
    again: Vec<Value>,
    used: usize,
    limit: usize,
    budget: usize,
    more: bool,
}

impl Fill {
    /// Adds `e`, or marks `more` and returns false when full. The first event
    /// always goes in, so paging moves on.
    fn push(&mut self, e: Value) -> bool {
        self.push_to(false, e)
    }

    /// `push`, into `again` when `again`; both share the limit and budget.
    fn push_to(&mut self, again: bool, e: Value) -> bool {
        let n = e.to_string().len() + 1;
        let had = self.events.len() + self.again.len();
        if had >= self.limit || (had > 0 && self.used + n > self.budget) {
            self.more = true;
            return false;
        }
        self.used += n;
        if again { &mut self.again } else { &mut self.events }.push(e);
        true
    }
}

/// A first, `before` or `after` page into `fill`; returns `newer`.
fn page(dir: &Path, q: &LogQuery, fill: &mut Fill) -> Option<String> {
    let srcs: Vec<Src> = match &q.src {
        None => vec![Src::Service, Src::Hub],
        Some(names) => [Src::Service, Src::Hub].into_iter().filter(|s| names.iter().any(|n| n == s.name())).collect(),
    };
    // An unknown kind matches nothing.
    let kind = q.kind.as_deref().map(Kind::parse);
    let needle = q.q.as_deref().map(str::to_lowercase).filter(|s| !s.is_empty());
    let matches = |ev: &Ev| {
        (!q.problems || ev.kind.is_some())
            && kind.is_none_or(|k| ev.kind.is_some() && ev.kind == k)
            && needle.as_ref().is_none_or(|n| ev.text.to_lowercase().contains(n))
    };
    let before = q.before.as_deref().map(parse_cursor);
    let after = q.after.as_deref().map(|c| parse_cursor(c).checked(dir));
    let mut evs = merged(dir, &srcs);
    // `newer` of a first or `after` page is the newest line there is, matched
    // or not (a `repeat` too), so the next poll reads only what came since.
    let top = evs.heads().max_by(|a, b| a.last_key().cmp(&b.last_key()));
    let newest = top.filter(|e| after.as_ref().is_none_or(|c| c.below_last(e))).map(|e| at(&e.last.0, e.src, e.last.1));
    // A source's newest event older than the cursor with a `repeat` written
    // since: sent again under `again`, to replace in place.
    let mut grown: Vec<&Ev> = match &after {
        Some(c) => evs.heads().filter(|e| e.repeat > 0 && !c.below(e) && c.below_last(e) && matches(e)).collect(),
        None => Vec::new(),
    };
    grown.sort_by(|a, b| b.key().cmp(&a.key()));
    let grown: Vec<Value> = grown.into_iter().map(Ev::entry).collect();
    for ev in evs.by_ref() {
        if after.as_ref().is_some_and(|c| ev.ts.as_str() < c.ts()) {
            break;
        }
        let keep = before.as_ref().is_none_or(|c| c.above(&ev)) && after.as_ref().is_none_or(|c| c.below(&ev)) && matches(&ev);
        if keep && !fill.push(ev.entry()) {
            break;
        }
    }
    // Older than every new row: after them, while there is room (else `gap`).
    for e in grown {
        if !fill.push_to(true, e) {
            break;
        }
    }
    match before {
        Some(_) => fill.events.first().and_then(|e| e["at"].as_str()).map(str::to_owned),
        None => newest,
    }
}

/// Everything within ±60 s of the cursor, every source and level, oldest
/// first. When it does not all fit, the run kept is centred on the cursor.
fn around(dir: &Path, c: &Cursor, fill: &mut Fill) {
    let Some(t) = parse_ts(c.ts()) else { return };
    let lo = crate::log::timestamp(t.checked_sub(AROUND).unwrap_or(UNIX_EPOCH));
    let hi = crate::log::timestamp(t + AROUND);
    let mut evs = Vec::new();
    for ev in merged(dir, &[Src::Service, Src::Hub]) {
        if ev.ts < lo {
            break;
        }
        if ev.ts <= hi {
            evs.push(ev);
        }
    }
    evs.reverse();
    let mid = evs
        .iter()
        .position(|e| match c {
            Cursor::At { .. } => !c.above(e),
            Cursor::Ts(ts) => e.ts >= *ts,
        })
        .unwrap_or(evs.len());
    let entries: Vec<Value> = evs.iter().map(Ev::entry).collect();
    let sizes: Vec<usize> = entries.iter().map(|e| e.to_string().len() + 1).collect();
    // Grow [a, b) from the middle, alternating sides.
    let (mut a, mut b, mut used, mut right) = (mid, mid, 0, true);
    while b - a < fill.limit && (a > 0 || b < entries.len()) {
        let i = if (right && b < entries.len()) || a == 0 { b } else { a - 1 };
        if b > a && used + sizes[i] > fill.budget {
            break;
        }
        used += sizes[i];
        if i == b {
            b += 1;
        } else {
            a -= 1;
        }
        right = !right;
    }
    fill.more = a > 0 || b < entries.len();
    fill.events = entries.into_iter().skip(a).take(b - a).collect();
}

/// Per kind, the last 24 h count (repeats included) and the newest event,
/// over both sources whatever the filters.
fn counts(dir: &Path, now: SystemTime) -> (Value, Value) {
    let since = crate::log::timestamp(now.checked_sub(COUNTS).unwrap_or(UNIX_EPOCH));
    let mut n = [0u64; 3];
    let mut latest = Map::new();
    for ev in merged(dir, &[Src::Service, Src::Hub]) {
        if ev.ts < since {
            break;
        }
        let Some(k) = ev.kind else { continue };
        n[k as usize] += 1 + ev.repeat;
        if !latest.contains_key(k.as_str()) {
            latest.insert(k.as_str().to_owned(), ev.entry());
        }
    }
    (json!({"unreachable": n[0], "refused": n[1], "fault": n[2]}), Value::Object(latest))
}

/// The last 100 lines of `launchd.log`, oldest first, each cut to 1 KiB;
/// `None` when there is no such file.
fn launchd_tail(dir: &Path) -> Option<Vec<String>> {
    let path = dir.join(LAUNCHD);
    std::fs::metadata(&path).ok()?;
    let rev = Rev { todo: vec![(path, 0)], cur: None, ready: Vec::new() };
    let (mut out, mut used) = (Vec::new(), 0);
    for l in rev.take(LAUNCHD_LINES) {
        let mut s = l.text;
        cut(&mut s, CUT);
        used += Value::from(s.as_str()).to_string().len() + 1;
        if used > LAUNCHD_BUDGET {
            break;
        }
        out.push(s);
    }
    out.reverse();
    Some(out)
}

/// One raw log line and its logical byte offset (`len(.1)` + offset in the
/// current file), so offsets order lines across a rotation.
pub(crate) struct Line {
    pub text: String,
    pub offset: u64,
}

struct FileRev {
    file: File,
    base: u64,
    /// Start of the not yet read region.
    pos: u64,
    /// Bytes of a partial line whose start is still unread.
    carry: Vec<u8>,
}

struct Rev {
    /// Files still to open, newest last (popped from the end).
    todo: Vec<(PathBuf, u64)>,
    cur: Option<FileRev>,
    /// Lines of the latest chunk, oldest first (popped from the end).
    ready: Vec<Line>,
}

/// Lines of `<file>.1` then `<file>`, read backwards in 64 KiB chunks, newest
/// first. Missing files are empty; empty lines are skipped.
pub(crate) fn lines_rev(dir: &Path, src: Src) -> impl Iterator<Item = Line> {
    let cur = dir.join(src.file());
    let old = crate::log::old_path(&cur);
    let old_len = std::fs::metadata(&old).map(|m| m.len()).unwrap_or(0);
    // Pop order: current file first, then the rotated one.
    Rev { todo: vec![(old, 0), (cur, old_len)], cur: None, ready: Vec::new() }
}

impl Rev {
    /// Appends oldest first, so popping from `ready` yields the newest.
    fn push_lines(&mut self, data: &[u8], start: u64, base: u64) {
        let mut off = start;
        for seg in data.split(|b| *b == b'\n') {
            if !seg.is_empty() {
                self.ready.push(Line { text: String::from_utf8_lossy(seg).into_owned(), offset: base + off });
            }
            off += seg.len() as u64 + 1;
        }
    }

    fn open_next(&mut self) -> bool {
        while let Some((path, base)) = self.todo.pop() {
            let Ok(file) = File::open(&path) else { continue };
            let Ok(len) = file.metadata().map(|m| m.len()) else { continue };
            if len == 0 {
                continue;
            }
            self.cur = Some(FileRev { file, base, pos: len, carry: Vec::new() });
            return true;
        }
        false
    }

    /// Read one more chunk of the current file; on failure the file is dropped.
    fn fill(&mut self) {
        let Some(f) = self.cur.as_mut() else { return };
        let n = CHUNK.min(f.pos);
        f.pos -= n;
        let mut data = vec![0u8; n as usize];
        let ok = f.file.seek(SeekFrom::Start(f.pos)).is_ok() && f.file.read_exact(&mut data).is_ok();
        if !ok {
            self.cur = None;
            return;
        }
        data.extend_from_slice(&f.carry);
        let (pos, base) = (f.pos, f.base);
        let split = if pos == 0 { Some(0) } else { data.iter().position(|b| *b == b'\n').map(|i| i + 1) };
        match split {
            None => f.carry = data,
            Some(i) => {
                f.carry = if pos == 0 { Vec::new() } else { data[..i - 1].to_vec() };
                if pos == 0 {
                    self.cur = None;
                }
                self.push_lines(&data[i..], pos + i as u64, base);
            }
        }
    }
}

impl Iterator for Rev {
    type Item = Line;
    fn next(&mut self) -> Option<Line> {
        loop {
            if let Some(l) = self.ready.pop() {
                return Some(l);
            }
            if self.cur.is_none() && !self.open_next() {
                return None;
            }
            self.fill();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::fs;

    fn texts(dir: &Path, src: Src) -> Vec<String> {
        lines_rev(dir, src).map(|l| l.text).collect()
    }

    #[test]
    fn lines_rev_spans_both_files_newest_first() {
        let d = tempfile::tempdir().unwrap();
        fs::write(d.path().join("service.log.1"), "a\nb\n").unwrap();
        fs::write(d.path().join("service.log"), "c\nd\n").unwrap();
        let ls: Vec<Line> = lines_rev(d.path(), Src::Service).collect();
        let t: Vec<&str> = ls.iter().map(|l| l.text.as_str()).collect();
        assert_eq!(t, ["d", "c", "b", "a"]);
        assert!(ls.windows(2).all(|w| w[0].offset > w[1].offset));
        assert_eq!(ls[0].offset, 4 + 2);
        assert_eq!(ls[3].offset, 0);
    }

    #[test]
    fn lines_rev_reads_across_chunk_boundaries() {
        let d = tempfile::tempdir().unwrap();
        let l: Vec<String> = ["x", "y", "z"].iter().map(|c| c.repeat(40 * 1024)).collect();
        fs::write(d.path().join("hub.log"), format!("{}\n{}\n{}\n", l[0], l[1], l[2])).unwrap();
        assert_eq!(texts(d.path(), Src::Hub), [l[2].clone(), l[1].clone(), l[0].clone()]);
    }

    #[test]
    fn lines_rev_skips_empty_and_handles_no_trailing_newline() {
        let d = tempfile::tempdir().unwrap();
        fs::write(d.path().join("hub.log"), "a\n\n\nb").unwrap();
        assert_eq!(texts(d.path(), Src::Hub), ["b", "a"]);
    }

    #[test]
    fn lines_rev_missing_files_are_empty() {
        let d = tempfile::tempdir().unwrap();
        assert_eq!(lines_rev(d.path(), Src::Hub).count(), 0);
    }

    #[test]
    fn kind_round_trips() {
        for k in [Kind::Unreachable, Kind::Refused, Kind::Fault] {
            assert_eq!(Kind::parse(k.as_str()), Some(k));
        }
        assert_eq!(Kind::parse("x"), None);
        assert_eq!((Src::Service.name(), Src::Hub.file(), Src::Service.rank(), Src::Hub.rank()), ("service", "hub.log", 0, 1));
    }

    #[test]
    fn classify_table() {
        use Kind::*;
        use Src::*;
        let c = |s, v: Value| classify(s, &v);
        assert_eq!(c(Hub, json!({"ev":"route","lvl":"warn"})), Some(Unreachable));
        assert_eq!(c(Hub, json!({"ev":"route","lvl":"error"})), Some(Unreachable));
        assert_eq!(c(Hub, json!({"ev":"route","lvl":"info"})), None);
        assert_eq!(c(Hub, json!({"ev":"log","lvl":"warn","msg":"x via relay: boom; reconnecting"})), Some(Unreachable));
        assert_eq!(c(Service, json!({"ev":"relay","lvl":"info","state":"connecting","error":"timeout"})), Some(Unreachable));
        assert_eq!(c(Service, json!({"ev":"relay","lvl":"info","state":"connecting"})), None);
        assert_eq!(c(Service, json!({"ev":"relay","lvl":"warn","state":"error"})), Some(Unreachable));
        assert_eq!(c(Service, json!({"ev":"trust","lvl":"warn","result":"refused"})), Some(Refused));
        assert_eq!(c(Service, json!({"ev":"trust","lvl":"warn","result":"other"})), Some(Fault));
        for ev in ["relay_revoked", "auth_fail", "rejected", "map_refused", "forward_refused"] {
            assert_eq!(c(Service, json!({"ev":ev,"lvl":"info"})), Some(Refused), "{ev}");
        }
        assert_eq!(c(Service, json!({"ev":"request","result":"busy","op":"open"})), Some(Refused));
        assert_eq!(c(Service, json!({"ev":"request","result":"ok","op":"open"})), None);
        assert_eq!(c(Service, json!({"ev":"request","lvl":"info","result":"busy","op":"watch_terms"})), None);
        assert_eq!(c(Hub, json!({"ev":"presence","lvl":"info","online":false})), None);
        assert_eq!(c(Service, json!({"ev":"log","lvl":"info","src":"host","msg":"thread 'main' panicked"})), Some(Fault));
        assert_eq!(c(Service, json!({"ev":"log","lvl":"info","src":"host","msg":"hello"})), None);
        assert_eq!(c(Hub, json!({"ev":"log","lvl":"info","src":"client","msg":"Fatal error"})), Some(Fault));
        assert_eq!(c(Service, json!({"ev":"update_failed","lvl":"warn"})), Some(Fault));
        assert_eq!(c(Service, json!({"ev":"worker_exit","lvl":"error"})), Some(Fault));
        assert_eq!(c(Service, json!({"ev":"session_start","lvl":"info"})), None);
    }

    #[test]
    fn lines_rev_line_longer_than_chunk() {
        let d = tempfile::tempdir().unwrap();
        let big = "x".repeat(70 * 1024);
        fs::write(d.path().join("hub.log"), format!("a\n{big}\nb\n")).unwrap();
        let ls: Vec<Line> = lines_rev(d.path(), Src::Hub).collect();
        let t: Vec<&str> = ls.iter().map(|l| l.text.as_str()).collect();
        assert_eq!(t, ["b", big.as_str(), "a"]);
        assert_eq!((ls[0].offset, ls[1].offset, ls[2].offset), (2 + big.len() as u64 + 1, 2, 0));
    }

    // ---- query ----

    use crate::log::timestamp;
    use std::io::Write;
    use std::time::{Duration, UNIX_EPOCH};

    fn t0() -> SystemTime {
        UNIX_EPOCH + Duration::from_secs(1_800_000_000)
    }

    /// `t0` plus `secs` (may be negative), formatted like the log.
    fn ts_at(secs: i64) -> String {
        let d = Duration::from_secs(secs.unsigned_abs());
        timestamp(if secs >= 0 { t0() + d } else { t0() - d })
    }

    fn line(ts: &str, body: Value) -> String {
        let mut v = body;
        v["ts"] = ts.into();
        v.to_string()
    }

    fn info(ts: &str, n: &str) -> String {
        line(ts, json!({"lvl":"info","ev":"x","n":n}))
    }

    fn append(dir: &Path, file: &str, lines: &[String]) {
        let mut f = fs::OpenOptions::new().create(true).append(true).open(dir.join(file)).unwrap();
        for l in lines {
            writeln!(f, "{l}").unwrap();
        }
    }

    fn run(dir: &Path, q: LogQuery) -> Value {
        query(dir, &q, t0())
    }

    fn evs(r: &Value) -> &Vec<Value> {
        r["events"].as_array().expect("events")
    }

    /// The `n` field of each event's raw line.
    fn ns(r: &Value) -> Vec<String> {
        evs(r).iter().map(|e| raw(e)["n"].as_str().unwrap_or("").to_owned()).collect()
    }

    fn raw(e: &Value) -> Value {
        serde_json::from_str(e["raw"].as_str().unwrap()).unwrap()
    }

    #[test]
    fn merges_newest_first_stable_on_same_ms() {
        let d = tempfile::tempdir().unwrap();
        let (t1, t2, t3) = (ts_at(-3), ts_at(-2), ts_at(-1));
        append(d.path(), "service.log", &[info(&t1, "s1"), info(&t2, "s2"), info(&t2, "s3")]);
        append(d.path(), "hub.log", &[info(&t2, "h1"), info(&t2, "h2"), info(&t3, "h3")]);
        let r = run(d.path(), LogQuery::default());
        assert_eq!(ns(&r), ["h3", "s3", "s2", "h2", "h1", "s1"]);
        let src: Vec<&str> = evs(&r).iter().map(|e| e["src"].as_str().unwrap()).collect();
        assert_eq!(src, ["hub", "service", "service", "hub", "hub", "service"]);
        let mut at: Vec<&str> = evs(&r).iter().map(|e| e["at"].as_str().unwrap()).collect();
        assert!(at[0].starts_with(&format!("{t3}~1~")));
        at.sort();
        at.dedup();
        assert_eq!(at.len(), 6);
        assert_eq!(r["more"], false);
        assert_eq!(r["newer"], evs(&r)[0]["at"]);
        assert_eq!(r["older"], evs(&r)[5]["at"]);
    }

    #[test]
    fn paging_with_cursor_no_gaps_no_dups() {
        let d = tempfile::tempdir().unwrap();
        let t = ts_at(-5);
        for i in 0..15 {
            append(d.path(), "service.log", &[info(&t, &format!("s{i}"))]);
            append(d.path(), "hub.log", &[info(&t, &format!("h{i}"))]);
        }
        let mut q = LogQuery { limit: Some(7), ..Default::default() };
        let mut seen = Vec::new();
        for _ in 0..10 {
            let r = run(d.path(), q.clone());
            seen.extend(ns(&r));
            if r["more"] == false {
                break;
            }
            assert_eq!(evs(&r).len(), 7);
            q.before = Some(r["older"].as_str().unwrap().to_owned());
        }
        let n = seen.len();
        seen.sort();
        seen.dedup();
        assert_eq!((n, seen.len()), (30, 30));
    }

    #[test]
    fn after_returns_only_newer() {
        let d = tempfile::tempdir().unwrap();
        let t = ts_at(-5);
        append(d.path(), "service.log", &(0..5).map(|i| info(&t, &format!("a{i}"))).collect::<Vec<_>>());
        let r = run(d.path(), LogQuery::default());
        append(d.path(), "service.log", &(0..3).map(|i| info(&t, &format!("b{i}"))).collect::<Vec<_>>());
        let r2 = run(d.path(), LogQuery { after: Some(r["newer"].as_str().unwrap().into()), ..Default::default() });
        assert_eq!(ns(&r2), ["b2", "b1", "b0"]);
        assert!(r2.get("counts").is_none() && r2.get("latest").is_none());
        // Nothing new: empty, and no cursors.
        let r3 = run(d.path(), LogQuery { after: Some(r2["newer"].as_str().unwrap().into()), ..Default::default() });
        assert!(evs(&r3).is_empty());
        assert!(r3.get("newer").is_none() && r3.get("older").is_none());
    }

    #[test]
    fn after_over_limit_sets_gap() {
        let d = tempfile::tempdir().unwrap();
        append(d.path(), "service.log", &[info(&ts_at(-100), "old")]);
        let r = run(d.path(), LogQuery::default());
        append(d.path(), "service.log", &(0..30).map(|i| info(&ts_at(-50 + i), &format!("n{i}"))).collect::<Vec<_>>());
        let after = Some(r["newer"].as_str().unwrap().into());
        let r2 = run(d.path(), LogQuery { after, limit: Some(7), ..Default::default() });
        assert_eq!(ns(&r2), ["n29", "n28", "n27", "n26", "n25", "n24", "n23"]);
        assert_eq!((r2["gap"].as_bool(), r2["more"].as_bool()), (Some(true), Some(false)));
    }

    #[test]
    fn after_within_limit_has_no_gap() {
        let d = tempfile::tempdir().unwrap();
        append(d.path(), "service.log", &[info(&ts_at(-100), "old")]);
        let r = run(d.path(), LogQuery::default());
        append(d.path(), "service.log", &(0..7).map(|i| info(&ts_at(-50 + i), &format!("n{i}"))).collect::<Vec<_>>());
        let after = Some(r["newer"].as_str().unwrap().into());
        let r2 = run(d.path(), LogQuery { after, limit: Some(7), ..Default::default() });
        assert_eq!(ns(&r2).len(), 7);
        assert!(r2.get("gap").is_none());
        assert_eq!(r2["more"], false);
        // A plain page over the limit has `more`, never `gap`.
        let r3 = run(d.path(), LogQuery { limit: Some(3), ..Default::default() });
        assert!(r3.get("gap").is_none());
        assert_eq!(r3["more"], true);
    }

    #[test]
    fn after_keeps_same_ms_lines_of_the_other_source() {
        // service sorts before hub within one ms, so a hub line written later in
        // the same ms lands below the cursor; `after` must still return it.
        let d = tempfile::tempdir().unwrap();
        let t = ts_at(-5);
        append(d.path(), "service.log", &[info(&t, "s0")]);
        let r = run(d.path(), LogQuery::default());
        append(d.path(), "hub.log", &[info(&t, "h0")]);
        let r2 = run(d.path(), LogQuery { after: Some(r["newer"].as_str().unwrap().into()), ..Default::default() });
        assert_eq!(ns(&r2), ["h0"]);
    }

    #[test]
    fn rotation_between_queries() {
        let d = tempfile::tempdir().unwrap();
        let t = ts_at(-5);
        let old: Vec<String> = (0..50).map(|i| info(&ts_at(-100), &format!("o{i}"))).collect();
        append(d.path(), "service.log.1", &old);
        append(d.path(), "service.log", &(0..3).map(|i| info(&t, &format!("a{i}"))).collect::<Vec<_>>());
        let r = run(d.path(), LogQuery::default());
        fs::rename(d.path().join("service.log"), d.path().join("service.log.1")).unwrap();
        append(d.path(), "service.log", &[info(&t, "n0"), info(&t, "n1")]);
        let r2 = run(d.path(), LogQuery { after: Some(r["newer"].as_str().unwrap().into()), ..Default::default() });
        let got = ns(&r2);
        assert!(got.contains(&"n0".to_owned()) && got.contains(&"n1".to_owned()), "{got:?}");
        assert!(!got.iter().any(|n| n.starts_with('o')), "{got:?}");
    }

    #[test]
    fn bare_ts_cursor_is_inclusive() {
        let d = tempfile::tempdir().unwrap();
        append(d.path(), "hub.log", &[info(&ts_at(-3), "a"), info(&ts_at(-2), "b"), info(&ts_at(-1), "c")]);
        let r = run(d.path(), LogQuery { before: Some(ts_at(-2)), ..Default::default() });
        assert_eq!(ns(&r), ["b", "a"]);
        let r = run(d.path(), LogQuery { after: Some(ts_at(-2)), ..Default::default() });
        assert_eq!(ns(&r), ["c", "b"]);
        let r = run(d.path(), LogQuery { after: Some(format!("{}~9~x", ts_at(-2))), ..Default::default() });
        assert_eq!(ns(&r), ["c", "b"], "an unparsable cursor is its bare ts");
    }

    fn refused(ts: &str, n: &str) -> String {
        line(ts, json!({"lvl":"warn","ev":"auth_fail","n":n}))
    }

    #[test]
    fn repeat_folds_into_previous() {
        let d = tempfile::tempdir().unwrap();
        let rep = |ts: &str| line(ts, json!({"lvl":"info","ev":"repeat","repeat":4}));
        append(d.path(), "service.log", &[refused(&ts_at(-60), "A"), rep(&ts_at(-50)), info(&ts_at(-40), "B")]);
        let r = run(d.path(), LogQuery::default());
        assert_eq!(ns(&r), ["B", "A"]);
        assert_eq!(evs(&r)[1]["repeat"], 4);
        assert!(evs(&r)[0].get("repeat").is_none());
        assert_eq!(r["counts"]["refused"], 5);

        // A ends `.1`, the repeat starts the current file.
        let d = tempfile::tempdir().unwrap();
        append(d.path(), "service.log.1", &[info(&ts_at(-70), "Z"), refused(&ts_at(-60), "A")]);
        append(d.path(), "service.log", &["not json".into(), rep(&ts_at(-50)), info(&ts_at(-40), "B")]);
        let r = run(d.path(), LogQuery::default());
        assert_eq!(ns(&r), ["B", "A", "Z"]);
        assert_eq!(evs(&r)[1]["repeat"], 4);
        assert_eq!(r["counts"]["refused"], 5);
    }

    fn rep(ts: &str, n: u64) -> String {
        line(ts, json!({"lvl":"info","ev":"repeat","repeat":n}))
    }

    fn after(r: &Value, q: LogQuery) -> LogQuery {
        LogQuery { after: Some(r["newer"].as_str().expect("newer").into()), ..q }
    }

    fn problems() -> LogQuery {
        LogQuery { problems: true, ..Default::default() }
    }

    /// The `n` of each `again` entry, and its `repeat`.
    fn again(r: &Value) -> Vec<(String, u64)> {
        let a = r.get("again").and_then(Value::as_array).map(Vec::as_slice).unwrap_or_default();
        a.iter().map(|e| (raw(e)["n"].as_str().unwrap_or("").to_owned(), e["repeat"].as_u64().unwrap_or(0))).collect()
    }

    #[test]
    fn filtered_first_page_with_no_match_still_returns_newer() {
        let d = tempfile::tempdir().unwrap();
        append(d.path(), "service.log", &[info(&ts_at(-30), "i0"), info(&ts_at(-20), "i1")]);
        let r = run(d.path(), problems());
        assert!(evs(&r).is_empty());
        let newer = r["newer"].as_str().expect("newer on an empty filtered page").to_owned();
        assert!(newer.starts_with(&format!("{}~0~", ts_at(-20))), "{newer}");
        assert!(r.get("older").is_none());
        assert_eq!(r["more"], false);
        // New lines that do not match: nothing, but `newer` moves on.
        append(d.path(), "service.log", &[info(&ts_at(-10), "i2")]);
        let r2 = run(d.path(), after(&r, problems()));
        assert!(evs(&r2).is_empty());
        let newer2 = r2["newer"].as_str().unwrap();
        assert!(newer2.starts_with(&format!("{}~0~", ts_at(-10))), "{newer2}");
        // A match after that comes through.
        append(d.path(), "hub.log", &[refused(&ts_at(-5), "r0")]);
        let r3 = run(d.path(), after(&r2, problems()));
        assert_eq!(ns(&r3), ["r0"]);
        assert_eq!(r3["newer"], evs(&r3)[0]["at"]);
        // Nothing new at all: empty, no cursors.
        let r4 = run(d.path(), after(&r3, problems()));
        assert!(evs(&r4).is_empty() && r4.get("newer").is_none() && r4.get("again").is_none(), "{r4}");
    }

    #[test]
    fn after_poll_reads_only_what_came_since() {
        let d = tempfile::tempdir().unwrap();
        let old: Vec<String> = (0..3000).map(|i| info(&ts_at(-3000 + i), &format!("o{i}"))).collect();
        append(d.path(), "service.log", &old);
        append(d.path(), "hub.log", &old);
        let r = run(d.path(), problems());
        assert!(evs(&r).is_empty());
        append(d.path(), "service.log", &[info(&ts_at(1), "n0"), info(&ts_at(2), "n1")]);
        SCANNED.with(|c| c.set(0));
        let r2 = run(d.path(), after(&r, problems()));
        assert!(evs(&r2).is_empty());
        let scanned = SCANNED.with(|c| c.get());
        assert!(scanned < 10, "an after poll parsed {scanned} lines");
        // And the next one again only what is new.
        append(d.path(), "hub.log", &[refused(&ts_at(3), "r0")]);
        SCANNED.with(|c| c.set(0));
        let r3 = run(d.path(), after(&r2, problems()));
        assert_eq!(ns(&r3), ["r0"]);
        let scanned = SCANNED.with(|c| c.get());
        assert!(scanned < 10, "an after poll parsed {scanned} lines");
    }

    #[test]
    fn a_grown_repeat_is_sent_again() {
        // The reviewer's repro: the newest row is the cursor; a `repeat` line
        // written after it must reach the next `after` poll.
        let d = tempfile::tempdir().unwrap();
        append(d.path(), "service.log", &[info(&ts_at(-200), "old"), refused(&ts_at(-120), "A")]);
        let r = run(d.path(), LogQuery::default());
        assert_eq!(ns(&r), ["A", "old"]);
        assert!(evs(&r)[0].get("repeat").is_none());
        append(d.path(), "service.log", &[rep(&ts_at(-60), 7)]);
        let r2 = run(d.path(), after(&r, LogQuery::default()));
        assert!(evs(&r2).is_empty(), "{r2}");
        assert_eq!(again(&r2), [("A".to_owned(), 7)]);
        assert_eq!(r2["again"][0]["at"], evs(&r)[0]["at"], "the same row, to replace in place");
        assert!(r2.get("gap").is_none());
        // Nothing since: not sent again, and no new cursor (the GUI keeps r2's).
        let r3 = run(d.path(), after(&r2, LogQuery::default()));
        assert!(evs(&r3).is_empty() && again(&r3).is_empty() && r3.get("newer").is_none(), "{r3}");
        // Grows again: the total.
        append(d.path(), "service.log", &[rep(&ts_at(-30), 3)]);
        let r4 = run(d.path(), after(&r2, LogQuery::default()));
        assert_eq!(again(&r4), [("A".to_owned(), 10)]);
        // A new row after it: the new row only.
        append(d.path(), "service.log", &[info(&ts_at(-10), "B")]);
        let r5 = run(d.path(), after(&r4, LogQuery::default()));
        assert_eq!(ns(&r5), ["B"]);
        assert!(again(&r5).is_empty());
        // A first page has it folded in, never as `again`.
        let r6 = run(d.path(), LogQuery::default());
        assert_eq!(evs(&r6)[1]["repeat"], 10);
        assert!(r6.get("again").is_none());
    }

    #[test]
    fn a_grown_repeat_in_the_other_source_is_sent_again() {
        let d = tempfile::tempdir().unwrap();
        append(d.path(), "service.log", &[refused(&ts_at(-120), "A")]);
        append(d.path(), "hub.log", &[info(&ts_at(-60), "H")]);
        let r = run(d.path(), LogQuery::default());
        assert_eq!(ns(&r), ["H", "A"]);
        append(d.path(), "service.log", &[rep(&ts_at(-30), 4)]);
        let r2 = run(d.path(), after(&r, LogQuery::default()));
        assert!(evs(&r2).is_empty(), "{r2}");
        assert_eq!(again(&r2), [("A".to_owned(), 4)]);
        // Both a new row and a grown repeat: the new row in `events`.
        append(d.path(), "hub.log", &[info(&ts_at(-20), "H2")]);
        append(d.path(), "service.log", &[rep(&ts_at(-10), 2)]);
        let r3 = run(d.path(), after(&r2, LogQuery::default()));
        assert_eq!(ns(&r3), ["H2"]);
        assert_eq!(again(&r3), [("A".to_owned(), 6)]);
    }

    #[test]
    fn a_grown_repeat_the_filter_does_not_match_is_not_sent() {
        let d = tempfile::tempdir().unwrap();
        append(d.path(), "service.log", &[refused(&ts_at(-120), "A"), info(&ts_at(-100), "I")]);
        let r = run(d.path(), problems());
        assert_eq!(ns(&r), ["A"]);
        append(d.path(), "service.log", &[rep(&ts_at(-30), 9)]);
        let r2 = run(d.path(), after(&r, problems()));
        assert!(evs(&r2).is_empty() && again(&r2).is_empty(), "{r2}");
        assert!(r2["newer"].as_str().unwrap().starts_with(&format!("{}~0~", ts_at(-30))), "{r2}");
    }

    #[test]
    fn around_after_rotation_centres_on_the_row() {
        let d = tempfile::tempdir().unwrap();
        let old: Vec<String> = (0..50).map(|i| info(&ts_at(-100), &format!("o{i}"))).collect();
        append(d.path(), "service.log.1", &old);
        append(d.path(), "service.log", &[info(&ts_at(-3), "a"), info(&ts_at(-2), "x"), info(&ts_at(-1), "b")]);
        let r = run(d.path(), LogQuery::default());
        let x = evs(&r).iter().find(|e| raw(e)["n"] == "x").unwrap()["at"].as_str().unwrap().to_owned();
        assert_eq!(ns(&run(d.path(), LogQuery { around: Some(x.clone()), limit: Some(1), ..Default::default() })), ["x"]);
        fs::rename(d.path().join("service.log"), d.path().join("service.log.1")).unwrap();
        append(d.path(), "service.log", &(1..=5).map(|i| info(&ts_at(i), &format!("n{i}"))).collect::<Vec<_>>());
        // `x`'s offset now points elsewhere: its bare ts still finds it.
        let r = run(d.path(), LogQuery { around: Some(x), limit: Some(1), ..Default::default() });
        assert_eq!(ns(&r), ["x"]);
    }

    fn filter_fixture() -> tempfile::TempDir {
        let d = tempfile::tempdir().unwrap();
        append(
            d.path(),
            "service.log",
            &[
                refused(&ts_at(-10), "s-ref"),
                line(&ts_at(-9), json!({"lvl":"warn","ev":"relay","state":"error","n":"s-unr"})),
                line(&ts_at(-8), json!({"lvl":"error","ev":"worker_exit","n":"s-flt"})),
                line(&ts_at(-7), json!({"lvl":"info","ev":"x","msg":"hello mini","n":"s-info"})),
            ],
        );
        append(
            d.path(),
            "hub.log",
            &[
                line(&ts_at(-6), json!({"lvl":"warn","ev":"route","n":"h-unr"})),
                line(&ts_at(-5), json!({"lvl":"info","ev":"presence","online":false,"n":"h-info"})),
            ],
        );
        d
    }

    #[test]
    fn problems_kind_src_q_filters() {
        let d = filter_fixture();
        let p = d.path();
        let r = run(p, LogQuery::default());
        assert_eq!(ns(&r), ["h-info", "h-unr", "s-info", "s-flt", "s-unr", "s-ref"]);
        let kinds: Vec<Value> = evs(&r).iter().map(|e| e.get("kind").cloned().unwrap_or(Value::Null)).collect();
        assert_eq!(kinds, [Value::Null, "unreachable".into(), Value::Null, "fault".into(), "unreachable".into(), "refused".into()]);
        assert_eq!(ns(&run(p, LogQuery { problems: true, ..Default::default() })), ["h-unr", "s-flt", "s-unr", "s-ref"]);
        assert_eq!(ns(&run(p, LogQuery { kind: Some("refused".into()), ..Default::default() })), ["s-ref"]);
        assert_eq!(ns(&run(p, LogQuery { kind: Some("unreachable".into()), ..Default::default() })), ["h-unr", "s-unr"]);
        assert!(ns(&run(p, LogQuery { kind: Some("nope".into()), ..Default::default() })).is_empty());
        assert_eq!(ns(&run(p, LogQuery { src: Some(vec!["hub".into()]), ..Default::default() })), ["h-info", "h-unr"]);
        assert!(ns(&run(p, LogQuery { src: Some(vec![]), ..Default::default() })).is_empty());
        assert_eq!(ns(&run(p, LogQuery { q: Some("MiNi".into()), ..Default::default() })), ["s-info"]);
        let r = run(p, LogQuery { problems: true, src: Some(vec!["service".into()]), q: Some("RELAY".into()), ..Default::default() });
        assert_eq!(ns(&r), ["s-unr"]);
    }

    #[test]
    fn counts_and_latest_24h_ignore_filters() {
        let d = tempfile::tempdir().unwrap();
        let p = d.path();
        append(p, "service.log", &[refused(&ts_at(-25 * 3600), "old"), refused(&ts_at(-3600), "r1")]);
        let route = line(&ts_at(-2 * 3600), json!({"lvl":"warn","ev":"route","n":"u1"}));
        append(p, "hub.log", &[refused(&ts_at(-3 * 3600), "r2"), route]);
        let want_counts = json!({"unreachable":1,"refused":2,"fault":0});
        let filtered =
            LogQuery { src: Some(vec!["hub".into()]), q: Some("zzz".into()), kind: Some("fault".into()), ..Default::default() };
        for q in [LogQuery::default(), filtered] {
            let r = run(p, q);
            assert_eq!(r["counts"], want_counts);
            let latest = r["latest"].as_object().unwrap();
            assert_eq!(latest.keys().collect::<Vec<_>>(), ["refused", "unreachable"]);
            assert_eq!(raw(&latest["refused"])["n"], "r1");
            assert_eq!(latest["refused"]["src"], "service");
            assert_eq!(latest["refused"]["kind"], "refused");
            assert_eq!(raw(&latest["unreachable"])["n"], "u1");
        }
        let c = ts_at(-3600);
        for q in [
            LogQuery { before: Some(c.clone()), ..Default::default() },
            LogQuery { after: Some(c.clone()), ..Default::default() },
            LogQuery { around: Some(c.clone()), ..Default::default() },
        ] {
            let r = run(p, q);
            assert!(r.get("counts").is_none() && r.get("latest").is_none(), "{r}");
        }
    }

    #[test]
    fn around_is_pm_60s_oldest_first_all_levels() {
        let d = tempfile::tempdir().unwrap();
        let p = d.path();
        append(p, "service.log", &[info(&ts_at(-90), "m90"), refused(&ts_at(0), "c"), info(&ts_at(90), "p90")]);
        append(p, "hub.log", &[line(&ts_at(-30), json!({"lvl":"debug","ev":"y","n":"m30"})), info(&ts_at(30), "p30")]);
        let first = run(p, LogQuery { problems: true, ..Default::default() });
        let at = evs(&first)[0]["at"].as_str().unwrap().to_owned();
        let filters = LogQuery { problems: true, kind: Some("refused".into()), q: Some("c".into()), src: Some(vec!["hub".into()]), ..Default::default() };
        let r = run(p, LogQuery { around: Some(at.clone()), ..filters });
        assert_eq!(ns(&r), ["m30", "c", "p30"]);
        assert_eq!(r["more"], false);
        assert_eq!(r["older"], evs(&r)[0]["at"]);
        assert_eq!(r["newer"], evs(&r)[2]["at"]);
        // A bare ts works too; an unparsable one gives nothing.
        assert_eq!(ns(&run(p, LogQuery { around: Some(ts_at(0)), ..Default::default() })), ["m30", "c", "p30"]);
        assert!(evs(&run(p, LogQuery { around: Some("garbage".into()), ..Default::default() })).is_empty());
    }

    #[test]
    fn around_trims_to_limit_keeping_the_middle() {
        let d = tempfile::tempdir().unwrap();
        let p = d.path();
        let lines: Vec<String> = (0..100).map(|i| info(&ts_at(i - 50), &format!("{i}"))).collect();
        append(p, "hub.log", &lines);
        let r = run(p, LogQuery { around: Some(ts_at(0)), limit: Some(10), ..Default::default() });
        assert_eq!(ns(&r), ["45", "46", "47", "48", "49", "50", "51", "52", "53", "54"]);
        assert_eq!(r["more"], true);
    }

    #[test]
    fn budget_keeps_reply_under_56k() {
        let d = tempfile::tempdir().unwrap();
        let pad = "p".repeat(150);
        let lines: Vec<String> = (0..2000).map(|i| line(&ts_at(-10), json!({"lvl":"info","ev":"x","n":i,"pad":pad}))).collect();
        assert!(lines[0].len() >= 190 && lines[0].len() <= 230);
        append(d.path(), "service.log", &lines);
        let r = run(d.path(), LogQuery { limit: Some(500), ..Default::default() });
        let n = serde_json::to_string(&r).unwrap().len();
        assert!(n < 56 * 1024 + 2048, "{n}");
        assert!(evs(&r).len() < 500 && evs(&r).len() > 100);
        assert_eq!(r["more"], true);
    }

    #[test]
    fn oversized_event_is_truncated_valid_json() {
        let d = tempfile::tempdir().unwrap();
        let big = "微".repeat(24_000); // 72 KB, longer than one 64 KiB read chunk
        append(
            d.path(),
            "service.log",
            &[
                info(&ts_at(-3), "before"),
                line(&ts_at(-2), json!({"lvl":"info","ev":"log","msg":big,"n":"big"})),
                info(&ts_at(-1), "after"),
            ],
        );
        let r = run(d.path(), LogQuery::default());
        assert_eq!(ns(&r), ["after", "big", "before"]);
        let e = &evs(&r)[1];
        assert_eq!(e["truncated"], true);
        let v = raw(e);
        let msg = v["msg"].as_str().unwrap();
        assert!(msg.len() <= 1024 && msg.len() > 1000 && msg.chars().all(|c| c == '微'));
        assert_eq!(v["ts"], ts_at(-2));
        assert!(evs(&r)[0].get("truncated").is_none());
        assert!(serde_json::to_string(&r).unwrap().len() < crate::line::MAX_LINE);
    }

    #[test]
    fn long_raw_of_short_strings_is_not_flagged() {
        let d = tempfile::tempdir().unwrap();
        let mut body = json!({"lvl":"info","ev":"x","n":"many"});
        for i in 0..300 {
            body[format!("k{i}")] = "short value".into();
        }
        let l = line(&ts_at(-1), body);
        assert!(l.len() > 4096);
        append(d.path(), "hub.log", std::slice::from_ref(&l));
        let r = run(d.path(), LogQuery::default());
        let e = &evs(&r)[0];
        assert!(e.get("truncated").is_none(), "{e}");
        assert_eq!(e["raw"], l);
    }

    #[test]
    fn bad_lines_are_skipped_in_reverse() {
        let d = tempfile::tempdir().unwrap();
        let bad = ["{\"ts\":\"half".to_owned(), "[1,2]".into(), "{\"no\":\"ts\"}".into()];
        append(d.path(), "hub.log", &[&[info(&ts_at(-3), "a")][..], &bad, &[info(&ts_at(-1), "b")]].concat());
        let r = run(d.path(), LogQuery::default());
        assert_eq!(ns(&r), ["b", "a"]);
        let r = run(d.path(), LogQuery { before: Some(evs(&r)[0]["at"].as_str().unwrap().into()), ..Default::default() });
        assert_eq!(ns(&r), ["a"]);
    }

    #[test]
    fn only_hub_log() {
        let d = tempfile::tempdir().unwrap();
        append(d.path(), "hub.log", &[info(&ts_at(-2), "h1"), info(&ts_at(-1), "h2")]);
        let r = run(d.path(), LogQuery { tail_launchd: true, ..Default::default() });
        assert_eq!(ns(&r), ["h2", "h1"]);
        assert!(r.get("launchd").is_none());
        assert_eq!(r["counts"], json!({"unreachable":0,"refused":0,"fault":0}));
        assert_eq!(r["latest"], json!({}));
        fs::write(d.path().join("service.log"), "").unwrap();
        assert_eq!(ns(&run(d.path(), LogQuery::default())), ["h2", "h1"]);
        let empty = tempfile::tempdir().unwrap();
        let r = run(empty.path(), LogQuery::default());
        assert!(evs(&r).is_empty());
        assert_eq!(r["more"], false);
    }

    #[test]
    fn launchd_tail_last_100_cut_1k() {
        let d = tempfile::tempdir().unwrap();
        let mut text = String::new();
        for i in 0..150 {
            if i == 120 {
                text.push_str(&"z".repeat(3000));
            } else {
                text.push_str(&format!("l{i}"));
            }
            text.push('\n');
        }
        fs::write(d.path().join("launchd.log"), text).unwrap();
        let r = run(d.path(), LogQuery { tail_launchd: true, ..Default::default() });
        let l = r["launchd"].as_array().unwrap();
        assert_eq!(l.len(), 100);
        assert_eq!((l[0].as_str().unwrap(), l[99].as_str().unwrap()), ("l50", "l149"));
        assert!(l.iter().all(|s| s.as_str().unwrap().len() <= 1024));
        assert_eq!(l[70].as_str().unwrap(), "z".repeat(1024));
        assert!(run(d.path(), LogQuery::default()).get("launchd").is_none());
    }

    #[test]
    fn launchd_tail_stays_inside_the_reply_budget() {
        let d = tempfile::tempdir().unwrap();
        let text: String = (0..150).map(|_| "y".repeat(2000) + "\n").collect();
        fs::write(d.path().join("launchd.log"), text).unwrap();
        let lines: Vec<String> = (0..2000).map(|i| info(&ts_at(-1), &format!("{i}"))).collect();
        append(d.path(), "service.log", &lines);
        let r = run(d.path(), LogQuery { tail_launchd: true, limit: Some(500), ..Default::default() });
        assert!(!r["launchd"].as_array().unwrap().is_empty());
        assert!(serde_json::to_string(&r).unwrap().len() < crate::line::MAX_LINE);
    }

    #[test]
    fn limit_default_200_max_500() {
        let d = tempfile::tempdir().unwrap();
        let lines: Vec<String> = (0..600).map(|_| format!("{{\"ts\":\"{}\"}}", ts_at(-1))).collect();
        append(d.path(), "hub.log", &lines);
        let r = run(d.path(), LogQuery::default());
        assert_eq!((evs(&r).len(), r["more"].as_bool()), (200, Some(true)));
        let r = run(d.path(), LogQuery { limit: Some(10_000), ..Default::default() });
        assert_eq!((evs(&r).len(), r["more"].as_bool()), (500, Some(true)));
        let before = Some(evs(&r)[499]["at"].as_str().unwrap().into());
        let r = run(d.path(), LogQuery { limit: Some(600), before, ..Default::default() });
        assert_eq!((evs(&r).len(), r["more"].as_bool()), (100, Some(false)));
    }

    #[test]
    fn parse_ts_round_trips_the_log_format() {
        for secs in [0u64, 951_782_400, 1_800_000_000, 4_102_444_799] {
            for ms in [0u64, 7, 999] {
                let t = UNIX_EPOCH + Duration::from_millis(secs * 1000 + ms);
                assert_eq!(parse_ts(&timestamp(t)), Some(t));
            }
        }
        for bad in [
            "",
            "2026-11-18T00:00:00Z",
            "2026-02-30T00:00:00.000Z",
            "2026-13-01T00:00:00.000Z",
            "2026-11-18T24:00:00.000Z",
            "2026-11-18 00:00:00.000Z",
            "２026-11-18T00:00:00.000Z",
            "+026-11-18T00:00:00.000Z",
        ] {
            assert_eq!(parse_ts(bad), None, "{bad}");
        }
    }

    #[test]
    fn log_query_wire_shape() {
        assert_eq!(serde_json::to_value(LogQuery::default()).unwrap(), json!({}));
        let q: LogQuery = serde_json::from_value(json!({"problems":true,"limit":5,"src":["hub"],"tail_launchd":true})).unwrap();
        let want = LogQuery { problems: true, limit: Some(5), src: Some(vec!["hub".into()]), tail_launchd: true, ..Default::default() };
        assert_eq!(q, want);
    }
}
