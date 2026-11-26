//! Linux collector: /proc/stat, /proc/loadavg, /proc/meminfo, /sys/class/thermal.

#![cfg_attr(not(target_os = "linux"), allow(dead_code))]

use super::{Heat, HeatLevel, Mem};
use std::path::Path;

/// CPU busy percentage between two `cpu` lines of /proc/stat. idle = idle + iowait.
/// guest time is already inside user/nice, so only the first 8 fields count.
pub(crate) fn cpu_pct(prev: &[u64], now: &[u64]) -> Option<f32> {
    if prev.len() < 5 || now.len() < 5 {
        return None;
    }
    let n = prev.len().min(now.len()).min(8);
    let total = |v: &[u64]| v[..n].iter().sum::<u64>();
    let idle = |v: &[u64]| v[3] + v[4];
    let dt = total(now).checked_sub(total(prev))?;
    let di = idle(now).checked_sub(idle(prev))?;
    if dt == 0 {
        return None;
    }
    Some((dt.saturating_sub(di)) as f32 / dt as f32 * 100.0)
}

/// The aggregate `cpu` line's fields, and the number of `cpuN` lines.
pub(crate) fn parse_stat(text: &str) -> Option<(Vec<u64>, u32)> {
    let mut agg = None;
    let mut cores = 0u32;
    for line in text.lines() {
        let mut it = line.split_whitespace();
        let Some(name) = it.next() else { continue };
        if name == "cpu" {
            agg = Some(it.map(|f| f.parse::<u64>().ok()).collect::<Option<Vec<_>>>()?);
        } else if name.strip_prefix("cpu").is_some_and(|n| n.parse::<u32>().is_ok()) {
            cores += 1;
        }
    }
    agg.map(|a| (a, cores))
}

pub(crate) fn parse_loadavg(text: &str) -> Option<f32> {
    text.split_whitespace().next()?.parse().ok()
}

pub(crate) fn parse_meminfo(text: &str) -> Option<Mem> {
    let (mut total, mut avail, mut swap_total, mut swap_free) = (None, None, None, None);
    for line in text.lines() {
        let Some((k, v)) = line.split_once(':') else { continue };
        let kb = v.split_whitespace().next().and_then(|n| n.parse::<u64>().ok());
        match k {
            "MemTotal" => total = kb,
            "MemAvailable" => avail = kb,
            "SwapTotal" => swap_total = kb,
            "SwapFree" => swap_free = kb,
            _ => {}
        }
    }
    Some(Mem {
        total: total? * 1024,
        avail: avail? * 1024,
        swap_used: swap_total.zip(swap_free).map(|(t, f)| t.saturating_sub(f) * 1024),
        pressure: None,
    })
}

/// The hottest `thermal_zone*/temp` (millidegrees).
pub(crate) fn heat_from_zones(dir: &Path) -> Option<Heat> {
    let mut max: Option<i64> = None;
    for e in std::fs::read_dir(dir).ok()?.flatten() {
        if !e.file_name().to_string_lossy().starts_with("thermal_zone") {
            continue;
        }
        let Ok(t) = std::fs::read_to_string(e.path().join("temp")) else { continue };
        if let Ok(m) = t.trim().parse::<i64>() {
            max = Some(max.map_or(m, |x| x.max(m)));
        }
    }
    let c = max? as f32 / 1000.0;
    let level = if c >= 95.0 {
        HeatLevel::Critical
    } else if c >= 90.0 {
        HeatLevel::Serious
    } else if c >= 80.0 {
        HeatLevel::Hot
    } else {
        HeatLevel::Normal
    };
    Some(Heat { level, celsius: Some(c) })
}

#[cfg(target_os = "linux")]
#[derive(Default)]
pub struct LinuxSampler {
    prev: Option<Vec<u64>>,
}

#[cfg(target_os = "linux")]
impl super::Sampler for LinuxSampler {
    fn sample(&mut self) -> super::Sample {
        let mut s = super::Sample { at: super::now_secs(), ..Default::default() };
        let stat = std::fs::read_to_string("/proc/stat").ok().and_then(|t| parse_stat(&t));
        if let Some((ticks, cores)) = stat {
            let pct = self.prev.as_deref().and_then(|p| cpu_pct(p, &ticks));
            if let Some(pct) = pct {
                let load1 = std::fs::read_to_string("/proc/loadavg").ok().and_then(|t| parse_loadavg(&t));
                s.cpu = Some(super::Cpu { pct, cores, load1 });
            }
            self.prev = Some(ticks);
        }
        s.mem = std::fs::read_to_string("/proc/meminfo").ok().and_then(|t| parse_meminfo(&t));
        s.heat = heat_from_zones(Path::new("/sys/class/thermal"));
        s
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const STAT1: &str = "cpu  100 0 100 700 100 0 0 0 0 0\ncpu0 50 0 50 350 50 0 0 0 0 0\ncpu1 50 0 50 350 50 0 0 0 0 0\nintr 1\n";
    const STAT2: &str = "cpu  200 0 200 750 150 0 0 0 0 0\ncpu0 100 0 100 375 75 0 0 0 0 0\ncpu1 100 0 100 375 75 0 0 0 0 0\n";

    #[test]
    fn stat_and_cpu_pct() {
        let (a, cores) = parse_stat(STAT1).unwrap();
        assert_eq!(cores, 2);
        let (b, _) = parse_stat(STAT2).unwrap();
        // total delta 300, idle delta 100 (idle 50 + iowait 50) -> 66.67%
        let p = cpu_pct(&a, &b).unwrap();
        assert!((p - 66.666).abs() < 0.1, "{p}");
        assert_eq!(cpu_pct(&a, &a), None);
        assert_eq!(parse_stat("intr 1\n"), None);
    }

    #[test]
    fn loadavg() {
        assert_eq!(parse_loadavg("0.52 0.40 0.30 1/200 999\n"), Some(0.52));
        assert_eq!(parse_loadavg(""), None);
    }

    #[test]
    fn meminfo() {
        let t = "MemTotal:       1000 kB\nMemFree: 1 kB\nMemAvailable:    400 kB\nSwapTotal: 200 kB\nSwapFree: 150 kB\n";
        let m = parse_meminfo(t).unwrap();
        assert_eq!(m.total, 1000 * 1024);
        assert_eq!(m.avail, 400 * 1024);
        assert_eq!(m.swap_used, Some(50 * 1024));
        assert_eq!(m.pressure, None);
        assert!(parse_meminfo("MemTotal: 1 kB\n").is_none());
    }

    #[test]
    fn zones_take_the_hottest() {
        let d = tempfile::tempdir().unwrap();
        for (z, t) in [("thermal_zone0", "45000"), ("thermal_zone1", "91000")] {
            std::fs::create_dir(d.path().join(z)).unwrap();
            std::fs::write(d.path().join(z).join("temp"), format!("{t}\n")).unwrap();
        }
        std::fs::create_dir(d.path().join("cooling_device0")).unwrap();
        let h = heat_from_zones(d.path()).unwrap();
        assert_eq!(h.level, HeatLevel::Serious);
        assert_eq!(h.celsius, Some(91.0));
        let e = tempfile::tempdir().unwrap();
        assert!(heat_from_zones(e.path()).is_none());
    }

    #[test]
    fn heat_bands() {
        for (m, lv) in [(79999, HeatLevel::Normal), (80000, HeatLevel::Hot), (90000, HeatLevel::Serious), (95000, HeatLevel::Critical)] {
            let d = tempfile::tempdir().unwrap();
            std::fs::create_dir(d.path().join("thermal_zone0")).unwrap();
            std::fs::write(d.path().join("thermal_zone0/temp"), m.to_string()).unwrap();
            assert_eq!(heat_from_zones(d.path()).unwrap().level, lv);
        }
    }
}
