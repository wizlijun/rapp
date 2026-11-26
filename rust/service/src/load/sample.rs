//! One reading of the machine, and the `Sampler` that produces it.

use serde::Serialize;
use std::sync::{Arc, Mutex};

#[derive(Clone, Debug, Default, PartialEq)]
pub struct Sample {
    /// Unix seconds.
    pub at: u64,
    pub cpu: Option<Cpu>,
    pub gpu: Option<f32>,
    pub mem: Option<Mem>,
    pub heat: Option<Heat>,
    pub disks: Vec<Disk>,
    pub battery: Option<Battery>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Cpu {
    pub pct: f32,
    pub cores: u32,
    pub load1: Option<f32>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Mem {
    pub total: u64,
    pub avail: u64,
    pub swap_used: Option<u64>,
    pub pressure: Option<Pressure>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Pressure {
    Normal,
    Warn,
    Critical,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Heat {
    pub level: HeatLevel,
    pub celsius: Option<f32>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum HeatLevel {
    Normal,
    Hot,
    Serious,
    Critical,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Disk {
    /// `st_dev`, to count one disk once.
    pub dev: u64,
    pub mount: String,
    pub total: u64,
    pub avail: u64,
    /// (total, free) inodes.
    pub files: Option<(u64, u64)>,
    pub paths: Vec<Covered>,
    pub unreadable: bool,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Covered {
    pub kind: CoverKind,
    pub path: String,
    pub term: Option<String>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum CoverKind {
    Term,
    Data,
    Cache,
    Home,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Battery {
    pub pct: f32,
    pub plugged: bool,
}

/// Blocking; called off the runtime. `disks` are filled by `load::disks`, not here.
pub trait Sampler: Send + 'static {
    fn sample(&mut self) -> Sample;
    fn top(&mut self) -> Option<serde_json::Value> {
        None
    }
}

/// Returns a clone of whatever the test last set.
pub struct FakeSampler(pub Arc<Mutex<Sample>>);

impl Sampler for FakeSampler {
    fn sample(&mut self) -> Sample {
        self.0.lock().unwrap().clone()
    }
}
