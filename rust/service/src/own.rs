//! This device's own shares on their share numbers: `localhost:<number>` here goes straight to
//! the shared port, so that the one address a share has on every other device works on the
//! sharer too. The numbers are listened on the same way visitors' maps are (both loopback
//! addresses), and a number another program already has is only reported, never fought for.

use crate::forward::{connect_local, local_addrs};
use crate::maps::listen;
use crate::shares::Share;
use std::collections::{HashMap, HashSet};
use std::sync::Mutex;
use tokio::net::TcpListener;
use tokio::task::JoinHandle;

/// What is listening for one share: its number, and one accept loop per loopback address.
type Held = (u16, Vec<JoinHandle<()>>);

/// This device's own shares served on their numbers.
pub struct Own {
    /// False: nothing is listened on (`Opts.own_ports`); `sync` does nothing and nothing is taken.
    on: bool,
    /// Per shared port: the number it is listened on, and the accept loops.
    held: Mutex<HashMap<u16, Held>>,
    /// The ports whose number another program had at the last `sync`.
    taken: Mutex<HashSet<u16>>,
    /// The (port, number) pairs `noted` has said so of, so a log line is not written on every sync.
    noted: Mutex<HashSet<(u16, u16)>>,
}

impl Own {
    /// `on` is `Opts.own_ports`: off for a test whose devices share one machine, where a visitor
    /// could otherwise never take a number the sharer is listening on.
    pub fn new(on: bool) -> Own {
        Own { on, held: Mutex::default(), taken: Mutex::default(), noted: Mutex::default() }
    }

    /// Listens on the number of every share that has one, and stops listening for the shares
    /// that are gone or have another number now. Returns the shares whose number another
    /// program has; each is tried again on the next `sync`.
    pub fn sync(&self, shares: &[Share]) -> Vec<Share> {
        if !self.on {
            return Vec::new();
        }
        let mut held = self.held.lock().unwrap();
        held.retain(|port, (local, tasks)| {
            let stays = shares.iter().any(|s| s.port == *port && s.local == Some(*local));
            if !stays {
                tasks.drain(..).for_each(|t| t.abort());
            }
            stays
        });
        let mut taken = Vec::new();
        for s in shares {
            let Some(local) = s.local else { continue };
            if held.contains_key(&s.port) {
                continue;
            }
            match listen(local) {
                Some(ls) => {
                    let tasks = ls.into_iter().map(|l| tokio::spawn(accept(l, s.port))).collect();
                    held.insert(s.port, (local, tasks));
                }
                None => taken.push(s.clone()),
            }
        }
        *self.taken.lock().unwrap() = taken.iter().map(|s| s.port).collect();
        taken
    }

    /// Whether another program had the number of the share of `port` at the last `sync`.
    pub fn taken(&self, port: u16) -> bool {
        self.taken.lock().unwrap().contains(&port)
    }

    /// True the first time it is asked of this share and number: the log says a number is taken
    /// once, not on every `sync`.
    pub fn first_taken(&self, port: u16, local: u16) -> bool {
        self.noted.lock().unwrap().insert((port, local))
    }

    /// Stops listening everywhere.
    pub fn stop(&self) {
        for (_, (_, tasks)) in self.held.lock().unwrap().drain() {
            tasks.into_iter().for_each(|t| t.abort());
        }
    }
}

/// The accept loop of one number: every connection is joined to the shared `port` of this device.
async fn accept(l: TcpListener, port: u16) {
    loop {
        let Ok((tcp, _)) = l.accept().await else {
            // Out of file descriptors, most likely: wait for some to come back.
            tokio::time::sleep(std::time::Duration::from_millis(100)).await;
            continue;
        };
        tokio::spawn(carry(tcp, port));
    }
}

/// Joins `tcp` to `port` of this device. When nothing answers there the connection is closed,
/// as a program that is not running would refuse it.
async fn carry(mut tcp: tokio::net::TcpStream, port: u16) {
    let Some(mut to) = connect_local(&local_addrs(port), crate::forward::LOCAL_CONNECT_WAIT).await else { return };
    let _ = tcp.set_nodelay(true);
    let _ = to.set_nodelay(true);
    let _ = tokio::io::copy_bidirectional(&mut tcp, &mut to).await;
}
