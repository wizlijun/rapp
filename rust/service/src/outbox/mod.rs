//! The outbox: while a state service is known, the terminal session lists go through the diff
//! into the 200-event cache, and from there to the chosen service (spec §7).
//! `diff`/`cache` are the pure logic, `send` speaks HTTP to the service, `pump` is the one task
//! that feeds and sends; this file runs it: which service, which source, and `rapp state`.

mod cache;
mod diff;
mod pump;
mod send;

pub use cache::Cache;
pub use diff::Diff;
pub use pump::{pump, PumpEnd, Stats};
pub use send::{Dial, DialErr};

use crate::pipe::{self, PipeErr};
use crate::sink::{self, Dest, Sinks};
use crate::state::State;
use rapp_net::log::{Log, Lvl};
use serde_json::{json, Value};
use std::future::Future;
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::sync::{mpsc, Notify};
use tokio::task::JoinHandle;

/// While terminal sessions are off, `term.json` is looked at again this often (or when IPC
/// `set_term` pokes). Only the file is read: no worker is started.
pub const SOURCE_RETRY: Duration = Duration::from_secs(60);
/// A worker watch that ended is opened again after this long.
const REWATCH: Duration = Duration::from_secs(2);
/// Session lists waiting for the pump, at most.
const LISTS_MAX: usize = 64;

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

/// What the outbox is doing, on `State`.
pub struct Outbox {
    stats: Mutex<Stats>,
    /// The service it sends to now; None when there is none.
    dest: Mutex<Option<Dest>>,
    /// Woken when terminal sessions may have been turned on.
    poke: Notify,
}

impl Outbox {
    pub fn new() -> Outbox {
        Outbox { stats: Mutex::default(), dest: Mutex::new(None), poke: Notify::new() }
    }

    /// Terminal sessions may have been turned on: look at `term.json` now, not at the next retry.
    pub fn poke(&self) {
        self.poke.notify_one();
    }

    /// A new start, for `dest`: nothing cached, nothing sent yet.
    fn reset(&self, dest: Option<Dest>) {
        *self.stats.lock().unwrap_or_else(|e| e.into_inner()) = Stats::default();
        *self.dest.lock().unwrap_or_else(|e| e.into_inner()) = dest;
    }
}

/// The `outbox` of IPC `state`: the pump's `Stats` and `dest` (`{"local":port}`, `{"id","port"}`
/// or null). No device names.
pub fn status(state: &State) -> Value {
    status_of(&state.outbox)
}

fn status_of(o: &Outbox) -> Value {
    let mut v = serde_json::to_value(o.stats.lock().unwrap_or_else(|e| e.into_inner()).clone()).unwrap_or_default();
    v["dest"] = match o.dest.lock().unwrap_or_else(|e| e.into_inner()).as_ref() {
        Some(Dest::Local(port)) => json!({"local": port}),
        Some(Dest::Remote { id, port }) => json!({"id": id, "port": port}),
        None => Value::Null,
    };
    v
}

/// Runs the outbox for as long as the service runs: nothing at all while no state service is
/// known; otherwise a pump to the chosen one, fed by this device's terminal sessions.
pub fn spawn(state: Arc<State>) -> JoinHandle<()> {
    tokio::spawn(async move {
        // Once per start of `rapp-service` (spec §6): the service then waits for this epoch's snap.
        let epoch = new_epoch();
        let me = || {
            let cfg = state.cfg.lock().unwrap();
            Me { fp: state.identity.fp.to_string(), id: cfg.id.clone(), device: cfg.name.clone(), epoch: epoch.clone() }
        };
        let run = |dest: Dest| run_dest(state.clone(), me(), dest);
        let forget = |id: &str| sink::forget(&state, id, "outbox");
        follow(&state.sinks, || sink::own_id(&state), &state.outbox, &state.log, forget, run).await;
    })
}

/// Follows the chosen service: `run(dest)` while it stays the chosen one, started again for a new
/// one, stopped (its cache with it) when there is none. A remote service whose share is gone is
/// forgotten (`forget`, which changes `sinks`). Returns only when `sinks` is gone.
async fn follow<R, F>(
    sinks: &Sinks,
    own_id: impl Fn() -> Option<String>,
    outbox: &Outbox,
    log: &Log,
    forget: impl Fn(&str) -> bool,
    mut run: R,
) where
    R: FnMut(Dest) -> F,
    F: Future<Output = PumpEnd>,
{
    let mut changes = sinks.subscribe();
    loop {
        changes.borrow_and_update();
        let dest = sinks.dest(own_id().as_deref());
        outbox.reset(dest.clone());
        let Some(dest) = dest else {
            if changes.changed().await.is_err() {
                return;
            }
            continue;
        };
        let known = sinks.known();
        if known >= 2 {
            let (id, port, local) = match &dest {
                Dest::Local(port) => (own_id(), *port, true),
                Dest::Remote { id, port } => (Some(id.clone()), *port, false),
            };
            log.event(Lvl::Info, "outbox_sink", json!({"id": id, "port": port, "local": local, "known": known}));
        }
        let running = run(dest.clone());
        tokio::pin!(running);
        let end = loop {
            tokio::select! {
                end = &mut running => break Some(end),
                changed = changes.changed() => {
                    if changed.is_err() {
                        return;
                    }
                    if sinks.dest(own_id().as_deref()).as_ref() != Some(&dest) {
                        break None;
                    }
                }
            }
        };
        // Stopped for another service (or none): start over at once. Gone: forget it, which is a
        // change. Anything else (or a forget that changed nothing) waits for a change, so a
        // service that keeps ending is not run again and again.
        let forgot = match (&end, &dest) {
            (None, _) => continue,
            (Some(PumpEnd::Gone), Dest::Remote { id, .. }) => forget(id),
            _ => false,
        };
        if !forgot && changes.changed().await.is_err() {
            return;
        }
    }
}

/// One run for `dest`: the pump, fed by this device's terminal sessions. Dropped, it stops both
/// (the worker watch with them) and its cache is gone.
async fn run_dest(state: Arc<State>, me: Me, dest: Dest) -> PumpEnd {
    let (tx, rx) = mpsc::channel(LISTS_MAX);
    let dial = StateDial { state: state.clone(), dest };
    tokio::select! {
        end = pump(me, rx, dial, &state.log, &state.outbox.stats) => end,
        () = terms(&state, tx) => PumpEnd::ListsClosed,
    }
}

fn now() -> u64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)
}

/// The terminal source (spec §7.3): every list of the worker's watch, while terminal sessions are
/// on. A watch that ends is opened again after `REWATCH` (the diff stays in the pump, so only real
/// changes come of it). Off: `term.json` is looked at every `SOURCE_RETRY`, or when poked; the
/// sessions told before are told gone (an empty list). Returns when the pump is gone.
async fn terms(state: &Arc<State>, tx: mpsc::Sender<(Value, u64)>) {
    let mut told = false;
    loop {
        let on = matches!(crate::term::config(state), Ok(c) if c.allow);
        if !on {
            if std::mem::take(&mut told) && tx.send((json!({"terms": [], "hosts": []}), now())).await.is_err() {
                return;
            }
            tokio::select! {
                _ = tokio::time::sleep(SOURCE_RETRY) => {}
                _ = state.outbox.poke.notified() => {}
            }
            continue;
        }
        if let Ok(mut watch) = crate::term::watch_local(state).await {
            while let Ok(Some(list)) = watch.next().await {
                if tx.send((list, now())).await.is_err() {
                    return;
                }
                told = true;
            }
        }
        tokio::time::sleep(REWATCH).await;
    }
}

/// Reaches the chosen service: this device's own port, or a forward to the other device's port
/// (the way `rapp pipe` goes, so no local port map is needed).
struct StateDial {
    state: Arc<State>,
    dest: Dest,
}

impl Dial for StateDial {
    async fn dial(&self) -> Result<rapp_conn::Pipe, DialErr> {
        match &self.dest {
            Dest::Local(port) => match tokio::net::TcpStream::connect(("127.0.0.1", *port)).await {
                Ok(tcp) => Ok(Box::new(tcp)),
                Err(e) if e.kind() == std::io::ErrorKind::ConnectionRefused => Err(DialErr::Down("refused")),
                Err(_) => Err(DialErr::Down("io")),
            },
            Dest::Remote { id, port } => pipe::open(&self.state, id, *port).await.map(|(p, _)| p).map_err(dial_err),
        }
    }
}

/// `not shared`: the service is gone (spec §7.2). The rest is for now only.
fn dial_err(e: PipeErr) -> DialErr {
    match e {
        PipeErr::Refused(why) if why == "not shared" => DialErr::Gone,
        PipeErr::Offline => DialErr::Down("offline"),
        // "not allowed": the share is there but this device is not on its allow list. That is
        // about this device only, so it is not Gone: forgetting would make every device told of
        // the sink forget it too, the allowed ones included. Tried again after the backoff.
        PipeErr::Refused(_) => DialErr::Down("refused"),
        _ => DialErr::Down("io"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use tokio::sync::mpsc;

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

    /// Dials only once `open` is notified, and then says the share is gone.
    struct GoneDial(Arc<Notify>);

    impl Dial for GoneDial {
        async fn dial(&self) -> Result<rapp_conn::Pipe, DialErr> {
            self.0.notified().await;
            Err(DialErr::Gone)
        }
    }

    fn list(state: &str, seq: u64) -> Value {
        json!({"terms":[{"id":"term:pty:a","name":"a","dead":false,"ps":{"state":state,"seq":seq,"since":seq}}],"hosts":[]})
    }

    #[tokio::test(start_paused = true)]
    async fn a_gone_dest_clears_the_cache() {
        let dir = tempfile::tempdir().unwrap();
        let (sinks, _) = Sinks::load(dir.path());
        assert!(sinks.learn("222222222", 8102));
        let outbox = Outbox::new();
        let open = Arc::new(Notify::new());
        let (tx, rx) = mpsc::channel(16);
        let mut rx = Some(rx);
        let dests = Mutex::new(vec![]);
        let run = |dest: Dest| {
            dests.lock().unwrap().push(dest);
            let (rx, dial, outbox) = (rx.take(), GoneDial(open.clone()), &outbox);
            async move {
                match rx {
                    Some(rx) => pump(me(), rx, dial, &Log::none(), &outbox.stats).await,
                    None => std::future::pending().await,
                }
            }
        };
        let drive = async {
            for (i, (state, seq)) in [("idle", 0), ("working", 1), ("blocked", 2)].into_iter().enumerate() {
                tx.send((list(state, seq), i as u64)).await.unwrap();
            }
            tokio::time::sleep(Duration::from_millis(1)).await;
            let st = status_of(&outbox);
            assert_eq!((st["active"].clone(), st["cached"].clone()), (json!(true), json!(2)), "{st}");
            assert_eq!(st["dest"], json!({"id": "222222222", "port": 8102}), "{st}");
            open.notify_one();
            tokio::time::sleep(Duration::from_millis(1)).await;
        };
        let log = Log::none();
        tokio::select! {
            _ = follow(&sinks, || None, &outbox, &log, |id| sinks.forget(id), run) => panic!("follow ended"),
            () = drive => {}
        }
        assert!(sinks.remote().is_empty(), "the gone service is forgotten");
        let st = status_of(&outbox);
        assert_eq!(st, json!({"active":false,"cached":0,"sent":0,"dropped":0,"refused":0,"last_ok":null,"up":false,"dest":null}));
        assert_eq!(dests.lock().unwrap().len(), 1, "no new run without a service");
    }

    #[test]
    fn status_says_where_to() {
        let o = Outbox::new();
        assert_eq!(status_of(&o)["dest"], Value::Null);
        o.reset(Some(Dest::Local(8102)));
        assert_eq!(status_of(&o)["dest"], json!({"local": 8102}));
        o.reset(Some(Dest::Remote { id: "111111111".into(), port: 9000 }));
        assert_eq!(status_of(&o)["dest"], json!({"id": "111111111", "port": 9000}));
    }

    #[test]
    fn a_gone_share_is_gone_and_the_rest_is_down() {
        use crate::pipe::PipeErr;
        assert_eq!(dial_err(PipeErr::Refused("not shared".into())), DialErr::Gone);
        assert_eq!(dial_err(PipeErr::Refused("not allowed".into())), DialErr::Down("refused"));
        assert_eq!(dial_err(PipeErr::Offline), DialErr::Down("offline"));
        assert_eq!(dial_err(PipeErr::Refused("limit".into())), DialErr::Down("refused"));
        assert_eq!(dial_err(PipeErr::Other("x".into())), DialErr::Down("io"));
        assert_eq!(dial_err(PipeErr::Old), DialErr::Down("io"));
    }
}
