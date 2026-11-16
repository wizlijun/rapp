//! Forward pacing (spec §5.3): a delay-based rate controller. Pure logic, no clocks or I/O;
//! time comes in as the `now` argument.

use std::collections::VecDeque;
use std::future::Future;
use std::io;
use std::pin::Pin;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::task::{Context, Poll};
use std::time::{Duration, Instant};

use tokio::io::{AsyncRead, AsyncWrite, ReadBuf};
use tokio::sync::futures::OwnedNotified;
use tokio::sync::Notify;
use tokio::time::{sleep, Sleep};

/// How often the relay link steps the controller.
pub(crate) const TICK: Duration = Duration::from_millis(100);
/// Queueing (rtt - base) above this means the forward is in the way of sessions.
pub(crate) const TARGET: Duration = Duration::from_millis(10);
/// The rate never goes below this (bit/s).
pub(crate) const FLOOR_BPS: u64 = 256_000;
/// Stuck at the floor with queueing this long: the queue is not ours, rebase.
const REBASE_AFTER: Duration = Duration::from_secs(10);

pub(crate) struct Control {
    /// Minimum rtt seen since the connection began (rebased when stuck at the floor).
    base: Option<Duration>,
    /// Current allowed rate in bit/s; `None` when not pacing.
    rate: Option<u64>,
    /// When the rate last grew or was cut.
    last_change: Option<Instant>,
    /// Since when the rate has sat at the floor with queueing above target.
    stuck_since: Option<Instant>,
    /// Recent rtt samples, for the rebase minimum.
    recent: VecDeque<(Instant, Duration)>,
}

impl Control {
    pub(crate) fn new() -> Control {
        Control { base: None, rate: None, last_change: None, stuck_since: None, recent: VecDeque::new() }
    }

    pub(crate) fn base(&self) -> Option<Duration> {
        self.base
    }

    /// One control step. Returns the allowed rate (bit/s) while `pacing`, else `None`.
    pub(crate) fn step(&mut self, now: Instant, rtt: Duration, sent_bps: u64, pacing: bool) -> Option<u64> {
        self.base = Some(self.base.map_or(rtt, |b| b.min(rtt)));
        self.recent.push_back((now, rtt));
        while self.recent.front().is_some_and(|(t, _)| now.duration_since(*t) > REBASE_AFTER) {
            self.recent.pop_front();
        }
        if !pacing {
            self.rate = None;
            self.last_change = None;
            self.stuck_since = None;
            return None;
        }
        let Some(rate) = self.rate else {
            let start = sent_bps.max(FLOOR_BPS);
            self.rate = Some(start);
            self.last_change = Some(now);
            self.stuck_since = None;
            return Some(start);
        };
        let base = self.base.unwrap_or(rtt);
        let queue = rtt.saturating_sub(base);
        let due = self.last_change.is_none_or(|t| now.duration_since(t) >= rtt);
        let mut rate = rate;
        if queue > TARGET {
            if due {
                rate = (rate / 2).max(FLOOR_BPS);
                self.last_change = Some(now);
            }
        } else if due {
            let cap = (sent_bps / 4 * 5 + sent_bps % 4 * 5 / 4).max(FLOOR_BPS);
            rate = (rate + rate / 20).min(cap).max(FLOOR_BPS);
            self.last_change = Some(now);
        }
        if rate == FLOOR_BPS && queue > TARGET {
            let since = *self.stuck_since.get_or_insert(now);
            if now.duration_since(since) >= REBASE_AFTER {
                self.base = self.recent.iter().map(|(_, r)| *r).min();
                self.stuck_since = None;
            }
        } else {
            self.stuck_since = None;
        }
        self.rate = Some(rate);
        Some(rate)
    }
}

/// Smallest chunk worth waking up for.
const MIN_CHUNK: usize = 1024;
/// Bucket depth floor (bytes).
const MIN_DEPTH: f64 = 16.0 * 1024.0;
/// Measured send rate looks back this many ticks (about 1 s).
const SENT_WINDOW: usize = 10;

#[derive(Debug, PartialEq, Eq)]
pub(crate) enum PaceEvent {
    On { kbps: u64, base_ms: u64 },
    Off { kbps: u64, secs: u64 },
}

struct State {
    control: Control,
    rate: Option<u64>,
    /// Bucket fill in bytes and when it was last refilled.
    tokens: f64,
    last: tokio::time::Instant,
    /// (tick time, total bytes written) for the last `SENT_WINDOW` + 1 ticks.
    history: VecDeque<(Instant, u64)>,
    /// When pacing began, and the last rate, for the `Off` event.
    since: Option<Instant>,
    last_rate: u64,
}

fn depth(rate: u64) -> f64 {
    (rate as f64 / 8.0 * 0.005).max(MIN_DEPTH)
}

enum Take {
    /// Bytes allowed, and whether they were charged to the bucket.
    Go(usize, bool),
    Wait(Duration),
}

/// One per relay link: counts sessions, owns the single token bucket every wrapped forward
/// pipe shares, and steps the controller.
pub(crate) struct Pacer {
    enabled: bool,
    sessions: AtomicU64,
    sent: AtomicU64,
    notify: Arc<Notify>,
    state: Mutex<State>,
}

pub(crate) struct SessionGuard(Arc<Pacer>);

impl Drop for SessionGuard {
    fn drop(&mut self) {
        if self.0.sessions.fetch_sub(1, Ordering::SeqCst) == 1 {
            self.0.notify.notify_waiters();
        }
    }
}

impl Pacer {
    pub(crate) fn new(enabled: bool) -> Arc<Pacer> {
        Arc::new(Pacer {
            enabled,
            sessions: AtomicU64::new(0),
            sent: AtomicU64::new(0),
            notify: Arc::new(Notify::new()),
            state: Mutex::new(State {
                control: Control::new(),
                rate: None,
                tokens: 0.0,
                last: tokio::time::Instant::now(),
                history: VecDeque::new(),
                since: None,
                last_rate: 0,
            }),
        })
    }

    pub(crate) fn session(self: &Arc<Self>) -> SessionGuard {
        self.sessions.fetch_add(1, Ordering::SeqCst);
        SessionGuard(self.clone())
    }

    pub(crate) fn wrap(self: &Arc<Self>, pipe: rapp_conn::Pipe) -> rapp_conn::Pipe {
        if !self.enabled {
            return pipe;
        }
        Box::new(Paced { inner: pipe, pacer: self.clone(), wait: None })
    }

    #[cfg(test)]
    pub(crate) fn rate_bps(&self) -> Option<u64> {
        self.state.lock().unwrap().rate
    }

    /// A new relay connection: forget the base and the rate. `Some(Off)` when pacing was on, so
    /// every `On` is still paired with an `Off` across reconnects.
    pub(crate) fn reset(&self, now: Instant) -> Option<PaceEvent> {
        let mut st = self.state.lock().unwrap();
        let ev = st.rate.map(|_| PaceEvent::Off {
            kbps: st.last_rate / 1000,
            secs: st.since.map_or(0, |s| now.saturating_duration_since(s).as_secs()),
        });
        st.control = Control::new();
        st.rate = None;
        st.history.clear();
        st.since = None;
        ev
    }

    pub(crate) fn tick(&self, now: Instant, rtt: Duration) -> Option<PaceEvent> {
        if !self.enabled {
            return None;
        }
        let sessions = self.sessions.load(Ordering::SeqCst) > 0;
        let total = self.sent.load(Ordering::Relaxed);
        let mut st = self.state.lock().unwrap();
        st.history.push_back((now, total));
        while st.history.len() > SENT_WINDOW + 1 {
            st.history.pop_front();
        }
        let (t0, b0) = st.history[0];
        let secs = now.duration_since(t0).as_secs_f64();
        let sent_bps = if secs > 0.0 { ((total - b0) as f64 * 8.0 / secs) as u64 } else { 0 };
        let new = st.control.step(now, rtt, sent_bps, sessions);
        let was = st.rate;
        st.rate = new;
        match (was, new) {
            (None, Some(r)) => {
                st.tokens = depth(r);
                st.last = tokio::time::Instant::now();
                st.since = Some(now);
                st.last_rate = r;
                let base_ms = st.control.base().map_or(0, |b| b.as_millis() as u64);
                Some(PaceEvent::On { kbps: r / 1000, base_ms })
            }
            (Some(_), Some(r)) => {
                st.tokens = st.tokens.min(depth(r));
                st.last_rate = r;
                None
            }
            (Some(_), None) => {
                let secs = st.since.take().map_or(0, |s| now.duration_since(s).as_secs());
                Some(PaceEvent::Off { kbps: st.last_rate / 1000, secs })
            }
            (None, None) => None,
        }
    }

    #[cfg(test)]
    fn force_rate(&self, bps: u64) {
        let mut st = self.state.lock().unwrap();
        st.rate = Some(bps);
        st.tokens = depth(bps);
        st.last = tokio::time::Instant::now();
    }

    /// Give back tokens charged for bytes the inner pipe did not accept.
    fn refund(&self, n: usize) {
        if n == 0 {
            return;
        }
        let mut st = self.state.lock().unwrap();
        if let Some(rate) = st.rate {
            st.tokens = (st.tokens + n as f64).min(depth(rate));
        }
    }

    /// How many of `want` bytes may go now, or how long to wait for a worthwhile chunk.
    fn take(&self, want: usize) -> Take {
        let mut st = self.state.lock().unwrap();
        let rate = match st.rate {
            Some(r) if self.sessions.load(Ordering::SeqCst) > 0 => r,
            _ => return Take::Go(want, false),
        };
        let now = tokio::time::Instant::now();
        let per_sec = rate as f64 / 8.0;
        let dt = now.saturating_duration_since(st.last).as_secs_f64();
        st.last = now;
        st.tokens = (st.tokens + dt * per_sec).min(depth(rate));
        let need = want.min(MIN_CHUNK) as f64;
        if st.tokens >= need {
            let n = want.min(st.tokens as usize);
            st.tokens -= n as f64;
            Take::Go(n, true)
        } else {
            Take::Wait(Duration::from_secs_f64((need - st.tokens) / per_sec))
        }
    }
}

/// Sleep until the bucket has a chunk, or until the last session guard drops.
type Waiting = (Pin<Box<Sleep>>, Pin<Box<OwnedNotified>>);

struct Paced {
    inner: rapp_conn::Pipe,
    pacer: Arc<Pacer>,
    wait: Option<Waiting>,
}

impl AsyncRead for Paced {
    fn poll_read(mut self: Pin<&mut Self>, cx: &mut Context<'_>, buf: &mut ReadBuf<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut self.inner).poll_read(cx, buf)
    }
}

impl AsyncWrite for Paced {
    fn poll_write(mut self: Pin<&mut Self>, cx: &mut Context<'_>, buf: &[u8]) -> Poll<io::Result<usize>> {
        if buf.is_empty() {
            return Pin::new(&mut self.inner).poll_write(cx, buf);
        }
        loop {
            if let Some((sleep, notified)) = &mut self.wait {
                let woke = notified.as_mut().poll(cx).is_ready();
                if !sleep.as_mut().poll(cx).is_ready() && !woke {
                    return Poll::Pending;
                }
                self.wait = None;
            }
            let mut act = self.pacer.take(buf.len());
            if let Take::Wait(_) = act {
                // Register for the last-guard wake-up before looking again, so a drop
                // between the check and the wait is not lost.
                let mut notified = Box::pin(self.pacer.notify.clone().notified_owned());
                notified.as_mut().enable();
                act = self.pacer.take(buf.len());
                if let Take::Wait(d) = act {
                    self.wait = Some((Box::pin(sleep(d)), notified));
                    continue;
                }
            }
            let Take::Go(n, charged) = act else { unreachable!() };
            let r = Pin::new(&mut self.inner).poll_write(cx, &buf[..n]);
            let written = match &r {
                Poll::Ready(Ok(w)) => *w,
                _ => 0,
            };
            self.pacer.sent.fetch_add(written as u64, Ordering::Relaxed);
            if charged {
                self.pacer.refund(n - written);
            }
            return r;
        }
    }

    fn poll_flush(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut self.inner).poll_flush(cx)
    }

    fn poll_shutdown(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut self.inner).poll_shutdown(cx)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ms(n: u64) -> Duration {
        Duration::from_millis(n)
    }

    /// A control with the base fixed at 30 ms and pacing started at `sent`.
    fn started(t0: Instant, sent: u64) -> Control {
        let mut c = Control::new();
        assert_eq!(c.step(t0, ms(30), sent, true), Some(sent.max(FLOOR_BPS)));
        c
    }

    #[test]
    fn starts_at_the_sent_rate_with_a_floor() {
        let t0 = Instant::now();
        assert_eq!(Control::new().step(t0, ms(30), 10_000_000, true), Some(10_000_000));
        assert_eq!(Control::new().step(t0, ms(30), 0, true), Some(FLOOR_BPS));
    }

    #[test]
    fn halves_when_the_queue_passes_the_target_once_per_rtt() {
        let t0 = Instant::now();
        let mut c = started(t0, 10_000_000);
        assert_eq!(c.step(t0 + ms(100), ms(60), 10_000_000, true), Some(5_000_000));
        assert_eq!(c.step(t0 + ms(110), ms(60), 10_000_000, true), Some(5_000_000));
        assert_eq!(c.step(t0 + ms(170), ms(60), 10_000_000, true), Some(2_500_000));
    }

    #[test]
    fn grows_five_percent_per_rtt_up_to_a_cap() {
        let t0 = Instant::now();
        let mut c = started(t0, 4_000_000);
        assert_eq!(c.step(t0 + ms(32), ms(32), 4_000_000, true), Some(4_200_000));
        assert_eq!(c.step(t0 + ms(40), ms(32), 4_000_000, true), Some(4_200_000));
        assert_eq!(c.step(t0 + ms(64), ms(32), 4_000_000, true), Some(4_410_000));
        let mut last = 0;
        for i in 3..200u64 {
            last = c.step(t0 + ms(32 * i), ms(32), 4_000_000, true).unwrap();
            assert!(last <= 5_000_000);
        }
        assert_eq!(last, 5_000_000);
    }

    #[test]
    fn never_below_the_floor() {
        let t0 = Instant::now();
        let mut c = started(t0, 10_000_000);
        for i in 1..=200u64 {
            let r = c.step(t0 + TICK * i as u32, ms(130), 1_000_000, true).unwrap();
            assert!(r >= FLOOR_BPS);
        }
    }

    #[test]
    fn rebases_after_ten_seconds_stuck_at_the_floor() {
        let t0 = Instant::now();
        let mut c = started(t0, 10_000_000);
        let mut floor_at = None;
        let mut i = 1u64;
        while c.base() == Some(ms(30)) && i < 1000 {
            let now = t0 + TICK * i as u32;
            let r = c.step(now, ms(80), 1_000_000, true).unwrap();
            if r == FLOOR_BPS && floor_at.is_none() {
                floor_at = Some(now);
            }
            i += 1;
        }
        assert_eq!(c.base(), Some(ms(80)));
        let held = t0 + TICK * (i - 1) as u32 - floor_at.unwrap();
        assert!(held >= Duration::from_secs(10) && held < Duration::from_secs(11), "{held:?}");
        let now = t0 + TICK * i as u32;
        let r = c.step(now, ms(80), 1_000_000, true).unwrap();
        assert!(r > FLOOR_BPS, "grows after rebase: {r}");
    }

    #[test]
    fn base_is_the_minimum_since_new() {
        let t0 = Instant::now();
        let mut c = Control::new();
        c.step(t0, ms(40), 0, false);
        c.step(t0 + ms(100), ms(30), 0, false);
        c.step(t0 + ms(200), ms(35), 0, true);
        assert_eq!(c.base(), Some(ms(30)));
    }

    #[test]
    fn not_pacing_clears_the_rate() {
        let t0 = Instant::now();
        let mut c = started(t0, 10_000_000);
        c.step(t0 + ms(100), ms(60), 10_000_000, true);
        assert_eq!(c.step(t0 + ms(200), ms(30), 10_000_000, false), None);
        assert_eq!(c.base(), Some(ms(30)));
        assert_eq!(c.step(t0 + ms(300), ms(30), 3_000_000, true), Some(3_000_000));
    }

    // ---- Pacer ----
    use tokio::io::{duplex, AsyncWriteExt};
    use tokio::time::Instant as TInstant;

    fn pipe(pacer: &Arc<Pacer>) -> rapp_conn::Pipe {
        let (a, mut b) = duplex(1 << 20);
        tokio::spawn(async move {
            let _ = tokio::io::copy(&mut b, &mut tokio::io::sink()).await;
        });
        pacer.wrap(Box::new(a))
    }

    #[tokio::test(start_paused = true)]
    async fn no_session_writes_at_once() {
        let p = Pacer::new(true);
        p.force_rate(FLOOR_BPS);
        let mut w = pipe(&p);
        let t = TInstant::now();
        w.write_all(&vec![0u8; 4 << 20]).await.unwrap();
        assert!(t.elapsed() < ms(1));
        let g = p.session();
        drop(g);
        let t = TInstant::now();
        w.write_all(&vec![0u8; 4 << 20]).await.unwrap();
        assert!(t.elapsed() < ms(1));
    }

    #[tokio::test(start_paused = true)]
    async fn a_session_paces_to_the_rate() {
        let p = Pacer::new(true);
        let _g = p.session();
        p.force_rate(8_000_000);
        let mut w = pipe(&p);
        let t = TInstant::now();
        w.write_all(&vec![0u8; 1_000_000]).await.unwrap();
        let e = t.elapsed();
        assert!(e >= ms(950) && e <= ms(1050), "{e:?}");
    }

    #[tokio::test(start_paused = true)]
    async fn dropping_the_last_guard_wakes_a_waiting_write() {
        let p = Pacer::new(true);
        let g = p.session();
        p.force_rate(FLOOR_BPS);
        let mut w = pipe(&p);
        let t = TInstant::now();
        let writer = tokio::spawn(async move {
            w.write_all(&vec![0u8; 1 << 20]).await.unwrap();
            TInstant::now()
        });
        tokio::time::sleep(ms(100)).await;
        drop(g);
        let done = writer.await.unwrap();
        assert!(done.duration_since(t) <= ms(110), "{:?}", done.duration_since(t));
    }

    #[tokio::test(start_paused = true)]
    async fn backpressure_does_not_burn_tokens() {
        let p = Pacer::new(true);
        let _g = p.session();
        p.force_rate(8_000_000);
        let (a, _b) = duplex(4096); // nobody reads: the inner pipe fills and returns Pending
        let mut w = p.wrap(Box::new(a));
        let writer = tokio::spawn(async move {
            let _ = w.write_all(&vec![0u8; 100_000]).await;
        });
        tokio::time::sleep(ms(1)).await;
        let tokens = p.state.lock().unwrap().tokens;
        // 16 KiB bucket minus the 4 KiB actually written (plus a little refill), not ~0.
        assert!(tokens > 10_000.0, "{tokens}");
        assert_eq!(p.sent.load(Ordering::Relaxed), 4096);
        writer.abort();
    }

    #[tokio::test(start_paused = true)]
    async fn disabled_wraps_nothing() {
        let p = Pacer::new(false);
        let _g = p.session();
        let mut w = pipe(&p);
        let t = TInstant::now();
        w.write_all(&vec![0u8; 4 << 20]).await.unwrap();
        assert!(t.elapsed() < ms(1));
        assert_eq!(p.tick(Instant::now(), ms(30)), None);
        assert_eq!(p.rate_bps(), None);
    }

    #[tokio::test(start_paused = true)]
    async fn tick_reports_on_and_off_once() {
        let p = Pacer::new(true);
        let t0 = Instant::now();
        assert_eq!(p.tick(t0, ms(30)), None);
        let g = p.session();
        assert_eq!(p.tick(t0 + ms(100), ms(30)), Some(PaceEvent::On { kbps: 256, base_ms: 30 }));
        assert_eq!(p.tick(t0 + ms(200), ms(30)), None);
        drop(g);
        assert!(matches!(p.tick(t0 + ms(300), ms(30)), Some(PaceEvent::Off { kbps, .. }) if kbps >= 256));
        assert_eq!(p.tick(t0 + ms(400), ms(30)), None);
    }

    #[tokio::test(start_paused = true)]
    async fn reset_forgets_the_base() {
        let p = Pacer::new(true);
        let t0 = Instant::now();
        let _g = p.session();
        p.tick(t0, ms(30));
        assert!(p.rate_bps().is_some());
        assert_eq!(p.reset(t0 + ms(2500)), Some(PaceEvent::Off { kbps: 256, secs: 2 }));
        assert_eq!(p.rate_bps(), None);
        assert_eq!(p.reset(t0 + ms(2600)), None);
        assert_eq!(p.tick(t0 + ms(100), ms(80)), Some(PaceEvent::On { kbps: 256, base_ms: 80 }));
    }
}
