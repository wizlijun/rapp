//! The access record of forwarded connections (port-sharing spec §14): a `forward_open` line when
//! a connection opens and a `forward` line when it ends, for every connection or for the first of
//! each (device, port) plus a `forward_sum` every `SUM_EVERY`; refusals are rate-limited. Only
//! addresses, names, fingerprints, ports and byte counts are written.

use crate::state::Peer;
use rapp_net::log::{Log, Lvl};
use serde_json::json;
use std::collections::{HashMap, HashSet};
use std::sync::Mutex;
use std::time::{Duration, Instant};

/// How often the service writes the `forward_sum` lines.
pub const SUM_EVERY: Duration = Duration::from_secs(600);
/// At most one `forward_refused` line per (device, port, reason) in this time.
pub const REFUSED_EVERY: Duration = Duration::from_secs(60);
/// Above this many remembered refusals, the expired ones are dropped.
const REFUSED_KEEP: usize = 1024;

#[derive(Clone, Copy, PartialEq, Debug)]
pub enum Mode {
    Summary,
    Each,
}

impl Mode {
    /// `service.json`'s `forward_log`: "each" logs every connection; anything else is the summary.
    pub fn parse(s: Option<&str>) -> Mode {
        if s == Some("each") {
            Mode::Each
        } else {
            Mode::Summary
        }
    }
}

/// What one (device, port) did since the last flush.
struct Tally {
    peer: Peer,
    conns: u64,
    bytes_in: u64,
    bytes_out: u64,
}

#[derive(Default)]
struct Inner {
    /// The (device, port) pairs whose `forward_open` line was written since the last flush.
    opened: HashSet<(String, u16)>,
    tally: HashMap<(String, u16), Tally>,
    refused: HashMap<(String, Option<u16>, String), Instant>,
}

pub struct ForwardLog {
    log: Log,
    inner: Mutex<Inner>,
}

/// A device is told apart by its fingerprint, or by its address when it has none.
fn who(peer: &Peer) -> String {
    peer.fp.map_or_else(|| peer.addr.clone(), |f| f.to_string())
}

impl ForwardLog {
    pub fn new(log: Log) -> ForwardLog {
        ForwardLog { log, inner: Mutex::default() }
    }

    /// One forwarded connection opened: written at once, so an access is on record while the
    /// connection still runs (and when the service stops before it ends). `Each`: every
    /// connection; `Summary`: the first of its (device, port) since the last flush.
    pub fn opened(&self, mode: Mode, peer: &Peer, port: u16) {
        let first = match mode {
            Mode::Each => true,
            Mode::Summary => self.inner.lock().unwrap().opened.insert((who(peer), port)),
        };
        if first {
            let more = json!({"fp": peer.fp.map(|f| f.to_string()), "port": port});
            self.log.event(Lvl::Info, "forward_open", peer.fields(more));
        }
    }

    /// One forwarded connection ended. `bytes_in` came from the visiting device, `bytes_out` went to it.
    pub fn done(&self, mode: Mode, peer: &Peer, port: u16, secs: f64, bytes_in: u64, bytes_out: u64) {
        let first = match mode {
            Mode::Each => true,
            Mode::Summary => {
                let mut inner = self.inner.lock().unwrap();
                let t = inner.tally.entry((who(peer), port)).or_insert_with(|| Tally { peer: peer.clone(), conns: 0, bytes_in: 0, bytes_out: 0 });
                t.conns += 1;
                t.bytes_in += bytes_in;
                t.bytes_out += bytes_out;
                t.conns == 1
            }
        };
        if first {
            let more = json!({"fp": peer.fp.map(|f| f.to_string()), "port": port, "secs": secs, "bytes_in": bytes_in, "bytes_out": bytes_out});
            self.log.event(Lvl::Info, "forward", peer.fields(more));
        }
    }

    /// A request was refused. At most one line per (peer fp or addr, port, reason) per `REFUSED_EVERY`.
    pub fn refused(&self, peer: &Peer, port: Option<u16>, reason: &str) {
        self.refused_at(Instant::now(), peer, port, reason);
    }

    fn refused_at(&self, now: Instant, peer: &Peer, port: Option<u16>, reason: &str) {
        {
            let mut inner = self.inner.lock().unwrap();
            if inner.refused.len() >= REFUSED_KEEP {
                inner.refused.retain(|_, t| now.saturating_duration_since(*t) < REFUSED_EVERY);
            }
            let key = (who(peer), port, reason.to_string());
            if inner.refused.get(&key).is_some_and(|t| now.saturating_duration_since(*t) < REFUSED_EVERY) {
                return;
            }
            inner.refused.insert(key, now);
        }
        let mut more = json!({"reason": reason});
        if let Some(fp) = peer.fp {
            more["fp"] = json!(fp.to_string());
        }
        if let Some(p) = port {
            more["port"] = json!(p);
        }
        self.log.event(Lvl::Warn, "forward_refused", peer.fields(more));
    }

    /// Writes one `forward_sum` line per (device, port) whose connections ended since the last
    /// flush; from here on the next connection of a (device, port) is a first one again.
    pub fn flush(&self) {
        let tallies = {
            let mut inner = self.inner.lock().unwrap();
            inner.opened.clear();
            std::mem::take(&mut inner.tally)
        };
        let mut sums: Vec<_> = tallies.into_iter().collect();
        sums.sort_by(|a, b| a.0.cmp(&b.0));
        for ((_, port), t) in sums {
            let more = json!({"fp": t.peer.fp.map(|f| f.to_string()), "port": port, "conns": t.conns, "bytes_in": t.bytes_in, "bytes_out": t.bytes_out});
            self.log.event(Lvl::Info, "forward_sum", t.peer.fields(more));
        }
        self.log.flush();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use rapp_wire::Fp;
    use serde_json::{json, Value};
    use std::path::Path;

    fn peer(b: u8) -> Peer {
        Peer { addr: "1.2.3.4:5".into(), name: Some("mini".into()), path: "lan", fp: Some(Fp([b; 32])) }
    }

    fn fl(dir: &Path) -> ForwardLog {
        ForwardLog::new(Log::file(dir, "t.log"))
    }

    fn all(fl: &ForwardLog, dir: &Path) -> Vec<Value> {
        fl.log.flush();
        let mut v = rapp_net::log::read_recent(dir, "t.log", |_| true, 100);
        v.reverse();
        v
    }

    fn lines(fl: &ForwardLog, dir: &Path, ev: &str) -> Vec<Value> {
        all(fl, dir).into_iter().filter(|v| v["ev"] == ev).collect()
    }

    #[test]
    fn each_writes_one_line_per_connection() {
        let d = tempfile::tempdir().unwrap();
        let f = fl(d.path());
        f.done(Mode::Each, &peer(1), 8000, 1.5, 10, 20);
        f.done(Mode::Each, &peer(1), 8000, 0.5, 1, 2);
        let l = lines(&f, d.path(), "forward");
        assert_eq!(l.len(), 2);
        assert_eq!(l[0]["port"], 8000);
        assert_eq!(l[0]["bytes_in"], 10);
        assert_eq!(l[0]["bytes_out"], 20);
        assert_eq!(l[0]["fp"], Fp([1; 32]).to_string());
        assert_eq!(l[0]["peer"], "1.2.3.4:5");
        assert_eq!(l[0]["name"], "mini");
        assert_eq!(l[0]["path"], "lan");
        f.flush();
        assert!(lines(&f, d.path(), "forward_sum").is_empty());
    }

    #[test]
    fn summary_writes_the_first_at_once_and_the_rest_on_flush() {
        let d = tempfile::tempdir().unwrap();
        let f = fl(d.path());
        f.done(Mode::Summary, &peer(1), 8000, 1.0, 10, 20);
        f.done(Mode::Summary, &peer(1), 8000, 1.0, 100, 200);
        f.done(Mode::Summary, &peer(1), 8000, 1.0, 1000, 2000);
        f.done(Mode::Summary, &peer(2), 8000, 1.0, 5, 6);
        let first = lines(&f, d.path(), "forward");
        assert_eq!(first.len(), 2);
        assert_eq!(first[0]["fp"], Fp([1; 32]).to_string());
        assert_eq!(first[1]["fp"], Fp([2; 32]).to_string());
        assert!(lines(&f, d.path(), "forward_sum").is_empty());

        f.flush();
        let sums = lines(&f, d.path(), "forward_sum");
        assert_eq!(sums.len(), 2);
        let one = sums.iter().find(|s| s["fp"] == Fp([1; 32]).to_string()).unwrap();
        assert_eq!((one["conns"].as_u64(), one["bytes_in"].as_u64(), one["bytes_out"].as_u64()), (Some(3), Some(1110), Some(2220)));
        assert_eq!(one["port"], 8000);
        let two = sums.iter().find(|s| s["fp"] == Fp([2; 32]).to_string()).unwrap();
        assert_eq!(two["conns"], 1);

        f.flush();
        assert_eq!(lines(&f, d.path(), "forward_sum").len(), 2);

        f.done(Mode::Summary, &peer(1), 8000, 1.0, 1, 1);
        assert_eq!(lines(&f, d.path(), "forward").len(), 3);
    }

    #[test]
    fn each_writes_an_open_line_for_every_connection() {
        let d = tempfile::tempdir().unwrap();
        let f = fl(d.path());
        // (the log folds identical lines that follow each other, so the ports alternate)
        for port in [8000, 8001, 8000] {
            f.opened(Mode::Each, &peer(1), port);
        }
        let l = lines(&f, d.path(), "forward_open");
        assert_eq!(l.iter().map(|v| v["port"].as_u64().unwrap()).collect::<Vec<_>>(), [8000, 8001, 8000]);
        assert_eq!(l[0]["fp"], Fp([1; 32]).to_string());
        assert_eq!((&l[0]["peer"], &l[0]["name"], &l[0]["path"]), (&json!("1.2.3.4:5"), &json!("mini"), &json!("lan")));
        assert_eq!(l[0]["lvl"], "info");
        assert_eq!(l[0].as_object().unwrap().len(), 8, "{}", l[0]); // ts, ev, lvl, peer, name, path, fp, port
    }

    #[test]
    fn summary_writes_an_open_line_for_the_first_connection_since_the_last_flush() {
        let d = tempfile::tempdir().unwrap();
        let f = fl(d.path());
        let opens = |f: &ForwardLog| {
            let l = lines(f, d.path(), "forward_open");
            l.iter().map(|v| (v["fp"].as_str().unwrap()[..2].to_string(), v["port"].as_u64().unwrap())).collect::<Vec<_>>()
        };
        f.opened(Mode::Summary, &peer(1), 8000);
        // written at once: before that connection, or any other, has ended
        assert_eq!(opens(&f), [("01".to_string(), 8000)]);
        f.opened(Mode::Summary, &peer(1), 8000);
        f.opened(Mode::Summary, &peer(1), 8001); // another port
        f.opened(Mode::Summary, &peer(2), 8000); // another device
        f.opened(Mode::Summary, &peer(2), 8000);
        f.done(Mode::Summary, &peer(1), 8000, 1.0, 1, 2);
        f.opened(Mode::Summary, &peer(1), 8000); // a connection that ended does not make the next one a first
        assert_eq!(opens(&f), [("01".to_string(), 8000), ("01".to_string(), 8001), ("02".to_string(), 8000)]);

        f.flush();
        f.opened(Mode::Summary, &peer(1), 8000);
        f.opened(Mode::Summary, &peer(1), 8000);
        assert_eq!(opens(&f).len(), 4);
        assert_eq!(opens(&f)[3], ("01".to_string(), 8000));
        // `forward` and `forward_sum` are as before
        assert_eq!(lines(&f, d.path(), "forward").len(), 1);
        assert_eq!(lines(&f, d.path(), "forward_sum").len(), 1);
    }

    #[test]
    fn refusals_are_rate_limited_per_peer_port_and_reason() {
        let d = tempfile::tempdir().unwrap();
        let f = fl(d.path());
        let t0 = Instant::now();
        for i in 0..5 {
            f.refused_at(t0 + Duration::from_secs(i), &peer(1), Some(9), "not shared");
        }
        assert_eq!(lines(&f, d.path(), "forward_refused").len(), 1);
        f.refused_at(t0, &peer(1), Some(9), "not allowed");
        assert_eq!(lines(&f, d.path(), "forward_refused").len(), 2);
        f.refused_at(t0, &peer(2), Some(9), "not shared");
        assert_eq!(lines(&f, d.path(), "forward_refused").len(), 3);
        // after the interval the same refusal is written again
        f.refused_at(t0 + REFUSED_EVERY, &peer(1), Some(9), "not shared");
        assert_eq!(lines(&f, d.path(), "forward_refused").len(), 4);

        // a peer without a fingerprint is keyed by its address; different addresses are different peers
        let anon = |addr: &str| Peer { addr: addr.into(), name: None, path: "lan", fp: None };
        f.refused_at(t0, &anon("9.9.9.9:1"), None, "not supported");
        f.refused_at(t0, &anon("9.9.9.9:1"), None, "not supported");
        assert_eq!(lines(&f, d.path(), "forward_refused").len(), 5);
        f.refused_at(t0, &anon("8.8.8.8:1"), None, "not supported");
        let l = lines(&f, d.path(), "forward_refused");
        assert_eq!(l.len(), 6);
        let last = l.last().unwrap();
        assert!(last.get("fp").is_none() && last.get("port").is_none());
        assert_eq!(last["reason"], "not supported");
        assert_eq!(l[0]["fp"], Fp([1; 32]).to_string());
        assert_eq!(l[0]["port"], 9);
        assert_eq!(l[0]["reason"], "not shared");
    }

    #[test]
    fn nothing_secret_is_logged() {
        let d = tempfile::tempdir().unwrap();
        let f = fl(d.path());
        f.opened(Mode::Each, &peer(1), 8000);
        f.done(Mode::Each, &peer(1), 8000, 1.0, 1, 2);
        f.opened(Mode::Summary, &peer(2), 8000);
        f.done(Mode::Summary, &peer(2), 8000, 1.0, 1, 2);
        f.refused(&peer(1), Some(22), "not shared");
        f.flush();
        let l = all(&f, d.path());
        assert!(l.len() >= 6);
        for v in &l {
            for k in v.as_object().unwrap().keys() {
                let k = k.to_lowercase();
                assert!(!k.contains("key") && !k.contains("password"), "field {k}");
            }
        }
    }

    #[test]
    fn mode_parse() {
        assert_eq!(Mode::parse(Some("each")), Mode::Each);
        assert_eq!(Mode::parse(Some("summary")), Mode::Summary);
        assert_eq!(Mode::parse(Some("?")), Mode::Summary);
        assert_eq!(Mode::parse(None), Mode::Summary);
    }
}
