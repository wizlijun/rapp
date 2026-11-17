//! Read-only log query pieces: a reverse line reader and the problem classifier.
// Task 2 (`query`) is the consumer of `lines_rev`; drop this allow then.
#![allow(dead_code)]

use serde_json::Value;
use std::fs::File;
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};

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
}
