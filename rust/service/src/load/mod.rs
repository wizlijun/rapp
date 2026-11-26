//! Device load (spec 2026-11-26): samples, a 1 h ring and the warning rules. Pure data; I/O lives elsewhere.

#[cfg(any(test, target_os = "linux"))]
pub(crate) mod linux;
#[cfg(target_os = "macos")]
pub(crate) mod mac;
pub mod rules;
pub mod sample;

pub use rules::{History, Level, Warning, KEEP};
pub use sample::{
    Battery, CoverKind, Covered, Cpu, Disk, FakeSampler, Heat, HeatLevel, Mem, Pressure, Sample, Sampler,
};

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
