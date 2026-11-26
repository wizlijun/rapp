//! The sampler task: every `every`, sample, read the working disks, push to the history, bump `tick`.

use super::sample::{CoverKind, Covered, Sampler};
use super::{Load, LoadOpts};
use crate::state::State;
use rapp_net::log::{Log, Lvl};
use serde_json::json;
use std::future::Future;
use std::pin::Pin;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

/// The terminal scan and when it was made.
pub(crate) type TermCache = Mutex<Option<(Instant, Vec<Covered>)>>;

pub type CoveredFuture = Pin<Box<dyn Future<Output = Vec<Covered>> + Send>>;

/// How long a terminal scan is reused.
const TERM_SCAN_EVERY: Duration = Duration::from_secs(30);

/// Spawned when `state.load` is some.
pub async fn run(state: Arc<State>, opts: LoadOpts) {
    let Some(load) = state.load.clone() else { return };
    let cache: Arc<TermCache> = Default::default();
    let log = state.log.clone();
    drive(load, opts, Some(log), move || {
        let (state, cache) = (state.clone(), cache.clone());
        Box::pin(async move { covered(&state, &cache).await })
    })
    .await
}

pub(crate) async fn drive(
    load: Arc<Load>,
    opts: LoadOpts,
    log: Option<Log>,
    covered: impl Fn() -> CoveredFuture,
) {
    let mut every = tokio::time::interval(opts.every);
    every.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    let mut sampler: Option<Box<dyn Sampler>> = None;
    let mut panicked = false;
    let disks = super::disks::DiskReader::default();
    loop {
        every.tick().await;
        let mut s = sampler.take().unwrap_or_else(|| (opts.sampler)());
        let sampled = tokio::task::spawn_blocking(move || {
            let sample = s.sample();
            (s, sample)
        })
        .await;
        let mut sample = match sampled {
            Ok((s, sample)) => {
                sampler = Some(s);
                sample
            }
            Err(e) => {
                // The sampler is lost with its thread; the next tick makes a new one.
                if !std::mem::replace(&mut panicked, true) {
                    if let Some(l) = &log {
                        l.event(Lvl::Warn, "load_sampler_panic", json!({"err": e.to_string()}));
                    }
                }
                continue;
            }
        };
        sample.disks = disks.read(covered().await, opts.disk_wait).await;
        load.hist.lock().unwrap().push(sample);
        load.tick.send_modify(|n| *n += 1);
    }
}

/// The paths this device is using: data, the home directory, the update cache and every terminal's cwd.
pub(crate) async fn covered(state: &State, cache: &TermCache) -> Vec<Covered> {
    let plain = |kind, p: &std::path::Path| Covered { kind, path: p.to_string_lossy().into_owned(), term: None };
    let mut out = vec![plain(CoverKind::Data, &state.home)];
    if let Some(h) = std::env::var_os("HOME") {
        out.push(plain(CoverKind::Home, std::path::Path::new(&h)));
    }
    if let Some(u) = &state.update_opts {
        out.push(plain(CoverKind::Cache, &u.cache_dir));
    }
    let fresh = cache.lock().unwrap().as_ref().filter(|(t, _)| t.elapsed() < TERM_SCAN_EVERY).map(|(_, v)| v.clone());
    let terms = match fresh {
        Some(v) => v,
        None => {
            let v = scan_terms(&state.home.join("term")).await;
            *cache.lock().unwrap() = Some((Instant::now(), v.clone()));
            v
        }
    };
    out.extend(terms);
    out
}

/// Reads the sockets on disk only; never starts the terminal worker.
async fn scan_terms(term_dir: &std::path::Path) -> Vec<Covered> {
    use rapp_term::pty::local;
    let Ok(token) = local::token(term_dir) else { return vec![] };
    local::scan(term_dir, &token)
        .await
        .into_iter()
        .filter_map(|s| {
            let cwd = s.cwd.clone()?;
            Some(Covered { kind: CoverKind::Term, path: cwd, term: Some(rapp_term::serve::pty_id(&s)) })
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::super::sample::{FakeSampler, Sample};
    use super::*;

    #[tokio::test]
    async fn sampler_pushes_every_tick() {
        let load = Arc::new(Load::new());
        let at = Arc::new(Mutex::new(Sample { at: 1, ..Default::default() }));
        let opts = LoadOpts {
            every: Duration::from_millis(50),
            sampler: Arc::new({
                let at = at.clone();
                move || Box::new(FakeSampler(at.clone())) as Box<dyn Sampler>
            }),
            disk_wait: Duration::from_millis(100),
        };
        let mut rx = load.tick.subscribe();
        let task = tokio::spawn(drive(load.clone(), opts, None, || Box::pin(async { vec![] })));
        tokio::time::sleep(Duration::from_secs(1)).await;
        task.abort();
        let points = load.hist.lock().unwrap().history_json();
        assert!(points.as_array().unwrap().len() >= 3, "{points}");
        assert!(rx.has_changed().unwrap() && *rx.borrow_and_update() >= 3);
    }

    struct Panics;
    impl Sampler for Panics {
        fn sample(&mut self) -> Sample {
            panic!("boom")
        }
    }

    #[tokio::test]
    async fn a_panicking_sampler_does_not_end_the_task() {
        let load = Arc::new(Load::new());
        let made = Arc::new(Mutex::new(0));
        let opts = LoadOpts {
            every: Duration::from_millis(30),
            sampler: Arc::new({
                let made = made.clone();
                move || {
                    let mut n = made.lock().unwrap();
                    *n += 1;
                    if *n == 1 {
                        Box::new(Panics) as Box<dyn Sampler>
                    } else {
                        Box::new(FakeSampler(Default::default()))
                    }
                }
            }),
            disk_wait: Duration::from_millis(100),
        };
        let task = tokio::spawn(drive(load.clone(), opts, None, || Box::pin(async { vec![] })));
        tokio::time::sleep(Duration::from_millis(500)).await;
        task.abort();
        assert!(*made.lock().unwrap() >= 2);
        assert!(load.hist.lock().unwrap().history_json().as_array().unwrap().len() >= 2);
    }
}
