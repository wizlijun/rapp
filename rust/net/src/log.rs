//! JSON-line logs (observability spec §2, §3, §5): one object per line,
//! `{"ts":"…Z","ev":…,"lvl":…,…}`, written to a rotating file or stderr.
//! Consecutive identical lines collapse into one plus `{"ev":"repeat","repeat":N}`.

use serde_json::{json, Map, Value};
use std::fmt::Display;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

/// A file grows to this size, then becomes `<name>.1` (the one old file kept).
pub const MAX_LOG: u64 = 5 << 20;
/// A run of repeated lines is reported at least this often.
pub const REPEAT_EVERY: Duration = Duration::from_secs(60);
/// Longest line taken from a child's stderr; the rest is cut.
pub const MAX_CHILD_LINE: usize = 4096;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Lvl {
    Info,
    Warn,
    Error,
}

impl Lvl {
    pub fn as_str(self) -> &'static str {
        match self {
            Lvl::Info => "info",
            Lvl::Warn => "warn",
            Lvl::Error => "error",
        }
    }
}

/// A log sink, cheap to clone; all clones share one file and one repeat counter.
#[derive(Clone)]
pub struct Log(Arc<Mutex<Writer>>);

enum Sink {
    None,
    Stderr,
    File { path: PathBuf, limit: u64 },
}

struct Writer {
    sink: Sink,
    file: Option<std::fs::File>,
    size: u64,
    /// The last line without its `ts`, to spot repeats.
    last: Option<String>,
    repeat: u64,
    repeat_since: Instant,
}

impl Log {
    fn with(sink: Sink) -> Log {
        Log(Arc::new(Mutex::new(Writer {
            sink,
            file: None,
            size: 0,
            last: None,
            repeat: 0,
            repeat_since: Instant::now(),
        })))
    }
    pub fn none() -> Log {
        Self::with(Sink::None)
    }
    pub fn stderr() -> Log {
        Self::with(Sink::Stderr)
    }
    /// `<dir>/<name>`, created (dir 0700, file 0600) on the first write.
    pub fn file(dir: &Path, name: &str) -> Log {
        Self::file_with_limit(dir, name, MAX_LOG)
    }
    pub fn file_with_limit(dir: &Path, name: &str, limit: u64) -> Log {
        Self::with(Sink::File { path: dir.join(name), limit })
    }

    /// One event; `fields` must be an object (anything else is ignored).
    pub fn event(&self, lvl: Lvl, ev: &str, fields: Value) {
        let mut body = match fields {
            Value::Object(m) => m,
            _ => Map::new(),
        };
        body.insert("ev".into(), ev.into());
        body.insert("lvl".into(), lvl.as_str().into());
        let body = Value::Object(body).to_string();
        let mut w = self.0.lock().unwrap_or_else(|e| e.into_inner());
        if w.last.as_deref() == Some(body.as_str()) {
            w.repeat += 1;
            if w.repeat_since.elapsed() >= REPEAT_EVERY {
                w.write_repeat();
            }
            return;
        }
        w.write_repeat();
        w.write(&body);
        w.last = Some(body);
    }

    /// Free text: `{"ev":"log","msg":…}`.
    pub fn msg(&self, lvl: Lvl, text: impl Display) {
        self.event(lvl, "log", json!({"msg": text.to_string()}));
    }

    /// Writes out a pending repeat count.
    pub fn flush(&self) {
        self.0.lock().unwrap_or_else(|e| e.into_inner()).write_repeat();
    }
}

impl Writer {
    fn write_repeat(&mut self) {
        if self.repeat > 0 {
            let body = json!({"ev":"repeat","lvl":"info","repeat":self.repeat}).to_string();
            self.write(&body);
        }
        self.repeat = 0;
        self.repeat_since = Instant::now();
    }

    /// Writes `{"ts":…,` + the rest of `body`; failures are dropped (spec §3).
    fn write(&mut self, body: &str) {
        let line = format!("{{\"ts\":\"{}\",{}\n", timestamp(SystemTime::now()), &body[1..]);
        match &self.sink {
            Sink::None => {}
            Sink::Stderr => {
                let _ = std::io::stderr().lock().write_all(line.as_bytes());
            }
            Sink::File { path, limit } => {
                let (path, limit) = (path.clone(), *limit);
                if self.file.is_none() {
                    self.file = open_private(&path);
                    self.size = self.file.as_ref().and_then(|f| f.metadata().ok()).map_or(0, |m| m.len());
                }
                if self.size > 0 && self.size + line.len() as u64 > limit {
                    self.file = None;
                    let _ = std::fs::rename(&path, old_path(&path));
                    self.file = open_private(&path);
                    self.size = 0;
                }
                if let Some(f) = self.file.as_mut() {
                    if f.write_all(line.as_bytes()).is_ok() {
                        self.size += line.len() as u64;
                    }
                }
            }
        }
    }
}

impl Drop for Writer {
    fn drop(&mut self) {
        self.write_repeat();
    }
}

fn old_path(path: &Path) -> PathBuf {
    let mut p = path.as_os_str().to_owned();
    p.push(".1");
    PathBuf::from(p)
}

fn open_private(path: &Path) -> Option<std::fs::File> {
    if let Some(dir) = path.parent() {
        let mut b = std::fs::DirBuilder::new();
        b.recursive(true);
        #[cfg(unix)]
        std::os::unix::fs::DirBuilderExt::mode(&mut b, 0o700);
        b.create(dir).ok()?;
    }
    let mut opts = std::fs::OpenOptions::new();
    opts.create(true).append(true);
    #[cfg(unix)]
    std::os::unix::fs::OpenOptionsExt::mode(&mut opts, 0o600);
    opts.open(path).ok()
}

/// UTC, RFC 3339 with milliseconds: `2026-11-11T14:04:05.123Z`.
pub fn timestamp(t: SystemTime) -> String {
    let d = t.duration_since(UNIX_EPOCH).unwrap_or_default();
    let secs = d.as_secs() as i64;
    let (days, rem) = (secs.div_euclid(86_400), secs.rem_euclid(86_400));
    // days → civil date (Howard Hinnant's days_from_civil, inverted).
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = yoe + era * 400 + i64::from(month <= 2);
    format!(
        "{year:04}-{month:02}-{day:02}T{:02}:{:02}:{:02}.{:03}Z",
        rem / 3600,
        rem / 60 % 60,
        rem % 60,
        d.subsec_millis()
    )
}

/// `RAPP_LOG_DIR`, else `$RAPP_HOME/logs`, else the platform log dir + `rapp` (spec §3).
pub fn log_dir() -> PathBuf {
    log_dir_from(|k| std::env::var_os(k))
}

/// `log_dir` with the environment passed in, so tests need not touch the real one.
fn log_dir_from(var: impl Fn(&str) -> Option<std::ffi::OsString>) -> PathBuf {
    let env = |k| var(k).filter(|v| !v.is_empty()).map(PathBuf::from);
    if let Some(d) = env("RAPP_LOG_DIR") {
        return d;
    }
    if let Some(h) = env("RAPP_HOME") {
        return h.join("logs");
    }
    let user = env("HOME").unwrap_or_else(|| PathBuf::from("."));
    if cfg!(target_os = "macos") {
        user.join("Library/Logs/rapp")
    } else if cfg!(windows) {
        env("LOCALAPPDATA").unwrap_or(user).join("rapp").join("logs")
    } else {
        env("XDG_STATE_HOME").unwrap_or_else(|| user.join(".local/state")).join("rapp")
    }
}

/// Up to `limit` matching events from `<name>` and `<name>.1`, newest first; bad lines are skipped.
pub fn read_recent(dir: &Path, name: &str, keep: impl Fn(&Value) -> bool, limit: usize) -> Vec<Value> {
    let path = dir.join(name);
    let mut out = Vec::new();
    for p in [path.clone(), old_path(&path)] {
        let text = std::fs::read_to_string(&p).unwrap_or_default();
        for line in text.lines().rev() {
            if out.len() >= limit {
                return out;
            }
            if let Ok(v) = serde_json::from_str::<Value>(line) {
                if v.is_object() && keep(&v) {
                    out.push(v);
                }
            }
        }
    }
    out
}

/// Copies each line a child writes (its stderr) into `log` as `{"ev":"log","msg":…}` plus `fields`.
pub fn pipe_lines<R>(log: Log, r: R, fields: Value) -> tokio::task::JoinHandle<()>
where
    R: tokio::io::AsyncRead + Unpin + Send + 'static,
{
    use tokio::io::AsyncBufReadExt;
    tokio::spawn(async move {
        let mut r = tokio::io::BufReader::new(r);
        let mut buf = Vec::new();
        loop {
            buf.clear();
            match r.read_until(b'\n', &mut buf).await {
                Ok(0) | Err(_) => break,
                Ok(_) => {}
            }
            let text = String::from_utf8_lossy(&buf);
            let mut text = text.trim_end_matches(['\n', '\r']).to_string();
            if text.is_empty() {
                continue;
            }
            if text.len() > MAX_CHILD_LINE {
                let mut cut = MAX_CHILD_LINE;
                while !text.is_char_boundary(cut) {
                    cut -= 1;
                }
                text.truncate(cut);
            }
            let mut v = fields.clone();
            if let Some(m) = v.as_object_mut() {
                m.insert("msg".into(), text.into());
            }
            log.event(Lvl::Info, "log", v);
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn lines(path: &Path) -> Vec<Value> {
        std::fs::read_to_string(path).unwrap_or_default().lines().map(|l| serde_json::from_str(l).unwrap()).collect()
    }

    #[test]
    fn timestamps_are_utc_rfc3339_with_millis() {
        assert_eq!(timestamp(UNIX_EPOCH), "1970-01-01T00:00:00.000Z");
        // 2024-02-29 (leap day) 23:59:59.007
        let t = UNIX_EPOCH + Duration::from_millis(1_709_251_199_007);
        assert_eq!(timestamp(t), "2024-02-29T23:59:59.007Z");
        let t = UNIX_EPOCH + Duration::from_secs(1_794_405_845);
        assert_eq!(timestamp(t), "2026-11-11T14:04:05.000Z");
    }

    #[test]
    fn a_line_has_ts_ev_lvl_and_the_fields() {
        let dir = tempfile::tempdir().unwrap();
        let log = Log::file(dir.path(), "t.log");
        log.event(Lvl::Warn, "auth_fail", json!({"peer":"1.2.3.4:5","reason":"bad password"}));
        log.msg(Lvl::Info, "hello");
        let raw = std::fs::read_to_string(dir.path().join("t.log")).unwrap();
        assert!(raw.starts_with("{\"ts\":\""), "{raw}");
        let v = lines(&dir.path().join("t.log"));
        assert_eq!(v.len(), 2);
        assert_eq!(v[0]["ev"], "auth_fail");
        assert_eq!(v[0]["lvl"], "warn");
        assert_eq!(v[0]["peer"], "1.2.3.4:5");
        assert!(v[0]["ts"].as_str().unwrap().ends_with('Z'));
        assert_eq!(v[1], json!({"ts": v[1]["ts"], "ev":"log","lvl":"info","msg":"hello"}));
    }

    #[cfg(unix)]
    #[test]
    fn file_is_private() {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::tempdir().unwrap();
        let sub = dir.path().join("logs");
        Log::file(&sub, "t.log").msg(Lvl::Info, "x");
        assert_eq!(std::fs::metadata(sub.join("t.log")).unwrap().permissions().mode() & 0o777, 0o600);
        assert_eq!(std::fs::metadata(&sub).unwrap().permissions().mode() & 0o777, 0o700);
    }

    #[test]
    fn rotates_at_the_limit_keeping_one_old_file() {
        let dir = tempfile::tempdir().unwrap();
        let log = Log::file_with_limit(dir.path(), "t.log", 300);
        for i in 0..20 {
            log.event(Lvl::Info, "n", json!({"i": i}));
        }
        let (cur, old) = (dir.path().join("t.log"), dir.path().join("t.log.1"));
        assert!(std::fs::metadata(&cur).unwrap().len() <= 300);
        assert!(std::fs::metadata(&old).unwrap().len() <= 300);
        assert!(!dir.path().join("t.log.2").exists());
        let mut all: Vec<i64> = lines(&old).into_iter().chain(lines(&cur)).map(|v| v["i"].as_i64().unwrap()).collect();
        assert_eq!(all.pop(), Some(19));
        assert!(all.windows(2).all(|w| w[0] + 1 == w[1]), "contiguous: {all:?}");
    }

    #[test]
    fn appends_to_an_existing_file_and_counts_its_size() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join("t.log"), "x".repeat(290) + "\n").unwrap();
        Log::file_with_limit(dir.path(), "t.log", 300).msg(Lvl::Info, "after restart");
        assert!(dir.path().join("t.log.1").exists());
        assert_eq!(lines(&dir.path().join("t.log"))[0]["msg"], "after restart");
    }

    #[test]
    fn identical_lines_collapse_into_a_repeat_count() {
        let dir = tempfile::tempdir().unwrap();
        let log = Log::file(dir.path(), "t.log");
        for _ in 0..1000 {
            log.msg(Lvl::Warn, "click dropped: covered by Dock");
        }
        log.msg(Lvl::Info, "other");
        log.msg(Lvl::Info, "other");
        log.flush();
        let v = lines(&dir.path().join("t.log"));
        let evs: Vec<(&str, Value)> = v.iter().map(|l| (l["ev"].as_str().unwrap(), l["repeat"].clone())).collect();
        assert_eq!(evs, vec![("log", Value::Null), ("repeat", json!(999)), ("log", Value::Null), ("repeat", json!(1))]);
        log.flush();
        assert_eq!(lines(&dir.path().join("t.log")).len(), 4, "flush twice writes nothing more");
    }

    #[test]
    fn read_recent_spans_both_files_newest_first_and_skips_bad_lines() {
        let dir = tempfile::tempdir().unwrap();
        let log = Log::file_with_limit(dir.path(), "t.log", 400);
        for i in 0..12 {
            log.event(Lvl::Info, if i % 2 == 0 { "keep" } else { "skip" }, json!({"i": i}));
        }
        std::fs::OpenOptions::new()
            .append(true)
            .open(dir.path().join("t.log"))
            .unwrap()
            .write_all(b"not json\n")
            .unwrap();
        let got = read_recent(dir.path(), "t.log", |v| v["ev"] == "keep", 3);
        let is: Vec<i64> = got.iter().map(|v| v["i"].as_i64().unwrap()).collect();
        assert_eq!(is, vec![10, 8, 6]);
        assert!(dir.path().join("t.log.1").exists(), "test must span two files");
        let all = read_recent(dir.path(), "t.log", |v| v["ev"] == "keep", 100);
        assert!(all.len() >= 4);
        assert!(read_recent(&dir.path().join("missing"), "t.log", |_| true, 5).is_empty());
    }

    #[test]
    fn log_dir_prefers_rapp_log_dir_then_rapp_home() {
        let env = |vars: &'static [(&'static str, &'static str)]| {
            move |k: &str| vars.iter().find(|(n, _)| *n == k).map(|(_, v)| std::ffi::OsString::from(v))
        };
        let both = env(&[("RAPP_LOG_DIR", "/l"), ("RAPP_HOME", "/h"), ("HOME", "/u")]);
        assert_eq!(log_dir_from(both), PathBuf::from("/l"));
        assert_eq!(log_dir_from(env(&[("RAPP_HOME", "/h"), ("HOME", "/u")])), PathBuf::from("/h/logs"));
        assert_eq!(log_dir_from(env(&[("RAPP_LOG_DIR", ""), ("RAPP_HOME", "/h")])), PathBuf::from("/h/logs"));
        #[cfg(target_os = "macos")]
        assert_eq!(log_dir_from(env(&[("HOME", "/u")])), PathBuf::from("/u/Library/Logs/rapp"));
    }

    #[test]
    fn none_writes_nothing_and_never_panics() {
        let log = Log::none();
        log.msg(Lvl::Error, "dropped");
        log.flush();
    }

    #[tokio::test]
    async fn pipe_lines_copies_child_lines_with_fields_and_cuts_long_ones() {
        let dir = tempfile::tempdir().unwrap();
        let log = Log::file(dir.path(), "t.log");
        let long = "y".repeat(MAX_CHILD_LINE + 100);
        let input = format!("first\n{long}\n");
        pipe_lines(log.clone(), std::io::Cursor::new(input.into_bytes()), json!({"src":"host","app":"Echo"}))
            .await
            .unwrap();
        let v = lines(&dir.path().join("t.log"));
        assert_eq!(v[0]["msg"], "first");
        assert_eq!(v[0]["src"], "host");
        assert_eq!(v[0]["app"], "Echo");
        assert_eq!(v[1]["msg"].as_str().unwrap().len(), MAX_CHILD_LINE);
    }
}
