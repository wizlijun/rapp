//! Weak-link profile: a JSON description of one simulated network (both directions share it).
//! Every field defaults to "this impairment is off" (rate 0 = unlimited, queue_ms 0 = unbounded).

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use std::path::Path;

/// A periodic outage: down for `for_s` seconds every `every_s` seconds, the first one starting at `offset_s`.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Outage {
    pub every_s: f64,
    pub for_s: f64,
    #[serde(default)]
    pub offset_s: f64,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct Profile {
    pub seed: u64,
    /// Bottleneck rate range in kbit/s (log-uniform pick per `rate_every_s`); 0 = unlimited.
    pub rate_kbps: (u32, u32),
    /// How often the rate and the one-way delay are re-drawn from their ranges; 0 = never (low end is used).
    pub rate_every_s: f64,
    /// One-way delay range in ms (log-uniform pick per `rate_every_s`).
    pub delay_ms: (u32, u32),
    pub jitter_ms: u32,
    /// Random per-packet loss probability.
    pub loss: f64,
    pub bursts_per_min: f64,
    pub burst_ms: u32,
    pub outages: Vec<Outage>,
    pub rebind_every_s: Option<f64>,
    /// Tail-drop when the bottleneck queue would exceed this many ms; 0 = unbounded.
    pub queue_ms: u32,
}

impl Profile {
    pub fn load(path: &Path) -> Result<Profile> {
        let text = std::fs::read_to_string(path).with_context(|| format!("read {}", path.display()))?;
        serde_json::from_str(&text).with_context(|| format!("parse {}", path.display()))
    }

    pub fn named(name: &str) -> Result<Profile> {
        let path = Path::new(env!("CARGO_MANIFEST_DIR")).join("profiles").join(format!("{name}.json"));
        Profile::load(&path)
    }
}
