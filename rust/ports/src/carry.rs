//! Carrying a connection to a local port on to the device's port, and the placement of a
//! device's shares (`ensure_all`): the same on every device that has local ports.

use crate::maps::Maps;
use rapp_conn::Pipe;
use rapp_net::log::{Log, Lvl};
use serde_json::{json, Value};
use std::future::Future;
use std::sync::Arc;
use std::time::Duration;
use tokio::net::{TcpListener, TcpStream};
use tokio::task::JoinHandle;

/// What a device with local ports gives them: its table, its log, and the way to the device's
/// port (the service through its `Outbound`, the embedded hub through its own).
pub trait Carrier: Send + Sync + 'static {
    fn maps(&self) -> &Maps;
    fn log(&self) -> &Log;
    /// A forward to `port` of the device `id`; the error is the reason the log gives.
    fn open(&self, id: &str, port: u16) -> impl Future<Output = Result<Pipe, String>> + Send;
}

/// `ensure` for the shares `(port, wanted)` of the device `id`: away from `avoid` (numbers seen
/// on other devices, and `mine`, this device's own). A map that could not have its number
/// because a map that just moved still held it is asked again once that listener is closed, so
/// that two maps on each other's numbers both end on their own in one read.
pub async fn ensure_all<F>(maps: &Maps, id: &str, wants: &[(u16, Option<u16>)], avoid: &[u16], mine: &[u16], serve: &F) -> Vec<Option<u16>>
where
    F: Fn(TcpListener, u16) -> JoinHandle<()> + Sync,
{
    let ensure = |&(port, wanted): &(u16, Option<u16>)| maps.ensure(id, port, wanted, avoid, mine, serve);
    let mut got: Vec<Option<u16>> = wants.iter().map(ensure).collect();
    let yielded = |got: &[Option<u16>]| wants.iter().zip(got).any(|((_, w), g)| w.is_some() && g != w);
    if yielded(&got) && maps.closed().await {
        got = wants.iter().map(ensure).collect();
    }
    got
}

/// The accept loop of a map's listener: every connection is carried to the device's port of
/// the map that has `local` when it comes.
pub fn serve<C: Carrier>(c: Arc<C>) -> impl Fn(TcpListener, u16) -> JoinHandle<()> + Send + Sync + 'static {
    move |l, local| {
        let c = c.clone();
        tokio::spawn(async move {
            loop {
                let Ok((tcp, _)) = l.accept().await else {
                    // Out of file descriptors, most likely: wait for some to come back.
                    tokio::time::sleep(Duration::from_millis(100)).await;
                    continue;
                };
                let c = c.clone();
                tokio::spawn(async move { carry(&*c, tcp, local).await });
            }
        })
    }
}

/// Splices `tcp` with a forward to the port of the map on `local`. When there is no such map
/// any more, or the forward cannot be had, the connection is closed, and the log says why.
async fn carry<C: Carrier>(c: &C, mut tcp: TcpStream, local: u16) {
    let _ = tcp.set_nodelay(true);
    let Some(map) = c.maps().target(local) else {
        c.log().event(Lvl::Warn, "map_refused", json!({"local": local, "reason": "gone"}));
        return;
    };
    match c.open(&map.id, map.port).await {
        Ok(mut far) => {
            let _ = rapp_net::quic::splice(&mut tcp, &mut far).await;
        }
        Err(e) => {
            let fields = json!({"id": map.id, "port": map.port, "local": map.local, "reason": e});
            c.log().event(Lvl::Warn, "map_refused", fields);
        }
    }
}

/// The share number an item of another device's table carries; None from a sharer from before
/// numbers, or one that had no number to give.
pub fn number(item: &Value) -> Option<u16> {
    item["local"].as_u64()?.try_into().ok()
}

/// The share numbers of another device's table.
pub fn numbers(items: &[Value]) -> Vec<u16> {
    items.iter().filter_map(number).collect()
}

/// The shares of another device's table as `(port, number)`: the ones with a port.
pub fn wants(items: &[Value]) -> Vec<(u16, Option<u16>)> {
    items.iter().filter_map(|s| Some((port_of(&s["port"])?, number(s)))).collect()
}

fn port_of(v: &Value) -> Option<u16> {
    v.as_u64().and_then(|p| u16::try_from(p).ok()).filter(|&p| p != 0)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    /// Carries to an echo at the other end of a duplex, or refuses with `refuse`; remembers what it was asked.
    struct Fake {
        maps: Maps,
        log: Log,
        refuse: Option<String>,
        asked: Mutex<Vec<(String, u16)>>,
    }

    impl Carrier for Fake {
        fn maps(&self) -> &Maps {
            &self.maps
        }
        fn log(&self) -> &Log {
            &self.log
        }
        async fn open(&self, id: &str, port: u16) -> Result<Pipe, String> {
            self.asked.lock().unwrap().push((id.to_string(), port));
            if let Some(e) = &self.refuse {
                return Err(e.clone());
            }
            let (near, mut far) = tokio::io::duplex(1 << 12);
            tokio::spawn(async move {
                let mut buf = Vec::new();
                let _ = far.read_to_end(&mut buf).await;
                let _ = far.write_all(&buf).await;
                let _ = far.shutdown().await;
            });
            Ok(Box::new(near))
        }
    }

    fn fake(home: &std::path::Path, first: u16, refuse: Option<&str>) -> Arc<Fake> {
        let (maps, _) = Maps::load(home, first, 10);
        let log = Log::file(home, "t.log");
        Arc::new(Fake { maps, log, refuse: refuse.map(str::to_string), asked: Mutex::default() })
    }

    async fn exchange(local: u16, data: &[u8]) -> Vec<u8> {
        let mut c = TcpStream::connect(("127.0.0.1", local)).await.unwrap();
        c.write_all(data).await.unwrap();
        c.shutdown().await.unwrap();
        let mut got = Vec::new();
        let _ = c.read_to_end(&mut got).await;
        got
    }

    #[tokio::test]
    async fn a_connection_is_carried_to_the_maps_device_port() {
        let home = tempfile::tempdir().unwrap();
        let c = fake(home.path(), 29510, None);
        let serve = serve(c.clone());
        assert_eq!(c.maps.ensure("123456789", 8101, Some(29510), &[], &[], &serve), Some(29510));
        assert_eq!(exchange(29510, b"hi").await, b"hi");
        assert_eq!(*c.asked.lock().unwrap(), vec![("123456789".to_string(), 8101)]);
        c.maps.stop();
    }

    #[tokio::test]
    async fn a_refused_open_closes_the_connection_and_logs_map_refused() {
        let home = tempfile::tempdir().unwrap();
        let c = fake(home.path(), 29520, Some("not allowed"));
        let serve = serve(c.clone());
        assert_eq!(c.maps.ensure("123456789", 8101, Some(29521), &[], &[], &serve), Some(29521));
        assert_eq!(exchange(29521, b"hi").await, b"");
        c.log.flush();
        let text = std::fs::read_to_string(home.path().join("t.log")).unwrap();
        let ev: serde_json::Value = text.lines().map(|l| serde_json::from_str(l).unwrap()).find(|v: &serde_json::Value| v["ev"] == "map_refused").expect("map_refused logged");
        for (k, want) in [("id", json!("123456789")), ("port", json!(8101)), ("local", json!(29521)), ("reason", json!("not allowed"))] {
            assert_eq!(ev[k], want, "{ev}");
        }
        c.maps.stop();
    }

    #[test]
    fn wants_are_the_ports_with_their_numbers() {
        let items = vec![json!({"port": 8101, "local": 28001}), json!({"port": 22}), json!({"port": 0}), json!({"port": "x"})];
        assert_eq!(wants(&items), vec![(8101, Some(28001)), (22, None)]);
        assert_eq!(numbers(&items), vec![28001]);
    }
}
