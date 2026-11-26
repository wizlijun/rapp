//! The outbox's one task: take the session lists in, send the events out, one request at a time.

use super::send::{connect, Conn, Dial, DialErr, Posted};
use super::{Cache, Diff, Me};
use rapp_net::log::{Log, Lvl};
use serde::Serialize;
use serde_json::{json, Value};
use std::future::Future;
use std::pin::Pin;
use std::sync::Mutex;
use std::time::Duration;
use tokio::sync::mpsc::Receiver;

/// Events in one post, at most.
pub const BATCH_MAX: usize = 50;
/// A dial, a health check or a post that takes longer than this has failed.
const WAIT: Duration = Duration::from_secs(30);

/// How long to wait after the `fails`-th failure in a row: 2, 4, 8, 16, 32, then 60 seconds.
pub fn backoff(fails: u32) -> Duration {
    let s = match fails {
        0..=1 => 2,
        2..=5 => 2u64 << (fails - 1),
        _ => 60,
    };
    Duration::from_secs(s)
}

/// What the outbox is doing, for `rapp state`.
#[derive(Default, Clone, Debug, Serialize)]
pub struct Stats {
    pub active: bool,
    pub cached: usize,
    pub sent: u64,
    pub dropped: u64,
    pub refused: u64,
    /// Unix seconds of the last post the service took.
    pub last_ok: Option<u64>,
    pub up: bool,
}

/// Why the pump stopped.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PumpEnd {
    /// The state service's share is gone: forget it.
    Gone,
    /// Nobody sends lists any more.
    ListsClosed,
}

/// Feed `lists` (`(session list, at)`) through the diff into the cache, and send the cache to the
/// service `dial` reaches: after each (re)connection the cached events in order, then a snap.
pub async fn pump<D: Dial>(
    me: Me,
    mut lists: Receiver<(Value, u64)>,
    dial: D,
    log: &Log,
    stats: &Mutex<Stats>,
) -> PumpEnd {
    let mut st = State::new(me);
    st.tell(stats);
    // The one request (or dial, or wait) in flight. It lives across loop turns, so a list that
    // comes in meanwhile never cancels it; it owns its inputs, so the cache stays free to feed.
    let mut busy: Option<Busy<'_>> = None;
    let end = loop {
        if busy.is_none() {
            busy = st.next(&dial);
        }
        tokio::select! {
            m = lists.recv() => match m {
                None => break PumpEnd::ListsClosed,
                Some((list, at)) => st.feed(&list, at),
            },
            step = run(&mut busy) => {
                busy = None;
                if let Some(end) = st.done(step, log) {
                    break end;
                }
            }
        }
        st.tell(stats);
    };
    let mut s = stats.lock().unwrap_or_else(|e| e.into_inner());
    (s.active, s.up) = (false, false);
    end
}

type Busy<'a> = Pin<Box<dyn Future<Output = Step> + Send + 'a>>;

/// The busy future's output, or never when there is none.
async fn run(busy: &mut Option<Busy<'_>>) -> Step {
    match busy {
        Some(f) => f.await,
        None => std::future::pending().await,
    }
}

/// What a post carried.
enum What {
    /// Cached events up to `n == through`.
    Events { through: u64, count: usize },
    /// A snap built when the cache had dropped `dropped` events in all.
    Snap { dropped: u64 },
}

/// How the busy future ended.
enum Step {
    Dialled(Result<Conn, DialErr>),
    Posted { conn: Conn, what: What, res: Result<Posted, &'static str> },
    Waited,
}

struct State {
    diff: Diff,
    cache: Cache,
    /// The connection, when it is idle here (a post in flight owns it).
    conn: Option<Conn>,
    connected: bool,
    /// A list came: the service may be dialled.
    started: bool,
    /// `at` of the latest list, for the snap.
    at: u64,
    fails: u32,
    /// Wait `backoff(fails)` before the next dial.
    wait: bool,
    /// This connection still owes the service a snap (after the resend).
    owe_snap: bool,
    /// This connection's resend so far; `None` once `outbox_up` is logged.
    resent: Option<usize>,
    /// `cache.dropped()` when `outbox_up` was last logged.
    dropped_told: u64,
    sent: u64,
    refused: u64,
    last_ok: Option<u64>,
}

fn now() -> u64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)
}

impl State {
    fn new(me: Me) -> State {
        State {
            diff: Diff::default(),
            cache: Cache::new(me),
            conn: None,
            connected: false,
            started: false,
            at: 0,
            fails: 0,
            wait: false,
            owe_snap: false,
            resent: None,
            dropped_told: 0,
            sent: 0,
            refused: 0,
            last_ok: None,
        }
    }

    fn feed(&mut self, list: &Value, at: u64) {
        let dropped = self.cache.dropped();
        for body in self.diff.feed(list, at) {
            self.cache.push(body, at);
        }
        // Spec §7.4: a loss from the cache is told like a reconnection, by the resend and then a
        // snap with `gap:true`. When not connected, the next connection owes the snap anyway.
        if self.connected && self.cache.dropped() > dropped {
            self.owe_snap = true;
        }
        self.at = at;
        self.started = true;
    }

    /// The next thing to do, if any: wait, dial, post the oldest cached events, or post the snap.
    fn next<'a, D: Dial>(&mut self, dial: &'a D) -> Option<Busy<'a>> {
        if !self.started {
            return None;
        }
        if self.wait {
            self.wait = false;
            let d = backoff(self.fails);
            return Some(Box::pin(async move {
                tokio::time::sleep(d).await;
                Step::Waited
            }));
        }
        let Some(mut conn) = self.conn.take() else {
            return Some(Box::pin(async move {
                let res = match tokio::time::timeout(WAIT, async {
                    let io = dial.dial().await?;
                    connect(io).await.map_err(DialErr::Down)
                })
                .await
                {
                    Ok(r) => r,
                    Err(_) => Err(DialErr::Down("timeout")),
                };
                Step::Dialled(res)
            }));
        };
        let (lines, what) = if self.cache.len() > 0 {
            let lines = self.cache.head(BATCH_MAX);
            let through = lines.last().and_then(|l| l["n"].as_u64()).unwrap_or(0);
            let count = lines.len();
            (lines, What::Events { through, count })
        } else if self.owe_snap && self.diff.ready() {
            let dropped = self.cache.dropped();
            (vec![self.cache.snap(self.diff.snap(), self.at)], What::Snap { dropped })
        } else {
            self.conn = Some(conn);
            return None;
        };
        Some(Box::pin(async move {
            let res = match tokio::time::timeout(WAIT, conn.post(&lines)).await {
                Ok(r) => r,
                Err(_) => Err("timeout"),
            };
            Step::Posted { conn, what, res }
        }))
    }

    /// Take in how the busy future ended; `Some` ends the pump.
    fn done(&mut self, step: Step, log: &Log) -> Option<PumpEnd> {
        match step {
            Step::Waited => {}
            Step::Dialled(Ok(conn)) => {
                self.conn = Some(conn);
                self.connected = true;
                self.owe_snap = true;
                self.resent = Some(0);
            }
            Step::Dialled(Err(DialErr::Gone)) => return Some(PumpEnd::Gone),
            Step::Dialled(Err(DialErr::Down(why))) => self.fail(why, log),
            Step::Posted { res: Err(why), .. } => self.fail(why, log),
            Step::Posted { conn, what, res: Ok(posted) } => {
                self.conn = Some(conn);
                match (what, posted) {
                    (What::Events { through, count }, Posted::Taken) => {
                        self.taken(count);
                        self.cache.ack(through);
                        if let Some(r) = &mut self.resent {
                            *r += count;
                        }
                    }
                    (What::Events { through, count }, Posted::Refused(status)) => {
                        self.cache.ack(through);
                        self.refused += count as u64;
                        log.event(Lvl::Warn, "outbox_refused", json!({"status": status, "count": count}));
                    }
                    (What::Snap { dropped }, posted) => {
                        self.owe_snap = false;
                        match posted {
                            Posted::Taken => {
                                self.taken(1);
                                if self.cache.dropped() == dropped {
                                    self.cache.snap_taken();
                                } else {
                                    // Lost while this snap was on its way: it did not say so,
                                    // so the gap stays and another snap follows.
                                    self.owe_snap = true;
                                }
                            }
                            // 4xx: the service will not take it, so it is not sent again on this
                            // connection. The gap (if any) stays set; the next snap, after the next
                            // drop or reconnection, carries it. That cannot loop: only a new drop
                            // or a new connection owes a snap.
                            Posted::Refused(status) => {
                                self.refused += 1;
                                log.event(Lvl::Warn, "outbox_refused", json!({"status": status, "count": 1}));
                            }
                        }
                        self.up(dropped, log);
                    }
                }
            }
        }
        None
    }

    fn taken(&mut self, count: usize) {
        self.fails = 0;
        self.sent += count as u64;
        self.last_ok = Some(now());
    }

    /// A snap is through: after a (re)connection say the outbox is up; and sum up what was
    /// dropped up to that snap (`dropped` in all) and not yet told.
    fn up(&mut self, dropped: u64, log: &Log) {
        if let Some(resent) = self.resent.take() {
            log.event(Lvl::Info, "outbox_up", json!({"resent": resent}));
        }
        let count = dropped.saturating_sub(self.dropped_told);
        if count > 0 {
            log.event(Lvl::Warn, "outbox_dropped", json!({"count": count}));
            self.dropped_told = dropped;
        }
    }

    fn fail(&mut self, why: &'static str, log: &Log) {
        self.conn = None;
        self.connected = false;
        self.resent = None;
        self.fails = self.fails.saturating_add(1);
        self.wait = true;
        log.event(Lvl::Warn, "outbox_down", json!({"cached": self.cache.len(), "why": why}));
    }

    fn tell(&self, stats: &Mutex<Stats>) {
        let mut s = stats.lock().unwrap_or_else(|e| e.into_inner());
        *s = Stats {
            active: true,
            cached: self.cache.len(),
            sent: self.sent,
            dropped: self.cache.dropped(),
            refused: self.refused,
            last_ok: self.last_ok,
            up: self.connected,
        };
    }
}

#[cfg(test)]
mod tests {
    use super::super::send::fake::Fake;
    use super::*;
    use std::collections::VecDeque;
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::Arc;
    use tokio::sync::{mpsc, watch};
    use tokio::time::Instant;

    fn me() -> Me {
        Me { fp: "a".repeat(64), id: Some("111111111".into()), device: "mac".into(), epoch: "e1".into(), numbers: Default::default() }
    }

    /// A dial that follows a script first, then works only while `open`; it notes when each dial came.
    struct FakeDial {
        fake: Arc<Fake>,
        script: Mutex<VecDeque<DialErr>>,
        open: AtomicBool,
        times: Mutex<Vec<Instant>>,
        tick: watch::Sender<usize>,
    }

    impl FakeDial {
        fn new(fake: &Arc<Fake>, open: bool) -> Arc<FakeDial> {
            Arc::new(FakeDial {
                fake: fake.clone(),
                script: Mutex::new(VecDeque::new()),
                open: AtomicBool::new(open),
                times: Mutex::new(vec![]),
                tick: watch::channel(0).0,
            })
        }
        fn times(&self) -> Vec<Instant> {
            self.times.lock().unwrap().clone()
        }
        fn set_open(&self, on: bool) {
            self.open.store(on, Ordering::SeqCst);
        }
        async fn dialled(&self, n: usize) {
            let mut rx = self.tick.subscribe();
            let got = tokio::time::timeout(Duration::from_secs(3600), rx.wait_for(|d| *d >= n)).await;
            assert!(got.is_ok(), "never dialled {n} times");
        }
    }

    impl Dial for Arc<FakeDial> {
        async fn dial(&self) -> Result<rapp_conn::Pipe, DialErr> {
            self.times.lock().unwrap().push(Instant::now());
            self.tick.send_modify(|n| *n += 1);
            if let Some(e) = self.script.lock().unwrap().pop_front() {
                return Err(e);
            }
            if !self.open.load(Ordering::SeqCst) {
                return Err(DialErr::Down("offline"));
            }
            Ok(self.fake.pipe())
        }
    }

    fn sample() -> Vec<(Value, u64)> {
        include_str!("../../../../services/state/api/samples/term-lists.ndjson")
            .lines()
            .map(|l| {
                let v: Value = serde_json::from_str(l).unwrap();
                (v["list"].clone(), v["at"].as_u64().unwrap())
            })
            .collect()
    }

    /// One live session `term:pty:a` in `state` with question number `seq`.
    fn list(state: &str, seq: u64, msg: &str) -> Value {
        json!({"terms":[{"id":"term:pty:a","name":"a","dead":false,
            "ps":{"state":state,"seq":seq,"since":seq,"msg":msg}}],"hosts":[]})
    }

    /// Under the paused clock, time moves only when every task is idle: this returns once the
    /// pump has taken in the last reply.
    async fn settle() {
        tokio::time::sleep(Duration::from_millis(1)).await;
    }

    fn ns(lines: &[Value]) -> Vec<u64> {
        lines.iter().map(|l| l["n"].as_u64().unwrap()).collect()
    }

    fn has_snap(n: u64) -> impl Fn(&[super::super::send::fake::Got]) -> bool {
        move |got| got.iter().any(|g| g.status / 100 == 2 && g.lines.iter().any(|l| l["t"] == "snap" && l["n"] == n))
    }

    #[test]
    fn backoff_doubles_to_a_minute() {
        let s: Vec<u64> = (1..=7).map(|f| backoff(f).as_secs()).collect();
        assert_eq!(s, [2, 4, 8, 16, 32, 60, 60]);
        assert_eq!(backoff(u32::MAX).as_secs(), 60);
    }

    #[tokio::test(start_paused = true)]
    async fn events_go_in_order_then_snap() {
        let fake = Fake::new("rapp-state");
        let dial = FakeDial::new(&fake, false);
        let (tx, rx) = mpsc::channel(16);
        let stats = Mutex::new(Stats::default());
        let log = Log::none();
        let drive = async {
            tokio::time::sleep(Duration::from_secs(10)).await;
            assert!(dial.times().is_empty(), "no dial before the first list");
            let s = sample();
            tx.send(s[0].clone()).await.unwrap();
            dial.dialled(1).await;
            for l in &s[1..4] {
                tx.send(l.clone()).await.unwrap();
            }
            dial.set_open(true);
            fake.until(has_snap(3)).await;
            settle().await;
            let st = stats.lock().unwrap().clone();
            drop(tx);
            st
        };
        let (end, st) = tokio::join!(pump(me(), rx, dial.clone(), &log, &stats), drive);
        assert_eq!(end, PumpEnd::ListsClosed);
        let got = fake.taken();
        assert_eq!(ns(&got), [1, 2, 3]);
        assert_eq!((got[0]["t"].as_str(), got[0]["state"].as_str()), (Some("state"), Some("working")));
        assert_eq!((got[1]["t"].as_str(), got[1]["state"].as_str()), (Some("state"), Some("blocked")));
        assert_eq!(got[2]["t"], "snap");
        assert!(got[2].get("gap").is_none());
        // The snap is now: the blocked session, as the 4th list (progress only) left it.
        assert_eq!(got[2]["at"], 1764130025);
        assert_eq!(got[2]["sessions"].as_array().unwrap().len(), 1);
        assert_eq!(got[2]["sessions"][0]["state"], "blocked");
        assert_eq!(got[2]["sessions"][0]["msg"], "approve Bash: touch /tmp/x");
        assert_eq!((st.sent, st.cached, st.dropped, st.refused, st.up, st.active), (3, 0, 0, 0, true, true));
        assert!(st.last_ok.is_some());
        let end = stats.lock().unwrap().clone();
        assert!(!end.active && !end.up, "a stopped pump says so");
    }

    #[tokio::test(start_paused = true)]
    async fn a_failed_service_is_tried_again_later() {
        let fake = Fake::new("rapp-state");
        let dial = FakeDial::new(&fake, true);
        dial.script.lock().unwrap().extend([DialErr::Down("offline"); 3]);
        let (tx, rx) = mpsc::channel(16);
        let stats = Mutex::new(Stats::default());
        let log = Log::none();
        let drive = async {
            tx.send((list("idle", 0, "x"), 1)).await.unwrap();
            tx.send((list("working", 1, "x"), 2)).await.unwrap();
            dial.dialled(3).await;
            let st = stats.lock().unwrap().clone();
            assert!(!st.up);
            assert_eq!(st.cached, 1);
            fake.until(has_snap(2)).await;
            settle().await;
            assert!(stats.lock().unwrap().up);
            drop(tx);
        };
        tokio::join!(pump(me(), rx, dial.clone(), &log, &stats), drive);
        let t = dial.times();
        assert_eq!(t.len(), 4);
        let gaps: Vec<Duration> = t.windows(2).map(|w| w[1] - w[0]).collect();
        let near = |d: Duration, s: u64| d >= Duration::from_secs(s) && d < Duration::from_secs(s) + Duration::from_millis(100);
        assert!(near(gaps[0], 2) && near(gaps[1], 4) && near(gaps[2], 8), "{gaps:?}");
        assert_eq!(ns(&fake.taken()), [1, 2]);
    }

    /// Connected and snapped, then the service fails while 3 changes come; then it is back.
    async fn three_changes(log: &Log) -> (Vec<Value>, Stats) {
        let fake = Fake::new("rapp-state");
        let dial = FakeDial::new(&fake, true);
        let (tx, rx) = mpsc::channel(16);
        let stats = Mutex::new(Stats::default());
        let drive = async {
            tx.send((list("idle", 0, "SECRET-TEXT"), 1)).await.unwrap();
            fake.until(has_snap(1)).await;
            fake.rules.lock().unwrap().down = true;
            dial.set_open(false);
            tx.send((list("working", 1, "SECRET-TEXT"), 2)).await.unwrap();
            tx.send((list("blocked", 2, "SECRET-TEXT"), 3)).await.unwrap();
            tx.send((list("done", 3, "SECRET-TEXT"), 4)).await.unwrap();
            fake.until(|got| got.iter().any(|g| g.status == 503)).await;
            dial.dialled(2).await;
            fake.rules.lock().unwrap().down = false;
            dial.set_open(true);
            fake.until(has_snap(5)).await;
            settle().await;
            let st = stats.lock().unwrap().clone();
            drop(tx);
            st
        };
        let (_, st) = tokio::join!(pump(me(), rx, dial.clone(), log, &stats), drive);
        (fake.taken(), st)
    }

    #[tokio::test(start_paused = true)]
    async fn three_changes_while_down_arrive_after() {
        let (got, st) = three_changes(&Log::none()).await;
        assert_eq!(ns(&got), [1, 2, 3, 4, 5]);
        let ts: Vec<&str> = got.iter().map(|l| l["t"].as_str().unwrap()).collect();
        assert_eq!(ts, ["snap", "state", "state", "state", "snap"]);
        let states: Vec<&str> = got[1..4].iter().map(|l| l["state"].as_str().unwrap()).collect();
        assert_eq!(states, ["working", "blocked", "done"]);
        assert!(got[4].get("gap").is_none());
        assert_eq!(got[4]["sessions"][0]["state"], "done");
        assert_eq!((st.sent, st.cached, st.dropped, st.up), (5, 0, 0, true));
    }

    #[tokio::test(start_paused = true)]
    async fn three_hundred_changes_leave_a_gap() {
        let dir = tempfile::tempdir().unwrap();
        let log = Log::file(dir.path(), "service.log");
        let fake = Fake::new("rapp-state");
        let dial = FakeDial::new(&fake, false);
        let (tx, rx) = mpsc::channel(16);
        let stats = Mutex::new(Stats::default());
        let drive = async {
            tx.send((list("idle", 0, "x"), 1)).await.unwrap();
            for seq in 1..=300 {
                tx.send((list("blocked", seq, "x"), 1 + seq)).await.unwrap();
            }
            dial.dialled(1).await;
            assert_eq!(stats.lock().unwrap().cached, 200);
            dial.set_open(true);
            fake.until(has_snap(301)).await;
            settle().await;
            drop(tx);
        };
        tokio::join!(pump(me(), rx, dial.clone(), &log, &stats), drive);
        let got = fake.taken();
        assert_eq!(got.len(), 201);
        assert_eq!(ns(&got[..200]), (101..=300).collect::<Vec<_>>());
        assert_eq!(got[0]["seq"], 101);
        assert_eq!(got[200]["t"], "snap");
        assert_eq!(got[200]["gap"], true);
        assert!(fake.got.lock().unwrap().iter().all(|g| g.lines.len() <= BATCH_MAX));
        let st = stats.lock().unwrap().clone();
        assert_eq!((st.dropped, st.cached, st.sent), (100, 0, 201));
        log.flush();
        let text = std::fs::read_to_string(dir.path().join("service.log")).unwrap();
        let lines: Vec<Value> = text.lines().map(|l| serde_json::from_str(l).unwrap()).collect();
        let dropped: Vec<&Value> = lines.iter().filter(|l| l["ev"] == "outbox_dropped").collect();
        assert_eq!(dropped.len(), 1);
        assert_eq!(dropped[0]["count"], 100);
        let up: Vec<&Value> = lines.iter().filter(|l| l["ev"] == "outbox_up").collect();
        assert_eq!(up.len(), 1);
        assert_eq!(up[0]["resent"], 200);
    }

    #[tokio::test(start_paused = true)]
    async fn a_refused_batch_is_dropped_not_retried() {
        let dir = tempfile::tempdir().unwrap();
        let log = Log::file(dir.path(), "service.log");
        let fake = Fake::new("rapp-state");
        fake.rules.lock().unwrap().statuses.push_back(400);
        let dial = FakeDial::new(&fake, false);
        let (tx, rx) = mpsc::channel(16);
        let stats = Mutex::new(Stats::default());
        let drive = async {
            tx.send((list("idle", 0, "x"), 1)).await.unwrap();
            tx.send((list("working", 1, "x"), 2)).await.unwrap();
            tx.send((list("blocked", 2, "x"), 3)).await.unwrap();
            dial.dialled(1).await;
            dial.set_open(true);
            fake.until(has_snap(3)).await;
            tx.send((list("done", 3, "x"), 4)).await.unwrap();
            fake.until(|got| got.iter().any(|g| g.status == 204 && g.lines.iter().any(|l| l["n"] == 4))).await;
            settle().await;
            let st = stats.lock().unwrap().clone();
            drop(tx);
            st
        };
        let (_, st) = tokio::join!(pump(me(), rx, dial.clone(), &log, &stats), drive);
        let all = fake.got.lock().unwrap().clone();
        assert_eq!(all[0].status, 400);
        assert_eq!(ns(&all[0].lines), [1, 2]);
        let sent: Vec<Vec<u64>> = all.iter().map(|g| ns(&g.lines)).collect();
        assert_eq!(sent, [vec![1, 2], vec![3], vec![4]], "the refused batch is not sent again");
        assert_eq!(fake.taken()[0]["t"], "snap");
        assert_eq!((st.refused, st.sent, st.cached, st.up), (2, 2, 0, true));
        assert_eq!(dial.times().len(), 2, "the connection stays after a refusal");
        log.flush();
        let text = std::fs::read_to_string(dir.path().join("service.log")).unwrap();
        let refused: Vec<Value> =
            text.lines().map(|l| serde_json::from_str::<Value>(l).unwrap()).filter(|l| l["ev"] == "outbox_refused").collect();
        assert_eq!(refused.len(), 1);
        assert_eq!((refused[0]["status"].as_u64(), refused[0]["count"].as_u64()), (Some(400), Some(2)));
    }

    #[tokio::test(start_paused = true)]
    async fn not_shared_ends_the_pump() {
        let fake = Fake::new("rapp-state");
        let dial = FakeDial::new(&fake, true);
        dial.script.lock().unwrap().extend([DialErr::Down("offline"), DialErr::Gone]);
        let (tx, rx) = mpsc::channel(16);
        let stats = Mutex::new(Stats::default());
        tx.send((list("idle", 0, "x"), 1)).await.unwrap();
        let end = tokio::time::timeout(Duration::from_secs(3600), pump(me(), rx, dial.clone(), &Log::none(), &stats)).await;
        assert_eq!(end, Ok(PumpEnd::Gone));
        assert_eq!(dial.times().len(), 2);
        assert!(fake.got.lock().unwrap().is_empty());
        assert!(!stats.lock().unwrap().active);
        drop(tx);
    }

    #[tokio::test(start_paused = true)]
    async fn a_service_that_is_not_rapp_state_is_tried_again() {
        let fake = Fake::new("other");
        let dial = FakeDial::new(&fake, true);
        let (tx, rx) = mpsc::channel(16);
        let stats = Mutex::new(Stats::default());
        let log = Log::none();
        let drive = async {
            tx.send((list("idle", 0, "x"), 1)).await.unwrap();
            dial.dialled(3).await;
            drop(tx);
        };
        let (end, ()) = tokio::join!(pump(me(), rx, dial.clone(), &log, &stats), drive);
        assert_eq!(end, PumpEnd::ListsClosed);
        let t = dial.times();
        assert!(t[1] - t[0] >= Duration::from_secs(2) && t[2] - t[1] >= Duration::from_secs(4));
        assert!(fake.got.lock().unwrap().is_empty());
    }

    #[tokio::test(start_paused = true)]
    async fn a_drop_while_connected_is_told_without_a_reconnection() {
        let dir = tempfile::tempdir().unwrap();
        let log = Log::file(dir.path(), "service.log");
        let fake = Fake::new("rapp-state");
        let dial = FakeDial::new(&fake, true);
        let (tx, rx) = mpsc::channel(16);
        let stats = Mutex::new(Stats::default());
        let drive = async {
            tx.send((list("idle", 0, "x"), 1)).await.unwrap();
            fake.until(has_snap(1)).await;
            settle().await;
            fake.hold(true);
            tx.send((list("blocked", 1, "x"), 2)).await.unwrap();
            fake.until(|got| got.len() == 2).await;
            // n2 is on its way; 250 more make 251 cached: the 51 oldest (n2..n52) go.
            for seq in 2..=251 {
                tx.send((list("blocked", seq, "x"), 1 + seq)).await.unwrap();
            }
            settle().await;
            assert_eq!(stats.lock().unwrap().dropped, 51);
            fake.hold(false);
            fake.until(has_snap(253)).await;
            settle().await;
            let st = stats.lock().unwrap().clone();
            drop(tx);
            st
        };
        let (_, st) = tokio::join!(pump(me(), rx, dial.clone(), &log, &stats), drive);
        let got = fake.taken();
        let mut want = vec![1, 2];
        want.extend(53..=253);
        assert_eq!(ns(&got), want);
        assert!(got[0].get("gap").is_none());
        assert_eq!((got[202]["t"].as_str(), got[202]["gap"].as_bool()), (Some("snap"), Some(true)));
        assert_eq!(dial.times().len(), 1, "no reconnection");
        assert_eq!((st.dropped, st.sent, st.cached, st.up), (51, 203, 0, true));
        log.flush();
        let text = std::fs::read_to_string(dir.path().join("service.log")).unwrap();
        let dropped: Vec<Value> =
            text.lines().map(|l| serde_json::from_str::<Value>(l).unwrap()).filter(|l| l["ev"] == "outbox_dropped").collect();
        assert_eq!(dropped.len(), 1);
        assert_eq!(dropped[0]["count"], 51);
    }

    #[tokio::test(start_paused = true)]
    async fn a_drop_while_a_snap_is_on_its_way_is_told_by_the_next() {
        let fake = Fake::new("rapp-state");
        let dial = FakeDial::new(&fake, true);
        let (tx, rx) = mpsc::channel(16);
        let stats = Mutex::new(Stats::default());
        let log = Log::none();
        let drive = async {
            fake.hold(true);
            tx.send((list("idle", 0, "x"), 1)).await.unwrap();
            fake.until(|got| got.len() == 1).await;
            // The snap n1 is on its way, built with no gap; 201 changes drop one (n2).
            for seq in 1..=201 {
                tx.send((list("blocked", seq, "x"), 1 + seq)).await.unwrap();
            }
            settle().await;
            assert_eq!(stats.lock().unwrap().dropped, 1);
            fake.hold(false);
            fake.until(has_snap(203)).await;
            drop(tx);
        };
        tokio::join!(pump(me(), rx, dial.clone(), &log, &stats), drive);
        let got = fake.taken();
        let mut want = vec![1];
        want.extend(3..=203);
        assert_eq!(ns(&got), want);
        assert!(got[0].get("gap").is_none());
        assert_eq!((got[201]["t"].as_str(), got[201]["gap"].as_bool()), (Some("snap"), Some(true)));
        assert_eq!(dial.times().len(), 1);
    }

    #[tokio::test(start_paused = true)]
    async fn a_refused_snap_with_a_gap_is_not_sent_again() {
        let fake = Fake::new("rapp-state");
        let dial = FakeDial::new(&fake, false);
        let (tx, rx) = mpsc::channel(16);
        let stats = Mutex::new(Stats::default());
        let log = Log::none();
        let drive = async {
            tx.send((list("idle", 0, "x"), 1)).await.unwrap();
            for seq in 1..=201 {
                tx.send((list("blocked", seq, "x"), 1 + seq)).await.unwrap();
            }
            dial.dialled(1).await;
            // 4 batches taken, then the snap (gap:true) refused.
            fake.rules.lock().unwrap().statuses.extend([204, 204, 204, 204, 400]);
            dial.set_open(true);
            fake.until(|got| got.len() == 5).await;
            settle().await;
            tx.send((list("done", 202, "x"), 203)).await.unwrap();
            fake.until(|got| got.len() == 6).await;
            settle().await;
            let st = stats.lock().unwrap().clone();
            drop(tx);
            st
        };
        let (_, st) = tokio::join!(pump(me(), rx, dial.clone(), &log, &stats), drive);
        let all = fake.got.lock().unwrap().clone();
        assert_eq!(all.len(), 6, "the refused snap is not sent again");
        assert_eq!((all[4].status, all[4].lines[0]["t"].as_str(), all[4].lines[0]["gap"].as_bool()), (400, Some("snap"), Some(true)));
        assert_eq!(ns(&all[5].lines), [203]);
        assert_eq!((st.refused, st.dropped, st.up), (1, 1, true));
    }

    /// One pump run with `me` that takes one list and its snap; what the service took.
    async fn one_run(me: Me, state: &str, seq: u64) -> Vec<Value> {
        let fake = Fake::new("rapp-state");
        let dial = FakeDial::new(&fake, true);
        let (tx, rx) = mpsc::channel(16);
        let stats = Mutex::new(Stats::default());
        let log = Log::none();
        let drive = async {
            tx.send((list("idle", seq, "x"), seq)).await.unwrap();
            fake.until(|got| got.iter().any(|g| g.status / 100 == 2 && g.lines.iter().any(|l| l["t"] == "snap"))).await;
            tx.send((list(state, seq + 1, "x"), seq + 1)).await.unwrap();
            fake.until(|got| got.iter().any(|g| g.status / 100 == 2 && g.lines.iter().any(|l| l["t"] == "state"))).await;
            settle().await;
            drop(tx);
        };
        tokio::join!(pump(me, rx, dial.clone(), &log, &stats), drive);
        fake.taken()
    }

    /// Spec §6: one epoch per start of `rapp-service`, so a new run (the service turned off and on,
    /// a crash, another dest and back) goes on numbering where the last one stopped. From 1 again,
    /// the service would take every event as one it has seen.
    #[tokio::test(start_paused = true)]
    async fn a_second_run_numbers_on() {
        let me = me();
        let first = ns(&one_run(me.clone(), "working", 0).await);
        let second = ns(&one_run(me.clone(), "blocked", 5).await);
        assert_eq!(first.len(), 2, "{first:?}");
        assert_eq!(second.len(), 2, "{second:?}");
        assert!(second[0] > *first.last().unwrap(), "{first:?} then {second:?}");
        assert!(second.windows(2).all(|w| w[0] < w[1]), "{second:?}");
    }

    #[tokio::test(start_paused = true)]
    async fn the_log_has_no_event_text() {
        let dir = tempfile::tempdir().unwrap();
        let log = Log::file(dir.path(), "service.log");
        let (got, _) = three_changes(&log).await;
        assert!(got.iter().any(|l| l.to_string().contains("SECRET-TEXT")), "the text was sent");
        log.flush();
        let text = std::fs::read_to_string(dir.path().join("service.log")).unwrap();
        assert!(text.contains("outbox_up") && text.contains("outbox_down"), "{text}");
        assert!(!text.contains("SECRET-TEXT"), "{text}");
        assert!(!text.contains("term:pty:"), "{text}");
    }
}
