//! The 1 h ring and the warning rules (spec §5-§7). Every threshold lives here and nowhere else.

use super::sample::*;
use serde::Serialize;
use serde_json::{json, Map, Value};
use std::cmp::Reverse;
use std::collections::VecDeque;

pub const KEEP: usize = 720;

const GB: f64 = 1e9;
const HOLD_S: u64 = 60; // a fall waits a full minute
const SUSTAIN_S: u64 = 300; // CPU / GPU / heat
const TREND_S: u64 = 600;

#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Debug, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Level {
    Normal,
    Warn,
    Danger,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Warning {
    pub item: String,
    pub level: Level,
    pub text: String,
    pub eta_min: Option<u64>,
}

/// What the rules say about one item right now, before hysteresis.
struct Raw {
    key: String,
    level: Level,
    text: String,
    eta: Option<u64>,
}

/// Per-item hysteresis: the level we show, and since when the raw level has been lower.
struct Held {
    key: String,
    level: Level,
    back_since: Option<u64>,
    text: String,
    eta: Option<u64>,
}

#[derive(Default)]
pub struct History {
    ring: VecDeque<Sample>,
    held: Vec<Held>,
}

fn lvl(danger: bool, warn: bool) -> Level {
    if danger {
        Level::Danger
    } else if warn {
        Level::Warn
    } else {
        Level::Normal
    }
}

/// Least-squares slope (units per second) of `pts` = (at, value). Needs >= 2 points spanning >= 300 s.
fn slope(pts: &[(f64, f64)]) -> Option<f64> {
    let (first, last) = (pts.first()?, pts.last()?);
    if pts.len() < 2 || last.0 - first.0 < 300.0 {
        return None;
    }
    let n = pts.len() as f64;
    let (mx, my) = (pts.iter().map(|p| p.0).sum::<f64>() / n, pts.iter().map(|p| p.1).sum::<f64>() / n);
    let sxx: f64 = pts.iter().map(|p| (p.0 - mx).powi(2)).sum();
    let sxy: f64 = pts.iter().map(|p| (p.0 - mx) * (p.1 - my)).sum();
    (sxx > 0.0).then(|| sxy / sxx)
}

/// Minutes until a falling value reaches `floor`, only when it fell by at least `min_used` over the window.
fn eta_min(pts: &[(f64, f64)], min_used: f64, floor: f64) -> Option<u64> {
    let m = slope(pts).filter(|m| *m < 0.0)?;
    let (first, last) = (pts.first()?.1, pts.last()?.1);
    if first - last < min_used {
        return None;
    }
    let remaining = last - floor;
    if remaining <= 0.0 {
        return Some(0);
    }
    Some((remaining / -m / 60.0 - 1e-6).ceil().max(0.0) as u64)
}

/// A fall of at least 1 GB or 1% of `total` counts as a real fill.
fn min_used(total: f64) -> f64 {
    (total * 0.01).min(GB)
}

fn pct_text(f: f64) -> i64 {
    (f * 100.0).round() as i64
}

fn home_short(path: &str, home: Option<&str>) -> String {
    match home {
        Some(h) if path == h => "~".into(),
        Some(h) if path.starts_with(&format!("{h}/")) => format!("~{}", &path[h.len()..]),
        _ => path.into(),
    }
}

fn cover_hint(d: &Disk) -> String {
    let home = d.paths.iter().find(|c| c.kind == CoverKind::Home).map(|c| c.path.as_str());
    let pick = d.paths.iter().find(|c| c.kind == CoverKind::Term).or_else(|| d.paths.first());
    pick.map_or(String::new(), |c| format!("，含 {}", home_short(&c.path, home)))
}

fn free_frac(d: &Disk) -> Option<f64> {
    (!d.unreadable && d.total > 0).then(|| d.avail as f64 / d.total as f64)
}

fn tightest_disk(s: &Sample) -> Option<f64> {
    s.disks.iter().filter_map(free_frac).reduce(f64::min)
}

fn heat_num(l: HeatLevel) -> u8 {
    match l {
        HeatLevel::Normal => 0,
        HeatLevel::Hot => 1,
        HeatLevel::Serious => 2,
        HeatLevel::Critical => 3,
    }
}

fn to_json<T: Serialize>(v: T) -> Value {
    serde_json::to_value(v).unwrap_or(Value::Null)
}

impl History {
    pub fn new() -> Self {
        Self::default()
    }

    /// Drops the oldest past `KEEP`, then re-evaluates levels.
    pub fn push(&mut self, s: Sample) {
        self.ring.push_back(s);
        while self.ring.len() > KEEP {
            self.ring.pop_front();
        }
        let now = self.ring.back().map_or(0, |s| s.at);
        let raws = self.evaluate(now);
        let mut old = std::mem::take(&mut self.held);
        for r in raws {
            let mut h = match old.iter().position(|h| h.key == r.key) {
                Some(i) => old.swap_remove(i),
                None => Held { key: r.key.clone(), level: Level::Normal, back_since: None, text: String::new(), eta: None },
            };
            if r.level >= h.level {
                h.back_since = None;
                if r.level > Level::Normal || r.level > h.level {
                    (h.level, h.text, h.eta) = (r.level, r.text, r.eta);
                }
            } else {
                let since = *h.back_since.get_or_insert(now);
                if now.saturating_sub(since) >= HOLD_S {
                    (h.level, h.text, h.eta, h.back_since) = (r.level, r.text, r.eta, None);
                }
            }
            self.held.push(h);
        }
        // An item with no reading this sample keeps what it held. Only a disk that is gone from the list loses it.
        let disks = &self.ring.back().map(|s| s.disks.as_slice()).unwrap_or_default();
        for h in old {
            let gone = h.key.split_once(':').is_some_and(|(_, mount)| !disks.iter().any(|d| d.mount == mount));
            if !gone {
                self.held.push(h);
            }
        }
    }

    fn level_of(&self, key: &str) -> Level {
        self.held.iter().find(|h| h.key == key).map_or(Level::Normal, |h| h.level)
    }

    /// Items above Normal after hysteresis, Danger first.
    pub fn warnings(&self) -> Vec<Warning> {
        let mut v: Vec<Warning> = self
            .held
            .iter()
            .filter(|h| h.level > Level::Normal)
            .map(|h| Warning { item: h.key.clone(), level: h.level, text: h.text.clone(), eta_min: h.eta })
            .collect();
        v.sort_by_key(|w| Reverse(w.level));
        v
    }

    /// (at, value) of the samples with `at >= now - 600` that have a value.
    fn window(&self, now: u64, f: impl Fn(&Sample) -> Option<f64>) -> Vec<(f64, f64)> {
        let from = now.saturating_sub(TREND_S);
        self.ring.iter().filter(|s| s.at >= from).filter_map(|s| f(s).map(|v| (s.at as f64, v))).collect()
    }

    fn disk_pts(&self, now: u64, mount: &str) -> Vec<(f64, f64)> {
        self.window(now, |x| x.disks.iter().find(|y| y.mount == mount && !y.unreadable).map(|y| y.avail as f64))
    }

    /// Start (unix s) of the unbroken run of newest samples satisfying `pred`.
    fn run_start(&self, pred: impl Fn(&Sample) -> bool) -> Option<u64> {
        let mut start = None;
        for s in self.ring.iter().rev() {
            if !pred(s) {
                break;
            }
            start = Some(s.at);
        }
        start
    }

    fn evaluate(&self, now: u64) -> Vec<Raw> {
        let Some(s) = self.ring.back() else { return vec![] };
        let mut out = vec![];
        let mut put = |key: &str, level, text: String, eta| out.push(Raw { key: key.into(), level, text, eta });
        type Get = fn(&Sample) -> Option<f32>;
        let loads: [(&str, &str, Get); 2] = [
            ("cpu", "CPU 持续 90% 以上", |s| s.cpu.as_ref().map(|c| c.pct)),
            ("gpu", "GPU 持续 90% 以上", |s| s.gpu),
        ];
        for (key, text, get) in loads {
            if get(s).is_some() {
                let busy = self.run_start(|x| get(x).is_some_and(|p| p >= 90.0)).is_some_and(|t| now.saturating_sub(t) >= SUSTAIN_S);
                put(key, if busy { Level::Warn } else { Level::Normal }, text.into(), None);
            }
        }
        if let Some(m) = s.mem.as_ref().filter(|m| m.total > 0) {
            let total = m.total as f64;
            let frac = m.avail as f64 / total;
            let by_frac = lvl(frac < 0.05, frac < 0.10);
            let by_press = match m.pressure {
                Some(Pressure::Critical) => Level::Danger,
                Some(Pressure::Warn) => Level::Warn,
                _ => Level::Normal,
            };
            let pts = self.window(now, |x| x.mem.as_ref().map(|m| m.avail as f64));
            let eta = eta_min(&pts, min_used(total), total * 0.05).filter(|e| *e <= 30);
            let by_trend = if eta.is_some() { Level::Warn } else { Level::Normal };
            let level = by_frac.max(by_press).max(by_trend);
            let (text, eta) = if level == Level::Normal {
                (String::new(), None)
            } else if by_frac >= by_press && by_frac >= by_trend {
                (format!("内存只剩 {}%", pct_text(frac)), None)
            } else if by_press >= by_trend {
                ("内存压力高".into(), None)
            } else {
                (format!("内存约 {} 分钟后用完", eta.unwrap_or(0)), eta)
            };
            put("mem", level, text, eta);
        }
        if let Some(h) = &s.heat {
            let hot = self.run_start(|x| x.heat.as_ref().is_some_and(|h| h.level >= HeatLevel::Hot));
            let (level, text) = match h.level {
                HeatLevel::Serious | HeatLevel::Critical => (Level::Danger, "过热，系统正在降频".into()),
                HeatLevel::Hot if hot.is_some_and(|t| now.saturating_sub(t) >= SUSTAIN_S) => {
                    (Level::Warn, format!("偏热已持续 {} 分钟", now.saturating_sub(hot.unwrap_or(now)) / 60))
                }
                _ => (Level::Normal, String::new()),
            };
            put("heat", level, text, None);
        }
        if let Some(b) = &s.battery {
            let low = !b.plugged;
            let level = lvl(low && b.pct <= 10.0, low && b.pct <= 20.0);
            let text = if level > Level::Normal { format!("电池只剩 {}%，没接电源", b.pct.round() as i64) } else { String::new() };
            put("battery", level, text, None);
        }
        for d in s.disks.iter().filter(|d| !d.unreadable && d.total > 0) {
            let (total, avail) = (d.total as f64, d.avail as f64);
            let frac = avail / total;
            let stat = lvl(frac < 0.05 && avail < 5.0 * GB || avail < GB, frac < 0.10 && avail < 20.0 * GB);
            let eta = eta_min(&self.disk_pts(now, &d.mount), min_used(total), 0.0);
            let trend = match eta {
                Some(e) if e <= 15 => Level::Danger,
                Some(e) if e <= 60 => Level::Warn,
                _ => Level::Normal,
            };
            let level = stat.max(trend);
            let (text, eta) = if level == Level::Normal {
                (String::new(), None)
            } else if trend >= stat {
                let e = eta.unwrap_or(0);
                (format!("磁盘约 {e} 分钟后写满（{}，剩 {}%{}）", d.mount, pct_text(frac), cover_hint(d)), eta)
            } else {
                (format!("磁盘只剩 {:.1} GB（{}，剩 {}%{}）", avail / GB, d.mount, pct_text(frac), cover_hint(d)), None)
            };
            put(&format!("disk:{}", d.mount), level, text, eta);
            if let Some((ft, ff)) = d.files.filter(|f| f.0 > 0) {
                let free = ff as f64 / ft as f64;
                let level = lvl(free < 0.05, free < 0.10);
                let text = if level > Level::Normal { format!("inode 只剩 {}%（{}）", pct_text(free), d.mount) } else { String::new() };
                put(&format!("inode:{}", d.mount), level, text, None);
            }
        }
        out
    }

    /// (0..=100, tightest item); None before any readable item.
    pub fn headroom(&self) -> Option<(u8, &'static str)> {
        let s = self.ring.back()?;
        let avg = |get: fn(&Sample) -> Option<f32>| {
            let v: Vec<f64> = self.ring.iter().filter(|x| x.at + 60 >= s.at).filter_map(get).map(f64::from).collect();
            (!v.is_empty()).then(|| 1.0 - v.iter().sum::<f64>() / v.len() as f64 / 100.0)
        };
        let shares = [
            ("cpu", avg(|x| x.cpu.as_ref().map(|c| c.pct))),
            ("gpu", avg(|x| x.gpu)),
            ("mem", s.mem.as_ref().filter(|m| m.total > 0).map(|m| m.avail as f64 / m.total as f64)),
            ("disk", tightest_disk(s).map(|f| (f / 0.20).min(1.0))),
            ("heat", s.heat.as_ref().map(|h| [1.0, 0.6, 0.3, 0.0][heat_num(h.level) as usize])),
            ("battery", s.battery.as_ref().map(|b| if b.plugged { 1.0 } else { (f64::from(b.pct) / 50.0).min(1.0) })),
        ];
        let mut best: Option<(&'static str, f64)> = None;
        for (name, v) in shares {
            if let Some(v) = v {
                if best.is_none_or(|b| v < b.1) {
                    best = Some((name, v));
                }
            }
        }
        best.map(|(n, v)| ((v.clamp(0.0, 1.0) * 100.0).round() as u8, n))
    }

    /// The `load` reply body without `ok` / `history`.
    pub fn snapshot(&self, term: bool) -> Value {
        let Some(s) = self.ring.back() else {
            return json!({"at": 0, "term": term, "items": {}, "disks": [], "warnings": []});
        };
        let mut o = Map::new();
        o.insert("at".into(), s.at.into());
        if let Some((h, t)) = self.headroom() {
            o.insert("headroom".into(), h.into());
            o.insert("tightest".into(), t.into());
        }
        o.insert("term".into(), term.into());
        let mut items = Map::new();
        if let Some(c) = &s.cpu {
            let mut v = json!({"pct": c.pct, "cores": c.cores});
            if let Some(l) = c.load1 {
                v["load1"] = l.into();
            }
            items.insert("cpu".into(), v);
        }
        if let Some(g) = s.gpu {
            items.insert("gpu".into(), json!({"pct": g}));
        }
        if let Some(m) = &s.mem {
            let mut v = json!({"total": m.total, "avail": m.avail});
            if let Some(w) = m.swap_used {
                v["swap_used"] = w.into();
            }
            if let Some(p) = m.pressure {
                v["pressure"] = to_json(p);
            }
            items.insert("mem".into(), v);
        }
        if let Some(h) = &s.heat {
            let mut v = json!({"level": to_json(h.level)});
            if let Some(c) = h.celsius {
                v["celsius"] = c.into();
            }
            items.insert("heat".into(), v);
        }
        if let Some(b) = &s.battery {
            items.insert("battery".into(), json!({"pct": b.pct, "plugged": b.plugged}));
        }
        o.insert("items".into(), items.into());
        let disks: Vec<Value> = s
            .disks
            .iter()
            .map(|d| {
                let paths: Vec<Value> = d
                    .paths
                    .iter()
                    .map(|c| {
                        let mut v = json!({"kind": to_json(c.kind), "path": c.path});
                        if let Some(t) = &c.term {
                            v["term"] = t.clone().into();
                        }
                        v
                    })
                    .collect();
                if d.unreadable {
                    return json!({"mount": d.mount, "paths": paths, "unreadable": true});
                }
                let level = self.level_of(&format!("disk:{}", d.mount));
                let mut v = json!({"mount": d.mount, "total": d.total, "avail": d.avail,
                                   "level": to_json(level), "paths": paths});
                if let Some((ft, ff)) = d.files.filter(|f| f.0 > 0) {
                    v["inode_free_pct"] = (ff as f64 * 100.0 / ft as f64).into();
                }
                if let Some(e) = eta_min(&self.disk_pts(s.at, &d.mount), min_used(d.total as f64), 0.0) {
                    v["eta_min"] = e.into();
                }
                v
            })
            .collect();
        o.insert("disks".into(), disks.into());
        let warnings: Vec<Value> = self
            .warnings()
            .iter()
            .map(|w| {
                let mut v = json!({"item": w.item, "level": to_json(w.level), "text": w.text});
                if let Some(e) = w.eta_min {
                    v["eta_min"] = e.into();
                }
                v
            })
            .collect();
        o.insert("warnings".into(), warnings.into());
        o.into()
    }

    fn point(s: &Sample) -> Value {
        let mut v = json!({"at": s.at});
        if let Some(c) = &s.cpu {
            v["cpu"] = c.pct.into();
        }
        if let Some(g) = s.gpu {
            v["gpu"] = g.into();
        }
        if let Some(m) = s.mem.as_ref().filter(|m| m.total > 0) {
            v["mem"] = (m.avail as f64 / m.total as f64).into();
        }
        if let Some(h) = &s.heat {
            v["heat"] = heat_num(h.level).into();
        }
        if let Some(f) = tightest_disk(s) {
            v["disk"] = f.into();
        }
        v
    }

    pub fn history_json(&self) -> Value {
        self.ring.iter().map(Self::point).collect::<Vec<_>>().into()
    }

    /// The newest point, `null` before any sample.
    pub fn point_json(&self) -> Value {
        self.ring.back().map_or(Value::Null, Self::point)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    const T0: u64 = 1_000_000;
    const GB: u64 = 1_000_000_000;

    fn series(n: usize, every_s: u64, f: impl Fn(usize) -> Sample) -> History {
        let mut h = History::new();
        for i in 0..n {
            let mut s = f(i);
            s.at = T0 + i as u64 * every_s;
            h.push(s);
        }
        h
    }
    fn disk(total: u64, avail: u64) -> Disk {
        Disk { dev: 1, mount: "/".into(), total, avail, files: None, paths: vec![], unreadable: false }
    }
    fn with_disk(d: Disk) -> Sample {
        Sample { disks: vec![d], ..Default::default() }
    }
    fn mem(total: u64, avail: u64, pressure: Option<Pressure>) -> Sample {
        Sample { mem: Some(Mem { total, avail, swap_used: None, pressure }), ..Default::default() }
    }
    fn level(h: &History, item: &str) -> Level {
        h.warnings().iter().find(|w| w.item == item).map_or(Level::Normal, |w| w.level)
    }
    fn one(s: Sample) -> History {
        series(1, 5, |_| s.clone())
    }

    #[test]
    fn disk_and_rule() {
        let l = |t: u64, a: u64| level(&one(with_disk(disk(t, a))), "disk:/");
        assert_eq!(l(2000 * GB, 180 * GB), Level::Normal);
        assert_eq!(l(100 * GB, 9 * GB), Level::Warn);
        assert_eq!(l(100 * GB, 4 * GB), Level::Danger);
        assert_eq!(l(2000 * GB, 9 * GB / 10), Level::Danger);
    }

    #[test]
    fn disk_trend_needs_a_real_fill() {
        // 121 samples over 10 min, losing `lost` bytes, ending at `end`.
        let fill = |total: u64, end: u64, lost: u64| {
            series(121, 5, |i| with_disk(disk(total, end + lost - lost * i as u64 / 120)))
        };
        let h = fill(1000 * GB, 10 * GB, 2 * GB);
        let w = &h.warnings()[0];
        assert_eq!((w.level, w.eta_min), (Level::Warn, Some(50)));
        assert_eq!(w.text, "磁盘约 50 分钟后写满（/，剩 1%）");
        let h = fill(2000 * GB, 1000 * GB, GB / 2);
        assert!(h.warnings().is_empty());
        assert!(h.snapshot(false)["disks"][0].get("eta_min").is_none());
        let h = fill(1000 * GB, 20 * GB, 15 * GB);
        assert_eq!(h.warnings()[0].level, Level::Danger);
    }

    #[test]
    fn inode_levels() {
        let l = |free: u64| {
            let mut d = disk(2000 * GB, 1000 * GB);
            d.files = Some((100, free));
            level(&one(with_disk(d)), "inode:/")
        };
        assert_eq!((l(9), l(4), l(50)), (Level::Warn, Level::Danger, Level::Normal));
        let mut d = disk(2000 * GB, 1000 * GB);
        d.files = Some((100, 9));
        assert_eq!(one(with_disk(d)).warnings()[0].text, "inode 只剩 9%（/）");
    }

    #[test]
    fn memory_levels() {
        let l = |a: u64, p| level(&one(mem(100, a, p)), "mem");
        assert_eq!((l(9, None), l(4, None), l(50, None)), (Level::Warn, Level::Danger, Level::Normal));
        assert_eq!(l(50, Some(Pressure::Warn)), Level::Warn);
        assert_eq!(l(50, Some(Pressure::Critical)), Level::Danger);
        assert_eq!(one(mem(100, 9, None)).warnings()[0].text, "内存只剩 9%");
        assert_eq!(one(mem(100, 50, Some(Pressure::Warn))).warnings()[0].text, "内存压力高");
        // 1% per minute, ending at 30%: 25 minutes to 5%.
        let h = series(121, 5, |i| mem(100 * GB, 40 * GB - GB * i as u64 / 12, None));
        let w = &h.warnings()[0];
        assert_eq!((w.level, w.eta_min, w.text.as_str()), (Level::Warn, Some(25), "内存约 25 分钟后用完"));
    }

    #[test]
    fn cpu_sustained_five_minutes() {
        let hot = |_| Sample { cpu: Some(Cpu { pct: 95.0, cores: 8, load1: None }), ..Default::default() };
        assert_eq!(level(&series(60, 5, hot), "cpu"), Level::Normal); // 4 min 55 s
        let h = series(61, 5, hot); // 5 min
        assert_eq!(level(&h, "cpu"), Level::Warn);
        assert_eq!(h.warnings()[0].text, "CPU 持续 90% 以上");
        let dip = |i| {
            let pct = if i == 30 { 50.0 } else { 95.0 };
            Sample { cpu: Some(Cpu { pct, cores: 8, load1: None }), ..Default::default() }
        };
        assert_eq!(level(&series(61, 5, dip), "cpu"), Level::Normal);
        let g = series(61, 5, |_| Sample { gpu: Some(95.0), ..Default::default() });
        assert_eq!(g.warnings()[0].text, "GPU 持续 90% 以上");
    }

    #[test]
    fn heat_levels() {
        let heat = |l| Sample { heat: Some(Heat { level: l, celsius: None }), ..Default::default() };
        assert_eq!(level(&series(48, 5, |_| heat(HeatLevel::Hot)), "heat"), Level::Normal); // 4 min 35 s
        let h = series(61, 5, |_| heat(HeatLevel::Hot));
        assert_eq!((level(&h, "heat"), h.warnings()[0].text.as_str()), (Level::Warn, "偏热已持续 5 分钟"));
        let h = one(heat(HeatLevel::Serious));
        assert_eq!((level(&h, "heat"), h.warnings()[0].text.as_str()), (Level::Danger, "过热，系统正在降频"));
    }

    #[test]
    fn battery_levels() {
        let b = |pct, plugged| level(&one(Sample { battery: Some(Battery { pct, plugged }), ..Default::default() }), "battery");
        assert_eq!((b(19.0, false), b(9.0, false), b(5.0, true)), (Level::Warn, Level::Danger, Level::Normal));
        let h = one(Sample { battery: Some(Battery { pct: 19.0, plugged: false }), ..Default::default() });
        assert_eq!(h.warnings()[0].text, "电池只剩 19%，没接电源");
    }

    fn pct_disk(pct: f64) -> Sample {
        with_disk(disk(100 * GB, (pct / 100.0 * 100.0 * GB as f64) as u64))
    }

    #[test]
    fn flapping_disk_rises_once_and_holds() {
        let mut h = History::new();
        for i in 0..37 {
            let mut s = pct_disk(if i % 2 == 0 { 9.9 } else { 10.1 });
            s.at = T0 + i * 5;
            h.push(s);
            assert_eq!(level(&h, "disk:/"), Level::Warn, "sample {i}");
        }
        // 37 samples ended on a 9.9. 12 samples (55 s) back inside: still Warn; the 13th makes a full minute.
        for i in 0..13 {
            let mut s = pct_disk(10.1);
            s.at = T0 + (37 + i) * 5;
            h.push(s);
            let want = if i < 12 { Level::Warn } else { Level::Normal };
            assert_eq!(level(&h, "disk:/"), want, "back {i}");
        }
    }

    #[test]
    fn danger_falls_to_warn_after_a_minute() {
        let h = series(14, 5, |i| pct_disk(if i == 0 { 4.0 } else { 8.0 }));
        // back inside from sample 1 (t=5); at t=65 (sample 13) a minute has passed
        let mut h2 = series(13, 5, |i| pct_disk(if i == 0 { 4.0 } else { 8.0 }));
        assert_eq!(level(&h2, "disk:/"), Level::Danger);
        assert_eq!(level(&h, "disk:/"), Level::Warn);
        let mut s = pct_disk(8.0);
        s.at = T0 + 65;
        h2.push(s);
        assert_eq!(level(&h2, "disk:/"), Level::Warn);
    }

    #[test]
    fn headroom_min_and_tightest() {
        let full = Sample {
            cpu: Some(Cpu { pct: 42.0, cores: 4, load1: None }),
            mem: mem(100, 25, None).mem,
            heat: Some(Heat { level: HeatLevel::Hot, celsius: None }),
            disks: vec![disk(100 * GB, 6 * GB)],
            ..Default::default()
        };
        assert_eq!(one(full.clone()).headroom(), Some((25, "mem")));
        let mut no_mem = full;
        no_mem.mem = None;
        assert_eq!(one(no_mem).headroom(), Some((30, "disk")));
        assert_eq!(one(Sample::default()).headroom(), None);
        assert_eq!(History::new().headroom(), None);
    }

    #[test]
    fn ring_is_capped() {
        let h = series(2000, 5, |_| Sample { gpu: Some(1.0), ..Default::default() });
        assert_eq!(h.history_json().as_array().unwrap().len(), 720);
        assert_eq!(h.point_json()["at"], T0 + 1999 * 5);
    }

    #[test]
    fn snapshot_shape() {
        let mut d = disk(100 * GB, 6 * GB);
        d.files = Some((1000, 310));
        d.paths = vec![
            Covered { kind: CoverKind::Home, path: "/Users/x".into(), term: None },
            Covered { kind: CoverKind::Term, path: "/Users/x/git/rapp".into(), term: Some("t1".into()) },
        ];
        let gone = Disk {
            dev: 2,
            mount: "/Volumes/nas".into(),
            total: 0,
            avail: 0,
            files: None,
            paths: vec![Covered { kind: CoverKind::Data, path: "/Volumes/nas/d".into(), term: None }],
            unreadable: true,
        };
        let s = Sample {
            at: 1764100000,
            cpu: Some(Cpu { pct: 42.0, cores: 8, load1: Some(3.5) }),
            gpu: None,
            mem: Some(Mem { total: 16 * GB, avail: 8 * GB, swap_used: Some(GB), pressure: Some(Pressure::Normal) }),
            heat: Some(Heat { level: HeatLevel::Normal, celsius: None }),
            disks: vec![d, gone],
            battery: None,
        };
        let want = json!({
            "at": 1764100000, "headroom": 30, "tightest": "disk", "term": true,
            "items": {
                "cpu": {"pct": 42.0, "cores": 8, "load1": 3.5},
                "mem": {"total": 16 * GB, "avail": 8 * GB, "swap_used": GB, "pressure": "normal"},
                "heat": {"level": "normal"}
            },
            "disks": [
                {"mount": "/", "total": 100 * GB, "avail": 6 * GB, "inode_free_pct": 31.0, "level": "warn",
                 "paths": [{"kind": "home", "path": "/Users/x"},
                           {"kind": "term", "path": "/Users/x/git/rapp", "term": "t1"}]},
                {"mount": "/Volumes/nas", "unreadable": true,
                 "paths": [{"kind": "data", "path": "/Volumes/nas/d"}]}
            ],
            "warnings": [{"item": "disk:/", "level": "warn",
                          "text": "磁盘只剩 6.0 GB（/，剩 6%，含 ~/git/rapp）"}]
        });
        let mut h = History::new();
        h.push(s);
        assert_eq!(h.snapshot(true), want);
    }
    fn at(mut s: Sample, t: u64) -> Sample {
        s.at = t;
        s
    }

    #[test]
    fn clock_stepping_back_does_not_panic_or_warn() {
        let mut h = History::new();
        let busy = |t| at(Sample { cpu: Some(Cpu { pct: 99.0, cores: 4, load1: None }), heat: Some(Heat { level: HeatLevel::Hot, celsius: None }), ..Default::default() }, t);
        h.push(busy(T0 + 1000));
        h.push(busy(T0 + 10)); // the wall clock went back
        h.push(at(pct_disk(8.0), T0 + 5));
        assert!(h.warnings().iter().all(|w| w.item != "cpu" && w.item != "heat"), "{:?}", h.warnings());
    }

    #[test]
    fn held_disk_warning_survives_an_unreadable_sample() {
        let mut h = History::new();
        h.push(at(pct_disk(8.0), T0));
        assert_eq!(level(&h, "disk:/"), Level::Warn);
        let mut d = disk(100 * GB, 0);
        d.unreadable = true;
        h.push(at(with_disk(d), T0 + 5));
        assert_eq!(level(&h, "disk:/"), Level::Warn);
    }

    #[test]
    fn held_cpu_warning_survives_a_missed_reading() {
        let mut h = History::new();
        for i in 0..=61 {
            h.push(at(Sample { cpu: Some(Cpu { pct: 95.0, cores: 4, load1: None }), ..Default::default() }, T0 + i * 5));
        }
        assert_eq!(level(&h, "cpu"), Level::Warn);
        h.push(at(Sample::default(), T0 + 62 * 5));
        assert_eq!(level(&h, "cpu"), Level::Warn);
    }

    #[test]
    fn a_disappearing_disk_drops_its_state() {
        let mut h = History::new();
        h.push(at(pct_disk(8.0), T0));
        assert_eq!(level(&h, "disk:/"), Level::Warn);
        h.push(at(Sample::default(), T0 + 5));
        assert_eq!(level(&h, "disk:/"), Level::Normal);
    }


    #[test]
    fn history_of_720_widest_points_stays_under_half_the_history_line() {
        // point() writes only at, cpu, gpu, the mem ratio, the heat level and the tightest disk's ratio.
        // Each is its longest form: a 10-digit at; an f32 0.1 widened to f64 has 17 decimals; ratios that do not divide; top heat level.
        let mut h = History::new();
        for i in 0..KEEP {
            h.push(Sample {
                at: 4_000_000_000 + i as u64,
                cpu: Some(Cpu {
                    pct: 0.1,
                    cores: 8,
                    load1: None,
                }),
                gpu: Some(0.1),
                mem: Some(Mem {
                    total: 9_876_543_211,
                    avail: 1_234_567_891,
                    swap_used: None,
                    pressure: None,
                }),
                heat: Some(Heat {
                    level: HeatLevel::Critical,
                    celsius: None,
                }),
                disks: vec![disk(9_876_543_211, 1_234_567_891)],
                ..Default::default()
            });
        }
        let line = serde_json::to_vec(&h.history_json()).unwrap().len();
        // About 95,000 bytes: over 64 KiB (the case being fixed), under half of HISTORY_LINE.
        assert!(
            rapp_net::line::MAX_LINE < line && line < rapp_net::line::HISTORY_LINE / 2,
            "{line}"
        );
    }
}
