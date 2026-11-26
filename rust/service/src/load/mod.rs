//! Device load (spec 2026-11-26): samples, a 1 h ring and the warning rules. Pure data; I/O lives elsewhere.

#[cfg(any(test, target_os = "linux"))]
pub(crate) mod linux;
#[cfg(target_os = "macos")]
pub(crate) mod mac;
pub mod disks;
pub mod rules;
pub mod sample;
pub mod task;

pub use rules::{History, Level, Warning, KEEP};
pub use sample::{
    Battery, CoverKind, Covered, Cpu, Disk, FakeSampler, Heat, HeatLevel, Mem, Pressure, Sample, Sampler,
};

/// How the sampler runs (`LoadOpts::system()` in the real service; the testkit sets a fake).
#[derive(Clone)]
pub struct LoadOpts {
    pub every: std::time::Duration,
    pub sampler: std::sync::Arc<dyn Fn() -> Box<dyn Sampler> + Send + Sync>,
    /// How long one disk may take to answer before it is `unreadable` for this sample.
    pub disk_wait: std::time::Duration,
}

impl LoadOpts {
    pub fn system() -> Self {
        LoadOpts {
            every: std::time::Duration::from_secs(5),
            sampler: std::sync::Arc::new(system_sampler),
            disk_wait: std::time::Duration::from_secs(2),
        }
    }
}

/// What the sampler task keeps: the 1 h history, and a counter bumped after each push.
pub struct Load {
    pub hist: std::sync::Mutex<History>,
    pub tick: tokio::sync::watch::Sender<u64>,
}

impl Load {
    pub fn new() -> Self {
        Load { hist: Default::default(), tick: tokio::sync::watch::channel(0).0 }
    }
}

impl Default for Load {
    fn default() -> Self {
        Self::new()
    }
}

fn now_secs() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// The sampler for this OS. Other OSes get an empty sample (everything shown as 「—」).
pub fn system_sampler() -> Box<dyn Sampler> {
    #[cfg(target_os = "macos")]
    {
        Box::new(mac::MacSampler::new())
    }
    #[cfg(target_os = "linux")]
    {
        Box::new(linux::LinuxSampler::default())
    }
    #[cfg(not(any(target_os = "macos", target_os = "linux")))]
    {
        struct Empty;
        impl Sampler for Empty {
            fn sample(&mut self) -> Sample {
                Sample { at: now_secs(), ..Default::default() }
            }
        }
        Box::new(Empty)
    }
}

#[cfg(test)]
mod system_tests {
    use super::*;

    #[test]
    #[ignore]
    fn system_sampler_reads_something() {
        let mut s = system_sampler();
        let _ = s.sample();
        std::thread::sleep(std::time::Duration::from_millis(500));
        let second = s.sample();
        let cpu = second.cpu.expect("cpu");
        assert!((0.0..=100.0).contains(&cpu.pct), "{cpu:?}");
        assert!(cpu.cores > 0);
        let mem = second.mem.expect("mem");
        assert!(mem.total > 0 && mem.avail <= mem.total, "{mem:?}");
        #[cfg(target_os = "macos")]
        assert!(second.heat.is_some());
    }
}
