//! Local ports for other devices' shares: `localhost:<local>` on this device carries to the
//! `<port>` the device `<id>` shares, by the same road as `rapp pipe` (LAN, direct or relay).
//! Nothing outside rapp is set up for it: no resolver, no hosts file, no address on an interface.
//! The table is kept in `local/maps.json`, so an address stays the same across restarts.

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
}

struct Entry {
    map: Map,
    /// One accept loop per loopback address; empty while the port could not be listened on.
    tasks: Vec<JoinHandle<()>>,
}

/// What to do with a listener of a map: spawn its accept loop.
pub type Serve<'a> = &'a dyn Fn(TcpListener, Map) -> JoinHandle<()>;

pub struct Maps {
    path: PathBuf,
    first: u16,
    count: u16,
    items: Mutex<Vec<Entry>>,
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
        (Maps { path, first, count, items: Mutex::new(items) }, why)
    }

    /// The range the local ports are given from: the first one, and how many.
    pub fn range(&self) -> (u16, u16) {
        (self.first, self.count)
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
                Some(ls) => e.tasks = ls.into_iter().map(|l| serve(l, e.map.clone())).collect(),
                None => failed.push(e.map.clone()),
            }
        }
        if items.len() != before {
            self.save(&items);
        }
        failed
    }

    /// The local port that carries to `port` of the device `id`, listening: the one it already
    /// has, or the lowest free one of the range. None when the range has no port left.
    pub fn ensure(&self, id: &str, port: u16, serve: Serve) -> Option<u16> {
        let mut items = self.items.lock().unwrap();
        if let Some(i) = items.iter().position(|e| e.map.id == id && e.map.port == port) {
            let e = &mut items[i];
            if !e.tasks.is_empty() {
                return Some(e.map.local);
            }
            if let Some(ls) = listen(e.map.local) {
                e.tasks = ls.into_iter().map(|l| serve(l, e.map.clone())).collect();
                return Some(e.map.local);
            }
            // Another program has its port now: it gets a new one.
            items.remove(i);
        }
        let end = self.first.saturating_add(self.count.saturating_sub(1));
        for local in self.first..=end {
            if self.count == 0 || items.iter().any(|e| e.map.local == local) {
                continue;
            }
            let Some(ls) = listen(local) else { continue };
            let map = Map { id: id.to_string(), port, local };
            let tasks = ls.into_iter().map(|l| serve(l, map.clone())).collect();
            items.push(Entry { map, tasks });
            self.save(&items);
            return Some(local);
        }
        self.save(&items);
        None
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
        items.retain(|e| {
            let stays = keep(&e.map);
            if !stays {
                e.tasks.iter().for_each(JoinHandle::abort);
            }
            stays
        });
        if items.len() != before {
            self.save(&items);
        }
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

fn bind(addr: SocketAddr) -> std::io::Result<TcpListener> {
    let l = std::net::TcpListener::bind(addr)?;
    l.set_nonblocking(true)?;
    TcpListener::from_std(l)
}

/// The accept loop of a map's listener in the running service: every connection is carried to
/// the device's port.
pub fn serve(state: &Arc<State>) -> impl Fn(TcpListener, Map) -> JoinHandle<()> {
    let state = state.clone();
    move |l, map| {
        let state = state.clone();
        tokio::spawn(async move {
            loop {
                let Ok((tcp, _)) = l.accept().await else {
                    // Out of file descriptors, most likely: wait for some to come back.
                    tokio::time::sleep(Duration::from_millis(100)).await;
                    continue;
                };
                let (state, map) = (state.clone(), map.clone());
                tokio::spawn(async move { carry(&state, tcp, &map).await });
            }
        })
    }
}

/// Splices `tcp` with a forward to the map's port. When the forward cannot be had the
/// connection is closed, and the log says why.
async fn carry(state: &State, mut tcp: TcpStream, map: &Map) {
    let _ = tcp.set_nodelay(true);
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
    fn counting(n: Arc<AtomicUsize>) -> impl Fn(TcpListener, Map) -> JoinHandle<()> {
        move |l, _| {
            let n = n.clone();
            tokio::spawn(async move {
                while l.accept().await.is_ok() {
                    n.fetch_add(1, Ordering::SeqCst);
                }
            })
        }
    }

    fn quiet() -> impl Fn(TcpListener, Map) -> JoinHandle<()> {
        counting(Arc::default())
    }

    fn saved(home: &Path) -> Vec<Map> {
        serde_json::from_slice(&std::fs::read(home.join(FILE)).unwrap()).unwrap()
    }

    fn map(id: &str, port: u16, local: u16) -> Map {
        Map { id: id.into(), port, local }
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
        assert_eq!(maps.ensure("111111111", 8000, &serve), Some(29100));
        assert_eq!(maps.ensure("111111111", 22, &serve), Some(29101));
        assert_eq!(maps.ensure("222222222", 8000, &serve), Some(29102));
        assert_eq!(maps.ensure("111111111", 8000, &serve), Some(29100));
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
        let local = maps.ensure("111111111", 8000, &serve).unwrap();
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
            maps.ensure("111111111", 8000, &serve);
            maps.ensure("111111111", 22, &serve);
            maps.stop();
        }
        until("ports free again", || !connects(29120) && !connects(29121)).await;
        let (maps, why) = Maps::load(home.path(), 29120, 10);
        assert_eq!(why, None);
        assert_eq!(maps.start(Some(&["111111111".into()]), &serve), vec![]);
        assert!(connects(29120) && connects(29121));
        assert_eq!(maps.ensure("111111111", 22, &serve), Some(29121));
        assert_eq!(maps.ensure("111111111", 9000, &serve), Some(29122));
    }

    #[tokio::test]
    async fn a_port_another_program_has_is_skipped() {
        let home = tempfile::tempdir().unwrap();
        let _theirs = std::net::TcpListener::bind((Ipv4Addr::LOCALHOST, 29130)).unwrap();
        let (maps, _) = Maps::load(home.path(), 29130, 10);
        assert_eq!(maps.ensure("111111111", 8000, &quiet()), Some(29131));
    }

    #[tokio::test]
    async fn a_port_another_program_has_on_every_address_is_skipped() {
        let home = tempfile::tempdir().unwrap();
        let _theirs = std::net::TcpListener::bind((Ipv4Addr::UNSPECIFIED, 29140)).unwrap();
        let (maps, _) = Maps::load(home.path(), 29140, 10);
        assert_eq!(maps.ensure("111111111", 8000, &quiet()), Some(29141));
    }

    #[tokio::test]
    async fn a_map_whose_port_was_taken_while_stopped_moves() {
        let home = tempfile::tempdir().unwrap();
        write_json(&home.path().join(FILE), &vec![map("111111111", 8000, 29150), map("111111111", 22, 29151)]).unwrap();
        let _theirs = std::net::TcpListener::bind((Ipv4Addr::LOCALHOST, 29150)).unwrap();
        let (maps, _) = Maps::load(home.path(), 29150, 10);
        let serve = quiet();
        assert_eq!(maps.start(Some(&["111111111".into()]), &serve), vec![map("111111111", 8000, 29150)]);
        assert_eq!(maps.ensure("111111111", 22, &serve), Some(29151));
        assert_eq!(maps.ensure("111111111", 8000, &serve), Some(29152));
        assert_eq!(saved(home.path()), vec![map("111111111", 22, 29151), map("111111111", 8000, 29152)]);
    }

    #[tokio::test]
    async fn keep_drops_the_other_ports_of_the_device_and_frees_them() {
        let home = tempfile::tempdir().unwrap();
        let (maps, _) = Maps::load(home.path(), 29160, 10);
        let serve = quiet();
        maps.ensure("111111111", 8000, &serve);
        maps.ensure("111111111", 22, &serve);
        maps.ensure("222222222", 22, &serve);
        maps.keep("111111111", &[22]);
        let left = vec![map("111111111", 22, 29161), map("222222222", 22, 29162)];
        assert_eq!(maps.list(), left);
        assert_eq!(saved(home.path()), left);
        until("29160 is closed", || !connects(29160)).await;
        assert!(connects(29161) && connects(29162));
        // The freed port is the lowest free one again.
        assert_eq!(maps.ensure("222222222", 8000, &serve), Some(29160));
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
        maps.ensure("333333333", 1, &serve);
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
        assert_eq!(maps.ensure("111111111", 1, &serve), Some(29180));
        assert_eq!(maps.ensure("111111111", 2, &serve), Some(29181));
        assert_eq!(maps.ensure("111111111", 3, &serve), None);
        assert_eq!(maps.ensure("111111111", 2, &serve), Some(29181));
        let (none, _) = Maps::load(home.path(), 29190, 0);
        assert_eq!(none.ensure("111111111", 1, &serve), None);
        // The end of the port numbers is not run over.
        let (last, _) = Maps::load(tempfile::tempdir().unwrap().path(), 65535, 10);
        let got = last.ensure("111111111", 1, &serve);
        assert!(got == Some(65535) || got.is_none(), "{got:?}");
    }

    #[tokio::test]
    async fn an_unreadable_file_is_an_empty_table_and_is_written_over() {
        let home = tempfile::tempdir().unwrap();
        std::fs::write(home.path().join(FILE), "{ not json").unwrap();
        let (maps, why) = Maps::load(home.path(), 29200, 10);
        assert!(why.is_some());
        assert_eq!(maps.list(), vec![]);
        assert_eq!(maps.ensure("111111111", 8000, &quiet()), Some(29200));
        assert_eq!(saved(home.path()), vec![map("111111111", 8000, 29200)]);
    }

    #[tokio::test]
    async fn stop_closes_every_port_and_keeps_the_table() {
        let home = tempfile::tempdir().unwrap();
        let (maps, _) = Maps::load(home.path(), 29210, 10);
        maps.ensure("111111111", 8000, &quiet());
        maps.stop();
        until("29210 is closed", || !connects(29210)).await;
        assert_eq!(saved(home.path()), vec![map("111111111", 8000, 29210)]);
    }
}
