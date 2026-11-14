//! The network monitor (spec 2026-11-14-rapp-network-status §3.2, §5.1, §7): keeps the hub's
//! connection to the relay up while a relay and key are set, measures it, and pushes
//! `{"event":"net","level","rtt_ms","loss"}` to the GUI.
//!
//! Normally it sends nothing of its own: it reads the QUIC connection's counters once a second
//! (keep-alives every 10 s keep them fresh). It probes every 2 s (`RelayConn::probe`) while
//! something looks wrong: no datagram for 12 s, a request timed out (`net_suspect`), the local
//! addresses changed, the connection is new or redialing, or the level is weak or down; it stops
//! after 30 s at strong or ok.
//!
//! Three missed probes are down. The connection is not closed for that: a replacement is dialed
//! (backoff 1, 2, 4, 8, 10 s) and swapped in once it is through, so sessions on the old one live on
//! when the network comes back within QUIC's idle timeout. A connection that ended is dialed
//! anew on the same backoff; a dial not through after 2 s shows down. A refused key is not dialed
//! again (`Hub::relay`).

use crate::link::Cached;
use crate::upgrade::local_addrs;
use crate::Hub;
use anyhow::Result;
use rapp_conn::netq::{Level, Meter, Stall};
use rapp_conn::relay::RelayConn;
use rapp_net::log::Lvl;
use serde_json::{json, Value};
use std::net::Ipv4Addr;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tokio::task::JoinHandle;
use tokio::time::{interval, MissedTickBehavior};

const TICK: Duration = Duration::from_secs(1);
/// Fast probing: one probe this often, each waiting this long for its answer.
const PROBE_EVERY: Duration = Duration::from_secs(2);
const PROBE_WAIT: Duration = Duration::from_secs(2);
/// Fast probing ends after this long at strong or ok.
const CALM: Duration = Duration::from_secs(30);
/// While the level holds, a new round trip is pushed at most this often.
const EMIT_EVERY: Duration = Duration::from_secs(2);
const BACKOFF_FIRST: Duration = Duration::from_secs(1);
const BACKOFF_MAX: Duration = Duration::from_secs(10);
/// A dial waits up to 10 s itself; still not through after this long is down.
const DIAL_SLOW: Duration = Duration::from_secs(2);
const ENROLL_WAIT: Duration = Duration::from_secs(5);
/// The relay turned the enroll down (enrollment closed, a limit, a lockout): the next dial waits
/// this long, so a device the relay will not take does not knock every second.
const ENROLL_REFUSED_WAIT: Duration = Duration::from_secs(60);

/// What the monitor shares with the rest of the hub.
#[derive(Default)]
pub(crate) struct NetState {
    /// Something saw the relay not answer: probe now.
    suspect: AtomicBool,
    level: Mutex<Option<Level>>,
    /// The last `net` event pushed (None: none, or `none` was the last).
    last: Mutex<Option<Value>>,
}

impl Hub {
    /// A request to the relay timed out, or a session reports its path looks broken.
    pub(crate) fn net_suspect(&self) {
        self.net.suspect.store(true, Ordering::Release);
    }

    /// The level of the link to the relay; None when no relay is set or nothing is known yet.
    pub(crate) fn net_level(&self) -> Option<Level> {
        *self.net.level.lock().unwrap()
    }

    /// The `net` event as it stands now (`{"cmd":"net"}`).
    pub(crate) fn net_event(&self) -> Value {
        self.net.last.lock().unwrap().clone().unwrap_or_else(|| json!({"event":"net","level":"none"}))
    }
}

pub(crate) async fn run(hub: Arc<Hub>) {
    let mut tick = interval(TICK);
    tick.set_missed_tick_behavior(MissedTickBehavior::Delay);
    let mut m = Monitor::new(local_addrs());
    loop {
        tick.tick().await;
        m.step(&hub, Instant::now()).await;
    }
}

type Dial = JoinHandle<Result<Option<RelayConn>>>;

struct Monitor {
    meter: Meter,
    stall: Stall,
    fast: bool,
    calm_since: Option<Instant>,
    next_probe: Instant,
    next_dial: Instant,
    backoff: Duration,
    /// The connection being measured.
    conn: Option<RelayConn>,
    /// A dial in flight, since when, and the connection it is to replace (None: the cache had none).
    dialing: Option<(Dial, Instant, Option<RelayConn>)>,
    addrs: Vec<Ipv4Addr>,
    /// The local addresses changed: a miss of the next probe dials a replacement at once.
    recheck: bool,
    /// What was pushed last: level, rtt, loss, when.
    sent: Option<(Level, Option<u32>, f64, Instant)>,
}

impl Monitor {
    fn new(addrs: Vec<Ipv4Addr>) -> Monitor {
        let now = Instant::now();
        Monitor {
            meter: Meter::new(),
            stall: Stall::new(),
            fast: true,
            calm_since: None,
            next_probe: now,
            next_dial: now,
            backoff: BACKOFF_FIRST,
            conn: None,
            dialing: None,
            addrs,
            recheck: false,
            sent: None,
        }
    }

    async fn step(&mut self, hub: &Arc<Hub>, now: Instant) {
        let addrs = local_addrs();
        if addrs != self.addrs {
            self.addrs = addrs;
            self.wake(now);
            self.recheck = true;
            self.next_dial = now;
            self.backoff = BACKOFF_FIRST;
        }
        if hub.net.suspect.swap(false, Ordering::AcqRel) {
            self.wake(now);
        }
        self.dial_result(hub, now).await;
        match hub.relay_cached() {
            Cached::Unset => {
                self.unset(hub).await;
                return;
            }
            Cached::Busy => {}
            Cached::Refused => {
                self.conn = None;
                self.meter.down();
            }
            Cached::Gone => {
                self.conn = None;
                self.fast = true;
                if self.dialing.is_none() && now >= self.next_dial {
                    let h = hub.clone();
                    let dial = tokio::spawn(async move { Ok(h.relay().await?.map(|(c, _)| c)) });
                    self.dialing = Some((dial, now, None));
                }
            }
            Cached::Open(c) => {
                if self.conn.as_ref().map(RelayConn::id) != Some(c.id()) {
                    self.adopt(hub, c.clone(), now).await;
                }
                self.measure(hub, &c, now).await;
            }
        }
        if let Some((_, since, _)) = &self.dialing {
            if now.duration_since(*since) >= DIAL_SLOW && self.meter.level() != Some(Level::Down) {
                self.meter.down();
            }
        }
        self.calm(now);
        self.emit(hub, now).await;
    }

    /// Something looks wrong: probe now and every 2 s.
    fn wake(&mut self, now: Instant) {
        self.fast = true;
        self.calm_since = None;
        self.next_probe = self.next_probe.min(now);
    }

    async fn dial_result(&mut self, hub: &Arc<Hub>, now: Instant) {
        if !self.dialing.as_ref().is_some_and(|(d, ..)| d.is_finished()) {
            return;
        }
        let (dial, _, old) = self.dialing.take().unwrap();
        match dial.await {
            Ok(Ok(Some(c))) => match old {
                None => self.adopt(hub, c, now).await,
                // The old connection answered again meanwhile: it stays, with the sessions on it.
                Some(_) if self.meter.level() != Some(Level::Down) => c.close(),
                Some(old) => {
                    if hub.relay_swap(&old, &c).await {
                        self.adopt(hub, c, now).await;
                    }
                }
            },
            Ok(Ok(None)) => {}
            Ok(Err(e)) => {
                hub.log.msg(Lvl::Debug, format_args!("relay dial: {e:#}"));
                self.failed(now);
            }
            Err(_) => self.failed(now),
        }
    }

    /// A dial failed: down, and the next one after the backoff.
    fn failed(&mut self, now: Instant) {
        self.meter.down();
        self.next_dial = now + self.backoff;
        self.backoff = (self.backoff * 2).min(BACKOFF_MAX);
    }

    /// A new connection (ours, or one a request dialed): enrolled at once, or the relay's idle
    /// deadline for unenrolled connections closes it; measured at once. The backoff starts over
    /// only once the relay took the enroll: a connection it turns away must not reset it.
    async fn adopt(&mut self, hub: &Arc<Hub>, c: RelayConn, now: Instant) {
        self.conn = Some(c.clone());
        self.stall.reset();
        self.wake(now);
        match tokio::time::timeout(ENROLL_WAIT, c.ensure_enrolled()).await {
            Ok(Ok(())) => {
                self.backoff = BACKOFF_FIRST;
                self.next_dial = now;
            }
            Ok(Err(e)) => {
                hub.log.msg(Lvl::Warn, format_args!("relay enroll: {e:#}"));
                if rapp_conn::relay::relay_said_no(&e) {
                    self.meter.down();
                    self.next_dial = now + ENROLL_REFUSED_WAIT;
                } else {
                    self.failed(now);
                }
            }
            Err(_) => {
                hub.log.msg(Lvl::Warn, format_args!("relay enroll: timed out"));
                self.failed(now);
            }
        }
    }

    async fn measure(&mut self, hub: &Arc<Hub>, c: &RelayConn, now: Instant) {
        let st = c.stats();
        if self.stall.observe(now, st.rx_datagrams) && !self.fast {
            self.wake(now);
        }
        if !self.fast {
            self.meter.sample(now, st.rtt, st.lost, st.sent);
            return;
        }
        if now >= self.next_probe {
            self.next_probe = now + PROBE_EVERY;
            match c.probe(PROBE_WAIT).await {
                Ok(rtt) => {
                    let st = c.stats();
                    self.meter.sample(now, rtt, st.lost, st.sent);
                    self.recheck = false;
                }
                Err(_) => {
                    self.meter.miss();
                    if std::mem::take(&mut self.recheck) {
                        self.meter.down();
                        self.next_dial = now;
                    }
                }
            }
        }
        if self.meter.level() == Some(Level::Down) && self.dialing.is_none() && now >= self.next_dial {
            let (h, old) = (hub.clone(), c.clone());
            self.dialing = Some((tokio::spawn(async move { h.relay_fresh().await }), now, Some(old)));
        }
    }

    /// Fast probing ends after 30 s at strong or ok.
    fn calm(&mut self, now: Instant) {
        match self.meter.level() {
            Some(Level::Strong | Level::Ok) if self.fast => {
                let since = *self.calm_since.get_or_insert(now);
                if now.duration_since(since) >= CALM {
                    self.fast = false;
                    self.calm_since = None;
                }
            }
            _ => self.calm_since = None,
        }
    }

    /// No relay set (or it was taken out): nothing to measure; `none` once if a level was pushed.
    async fn unset(&mut self, hub: &Arc<Hub>) {
        if let Some((d, ..)) = self.dialing.take() {
            d.abort();
        }
        let was = self.sent.take().is_some();
        *self = Monitor { addrs: std::mem::take(&mut self.addrs), ..Monitor::new(Vec::new()) };
        *hub.net.level.lock().unwrap() = None;
        *hub.net.last.lock().unwrap() = None;
        if was {
            hub.emit(json!({"event":"net","level":"none"}), &None).await;
        }
    }

    /// Pushes the level when it changed, or the round trip at most every 2 s while it holds.
    async fn emit(&mut self, hub: &Arc<Hub>, now: Instant) {
        let level = self.meter.level();
        *hub.net.level.lock().unwrap() = level;
        let Some(level) = level else { return };
        let rtt = self.meter.rtt_ms();
        let loss = (self.meter.loss() * 1000.0).round() / 1000.0;
        let due = match self.sent {
            None => true,
            Some((l, ..)) if l != level => true,
            Some((_, r, lo, at)) => (r, lo) != (rtt, loss) && now.duration_since(at) >= EMIT_EVERY,
        };
        if !due {
            return;
        }
        self.sent = Some((level, rtt, loss, now));
        let mut ev = json!({"event":"net","level":level.as_str(),"loss":loss});
        if let Some(ms) = rtt {
            ev["rtt_ms"] = json!(ms);
        }
        *hub.net.last.lock().unwrap() = Some(ev.clone());
        hub.emit(ev, &None).await;
    }
}
