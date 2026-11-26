//! The outbox's pure logic: the session-list diff, the event envelope and the 200-event cache.
//! `send` speaks HTTP to the state service; `pump` is the one task that feeds and sends.

mod cache;
mod diff;
mod pump;
mod send;

pub use cache::{Cache, CACHE_MAX};
pub use diff::Diff;
pub use pump::{backoff, pump, PumpEnd, Stats, BATCH_MAX};
pub use send::{connect, Conn, Dial, DialErr, Posted};

/// Who the events are from.
#[derive(Clone, Debug)]
pub struct Me {
    pub fp: String,
    pub id: Option<String>,
    pub device: String,
    pub epoch: String,
}

/// A fresh epoch: 6 random hex characters.
pub fn new_epoch() -> String {
    use rand::Rng;
    let n: u32 = rand::rng().random_range(0..0x100_0000);
    format!("{n:06x}")
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::Value;

    fn me() -> Me {
        Me { fp: "a".repeat(64), id: Some("111111111".into()), device: "mac".into(), epoch: "e1".into() }
    }

    #[test]
    fn epoch_is_six_hex() {
        let e = new_epoch();
        assert_eq!(e.len(), 6);
        assert!(e.chars().all(|c| c.is_ascii_hexdigit()));
    }

    #[test]
    fn lists_become_the_sample_events() {
        let lists = include_str!("../../../../services/state/api/samples/term-lists.ndjson");
        let want: Vec<Value> = include_str!("../../../../services/state/api/samples/term-events.ndjson")
            .lines()
            .map(|l| serde_json::from_str(l).unwrap())
            .collect();
        let mut diff = Diff::default();
        let mut cache = Cache::new(me());
        let mut snap = None;
        for line in lists.lines() {
            let v: Value = serde_json::from_str(line).unwrap();
            let at = v["at"].as_u64().unwrap();
            let first = !diff.ready();
            let bodies = diff.feed(&v["list"], at);
            if first {
                snap = Some(cache.snap(diff.snap(), at));
            }
            for b in bodies {
                cache.push(b, at);
            }
        }
        let mut got = vec![snap.unwrap()];
        got.extend(cache.head(50));
        assert_eq!(got, want);
    }
}
