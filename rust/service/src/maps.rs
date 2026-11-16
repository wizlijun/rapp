//! Local ports for other devices' shares: `localhost:<local>` on this device carries to the
//! `<port>` the device `<id>` shares, by the same road as `rapp pipe` (LAN, direct or relay).
//! Nothing outside rapp is set up for it: no resolver, no hosts file, no address on an interface.
//! The table is kept in `local/maps.json`, so an address stays the same across restarts.
//!
//! A share that has a share number is mapped onto that number, so that one address means the
//! same share on every device; when another program (or another map on its own number) has it
//! here, the map yields to another port and says which number it wanted.

use crate::state::State;
use rapp_net::config::write_json;
use rapp_net::log::Lvl;
use serde::{Deserialize, Serialize};
use serde_json::json;
use std::io::ErrorKind;
use std::net::{Ipv4Addr, Ipv6Addr, SocketAddr};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::net::{TcpListener, TcpStream};
use tokio::task::JoinHandle;

const FILE: &str = "maps.json";
/// The local ports given out: 28000-28999. Below the range the system picks outgoing ports from
/// (Linux from 32768, macOS and Windows from 49152), so a connection of another program does
/// not sit on one of them by chance.
pub const FIRST: u16 = 28000;
pub const COUNT: u16 = 1000;
/// How long a port is asked whether another program already answers on it.
const TAKEN_WAIT: Duration = Duration::from_millis(200);

/// `localhost:<local>` on this device is the `<port>` of the device `<id>`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Map {
    pub id: String,
    pub port: u16,
    pub local: u16,
    /// The share number the sharer gave the share (None: a sharer from before numbers). When it
    /// differs from `local` the map yielded, and moves back once the number is free here. Kept
    /// in the file so that a map on its own number is not moved out of the way by another.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub wanted: Option<u16>,
}

struct Entry {
    map: Map,
    /// One accept loop per loopback address; empty while the port could not be listened on.
    tasks: Vec<JoinHandle<()>>,
}

/// What to do with a listener on `local`: spawn its accept loop. Each connection asks
/// `Maps::target(local)` where it goes, so a map can change ports without a rebind.
pub type Serve<'a> = &'a dyn Fn(TcpListener, u16) -> JoinHandle<()>;

pub struct Maps {
    path: PathBuf,
    first: u16,
    count: u16,
    items: Mutex<Vec<Entry>>,
    /// Accept loops of ports a map left, aborted but maybe not yet dropped: their port is still
    /// bound until then, so taking it again waits for them (`closed`).
    closing: Mutex<Vec<JoinHandle<()>>>,
}

impl Maps {
    /// `home` is the device's `local/`. A missing file is an empty table. So is an unreadable
    /// one; the second field then carries why, and the first save writes over it (the file only
    /// remembers which port was given to what).
    pub fn load(home: &Path, first: u16, count: u16) -> (Maps, Option<String>) {
        let path = home.join(FILE);
        let (maps, why) = match std::fs::read(&path) {
            Ok(b) => match serde_json::from_slice::<Vec<Map>>(&b) {
                Ok(v) => (v, None),
                Err(e) => (Vec::new(), Some(e.to_string())),
            },
            Err(e) if e.kind() == ErrorKind::NotFound => (Vec::new(), None),
            Err(e) => (Vec::new(), Some(e.to_string())),
        };
        let items = maps.into_iter().map(|map| Entry { map, tasks: Vec::new() }).collect();
        (Maps { path, first, count, items: Mutex::new(items), closing: Mutex::default() }, why)
    }

    /// The range the local ports are given from: the first one, and how many.
    pub fn range(&self) -> (u16, u16) {
        (self.first, self.count)
    }

    /// The share number `wanted` if this device takes it: only one it could hand out itself.
    /// One outside the range (or 0) would sit on a port the user's own servers may need, so
    /// its sharer is treated as one from before numbers, and no number is said to be wanted.
    pub fn honoured(&self, wanted: Option<u16>) -> Option<u16> {
        wanted.filter(|&w| w != 0 && (self.first..self.first.saturating_add(self.count)).contains(&w))
    }

    /// Every map, in the order they were given out.
    pub fn list(&self) -> Vec<Map> {
        self.items.lock().unwrap().iter().map(|e| e.map.clone()).collect()
    }

    /// Listens for every map read from the file. A map of a device that is not in `known` is
    /// dropped (None: the device list could not be read, so every map stays). The maps whose
    /// port could not be listened on are returned; each gets another port the next time
    /// `ensure` is asked for it.
    pub fn start(&self, known: Option<&[String]>, serve: Serve) -> Vec<Map> {
        let mut items = self.items.lock().unwrap();
        let before = items.len();
        if let Some(known) = known {
            items.retain(|e| known.contains(&e.map.id));
        }
        let mut failed = Vec::new();
        for e in items.iter_mut().filter(|e| e.tasks.is_empty()) {
            match listen(e.map.local) {
                Some(ls) => e.tasks = spawn(ls, e.map.local, serve),
                None => failed.push(e.map.clone()),
            }
        }
        if items.len() != before {
            self.save(&items);
        }
        failed
    }

    /// The local port that carries to `port` of the device `id`, listening; None when the range
    /// has no port left. `wanted` is the share number the sharer gave it: it is taken when free
    /// here, so that the address is the same as on every other device; otherwise the map yields
    /// to a port that is not in `avoid` (numbers in use elsewhere) and not `wanted`. With no
    /// `wanted` (a sharer from before numbers) the map keeps the port it has, or gets the lowest
    /// free one that is not in `avoid`.
    ///
    /// `mine` are the numbers of this device's own shares (also in `avoid`). A `wanted` among
    /// them is one this device listens on for its own share (two sharers gave the same number),
    /// so the map yields straight away: no probe of it, and it is not taken in the moment that
    /// this device is not listening there (a number changing hands).
    #[allow(clippy::too_many_arguments)]
    pub fn ensure(&self, id: &str, port: u16, wanted: Option<u16>, avoid: &[u16], mine: &[u16], serve: Serve) -> Option<u16> {
        let mut items = self.items.lock().unwrap();
        let before: Vec<Map> = items.iter().map(|e| e.map.clone()).collect();
        let mut closing = Vec::new();
        let got = self.place(&mut items, id, port, wanted, avoid, mine, serve, &mut closing);
        if items.len() != before.len() || items.iter().zip(&before).any(|(e, m)| e.map != *m) {
            self.save(&items);
        }
        drop(items);
        self.let_go(closing);
        got
    }

    /// `ensure` on the locked table: the rules in order, the old listeners of a map that moves
    /// put in `closing`.
    #[allow(clippy::too_many_arguments)]
    fn place(&self, items: &mut Vec<Entry>, id: &str, port: u16, wanted: Option<u16>, avoid: &[u16], mine: &[u16], serve: Serve, closing: &mut Vec<JoinHandle<()>>) -> Option<u16> {
        let wanted = self.honoured(wanted);
        let at = items.iter().position(|e| e.map.id == id && e.map.port == port);
        if let Some(i) = at {
            items[i].map.wanted = wanted;
        }
        // This device's own share is on that number (or is about to be): yield without asking.
        if let Some(w) = wanted.filter(|w| !mine.contains(w)) {
            if let Some(i) = at.filter(|&i| items[i].map.local == w && !items[i].tasks.is_empty()) {
                return Some(items[i].map.local);
            }
            let other = (0..items.len()).find(|&i| Some(i) != at && items[i].map.local == w);
            match other {
                // Free here: the map moves to its number.
                None => {
                    if let Some(ls) = listen(w) {
                        let tasks = spawn(ls, w, serve);
                        put(items, at, Map { id: id.into(), port, local: w, wanted }, tasks, closing);
                        return Some(w);
                    }
                }
                // Another map sits on it but it is not that one's number (it yielded there, or
                // got it before numbers): it is moved out of the way, and the map takes over its
                // listeners, which carry for whoever `target` says.
                Some(j) if items[j].map.wanted != Some(w) && !items[j].tasks.is_empty() => {
                    if let Some((n, ls)) = self.lowest(items, avoid, Some(w)) {
                        let theirs = std::mem::replace(&mut items[j].tasks, spawn(ls, n, serve));
                        items[j].map.local = n;
                        put(items, at, Map { id: id.into(), port, local: w, wanted }, theirs, closing);
                        return Some(w);
                    }
                }
                // Another map on its own number: two sharers gave the same one, and the clash is
                // theirs to settle. This one yields.
                Some(_) => {}
            }
        }
        // Another program has the number, or there is none: the port the map has, while it
        // still listens there, or the lowest free one.
        if let Some(i) = at.filter(|&i| Some(items[i].map.local) != wanted) {
            let e = &mut items[i];
            if e.tasks.is_empty() {
                if let Some(ls) = listen(e.map.local) {
                    e.tasks = spawn(ls, e.map.local, serve);
                }
            }
            if !e.tasks.is_empty() {
                return Some(e.map.local);
            }
        }
        match self.lowest(items, avoid, wanted) {
            Some((local, ls)) => {
                let tasks = spawn(ls, local, serve);
                put(items, at, Map { id: id.into(), port, local, wanted }, tasks, closing);
                Some(local)
            }
            None => {
                // Another program has its port now, and there is no other: it has none.
                if let Some(i) = at {
                    closing.extend(items.remove(i).tasks);
                }
                None
            }
        }
    }

    /// The lowest port of the range that no map uses, that is not in `avoid` and not `wanted`,
    /// with its listeners.
    fn lowest(&self, items: &[Entry], avoid: &[u16], wanted: Option<u16>) -> Option<(u16, Vec<TcpListener>)> {
        let end = self.first.saturating_add(self.count.saturating_sub(1));
        (self.first..=end)
            .filter(|_| self.count > 0)
            .filter(|n| Some(*n) != wanted && !avoid.contains(n) && !items.iter().any(|e| e.map.local == *n))
            .find_map(|n| Some((n, listen(n)?)))
    }

    /// The map a connection to `local` is for: looked up when it is accepted, so that it goes to
    /// whichever map has the port now. None: no map has it any more.
    pub fn target(&self, local: u16) -> Option<Map> {
        self.items.lock().unwrap().iter().find(|e| e.map.local == local).map(|e| e.map.clone())
    }

    /// Aborts `tasks` and keeps them until they are dropped, for `closed`.
    fn let_go(&self, tasks: Vec<JoinHandle<()>>) {
        if tasks.is_empty() {
            return;
        }
        tasks.iter().for_each(JoinHandle::abort);
        let mut closing = self.closing.lock().unwrap();
        closing.retain(|t| !t.is_finished());
        closing.extend(tasks);
    }

    /// Waits until every listener a map left is closed, so that its port can be taken again.
    /// Whether there was any: none means asking again would change nothing.
    pub async fn closed(&self) -> bool {
        let tasks = std::mem::take(&mut *self.closing.lock().unwrap());
        let any = !tasks.is_empty();
        for t in tasks {
            let _ = t.await;
        }
        any
    }

    /// Drops the maps of the device `id` whose port is not in `ports`, and stops listening for them.
    pub fn keep(&self, id: &str, ports: &[u16]) {
        self.retain(|m| m.id != id || ports.contains(&m.port));
    }

    /// Drops the maps of every device that is not in `known`.
    pub fn keep_devices(&self, known: &[String]) {
        self.retain(|m| known.contains(&m.id));
    }

    fn retain(&self, keep: impl Fn(&Map) -> bool) {
        let mut items = self.items.lock().unwrap();
        let before = items.len();
        let mut gone = Vec::new();
        items.retain_mut(|e| {
            let stays = keep(&e.map);
            if !stays {
                gone.append(&mut e.tasks);
            }
            stays
        });
        if items.len() != before {
            self.save(&items);
        }
        drop(items);
        self.let_go(gone);
    }

    /// Stops listening everywhere; the table and the file stay.
    pub fn stop(&self) {
        for e in self.items.lock().unwrap().iter_mut() {
            e.tasks.drain(..).for_each(|t| t.abort());
        }
    }

    fn save(&self, items: &[Entry]) {
        let maps: Vec<&Map> = items.iter().map(|e| &e.map).collect();
        // Not saved: the ports are given out again in the same order after a restart, at worst differently.
        let _ = write_json(&self.path, &maps);
    }
}

/// No program answers on `local` of either loopback address. A program listening on every
/// address does not always stop a bind to one of them (macOS), so the port is asked, not bound.
pub fn free(local: u16) -> bool {
    let v4: SocketAddr = (Ipv4Addr::LOCALHOST, local).into();
    let v6: SocketAddr = (Ipv6Addr::LOCALHOST, local).into();
    ![v4, v6].iter().any(|a| std::net::TcpStream::connect_timeout(a, TAKEN_WAIT).is_ok())
}

/// Listeners on `local` of both loopback addresses (`localhost` may mean either). None when
/// the port is not free: another program answers on it, or holds it on one of the two.
pub(crate) fn listen(local: u16) -> Option<Vec<TcpListener>> {
    if !free(local) {
        return None;
    }
    let v4: SocketAddr = (Ipv4Addr::LOCALHOST, local).into();
    let v6: SocketAddr = (Ipv6Addr::LOCALHOST, local).into();
    let mut out = vec![bind(v4).ok()?];
    match bind(v6) {
        Ok(l) => out.push(l),
        Err(e) if e.kind() == ErrorKind::AddrInUse => return None,
        // No IPv6 loopback on this machine.
        Err(_) => {}
    }
    Some(out)
}

/// Puts `map` with its `tasks` at the end of the table, in place of the entry `at` when there is
/// one; that entry's listeners (on the port it leaves) go to `closing`.
fn put(items: &mut Vec<Entry>, at: Option<usize>, map: Map, tasks: Vec<JoinHandle<()>>, closing: &mut Vec<JoinHandle<()>>) {
    if let Some(i) = at {
        closing.extend(items.remove(i).tasks);
    }
    items.push(Entry { map, tasks });
}

/// The accept loops of `local`'s listeners.
fn spawn(ls: Vec<TcpListener>, local: u16, serve: Serve) -> Vec<JoinHandle<()>> {
    ls.into_iter().map(|l| serve(l, local)).collect()
}

fn bind(addr: SocketAddr) -> std::io::Result<TcpListener> {
    let l = std::net::TcpListener::bind(addr)?;
    l.set_nonblocking(true)?;
    TcpListener::from_std(l)
}

/// `ensure` for the shares `(port, wanted)` of the device `id`, in the running service: away
/// from the numbers seen on other devices and this device's own. A map that could not have its
/// number because a map that just moved still held it is asked again once that listener is
/// closed, so that two maps on each other's numbers both end on their own in one read.
pub async fn ensure_all(state: &Arc<State>, id: &str, wants: &[(u16, Option<u16>)]) -> Vec<Option<u16>> {
    let mine: Vec<u16> = state.shares.list().iter().filter_map(|s| s.local).collect();
    let mut avoid = state.numbers.seen();
    avoid.extend(&mine);
    let serve = serve(state);
    let ensure = |&(port, wanted): &(u16, Option<u16>)| state.maps.ensure(id, port, wanted, &avoid, &mine, &serve);
    let mut got: Vec<Option<u16>> = wants.iter().map(ensure).collect();
    let yielded = |got: &[Option<u16>]| wants.iter().zip(got).any(|((_, w), g)| w.is_some() && g != w);
    if yielded(&got) && state.maps.closed().await {
        got = wants.iter().map(ensure).collect();
    }
    got
}

/// The accept loop of a map's listener in the running service: every connection is carried to
/// the device's port of the map that has `local` when it comes.
pub fn serve(state: &Arc<State>) -> impl Fn(TcpListener, u16) -> JoinHandle<()> {
    let state = state.clone();
    move |l, local| {
        let state = state.clone();
        tokio::spawn(async move {
            loop {
                let Ok((tcp, _)) = l.accept().await else {
                    // Out of file descriptors, most likely: wait for some to come back.
                    tokio::time::sleep(Duration::from_millis(100)).await;
                    continue;
                };
                let state = state.clone();
                tokio::spawn(async move { carry(&state, tcp, local).await });
            }
        })
    }
}

/// Splices `tcp` with a forward to the port of the map on `local`. When there is no such map
/// any more, or the forward cannot be had, the connection is closed, and the log says why.
async fn carry(state: &State, mut tcp: TcpStream, local: u16) {
    let _ = tcp.set_nodelay(true);
    let Some(map) = state.maps.target(local) else {
        state.log.event(Lvl::Warn, "map_refused", json!({"local": local, "reason": "gone"}));
        return;
    };
    match crate::pipe::open(state, &map.id, map.port).await {
        Ok((mut far, _)) => {
            let _ = rapp_net::quic::splice(&mut tcp, &mut far).await;
        }
        Err(e) => {
            let fields = json!({"id": map.id, "port": map.port, "local": map.local, "reason": e.as_str()});
            state.log.event(Lvl::Warn, "map_refused", fields);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};

    /// A `Serve` that counts the connections its listeners accept.
    fn counting(n: Arc<AtomicUsize>) -> impl Fn(TcpListener, u16) -> JoinHandle<()> {
        move |l, _| {
            let n = n.clone();
            tokio::spawn(async move {
                while l.accept().await.is_ok() {
                    n.fetch_add(1, Ordering::SeqCst);
                }
            })
        }
    }

    fn quiet() -> impl Fn(TcpListener, u16) -> JoinHandle<()> {
        counting(Arc::default())
    }

    fn saved(home: &Path) -> Vec<Map> {
        serde_json::from_slice(&std::fs::read(home.join(FILE)).unwrap()).unwrap()
    }

    fn map(id: &str, port: u16, local: u16) -> Map {
        Map { id: id.into(), port, local, wanted: None }
    }

    async fn until(what: &str, pred: impl Fn() -> bool) {
        for _ in 0..200 {
            if pred() {
                return;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        panic!("never: {what}");
    }

    fn connects(local: u16) -> bool {
        std::net::TcpStream::connect_timeout(&(Ipv4Addr::LOCALHOST, local).into(), TAKEN_WAIT).is_ok()
    }

    // Each test has its own ports, so that they can run at the same time.

    #[tokio::test]
    async fn a_map_gets_the_lowest_free_port_and_keeps_it() {
        let home = tempfile::tempdir().unwrap();
        let (maps, why) = Maps::load(home.path(), 29100, 10);
        assert_eq!(why, None);
        let serve = quiet();
        assert_eq!(maps.ensure("111111111", 8000, None, &[], &[], &serve), Some(29100));
        assert_eq!(maps.ensure("111111111", 22, None, &[], &[], &serve), Some(29101));
        assert_eq!(maps.ensure("222222222", 8000, None, &[], &[], &serve), Some(29102));
        assert_eq!(maps.ensure("111111111", 8000, None, &[], &[], &serve), Some(29100));
        let all = vec![map("111111111", 8000, 29100), map("111111111", 22, 29101), map("222222222", 8000, 29102)];
        assert_eq!(maps.list(), all);
        assert_eq!(saved(home.path()), all);
    }

    #[tokio::test]
    async fn a_connection_to_the_local_port_reaches_the_map() {
        let home = tempfile::tempdir().unwrap();
        let (maps, _) = Maps::load(home.path(), 29110, 10);
        let n = Arc::new(AtomicUsize::new(0));
        let serve = counting(n.clone());
        let local = maps.ensure("111111111", 8000, None, &[], &[], &serve).unwrap();
        assert!(connects(local));
        until("accepted", || n.load(Ordering::SeqCst) == 1).await;
        if std::net::TcpStream::connect_timeout(&(Ipv6Addr::LOCALHOST, local).into(), TAKEN_WAIT).is_ok() {
            until("accepted on ::1", || n.load(Ordering::SeqCst) == 2).await;
        }
    }

    #[tokio::test]
    async fn the_same_ports_after_a_restart() {
        let home = tempfile::tempdir().unwrap();
        let serve = quiet();
        {
            let (maps, _) = Maps::load(home.path(), 29120, 10);
            maps.ensure("111111111", 8000, None, &[], &[], &serve);
            maps.ensure("111111111", 22, None, &[], &[], &serve);
            maps.stop();
        }
        until("ports free again", || !connects(29120) && !connects(29121)).await;
        let (maps, why) = Maps::load(home.path(), 29120, 10);
        assert_eq!(why, None);
        assert_eq!(maps.start(Some(&["111111111".into()]), &serve), vec![]);
        assert!(connects(29120) && connects(29121));
        assert_eq!(maps.ensure("111111111", 22, None, &[], &[], &serve), Some(29121));
        assert_eq!(maps.ensure("111111111", 9000, None, &[], &[], &serve), Some(29122));
    }

    #[tokio::test]
    async fn a_port_another_program_has_is_skipped() {
        let home = tempfile::tempdir().unwrap();
        let _theirs = std::net::TcpListener::bind((Ipv4Addr::LOCALHOST, 29130)).unwrap();
        let (maps, _) = Maps::load(home.path(), 29130, 10);
        assert_eq!(maps.ensure("111111111", 8000, None, &[], &[], &quiet()), Some(29131));
    }

    #[tokio::test]
    async fn a_port_another_program_has_on_every_address_is_skipped() {
        let home = tempfile::tempdir().unwrap();
        let _theirs = std::net::TcpListener::bind((Ipv4Addr::UNSPECIFIED, 29140)).unwrap();
        let (maps, _) = Maps::load(home.path(), 29140, 10);
        assert_eq!(maps.ensure("111111111", 8000, None, &[], &[], &quiet()), Some(29141));
    }

    #[tokio::test]
    async fn a_map_whose_port_was_taken_while_stopped_moves() {
        let home = tempfile::tempdir().unwrap();
        write_json(&home.path().join(FILE), &vec![map("111111111", 8000, 29150), map("111111111", 22, 29151)]).unwrap();
        let _theirs = std::net::TcpListener::bind((Ipv4Addr::LOCALHOST, 29150)).unwrap();
        let (maps, _) = Maps::load(home.path(), 29150, 10);
        let serve = quiet();
        assert_eq!(maps.start(Some(&["111111111".into()]), &serve), vec![map("111111111", 8000, 29150)]);
        assert_eq!(maps.ensure("111111111", 22, None, &[], &[], &serve), Some(29151));
        assert_eq!(maps.ensure("111111111", 8000, None, &[], &[], &serve), Some(29152));
        assert_eq!(saved(home.path()), vec![map("111111111", 22, 29151), map("111111111", 8000, 29152)]);
    }

    #[tokio::test]
    async fn keep_drops_the_other_ports_of_the_device_and_frees_them() {
        let home = tempfile::tempdir().unwrap();
        let (maps, _) = Maps::load(home.path(), 29160, 10);
        let serve = quiet();
        maps.ensure("111111111", 8000, None, &[], &[], &serve);
        maps.ensure("111111111", 22, None, &[], &[], &serve);
        maps.ensure("222222222", 22, None, &[], &[], &serve);
        maps.keep("111111111", &[22]);
        let left = vec![map("111111111", 22, 29161), map("222222222", 22, 29162)];
        assert_eq!(maps.list(), left);
        assert_eq!(saved(home.path()), left);
        until("29160 is closed", || !connects(29160)).await;
        assert!(connects(29161) && connects(29162));
        // The freed port is the lowest free one again.
        assert_eq!(maps.ensure("222222222", 8000, None, &[], &[], &serve), Some(29160));
    }

    #[tokio::test]
    async fn devices_that_are_not_known_lose_their_maps() {
        let home = tempfile::tempdir().unwrap();
        write_json(&home.path().join(FILE), &vec![map("111111111", 8000, 29170), map("222222222", 8000, 29171)]).unwrap();
        let (maps, _) = Maps::load(home.path(), 29170, 10);
        let serve = quiet();
        assert_eq!(maps.start(Some(&["222222222".into()]), &serve), vec![]);
        assert_eq!(saved(home.path()), vec![map("222222222", 8000, 29171)]);
        assert!(!connects(29170) && connects(29171));
        maps.ensure("333333333", 1, None, &[], &[], &serve);
        maps.keep_devices(&["333333333".into()]);
        assert_eq!(maps.list(), vec![map("333333333", 1, 29170)]);
        until("29171 is closed", || !connects(29171)).await;
    }

    #[tokio::test]
    async fn every_map_stays_when_the_device_list_cannot_be_read() {
        let home = tempfile::tempdir().unwrap();
        let both = vec![map("111111111", 8000, 29220), map("222222222", 8000, 29221)];
        write_json(&home.path().join(FILE), &both).unwrap();
        let (maps, _) = Maps::load(home.path(), 29220, 10);
        assert_eq!(maps.start(None, &quiet()), vec![]);
        assert_eq!(maps.list(), both);
        assert!(connects(29220) && connects(29221));
    }

    #[tokio::test]
    async fn free_says_whether_something_answers() {
        assert!(free(29230));
        let _theirs = std::net::TcpListener::bind((Ipv4Addr::LOCALHOST, 29230)).unwrap();
        assert!(!free(29230));
        let (maps, _) = Maps::load(tempfile::tempdir().unwrap().path(), 29231, 7);
        assert_eq!(maps.range(), (29231, 7));
    }

    #[tokio::test]
    async fn a_full_range_gives_none() {
        let home = tempfile::tempdir().unwrap();
        let (maps, _) = Maps::load(home.path(), 29180, 2);
        let serve = quiet();
        assert_eq!(maps.ensure("111111111", 1, None, &[], &[], &serve), Some(29180));
        assert_eq!(maps.ensure("111111111", 2, None, &[], &[], &serve), Some(29181));
        assert_eq!(maps.ensure("111111111", 3, None, &[], &[], &serve), None);
        assert_eq!(maps.ensure("111111111", 2, None, &[], &[], &serve), Some(29181));
        let (none, _) = Maps::load(home.path(), 29190, 0);
        assert_eq!(none.ensure("111111111", 1, None, &[], &[], &serve), None);
        // The end of the port numbers is not run over.
        let (last, _) = Maps::load(tempfile::tempdir().unwrap().path(), 65535, 10);
        let got = last.ensure("111111111", 1, None, &[], &[], &serve);
        assert!(got == Some(65535) || got.is_none(), "{got:?}");
    }

    #[tokio::test]
    async fn an_unreadable_file_is_an_empty_table_and_is_written_over() {
        let home = tempfile::tempdir().unwrap();
        std::fs::write(home.path().join(FILE), "{ not json").unwrap();
        let (maps, why) = Maps::load(home.path(), 29200, 10);
        assert!(why.is_some());
        assert_eq!(maps.list(), vec![]);
        assert_eq!(maps.ensure("111111111", 8000, None, &[], &[], &quiet()), Some(29200));
        assert_eq!(saved(home.path()), vec![map("111111111", 8000, 29200)]);
    }

    #[tokio::test]
    async fn stop_closes_every_port_and_keeps_the_table() {
        let home = tempfile::tempdir().unwrap();
        let (maps, _) = Maps::load(home.path(), 29210, 10);
        maps.ensure("111111111", 8000, None, &[], &[], &quiet());
        maps.stop();
        until("29210 is closed", || !connects(29210)).await;
        assert_eq!(saved(home.path()), vec![map("111111111", 8000, 29210)]);
    }

    fn wanting(id: &str, port: u16, local: u16, wanted: u16) -> Map {
        Map { id: id.into(), port, local, wanted: Some(wanted) }
    }

    // The ones below take a share number (`wanted`); 29400-29409 is taken by testkit's share_set.

    #[tokio::test]
    async fn a_wanted_number_is_used_when_free() {
        let home = tempfile::tempdir().unwrap();
        let (maps, _) = Maps::load(home.path(), 29440, 10);
        assert_eq!(maps.ensure("111111111", 8000, Some(29440), &[], &[], &quiet()), Some(29440));
        assert_eq!(saved(home.path()), vec![wanting("111111111", 8000, 29440, 29440)]);
        assert!(connects(29440));
    }

    #[tokio::test]
    async fn a_wanted_number_another_program_has_yields_past_avoided() {
        let home = tempfile::tempdir().unwrap();
        let theirs = std::net::TcpListener::bind((Ipv4Addr::LOCALHOST, 29450)).unwrap();
        let (maps, _) = Maps::load(home.path(), 29450, 10);
        let serve = quiet();
        assert_eq!(maps.ensure("111111111", 8000, Some(29450), &[29451], &[], &serve), Some(29452));
        assert_eq!(saved(home.path()), vec![wanting("111111111", 8000, 29452, 29450)]);
        // Asked again while the number is still taken: it stays where it yielded to.
        assert_eq!(maps.ensure("111111111", 8000, Some(29450), &[29451], &[], &serve), Some(29452));
        drop(theirs);
    }

    #[tokio::test]
    async fn a_yielded_map_moves_back_when_its_number_is_free() {
        let home = tempfile::tempdir().unwrap();
        let theirs = std::net::TcpListener::bind((Ipv4Addr::LOCALHOST, 29460)).unwrap();
        let (maps, _) = Maps::load(home.path(), 29460, 10);
        let serve = quiet();
        assert_eq!(maps.ensure("111111111", 8000, Some(29460), &[29461], &[], &serve), Some(29462));
        drop(theirs);
        assert_eq!(maps.ensure("111111111", 8000, Some(29460), &[29461], &[], &serve), Some(29460));
        assert_eq!(saved(home.path()), vec![wanting("111111111", 8000, 29460, 29460)]);
        assert_eq!(maps.target(29460).map(|m| m.port), Some(8000));
        assert_eq!(maps.target(29462), None);
        until("29462 stops answering", || !connects(29462)).await;
        assert!(connects(29460));
    }

    #[tokio::test]
    async fn a_map_on_its_own_number_is_not_moved() {
        let home = tempfile::tempdir().unwrap();
        let (maps, _) = Maps::load(home.path(), 29470, 10);
        let serve = quiet();
        assert_eq!(maps.ensure("111111111", 8000, Some(29470), &[], &[], &serve), Some(29470));
        assert_eq!(maps.ensure("333333333", 8000, Some(29470), &[], &[], &serve), Some(29471));
        assert_eq!(maps.ensure("111111111", 8000, Some(29470), &[], &[], &serve), Some(29470));
        assert_eq!(maps.list(), vec![wanting("111111111", 8000, 29470, 29470), wanting("333333333", 8000, 29471, 29470)]);
    }

    #[tokio::test]
    async fn two_maps_on_each_others_numbers_both_end_on_their_own() {
        let home = tempfile::tempdir().unwrap();
        write_json(&home.path().join(FILE), &vec![map("111111111", 8000, 29480), map("333333333", 5353, 29481)]).unwrap();
        let (maps, _) = Maps::load(home.path(), 29480, 10);
        let n = Arc::new(AtomicUsize::new(0));
        let serve = counting(n.clone());
        assert_eq!(maps.start(None, &serve), vec![]);
        assert_eq!(maps.ensure("111111111", 8000, Some(29481), &[], &[], &serve), Some(29481));
        // The listener A left is closed a moment later (its task is aborted, not yet dropped).
        maps.closed().await;
        assert_eq!(maps.ensure("333333333", 5353, Some(29480), &[], &[], &serve), Some(29480));
        assert_eq!(maps.target(29481).map(|m| m.id), Some("111111111".into()));
        assert_eq!(maps.target(29480).map(|m| m.id), Some("333333333".into()));
        assert_eq!(maps.list().len(), 2);
        // A took over C's listeners on 29481: they still accept.
        assert!(connects(29481) && connects(29480));
    }

    #[tokio::test]
    async fn a_map_of_an_old_sharer_avoids_seen_numbers() {
        let home = tempfile::tempdir().unwrap();
        let (maps, _) = Maps::load(home.path(), 29490, 10);
        assert_eq!(maps.ensure("111111111", 8000, None, &[29490, 29491], &[], &quiet()), Some(29492));
        assert_eq!(saved(home.path()), vec![map("111111111", 8000, 29492)]);
    }

    /// A wanted number that is this device's own share number (two sharers gave the same one)
    /// is not taken here even while nothing listens on it: this device's own share may be
    /// between listeners. The map yields at once, and one already on it moves off.
    #[tokio::test]
    async fn a_wanted_number_this_device_shares_on_is_never_taken() {
        let home = tempfile::tempdir().unwrap();
        let (maps, _) = Maps::load(home.path(), 29250, 10);
        let serve = quiet();
        assert!(free(29250));
        assert_eq!(maps.ensure("111111111", 8000, Some(29250), &[29250], &[29250], &serve), Some(29251));
        assert_eq!(saved(home.path()), vec![wanting("111111111", 8000, 29251, 29250)]);
        assert!(!connects(29250));
        // A map that sits on it already (from before this device shared on it) moves off.
        assert_eq!(maps.ensure("333333333", 8000, None, &[], &[], &serve), Some(29250));
        assert_eq!(maps.ensure("333333333", 8000, Some(29250), &[29250], &[29250], &serve), Some(29252));
        until("29250 is closed", || !connects(29250)).await;
    }

    /// A number outside this device's range is not one this device hands out, and 0 is no
    /// port at all: binding it would sit on a port the user's own server may want later. Such
    /// a map is placed as for a sharer from before numbers, and says it wanted nothing.
    #[tokio::test]
    async fn a_wanted_number_outside_the_range_is_ignored() {
        let home = tempfile::tempdir().unwrap();
        let (maps, _) = Maps::load(home.path(), 29580, 10);
        let serve = quiet();
        assert_eq!(maps.ensure("111111111", 8000, Some(5432), &[], &[], &serve), Some(29580));
        assert_eq!(maps.ensure("111111111", 8001, Some(0), &[], &[], &serve), Some(29581));
        assert_eq!(saved(home.path()), vec![map("111111111", 8000, 29580), map("111111111", 8001, 29581)]);
    }
}
