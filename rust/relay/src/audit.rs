//! Audit log (spec §11): one JSON line per admission/identity/connection action, appended to
//! `<data>/audit/YYYY-MM-DD.jsonl` (UTC day, mode 0600). Also mirrored to the run log.
use crate::config::AuditCfg;
use anyhow::{Context, Result};
use rapp_net::log::{timestamp, Log, Lvl};
use rapp_wire::fp::Fp;
use serde_json::{json, Map, Value};
use std::collections::BTreeMap;
use std::fs::{self, OpenOptions};
use std::io::Write;
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, MutexGuard, Weak};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

const TENANT: &str = "default";
const TICK: Duration = Duration::from_millis(250);

struct Inner {
    /// (day, line) waiting for the next write.
    buf: Vec<(String, String)>,
    probes: BTreeMap<(Fp, String), u64>,
    healthy: bool,
    hour: u64,
}

struct Shared {
    dir: PathBuf,
    cfg: AuditCfg,
    mirror: Log,
    inner: Mutex<Inner>,
}

#[derive(Clone)]
pub struct Audit(Arc<Shared>);

fn hour_of(t: SystemTime) -> u64 {
    t.duration_since(UNIX_EPOCH).unwrap_or_default().as_secs() / 3600
}

/// `2026-11-13` for a time.
fn day_of(t: SystemTime) -> String {
    timestamp(t)[..10].to_string()
}

/// `Some("2026-11-13")` for `2026-11-13.jsonl`.
fn day_name(name: &str) -> Option<&str> {
    let d = name.strip_suffix(".jsonl")?;
    let ok = d.len() == 10
        && d.bytes().enumerate().all(|(i, c)| if i == 4 || i == 7 { c == b'-' } else { c.is_ascii_digit() });
    ok.then_some(d)
}

/// Day files in `dir`, oldest first: (date, path, size).
fn day_files(dir: &Path) -> Vec<(String, PathBuf, u64)> {
    let mut v = Vec::new();
    if let Ok(rd) = fs::read_dir(dir) {
        for e in rd.flatten() {
            let name = e.file_name().to_string_lossy().into_owned();
            if let Some(d) = day_name(&name) {
                v.push((d.to_string(), e.path(), e.metadata().map(|m| m.len()).unwrap_or(0)));
            }
        }
    }
    v.sort();
    v
}

impl Audit {
    pub fn open(data: &Path, cfg: &AuditCfg, mirror: Log) -> Result<Audit> {
        let dir = data.join("audit");
        fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(&dir)
            .with_context(|| format!("create {}", dir.display()))?;
        let inner = Inner { buf: Vec::new(), probes: BTreeMap::new(), healthy: true, hour: hour_of(SystemTime::now()) };
        let a = Audit(Arc::new(Shared { dir, cfg: cfg.clone(), mirror, inner: Mutex::new(inner) }));
        a.prune(SystemTime::now());
        let weak: Weak<Shared> = Arc::downgrade(&a.0);
        let mut day = day_of(SystemTime::now());
        std::thread::Builder::new().name("audit-flush".into()).spawn(move || loop {
            std::thread::sleep(TICK);
            let Some(s) = weak.upgrade() else { return };
            let a = Audit(s);
            let today = day_of(SystemTime::now());
            if today != day {
                day = today;
                a.prune(SystemTime::now());
            }
            let h = hour_of(SystemTime::now());
            let rolled = std::mem::replace(&mut a.lock().hour, h) != h;
            if rolled {
                a.flush_probes();
            }
            let mut g = a.lock();
            a.write_locked(&mut g);
        })?;
        Ok(a)
    }

    fn lock(&self) -> MutexGuard<'_, Inner> {
        self.0.inner.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// Writes the buffer; on failure drops it, marks unhealthy and reports to the run log.
    fn write_locked(&self, g: &mut Inner) -> bool {
        if g.buf.is_empty() {
            return g.healthy;
        }
        let mut by_day: BTreeMap<String, String> = BTreeMap::new();
        for (day, line) in g.buf.drain(..) {
            let s = by_day.entry(day).or_default();
            s.push_str(&line);
            s.push('\n');
        }
        let mut res = Ok(());
        for (day, text) in by_day {
            let path = self.0.dir.join(format!("{day}.jsonl"));
            let r = OpenOptions::new()
                .append(true)
                .create(true)
                .mode(0o600)
                .open(&path)
                .and_then(|mut f| f.write_all(text.as_bytes()).and_then(|_| f.flush()));
            if let Err(e) = r {
                res = Err(e);
            }
        }
        g.healthy = res.is_ok();
        if let Err(e) = res {
            self.0.mirror.event(Lvl::Error, "audit_write_failed", json!({"error": e.to_string()}));
        }
        g.healthy
    }

    fn line(ev: &str, fields: &Value, now: SystemTime) -> Value {
        let mut m = match fields {
            Value::Object(m) => m.clone(),
            _ => Map::new(),
        };
        m.insert("t".into(), timestamp(now).into());
        m.insert("ev".into(), ev.into());
        m.insert("tenant".into(), TENANT.into());
        Value::Object(m)
    }

    /// Records an event. `urgent` writes it at once; otherwise it waits for the next flush (<= ~1 s).
    /// Returns false when it could not be written.
    pub fn event(&self, ev: &str, fields: Value, urgent: bool) -> bool {
        let now = SystemTime::now();
        let rec = Self::line(ev, &fields, now);
        let mut mirror = match fields {
            Value::Object(m) => m,
            _ => Map::new(),
        };
        mirror.insert("audit".into(), true.into());
        self.0.mirror.event(Lvl::Info, ev, Value::Object(mirror));
        let mut g = self.lock();
        g.buf.push((day_of(now), rec.to_string()));
        if urgent {
            self.write_locked(&mut g)
        } else {
            g.healthy
        }
    }

    /// Counts one online probe from `from` to target ID `to`.
    pub fn probe(&self, from: &Fp, to: &str) {
        *self.lock().probes.entry((*from, to.to_string())).or_insert(0) += 1;
    }

    /// Writes the pending probe counts as `probes` lines and resets them.
    #[doc(hidden)]
    pub fn flush_probes(&self) {
        let now = SystemTime::now();
        let mut g = self.lock();
        let probes = std::mem::take(&mut g.probes);
        for ((from, to), n) in probes {
            let rec = Self::line("probes", &json!({"from": from.to_string(), "to": to, "n": n}), now);
            g.buf.push((day_of(now), rec.to_string()));
        }
        self.write_locked(&mut g);
    }

    /// Writes everything pending now (the server calls this at shutdown).
    pub fn flush(&self) {
        self.flush_probes();
    }

    /// Whether the most recent write succeeded.
    pub fn healthy(&self) -> bool {
        self.lock().healthy
    }

    /// Deletes whole-day files older than `keep_days`, then the oldest ones while the total exceeds
    /// `max_mb`. Today's file is never deleted. Records one `audit_prune` if anything went.
    pub fn prune(&self, now: SystemTime) {
        let today = day_of(now);
        let cutoff = day_of(now - Duration::from_secs(u64::from(self.0.cfg.keep_days) * 86_400));
        let files = day_files(&self.0.dir);
        let mut total: u64 = files.iter().map(|f| f.2).sum();
        let limit = self.0.cfg.max_mb.saturating_mul(1024 * 1024);
        let mut gone = Vec::new();
        for (day, path, size) in files {
            if day >= today {
                continue;
            }
            if (day < cutoff || total > limit) && fs::remove_file(&path).is_ok() {
                total = total.saturating_sub(size);
                gone.push(day);
            }
        }
        if !gone.is_empty() {
            self.event("audit_prune", json!({"days": gone}), true);
        }
    }
}

/// Reads the audit records in date order. `since` keeps records at or after that time; `id` matches
/// the `id` or `to` field; `event` matches `ev`. Malformed lines are skipped.
pub fn read(data: &Path, since: Option<SystemTime>, id: Option<&str>, event: Option<&str>) -> Result<Vec<Value>> {
    let dir = data.join("audit");
    let since = since.map(|s| (day_of(s), timestamp(s)));
    let mut out = Vec::new();
    for (day, path, _) in day_files(&dir) {
        if since.as_ref().is_some_and(|(d, _)| day < *d) {
            continue;
        }
        let text = fs::read_to_string(&path).with_context(|| format!("read {}", path.display()))?;
        for l in text.lines() {
            let Ok(v) = serde_json::from_str::<Value>(l) else { continue };
            if !v.is_object() {
                continue;
            }
            if let Some((_, ts)) = &since {
                if v["t"].as_str().is_none_or(|t| t < ts.as_str()) {
                    continue;
                }
            }
            if let Some(id) = id {
                if v["id"].as_str() != Some(id) && v["to"].as_str() != Some(id) {
                    continue;
                }
            }
            if event.is_some_and(|e| v["ev"].as_str() != Some(e)) {
                continue;
            }
            out.push(v);
        }
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    fn fp(c: char) -> Fp {
        c.to_string().repeat(64).parse().unwrap()
    }
    fn cfg() -> AuditCfg {
        AuditCfg { keep_days: 180, max_mb: 256, required: false }
    }
    fn today() -> String {
        day_of(SystemTime::now())
    }
    fn lines(dir: &Path, day: &str) -> Vec<Value> {
        let t = fs::read_to_string(dir.join("audit").join(format!("{day}.jsonl"))).unwrap();
        t.lines().map(|l| serde_json::from_str(l).unwrap()).collect()
    }
    fn old_file(dir: &Path, day: &str, size: usize) {
        fs::write(dir.join("audit").join(format!("{day}.jsonl")), "x".repeat(size)).unwrap();
    }

    #[test]
    fn event_lands_in_todays_file_with_time_tenant_and_fields() {
        let d = tempfile::tempdir().unwrap();
        let a = Audit::open(d.path(), &cfg(), Log::none()).unwrap();
        assert!(a.event("enroll", json!({"fp":"ab","result":"ok","ev":"evil","tenant":"x","t":"y"}), true));
        let v = lines(d.path(), &today()).pop().unwrap();
        assert_eq!(v["ev"], "enroll");
        assert_eq!(v["tenant"], "default");
        assert!(v["t"].as_str().unwrap().ends_with('Z'));
        assert_eq!((v["fp"].as_str(), v["result"].as_str()), (Some("ab"), Some("ok")));
        assert!(a.healthy());
    }

    #[test]
    fn non_urgent_is_written_within_a_second() {
        let d = tempfile::tempdir().unwrap();
        let a = Audit::open(d.path(), &cfg(), Log::none()).unwrap();
        assert!(a.event("connect", json!({"to":"x"}), false));
        std::thread::sleep(Duration::from_millis(1500));
        assert_eq!(lines(d.path(), &today()).len(), 1);
    }

    #[test]
    fn file_is_private_and_append_only_across_reopen() {
        let d = tempfile::tempdir().unwrap();
        let a = Audit::open(d.path(), &cfg(), Log::none()).unwrap();
        a.event("one", json!({}), true);
        drop(a);
        let a = Audit::open(d.path(), &cfg(), Log::none()).unwrap();
        a.event("two", json!({}), true);
        let v = lines(d.path(), &today());
        assert_eq!((v[0]["ev"].as_str(), v[1]["ev"].as_str()), (Some("one"), Some("two")));
        let p = d.path().join("audit").join(format!("{}.jsonl", today()));
        assert_eq!(fs::metadata(p).unwrap().permissions().mode() & 0o777, 0o600);
        assert_eq!(fs::metadata(d.path().join("audit")).unwrap().permissions().mode() & 0o777, 0o700);
    }

    #[test]
    fn probes_are_merged_per_pair_per_hour() {
        let d = tempfile::tempdir().unwrap();
        let a = Audit::open(d.path(), &cfg(), Log::none()).unwrap();
        for _ in 0..5 {
            a.probe(&fp('a'), "id1");
        }
        for _ in 0..2 {
            a.probe(&fp('b'), "id1");
        }
        a.flush_probes();
        a.flush_probes();
        let v: Vec<Value> = lines(d.path(), &today()).into_iter().filter(|v| v["ev"] == "probes").collect();
        assert_eq!(v.len(), 2);
        let n = |c: char| v.iter().find(|v| v["from"] == fp(c).to_string()).unwrap()["n"].as_u64().unwrap();
        assert_eq!((n('a'), n('b')), (5, 2));
        assert!(v.iter().all(|v| v["to"] == "id1" && v["tenant"] == "default" && v["t"].is_string()));
    }

    #[test]
    fn prune_removes_old_days_and_records_it() {
        let d = tempfile::tempdir().unwrap();
        let a = Audit::open(d.path(), &AuditCfg { keep_days: 1, ..cfg() }, Log::none()).unwrap();
        for day in ["2020-01-01", "2020-01-02", "2020-01-03"] {
            old_file(d.path(), day, 10);
        }
        old_file(d.path(), "notes", 1);
        a.prune(SystemTime::now());
        for day in ["2020-01-01", "2020-01-02", "2020-01-03"] {
            assert!(!d.path().join("audit").join(format!("{day}.jsonl")).exists());
        }
        assert!(d.path().join("audit/notes.jsonl").exists());
        let v = lines(d.path(), &today()).pop().unwrap();
        assert_eq!(v["ev"], "audit_prune");
        assert_eq!(v["days"], json!(["2020-01-01", "2020-01-02", "2020-01-03"]));
    }

    #[test]
    fn open_prunes_old_days_without_a_direct_call() {
        let d = tempfile::tempdir().unwrap();
        fs::create_dir_all(d.path().join("audit")).unwrap();
        old_file(d.path(), "2020-01-01", 10);
        old_file(d.path(), "2020-01-02", 10);
        let a = Audit::open(d.path(), &AuditCfg { keep_days: 1, ..cfg() }, Log::none()).unwrap();
        assert!(!d.path().join("audit/2020-01-01.jsonl").exists());
        assert!(!d.path().join("audit/2020-01-02.jsonl").exists());
        let v = lines(d.path(), &today()).pop().unwrap();
        assert_eq!(v["ev"], "audit_prune");
        drop(a);
    }

    #[test]
    fn prune_by_size_keeps_today() {
        let d = tempfile::tempdir().unwrap();
        let a = Audit::open(d.path(), &AuditCfg { max_mb: 0, ..cfg() }, Log::none()).unwrap();
        a.event("x", json!({}), true);
        old_file(d.path(), &day_of(SystemTime::now() - Duration::from_secs(86_400 * 2)), 10);
        old_file(d.path(), &day_of(SystemTime::now() - Duration::from_secs(86_400 * 3)), 10);
        a.prune(SystemTime::now());
        let names: Vec<_> = day_files(&d.path().join("audit")).into_iter().map(|f| f.0).collect();
        assert_eq!(names, vec![today()]);
        // Today's own record survived (a deleted file would be recreated holding only audit_prune).
        let v = lines(d.path(), &today());
        assert_eq!((v[0]["ev"].as_str(), v[1]["ev"].as_str()), (Some("x"), Some("audit_prune")));
        assert_eq!(v[1]["days"].as_array().unwrap().len(), 2);
    }

    #[test]
    fn unwritable_dir_reports_unhealthy_instead_of_panicking() {
        let d = tempfile::tempdir().unwrap();
        let a = Audit::open(d.path(), &cfg(), Log::none()).unwrap();
        let dir = d.path().join("audit");
        fs::set_permissions(&dir, fs::Permissions::from_mode(0o500)).unwrap();
        if fs::write(dir.join("probe"), "x").is_ok() {
            eprintln!("skip: directory permissions do not block writes (root?)");
        } else {
            assert!(!a.event("enroll", json!({}), true));
            assert!(!a.healthy());
            fs::set_permissions(&dir, fs::Permissions::from_mode(0o700)).unwrap();
            assert!(a.event("enroll", json!({}), true));
            assert!(a.healthy());
        }
        fs::set_permissions(&dir, fs::Permissions::from_mode(0o700)).unwrap();
    }

    #[test]
    fn read_filters_by_since_id_and_event() {
        let d = tempfile::tempdir().unwrap();
        let a = Audit::open(d.path(), &cfg(), Log::none()).unwrap();
        fs::write(
            d.path().join("audit/2020-01-01.jsonl"),
            "{\"t\":\"2020-01-01T00:00:00.000Z\",\"ev\":\"enroll\",\"id\":\"A\"}\nnot json\n",
        )
        .unwrap();
        a.event("register", json!({"id":"A"}), true);
        a.event("connect", json!({"to":"A"}), true);
        a.event("connect", json!({"to":"B"}), true);
        let all = read(d.path(), None, None, None).unwrap();
        assert_eq!(all.len(), 4);
        assert_eq!(all[0]["ev"], "enroll");
        assert_eq!(read(d.path(), None, Some("A"), None).unwrap().len(), 3);
        assert_eq!(read(d.path(), None, None, Some("connect")).unwrap().len(), 2);
        assert_eq!(read(d.path(), None, Some("B"), Some("connect")).unwrap().len(), 1);
        let since = SystemTime::now() - Duration::from_secs(3600);
        assert_eq!(read(d.path(), Some(since), None, None).unwrap().len(), 3);
        assert!(read(d.path(), Some(SystemTime::now() + Duration::from_secs(3600)), None, None).unwrap().is_empty());
        assert!(read(&d.path().join("nope"), None, None, None).unwrap().is_empty());
    }
}
