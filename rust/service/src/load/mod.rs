//! Device load (spec 2026-11-26): samples, a 1 h ring and the warning rules. Pure data; I/O lives elsewhere.

pub mod rules;
pub mod sample;

pub use rules::{History, Level, Warning, KEEP};
pub use sample::{
    Battery, CoverKind, Covered, Cpu, Disk, FakeSampler, Heat, HeatLevel, Mem, Pressure, Sample, Sampler,
};
